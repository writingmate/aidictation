import Darwin
import Foundation

private enum BoundaryServerError: Error, Sendable {
    case setupFailed(Int32)
}

private final class HTTPBoundaryState: @unchecked Sendable {
    enum Scenario: Sendable {
        case stalled(statusCode: Int)
        case disconnectTwiceThenSucceed
        case oversizedSuccess(contentLength: Int)
    }

    private let lock = NSLock()
    private var scenario: Scenario = .stalled(statusCode: 500)
    private var requestCount = 0

    func configure(_ scenario: Scenario) {
        lock.lock()
        self.scenario = scenario
        requestCount = 0
        lock.unlock()
    }

    func nextRequest() -> (scenario: Scenario, attempt: Int) {
        lock.lock()
        requestCount += 1
        let snapshot = (scenario, requestCount)
        lock.unlock()
        return snapshot
    }

    func attempts() -> Int {
        lock.lock()
        let snapshot = requestCount
        lock.unlock()
        return snapshot
    }
}

private final class HTTPBoundaryServer: @unchecked Sendable {
    let state = HTTPBoundaryState()
    let url: URL

    private let lifecycleLock = NSLock()
    private let listeningSocket: Int32
    private var isStopped = false

    init() throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw BoundaryServerError.setupFailed(errno)
        }

        var reuseAddress: Int32 = 1
        guard setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let setupError = errno
            Darwin.close(socketDescriptor)
            throw BoundaryServerError.setupFailed(setupError)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    socketDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(socketDescriptor, 8) == 0 else {
            let setupError = errno
            Darwin.close(socketDescriptor)
            throw BoundaryServerError.setupFailed(setupError)
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(socketDescriptor, socketAddress, &addressLength)
            }
        }
        guard nameResult == 0 else {
            let setupError = errno
            Darwin.close(socketDescriptor)
            throw BoundaryServerError.setupFailed(setupError)
        }

        listeningSocket = socketDescriptor
        let port = UInt16(bigEndian: address.sin_port)
        guard let url = URL(string: "http://127.0.0.1:\(port)/transcribe") else {
            Darwin.close(socketDescriptor)
            throw BoundaryServerError.setupFailed(EINVAL)
        }
        self.url = url

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            acceptConnections()
        }
    }

    func stop() {
        lifecycleLock.lock()
        guard !isStopped else {
            lifecycleLock.unlock()
            return
        }
        isStopped = true
        lifecycleLock.unlock()
        Darwin.shutdown(listeningSocket, SHUT_RDWR)
        Darwin.close(listeningSocket)
    }

    private func acceptConnections() {
        while true {
            let clientSocket = Darwin.accept(listeningSocket, nil, nil)
            guard clientSocket >= 0 else { return }
            let requestSnapshot = state.nextRequest()
            DispatchQueue.global(qos: .userInitiated).async {
                Self.serve(clientSocket, request: requestSnapshot)
            }
        }
    }

    private static func serve(
        _ clientSocket: Int32,
        request: (scenario: HTTPBoundaryState.Scenario, attempt: Int)
    ) {
        defer { Darwin.close(clientSocket) }

        var noSignal: Int32 = 1
        _ = setsockopt(
            clientSocket,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var noDelay: Int32 = 1
        _ = setsockopt(
            clientSocket,
            IPPROTO_TCP,
            TCP_NODELAY,
            &noDelay,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var receiveTimeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(
            clientSocket,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var requestBytes = [UInt8](repeating: 0, count: 4_096)
        _ = requestBytes.withUnsafeMutableBytes { buffer in
            Darwin.recv(clientSocket, buffer.baseAddress, buffer.count, 0)
        }

        switch request.scenario {
        case .stalled(let statusCode):
            let reason = statusCode == 413 ? "Payload Too Large" : (statusCode == 200 ? "OK" : "Bad Request")
            sendResponse(
                socket: clientSocket,
                statusCode: statusCode,
                reason: reason,
                contentLength: 2_048,
                body: Data(repeating: 0x78, count: 1_024)
            )
            waitForCancellation(on: clientSocket)
        case .oversizedSuccess(let contentLength):
            sendResponse(
                socket: clientSocket,
                statusCode: 200,
                reason: "OK",
                contentLength: contentLength,
                body: Data(repeating: 0x78, count: 1_024)
            )
            waitForCancellation(on: clientSocket)
        case .disconnectTwiceThenSucceed:
            let completedBody = Data(String(repeating: "r", count: 2_048).utf8)
            if request.attempt < 3 {
                sendResponse(
                    socket: clientSocket,
                    statusCode: 200,
                    reason: "OK",
                    contentLength: completedBody.count,
                    body: Data(repeating: 0x70, count: 1_024)
                )
            } else {
                sendResponse(
                    socket: clientSocket,
                    statusCode: 200,
                    reason: "OK",
                    contentLength: completedBody.count,
                    body: completedBody
                )
            }
        }
    }

    private static func sendResponse(
        socket: Int32,
        statusCode: Int,
        reason: String,
        contentLength: Int,
        body: Data
    ) {
        let headerText =
            "HTTP/1.1 \(statusCode) \(reason)\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: \(contentLength)\r\n" +
            "Retry-After: 7\r\n" +
            "X-AIDictation-Request-ID: boundary-test\r\n" +
            "Connection: close\r\n\r\n"
        let headers = Data(headerText.utf8)
        sendAll(headers, to: socket)
        sendAll(body, to: socket)
    }

    private static func sendAll(_ data: Data, to socket: Int32) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let byteCount = Darwin.send(
                    socket,
                    baseAddress.advanced(by: sent),
                    buffer.count - sent,
                    0
                )
                guard byteCount > 0 else { return }
                sent += byteCount
            }
        }
    }

    private static func waitForCancellation(on socket: Int32) {
        var bytes = [UInt8](repeating: 0, count: 256)
        while bytes.withUnsafeMutableBytes({ buffer in
            Darwin.recv(socket, buffer.baseAddress, buffer.count, 0)
        }) > 0 {}
    }
}

