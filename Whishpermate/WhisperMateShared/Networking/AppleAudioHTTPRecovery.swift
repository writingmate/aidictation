import Foundation

/// The shared, deterministic recovery policy for Apple audio transcription uploads.
///
/// This type deliberately contains no recording or UI state. Callers own the source
/// audio and the attempt deadline; cancellation of the caller propagates through the
/// request, retry delay, and sequential 413 split traversal.
public enum AppleAudioHTTPRecovery {
    public typealias Checkpoint = (_ completedLeafIndex: Int, _ transcript: String) async throws -> Void

    public struct Policy: Sendable, Equatable {
        public let maximumAttempts: Int
        public let maximumRetryDelay: TimeInterval
        public let baseRetryDelay: TimeInterval
        public let maximumSplitDepth: Int

        public init(
            maximumAttempts: Int = 3,
            maximumRetryDelay: TimeInterval = 10,
            baseRetryDelay: TimeInterval = 0.5,
            maximumSplitDepth: Int = 6
        ) {
            self.maximumAttempts = min(3, max(1, maximumAttempts))
            self.maximumRetryDelay = min(10, max(0, maximumRetryDelay))
            self.baseRetryDelay = max(0, baseRetryDelay)
            self.maximumSplitDepth = min(6, max(0, maximumSplitDepth))
        }

        public static let standard = Policy()
    }

    public struct Response: Sendable, Equatable {
        public let statusCode: Int
        public let headers: [String: String]
        public let body: Data

        public init(statusCode: Int, headers: [String: String], body: Data) {
            self.statusCode = statusCode
            self.headers = headers.reduce(into: [:]) { result, pair in
                result[pair.key.lowercased()] = pair.value
            }
            self.body = body
        }

        public var contentType: String? {
            headers["content-type"]?
                .split(separator: ";", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        }
    }

    public enum Failure: Error, LocalizedError, Sendable, Equatable {
        case permanentHTTP(statusCode: Int)
        case payloadTooLarge
        case transientRetriesExhausted(statusCode: Int?)
        case invalidTranscriptionResponse
        case transportUnavailable
        case splitLimitReached

        public var errorDescription: String? {
            switch self {
            case .permanentHTTP(let statusCode):
                switch statusCode {
                case 401, 403:
                    return "Cloud transcription access was rejected. Check your account settings and try again."
                case 404:
                    return "Cloud transcription is not available at the configured address."
                case 400, 422:
                    return "This recording could not be accepted for transcription."
                default:
                    return "Cloud transcription could not complete this request."
                }
            case .payloadTooLarge, .splitLimitReached:
                return "This recording is too large to transcribe safely."
            case .transientRetriesExhausted, .transportUnavailable:
                return "Cloud transcription could not connect. Check your connection and try again."
            case .invalidTranscriptionResponse:
                return "Cloud transcription returned an unreadable result. Try again."
            }
        }
    }

    public struct SequentialResult: Sendable, Equatable {
        public let transcripts: [String]
        public let didSplitRejectedLeaf: Bool

        public init(transcripts: [String], didSplitRejectedLeaf: Bool) {
            self.transcripts = transcripts
            self.didSplitRejectedLeaf = didSplitRejectedLeaf
        }
    }

    public struct Segment: Sendable, Equatable {
        public let start: TimeInterval
        public let duration: TimeInterval

        public init(start: TimeInterval, duration: TimeInterval) {
            self.start = start
            self.duration = duration
        }
    }

    /// Produces contiguous ranges that cover the source through its exact end.
    /// A short final range is retained; silently dropping it can lose the final
    /// dictated token.
    public static func segments(
        sourceDuration: TimeInterval,
        maximumSegmentDuration: TimeInterval
    ) throws -> [Segment] {
        guard sourceDuration.isFinite,
              maximumSegmentDuration.isFinite,
              sourceDuration > 0,
              maximumSegmentDuration > 0 else {
            throw Failure.splitLimitReached
        }

        var result: [Segment] = []
        var start: TimeInterval = 0
        while start < sourceDuration {
            let end = min(sourceDuration, start + maximumSegmentDuration)
            guard end > start else { throw Failure.splitLimitReached }
            result.append(Segment(start: start, duration: end - start))
            start = end
        }
        return result
    }