private enum ValidationError: Error, CustomStringConvertible, Sendable {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private enum CheckpointError: Error {
    case persistenceFailed
}

private actor StringLog {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private actor HeaderLog {
    private var headers: [String: String] = [:]

    func record(_ headers: [String: String]) {
        self.headers = headers
    }

    func snapshot() -> [String: String] {
        headers
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationError.failed(message) }
}

private func completeWithin<T: Sendable>(
    _ label: String,
    _ timeoutNanoseconds: UInt64 = 2_000_000_000,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw ValidationError.failed("Transport-boundary check timed out: \(label)")
        }

        guard let result = try await group.next() else {
            throw ValidationError.failed("A transport-boundary check did not run")
        }
        return result
    }
}

private func textResponse(
    _ status: Int,
    text: String = "kept transcript",
    headers: [String: String] = [:]
) -> AppleAudioHTTPRecovery.Response {
    var responseHeaders = headers
    responseHeaders["Content-Type"] = responseHeaders["Content-Type"] ?? "text/plain; charset=utf-8"
    return AppleAudioHTTPRecovery.Response(
        statusCode: status,
        headers: responseHeaders,
        body: Data(text.utf8)
    )
}

private func expectFailure(
    _ expected: AppleAudioHTTPRecovery.Failure,
    operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        throw ValidationError.failed("Expected \(expected), but operation succeeded")
    } catch let failure as AppleAudioHTTPRecovery.Failure {
        try require(failure == expected, "Expected \(expected), got \(failure)")
    }
}

private func validatePermanentStatuses() async throws {
    let permanentClientStatuses = (400...499).filter {
        $0 != 408 && $0 != 413 && $0 != 429
    }
    for status in [202, 206] + permanentClientStatuses {
        var attempts = 0
        var sleeps = 0
        try await expectFailure(.permanentHTTP(statusCode: status)) {
            _ = try await AppleAudioHTTPRecovery.transcribe(
                sleep: { _ in sleeps += 1 },
                request: { _ in
                    attempts += 1
                    return textResponse(status)
                }
            )
        }
        try require(attempts == 1, "HTTP \(status) was retried")
        try require(sleeps == 0, "HTTP \(status) slept before failing")
    }
}

private func validateTransientStatusTable() async throws {
    let bounded = AppleAudioHTTPRecovery.Policy(
        maximumAttempts: 99,
        maximumRetryDelay: 99,
        maximumSplitDepth: 99
    )
    try require(bounded.maximumAttempts == 3, "Retry policy can exceed three attempts")
    try require(bounded.maximumRetryDelay == 10, "Retry delay can exceed ten seconds")
    try require(bounded.maximumSplitDepth == 6, "413 recursion can exceed its depth bound")

    for status in [408, 429, 500, 503, 599] {
        var attempts = 0
        var delays: [TimeInterval] = []
        let result = try await AppleAudioHTTPRecovery.transcribe(
            sleep: { delays.append($0) },
            request: { _ in
                attempts += 1
                if attempts < 3 {
                    return textResponse(status)
                }
                return textResponse(200, text: "attempt three")
            }
        )
        try require(result == "attempt three", "HTTP \(status) did not recover")
        try require(attempts == 3, "HTTP \(status) used \(attempts) attempts")
        try require(delays == [0.5, 1.0], "HTTP \(status) used unexpected delays \(delays)")
    }

    var attempts = 0
    var delays: [TimeInterval] = []
    try await expectFailure(.transientRetriesExhausted(statusCode: 503)) {
        _ = try await AppleAudioHTTPRecovery.transcribe(
            sleep: { delays.append($0) },
            request: { _ in
                attempts += 1
                return textResponse(503)
            }
        )
    }
    try require(attempts == 3, "Transient exhaustion did not stop after three attempts")
    try require(delays == [0.5, 1.0], "Transient exhaustion slept after its terminal attempt")
}

private func validatePayloadTooLargeIsSplitSignal() async throws {
    var attempts = 0
    var sleeps = 0
    try await expectFailure(.payloadTooLarge) {
        _ = try await AppleAudioHTTPRecovery.transcribe(
            sleep: { _ in sleeps += 1 },
            request: { _ in
                attempts += 1
                return textResponse(413)
            }
        )
    }
    try require(attempts == 1, "HTTP 413 was retried instead of being split")
    try require(sleeps == 0, "HTTP 413 slept instead of being split")
}

private func validateRetryAfter() async throws {
    var delays: [TimeInterval] = []
    var attempts = 0
    _ = try await AppleAudioHTTPRecovery.transcribe(
        now: { Date(timeIntervalSince1970: 0) },
        sleep: { delays.append($0) },
        request: { _ in
            attempts += 1
            if attempts == 1 {
                return textResponse(429, headers: ["Retry-After": "99"])
            }
            return textResponse(200)
        }
    )
    try require(delays == [10], "Retry-After seconds were not capped at 10s: \(delays)")

    delays.removeAll()
    attempts = 0
    _ = try await AppleAudioHTTPRecovery.transcribe(
        now: { Date(timeIntervalSince1970: 0) },
        sleep: { delays.append($0) },
        request: { _ in
            attempts += 1
            if attempts == 1 {
                return textResponse(408, headers: ["Retry-After": "Thu, 01 Jan 1970 00:00:06 GMT"])
            }
            return textResponse(200)
        }
    )
    try require(delays == [6], "Retry-After HTTP date was not honored: \(delays)")
}

private func validateTransportFailures() async throws {
    for code in [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .cannotDecodeContentData] {
        var attempts = 0
        let result = try await AppleAudioHTTPRecovery.transcribe(
            sleep: { _ in },
            request: { _ in
                attempts += 1
                if attempts < 3 { throw URLError(code) }
                return textResponse(200, text: "transport recovered")
            }
        )
        try require(result == "transport recovered", "\(code) did not recover")
        try require(attempts == 3, "\(code) did not use three total attempts")
    }

    var attempts = 0
    try await expectFailure(.transientRetriesExhausted(statusCode: nil)) {
        _ = try await AppleAudioHTTPRecovery.transcribe(
            sleep: { _ in },
            request: { _ in
                attempts += 1
                throw URLError(.networkConnectionLost)
            }
        )
    }
    try require(attempts == 3, "Body disconnect was not bounded to three attempts")

    attempts = 0
    try await expectFailure(.transportUnavailable) {
        _ = try await AppleAudioHTTPRecovery.transcribe(
            sleep: { _ in },
            request: { _ in
                attempts += 1
                throw URLError(.serverCertificateUntrusted)
            }
        )
    }
    try require(attempts == 1, "Permanent transport failure was retried")
}