    /// Accepts cleanup text only when the provider explicitly reports a normal
    /// stop. Token-limit or policy truncation must fall back to the already
    /// durable raw transcript instead of replacing it with a prefix.
    public static func completeChatContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let finishReason = firstChoice["finish_reason"] as? String,
              finishReason == "stop",
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw Failure.invalidTranscriptionResponse
        }

        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw Failure.invalidTranscriptionResponse }
        return result
    }

    /// Runs one HTTP leaf with the shared retry policy. A received 413 is returned
    /// immediately to the sequential leaf walker and never consumes retry attempts.
    public static func transcribe(
        policy: Policy = .standard,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) async throws -> Void = cancellationAwareSleep,
        request: (Int) async throws -> Response
    ) async throws -> String {
        var attempt = 1

        while true {
            try Task.checkCancellation()

            do {
                let response = try await request(attempt)
                try Task.checkCancellation()
                switch response.statusCode {
                case 200:
                    return try transcript(from: response)
                case 413:
                    throw Failure.payloadTooLarge
                case 408, 429, 500...599:
                    guard attempt < policy.maximumAttempts else {
                        throw Failure.transientRetriesExhausted(statusCode: response.statusCode)
                    }

                    let delay = retryDelay(
                        for: response,
                        attempt: attempt,
                        policy: policy,
                        now: now()
                    )
                    try Task.checkCancellation()
                    try await sleep(delay)
                    attempt += 1
                default:
                    throw Failure.permanentHTTP(statusCode: response.statusCode)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as Failure {
                throw failure
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard isTransientTransportFailure(error) else {
                    throw Failure.transportUnavailable
                }
                guard attempt < policy.maximumAttempts else {
                    throw Failure.transientRetriesExhausted(statusCode: nil)
                }

                let delay = exponentialDelay(attempt: attempt, policy: policy)
                try Task.checkCancellation()
                try await sleep(delay)
                attempt += 1
            }
        }
    }

    /// Processes leaves in source order. Only a leaf rejected with 413 is split;
    /// completed siblings are retained and never sent again.
    public static func transcribeSequentially<Leaf>(
        leaves: [Leaf],
        policy: Policy = .standard,
        transcribeLeaf: (Leaf, Int) async throws -> String,
        splitRejectedLeaf: (Leaf, Int) async throws -> [Leaf],
        cleanupSplitLeaves: ([Leaf]) -> Void = { _ in },
        checkpoint: Checkpoint? = nil
    ) async throws -> SequentialResult {
        var transcripts: [String] = []
        var didSplit = false

        func visit(_ leaf: Leaf, depth: Int) async throws {
            try Task.checkCancellation()

            let transcript: String
            do {
                transcript = try await transcribeLeaf(leaf, depth)
                try Task.checkCancellation()
            } catch Failure.payloadTooLarge {
                guard depth < policy.maximumSplitDepth else {
                    throw Failure.splitLimitReached
                }

                let children = try await splitRejectedLeaf(leaf, depth)
                guard children.count >= 2 else {
                    cleanupSplitLeaves(children)
                    throw Failure.splitLimitReached
                }

                didSplit = true
                defer { cleanupSplitLeaves(children) }
                for child in children {
                    try await visit(child, depth: depth + 1)
                }
                return
            }

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Failure.invalidTranscriptionResponse
            }

            try await checkpoint?(transcripts.count, trimmed)
            try Task.checkCancellation()
            transcripts.append(trimmed)
        }

        for leaf in leaves {
            try await visit(leaf, depth: 0)
        }
        try Task.checkCancellation()

        return SequentialResult(
            transcripts: transcripts,
            didSplitRejectedLeaf: didSplit
        )
    }

    public static func isTransientTransportFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }

        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .resourceUnavailable,
             .cannotLoadFromNetwork,
             .badServerResponse,
             .cannotDecodeRawData,
             .cannotDecodeContentData,
             .zeroByteResource,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .backgroundSessionInUseByAnotherProcess,
             .backgroundSessionWasDisconnected:
            return true
        case .cancelled:
            return false
        default:
            return false
        }
    }

    private static func transcript(from response: Response) throws -> String {
        guard let contentType = response.contentType else {
            throw Failure.invalidTranscriptionResponse
        }

        let text: String?
        if contentType == "text/plain" {
            text = String(data: response.body, encoding: .utf8)
        } else if contentType == "application/json" || contentType.hasSuffix("+json") {
            text = transcriptFromJSON(response.body)
        } else {
            text = nil
        }

        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            throw Failure.invalidTranscriptionResponse
        }

        return trimmed
    }

    private static func transcriptFromJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.count == 1
        else {
            return nil
        }

        if let text = dictionary["text"] as? String {
            return text
        }
        if let transcript = dictionary["transcript"] as? String {
            return transcript
        }
        return nil
    }

    private static func retryDelay(
        for response: Response,
        attempt: Int,
        policy: Policy,
        now: Date
    ) -> TimeInterval {
        if let value = response.headers["retry-after"],
           let retryAfter = parseRetryAfter(value, now: now)
        {
            return min(policy.maximumRetryDelay, max(0, retryAfter))
        }
        return exponentialDelay(attempt: attempt, policy: policy)
    }

    private static func exponentialDelay(attempt: Int, policy: Policy) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let delay = policy.baseRetryDelay * pow(2, Double(exponent))
        return min(policy.maximumRetryDelay, delay)
    }

    private static func parseRetryAfter(_ value: String, now: Date) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds.isFinite {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return date.timeIntervalSince(now)
    }

    public static func cancellationAwareSleep(_ delay: TimeInterval) async throws {
        guard delay > 0 else {
            try Task.checkCancellation()
            return
        }

        let nanoseconds = UInt64(min(delay, 10) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