private func validateHeadersFirstTransportBoundary() async throws {
    let server = try HTTPBoundaryServer()
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    let transport = AppleAudioHTTPTransport(
        configuration: configuration,
        maximumSuccessBodyBytes: 4_096
    )
    let request: URLRequest = {
        var request = URLRequest(url: server.url)
        request.httpMethod = "POST"
        return request
    }()

    for (statusCode, expectedFailure) in [
        (400, AppleAudioHTTPRecovery.Failure.permanentHTTP(statusCode: 400)),
        (413, AppleAudioHTTPRecovery.Failure.payloadTooLarge),
    ] {
        let headerLog = HeaderLog()
        server.state.configure(.stalled(statusCode: statusCode))
        try await completeWithin("stalled HTTP \(statusCode)") {
            try await expectFailure(expectedFailure) {
                _ = try await AppleAudioHTTPRecovery.transcribe(
                    sleep: { _ in },
                    request: { _ in
                        let response = try await transport.response(for: request)
                        await headerLog.record(response.headers)
                        return response
                    }
                )
            }
        }
        try require(
            server.state.attempts() == 1,
            "Stalled HTTP \(statusCode) response was drained or retried"
        )
        let headers = await headerLog.snapshot()
        try require(headers["retry-after"] == "7", "Retry-After header casing was not normalized")
        try require(
            headers["x-aidictation-request-id"] == "boundary-test",
            "Proxy request header casing was not normalized"
        )
    }

    server.state.configure(.disconnectTwiceThenSucceed)
    let recovered = try await completeWithin("disconnected HTTP 200") {
        try await AppleAudioHTTPRecovery.transcribe(
            sleep: { _ in },
            request: { _ in try await transport.response(for: request) }
        )
    }
    try require(
        recovered == String(repeating: "r", count: 2_048),
        "A complete retried 200 body was not returned"
    )
    try require(
        server.state.attempts() == 3,
        "A disconnected 200 body did not use the bounded three-attempt policy"
    )

    server.state.configure(.oversizedSuccess(contentLength: 8_192))
    try await completeWithin("oversized HTTP 200") {
        try await expectFailure(.invalidTranscriptionResponse) {
            _ = try await AppleAudioHTTPRecovery.transcribe(
                sleep: { _ in },
                request: { _ in try await transport.response(for: request) }
            )
        }
    }
    try require(
        server.state.attempts() == 1,
        "An oversized successful response body was drained or retried"
    )

    server.state.configure(.stalled(statusCode: 200))
    let pending = Task {
        try await transport.response(for: request)
    }
    defer { pending.cancel() }
    try await completeWithin("cancelled HTTP 200 request start") {
        while server.state.attempts() == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
    pending.cancel()
    try await completeWithin("cancelled HTTP 200") {
        do {
            _ = try await pending.value
            throw ValidationError.failed("A cancelled transport returned a late response")
        } catch is CancellationError {
            return
        }
    }
    try require(
        server.state.attempts() == 1,
        "Cancellation started a replacement transport request"
    )
}

private func validateReceivedResponseIsTerminal() async throws {
    let malformedResponses = [
        AppleAudioHTTPRecovery.Response(
            statusCode: 200,
            headers: ["Content-Type": "text/plain"],
            body: Data()
        ),
        AppleAudioHTTPRecovery.Response(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"status\":\"ok\"}".utf8)
        ),
        AppleAudioHTTPRecovery.Response(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"text\":\"looks valid\",\"extra\":true}".utf8)
        ),
        AppleAudioHTTPRecovery.Response(
            statusCode: 200,
            headers: ["Content-Type": "text/html"],
            body: Data("<html>not a transcript</html>".utf8)
        ),
        AppleAudioHTTPRecovery.Response(
            statusCode: 200,
            headers: [:],
            body: Data("missing type".utf8)
        ),
    ]

    for response in malformedResponses {
        var attempts = 0
        var sleeps = 0
        try await expectFailure(.invalidTranscriptionResponse) {
            _ = try await AppleAudioHTTPRecovery.transcribe(
                sleep: { _ in sleeps += 1 },
                request: { _ in
                    attempts += 1
                    return response
                }
            )
        }
        try require(attempts == 1, "A fully received malformed response was retried")
        try require(sleeps == 0, "A fully received malformed response slept")
    }

    let json = AppleAudioHTTPRecovery.Response(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data("{\"text\":\"  json transcript  \"}".utf8)
    )
    let parsed = try await AppleAudioHTTPRecovery.transcribe(request: { _ in json })
    try require(parsed == "json transcript", "Valid JSON transcript was not parsed")
}

private func validateCancellation() async throws {
    var attempts = 0
    do {
        _ = try await AppleAudioHTTPRecovery.transcribe(
            sleep: { _ in throw CancellationError() },
            request: { _ in
                attempts += 1
                return textResponse(503)
            }
        )
        throw ValidationError.failed("Cancellation during retry delay was swallowed")
    } catch is CancellationError {
        try require(attempts == 1, "Cancellation started another request")
    }
}

private func validateSequentialRejectedLeafSplitting() async throws {
    var order: [String] = []
    var cleaned: [[String]] = []
    var checkpoints: [String] = []

    let result = try await AppleAudioHTTPRecovery.transcribeSequentially(
        leaves: ["A", "B", "C"],
        policy: .init(maximumSplitDepth: 3),
        transcribeLeaf: { leaf, _ in
            order.append(leaf)
            if leaf == "B" || leaf == "B2" {
                throw AppleAudioHTTPRecovery.Failure.payloadTooLarge
            }
            return leaf.lowercased()
        },
        splitRejectedLeaf: { leaf, _ in
            switch leaf {
            case "B": return ["B1", "B2"]
            case "B2": return ["B2a", "B2b"]
            default: return []
            }
        },
        cleanupSplitLeaves: { cleaned.append($0) },
        checkpoint: { index, transcript in
            checkpoints.append("\(index):\(transcript)")
        }
    )

    try require(order == ["A", "B", "B1", "B2", "B2a", "B2b", "C"], "413 traversal order changed or replayed a completed leaf: \(order)")
    try require(result.transcripts == ["a", "b1", "b2a", "b2b", "c"], "Sequential transcript order changed")
    try require(result.didSplitRejectedLeaf, "413 split was not reported")
    try require(cleaned == [["B2a", "B2b"], ["B1", "B2"]], "Temporary split leaves were not cleaned after traversal")
    try require(checkpoints == ["0:a", "1:b1", "2:b2a", "3:b2b", "4:c"], "Checkpoints were not persisted after each leaf in source order: \(checkpoints)")

    order.removeAll()
    try await expectFailure(.splitLimitReached) {
        _ = try await AppleAudioHTTPRecovery.transcribeSequentially(
            leaves: ["root"],
            policy: .init(maximumSplitDepth: 1),
            transcribeLeaf: { leaf, _ in
                order.append(leaf)
                throw AppleAudioHTTPRecovery.Failure.payloadTooLarge
            },
            splitRejectedLeaf: { leaf, _ in [leaf + "L", leaf + "R"] }
        )
    }
    try require(order == ["root", "rootL"], "Depth bound replayed or processed later siblings: \(order)")

    order.removeAll()
    checkpoints.removeAll()
    do {
        _ = try await AppleAudioHTTPRecovery.transcribeSequentially(
            leaves: ["A", "B", "C"],
            transcribeLeaf: { leaf, _ in
                order.append(leaf)
                return leaf.lowercased()
            },
            splitRejectedLeaf: { _, _ in [] },
            checkpoint: { index, transcript in
                checkpoints.append("\(index):\(transcript)")
                if index == 1 { throw CheckpointError.persistenceFailed }
            }
        )
        throw ValidationError.failed("Checkpoint persistence failure was swallowed")
    } catch CheckpointError.persistenceFailed {
        try require(order == ["A", "B"], "Checkpoint failure did not stop before C: \(order)")
        try require(checkpoints == ["0:a", "1:b"], "Checkpoint failure changed checkpoint order: \(checkpoints)")
    }

    let cancellationOrder = StringLog()
    let cancelledAfterCheckpoint = Task {
        try await AppleAudioHTTPRecovery.transcribeSequentially(
            leaves: ["A"],
            transcribeLeaf: { leaf, _ in
                await cancellationOrder.append(leaf)
                return leaf.lowercased()
            },
            splitRejectedLeaf: { _, _ in [] },
            checkpoint: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )
    }
    do {
        _ = try await cancelledAfterCheckpoint.value
        throw ValidationError.failed("Cancellation after a checkpoint returned a late success")
    } catch is CancellationError {
        let cancelledOrder = await cancellationOrder.snapshot()
        try require(cancelledOrder == ["A"], "Cancellation during the final checkpoint returned a late result: \(cancelledOrder)")
    }
}

private func validateSegmentCoverageKeepsShortTail() throws {
    let segments = try AppleAudioHTTPRecovery.segments(
        sourceDuration: 10.1,
        maximumSegmentDuration: 5
    )
    try require(segments.count == 3, "Short final audio range was omitted")
    try require(segments[0] == .init(start: 0, duration: 5), "First audio range changed")
    try require(segments[1] == .init(start: 5, duration: 5), "Second audio range changed")
    try require(abs(segments[2].start - 10) < 0.000_001, "Final audio range starts at the wrong point")
    try require(abs(segments[2].duration - 0.1) < 0.000_001, "Sub-250ms final audio range was dropped")

    var expectedStart: TimeInterval = 0
    for segment in segments {
        try require(abs(segment.start - expectedStart) < 0.000_001, "Audio ranges contain a gap or overlap")
        expectedStart = segment.start + segment.duration
    }
    try require(abs(expectedStart - 10.1) < 0.000_001, "Audio ranges do not preserve the exact source tail")
}

private func validateCleanupCompletionMustBeComplete() throws {
    func response(finishReason: Any?, content: String = "complete transcript") throws -> Data {
        var choice: [String: Any] = [
            "message": ["content": content]
        ]
        if let finishReason {
            choice["finish_reason"] = finishReason
        }
        return try JSONSerialization.data(withJSONObject: ["choices": [choice]])
    }

    let complete = try AppleAudioHTTPRecovery.completeChatContent(
        from: response(finishReason: "stop", content: "  complete transcript  ")
    )
    try require(complete == "complete transcript", "A complete cleanup response was not accepted")

    for finishReason: Any? in ["length", "content_filter", NSNull(), nil] {
        do {
            _ = try AppleAudioHTTPRecovery.completeChatContent(
                from: response(finishReason: finishReason)
            )
            throw ValidationError.failed("Truncated cleanup response was accepted: \(String(describing: finishReason))")
        } catch AppleAudioHTTPRecovery.Failure.invalidTranscriptionResponse {
            // Expected: caller keeps the complete raw transcript.
        }
    }

    do {
        _ = try AppleAudioHTTPRecovery.completeChatContent(
            from: response(finishReason: "stop", content: "   ")
        )
        throw ValidationError.failed("Empty cleanup response was accepted")
    } catch AppleAudioHTTPRecovery.Failure.invalidTranscriptionResponse {
        // Expected.
    }
}

private func validateClientBulkSourceContract() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let paths = [
        "Whishpermate/Whispermate/Services/OpenAIClient.swift",
        "Whishpermate/WhisperMateShared/Networking/OpenAIClient.swift",
    ]

    for path in paths {
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        try require(
            source.contains("let shouldChunkImmediately = audioByteCount > Self.maxSingleUploadAudioBytes"),
            "\(path) does not proactively split oversized audio for every endpoint"
        )
        try require(
            !source.contains("Self.shouldUseChunkedUpload(for: url) &&\n            audioByteCount >"),
            "\(path) still gates safe-size splitting on a provider hostname"
        )
        try require(
            source.contains("let recognitionHint = sttPrompt ?? prompt")
                || source.contains(
                    "let recognitionHint = usesModernContext ? prompt : (sttPrompt ?? prompt)"
                ),
            "\(path) does not route recognition-only hints to split leaves"
        )
        try require(
            source.contains("postProcessingPrompt: chunk.usesChunkFields ? nil : postProcessingPrompt"),
            "\(path) sends cleanup context to split recognition leaves"
        )
        try require(
            source.contains("postProcessingEnabled: postProcessingEnabled")
                && source.contains("&& !(chunk.usesChunkFields && endpointHasServerCleanup)"),
            "\(path) does not preserve the caller cleanup policy or disable server cleanup for split leaves"
        )
        try require(
            source.contains("serverPostProcessingEnabledByDefault: Bool = false"),
            "\(path) cannot declare custom endpoints that clean by default"
        )
        try require(
            source.contains("AppleAudioHTTPTransport.shared.response(for: request)"),
            "\(path) does not classify transcription status before reading the response body"
        )
        try require(
            source.contains("Never fall back to materializing an already-oversized source"),
            "\(path) can fall back to an unsafe whole-file multipart body"
        )
        try require(
            source.contains("Applying one cleanup pass to merged chunk transcript"),
            "\(path) lacks a single merged cleanup pass"
        )
        try require(
            source.contains("guard onMergedRawTranscript != nil,\n                  let cleanupMergedTranscript"),
            "\(path) incorrectly makes core merged cleanup depend on optional rules"
        )
    }
}

private func validateSharedRequestSnapshotAndCleanupContract() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let path = "Whishpermate/WhisperMateShared/Services/SharedTranscriptionService.swift"
    let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)

    for required in [
        "public struct RequestSnapshot: Sendable",
        "public static func capture(",
        "request: RequestSnapshot",
        "cleanup: captureCleanupConfiguration()",
        "serverPostProcessingEnabledByDefault: false",
        "postProcessingEnabled: !cloud.isOneStage",
        "onMergedRawTranscript: { mergedRaw in",
        "try await onRawTranscript(durableRaw)",
        "try await onCleanupStarted()",
        "if cloud.isOneStage {",
        "mergedCleanup = nil",
        "cleanupMergedTranscript: mergedCleanup",
        "let rules = postProcessingPrompt.isEmpty ? [] : [postProcessingPrompt]",
        "rawCallbacksCompleted: true",
        "return nonemptyModeResult.isEmpty ? durableRawTranscript : nonemptyModeResult",
    ] {
        try require(source.contains(required), "Shared transcription recovery is missing: \(required)")
    }
    try require(
        !source.contains("guard outputMode != .dictation || !prompts.postProcessing.isEmpty"),
        "Core generic cleanup is still skipped for dictation without optional rules"
    )
    try require(
        !source.contains("expandShortcuts") && !source.contains("shortcutExpansions"),
        "Shared cleanup still mutates successful or raw-fallback text after the LLM decision"
    )

    try require(
        source.contains("onMergedRawTranscript: { mergedRaw in")
            && source.contains("cleanupMergedTranscript: mergedCleanup"),
        "Shared raw capture and merged cleanup ownership markers are missing"
    )
}

@main
private enum AppleAudioHTTPRecoveryValidator {
    static func main() async {
        do {
            try await validatePermanentStatuses()
            try await validateTransientStatusTable()
            try await validatePayloadTooLargeIsSplitSignal()
            try await validateRetryAfter()
            try await validateTransportFailures()
            try await validateHeadersFirstTransportBoundary()
            try await validateReceivedResponseIsTerminal()
            try await validateCancellation()
            try await validateSequentialRejectedLeafSplitting()
            try validateSegmentCoverageKeepsShortTail()
            try validateCleanupCompletionMustBeComplete()
            try validateClientBulkSourceContract()
            try validateSharedRequestSnapshotAndCleanupContract()
            print("Apple HTTP audio recovery validator passed")
        } catch {
            fputs("Apple HTTP audio recovery validator failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
