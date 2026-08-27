import AVFoundation
import Foundation
import WhisperMateShared

enum OpenAIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case apiError(String)
    case encodingError
    case transcriptionFailure(AppleAudioHTTPRecovery.Failure)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Cloud transcription is not configured correctly."
        case .invalidResponse:
            return "The transcription result could not be read. Try again."
        case .networkError:
            return "Cloud transcription could not connect. Check your connection and try again."
        case .apiError:
            return "Cloud processing could not complete this request."
        case .encodingError:
            return "The recording could not be prepared for transcription."
        case .transcriptionFailure(let failure):
            return failure.localizedDescription
        }
    }
}

actor CodexTranscriptionAuthentication {
    struct Credentials: Sendable {
        let accessToken: String
        let accountID: String?
    }

    enum AuthenticationError: Error, LocalizedError {
        case appUnavailable
        case refreshFailed
        case signInRequired

        var errorDescription: String? {
            switch self {
            case .appUnavailable:
                return "Install ChatGPT to use this transcription option."
            case .refreshFailed:
                return "ChatGPT could not refresh your sign-in. Open ChatGPT and try again."
            case .signInRequired:
                return "Sign in to ChatGPT to use transcription."
            }
        }
    }

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String
            let accountID: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountID = "account_id"
            }
        }

        let authMode: String?
        let tokens: Tokens?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case tokens
        }
    }

    private final class RefreshResult: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var bufferedData = Data()
        private var resolved = false
        private(set) var succeeded = false

        func append(_ data: Data) {
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return
            }
            bufferedData.append(data)

            while let newline = bufferedData.firstIndex(of: 0x0A) {
                let line = bufferedData.prefix(upTo: newline)
                bufferedData.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   (object["id"] as? NSNumber)?.intValue == 2
                {
                    let result = object["result"] as? [String: Any]
                    let account = result?["account"] as? [String: Any]
                    succeeded = account?["type"] as? String == "chatgpt"
                    resolved = true
                    lock.unlock()
                    semaphore.signal()
                    return
                }
            }
            lock.unlock()
        }

        func processExited() {
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return
            }
            resolved = true
            lock.unlock()
            semaphore.signal()
        }
    }

    static let shared = CodexTranscriptionAuthentication()

    private var cachedCredentials: Credentials?
    private var cachedAt: Date?

    func credentials() async throws -> Credentials {
        if let cachedCredentials,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < 240
        {
            return cachedCredentials
        }

        guard let executableURL = CodexTranscriptionSupport.executableURL else {
            throw AuthenticationError.appUnavailable
        }

        let refreshed = await Task.detached(priority: .utility) {
            Self.refreshCodexAuthentication(using: executableURL)
        }.value
        guard refreshed else { throw AuthenticationError.refreshFailed }

        let authURL = Self.codexHomeURL()
            .appendingPathComponent("auth.json", isDirectory: false)
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              auth.authMode == nil || auth.authMode == "chatgpt",
              let tokens = auth.tokens,
              !tokens.accessToken.isEmpty
        else {
            throw AuthenticationError.signInRequired
        }

        let credentials = Credentials(
            accessToken: tokens.accessToken,
            accountID: tokens.accountID
        )
        cachedCredentials = credentials
        cachedAt = Date()
        return credentials
    }

    nonisolated private static func codexHomeURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    nonisolated private static func refreshCodexAuthentication(
        using executableURL: URL
    ) -> Bool {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let result = RefreshResult()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                result.processExited()
            } else {
                result.append(data)
            }
        }
        process.terminationHandler = { _ in result.processExited() }

        do {
            try process.run()
            let messages = [
                "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"aidictation\",\"version\":\"1\"},\"capabilities\":{}}}",
                "{\"method\":\"initialized\",\"params\":{}}",
                "{\"id\":2,\"method\":\"account/read\",\"params\":{\"refreshToken\":true}}",
            ].joined(separator: "\n") + "\n"
            try input.fileHandleForWriting.write(contentsOf: Data(messages.utf8))

            let waitResult = result.semaphore.wait(timeout: .now() + 15)
            try? input.fileHandleForWriting.close()
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            return waitResult == .success && result.succeeded
        } catch {
            try? input.fileHandleForWriting.close()
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            return false
        }
    }
}

/// Unified OpenAI-compatible client that works with Groq, OpenAI, and any OpenAI-compatible API
/// Single client configured once and used everywhere
final class OpenAIClient: @unchecked Sendable {
    private struct AudioUploadChunk {
        let url: URL
        let isTemporary: Bool
        let usesChunkFields: Bool
    }

    private static let maxSingleUploadAudioBytes = 3_600_000
    private static let maxChunkDuration: TimeInterval = 240
    private static let rejectedLeafMinimumDuration: TimeInterval = 2
    private static let chunkDurationSafetyFactor = 0.9
    private static let chunkExportTimeoutNanoseconds: UInt64 = 60_000_000_000

    // Custom URLSession optimized for persistent connections and SSL session reuse
    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0 // Allow slower uploads/transcription responses before failing
        config.timeoutIntervalForResource = 300.0 // Keep connection alive for 5 minutes
        config.httpMaximumConnectionsPerHost = 6 // Allow multiple connections to same host
        // URLSession automatically handles SSL session resumption and connection reuse
        return URLSession(configuration: config)
    }()

    // MARK: - Configuration

    struct Configuration {
        var transcriptionEndpoint: String
        var transcriptionModel: String
        var chatCompletionEndpoint: String
        var chatCompletionModel: String
        var apiKey: String
        var chatCompletionApiKey: String?
        var customHeaders: [String: String]

        init(
            transcriptionEndpoint: String = "",
            transcriptionModel: String = "",
            chatCompletionEndpoint: String = "",
            chatCompletionModel: String = "",
            apiKey: String = "",
            chatCompletionApiKey: String? = nil,
            customHeaders: [String: String] = [:]
        ) {
            self.transcriptionEndpoint = transcriptionEndpoint
            self.transcriptionModel = transcriptionModel
            self.chatCompletionEndpoint = chatCompletionEndpoint
            self.chatCompletionModel = chatCompletionModel
            self.apiKey = apiKey
            self.chatCompletionApiKey = chatCompletionApiKey
            self.customHeaders = customHeaders
        }
    }

    private var config: Configuration

    init(config: Configuration) {
        self.config = config
        DebugLog.info("Initialized", context: "OpenAIClient")
        DebugLog.api("Transcription endpoint: \(config.transcriptionEndpoint)")
        DebugLog.api("Chat endpoint: \(config.chatCompletionEndpoint)")
    }

    /// Update configuration (useful for switching providers or updating settings)
    func updateConfig(_ newConfig: Configuration) {
        config = newConfig
        DebugLog.info("Configuration updated", context: "OpenAIClient")
    }

    // MARK: - Transcription

    func transcribe(
        audioURL: URL,
        prompt: String? = nil,
        model: String? = nil,
        language: String? = nil,
        keywords: [String] = [],
        languages: [String] = [],
        sttPrompt: String? = nil,
        postProcessingPrompt: String? = nil,
        serverPostProcessingEnabledByDefault: Bool = false,
        transientWorkspace: MacTransientWorkspace,
        onChunkCheckpoint: AppleAudioHTTPRecovery.Checkpoint? = nil,
        onMergedRawTranscript: ((String) async throws -> Void)? = nil,
        cleanupMergedTranscript: ((String) async throws -> String)? = nil
    ) async throws -> String {
        let effectiveModel = model ?? config.transcriptionModel

        guard let url = URL(string: config.transcriptionEndpoint) else {
            throw OpenAIError.invalidURL
        }

        let audioByteCount = Self.fileSize(at: audioURL)
        // Bound multipart memory for every endpoint. A provider-specific host
        // must never be the thing that decides whether a large source is safe
        // to materialize in memory.
        let shouldChunkImmediately = audioByteCount > Self.maxSingleUploadAudioBytes

        do {
            let initialChunks: [AudioUploadChunk]
            if shouldChunkImmediately {
                initialChunks = try await Self.makeUploadChunks(
                    for: audioURL,
                    workspace: transientWorkspace
                )
            } else {
                initialChunks = [AudioUploadChunk(
                    url: audioURL,
                    isTemporary: false,
                    usesChunkFields: false
                )]
            }
            defer { Self.cleanup(initialChunks, in: transientWorkspace) }

            let useWritingmateChunkFields = Self.shouldUseChunkedUpload(for: url)
            let usesModernContext = Self.usesModernTranscriptionContext(
                model: effectiveModel
            )
            let recognitionHint = usesModernContext ? prompt : (sttPrompt ?? prompt)
            let chunkPrompt = usesModernContext
                ? recognitionHint
                : (useWritingmateChunkFields ? nil : recognitionHint)
            let chunkSTTPrompt = usesModernContext
                ? nil
                : (useWritingmateChunkFields ? recognitionHint : nil)
            let endpointHasServerCleanup = useWritingmateChunkFields || serverPostProcessingEnabledByDefault ||
                !(postProcessingPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            let result = try await AppleAudioHTTPRecovery.transcribeSequentially(
                leaves: initialChunks,
                transcribeLeaf: { chunk, _ in
                    try await self.transcribeSinglePart(
                        audioURL: chunk.url,
                        endpointURL: url,
                        effectiveModel: effectiveModel,
                        prompt: chunk.usesChunkFields ? chunkPrompt : prompt,
                        language: language,
                        keywords: keywords,
                        languages: languages,
                        sttPrompt: chunk.usesChunkFields ? chunkSTTPrompt : sttPrompt,
                        postProcessingPrompt: chunk.usesChunkFields ? nil : postProcessingPrompt,
                        postProcessingEnabled: !(chunk.usesChunkFields && endpointHasServerCleanup)
                    )
                },
                splitRejectedLeaf: { chunk, _ in
                    try await Self.splitRejectedLeaf(
                        chunk,
                        workspace: transientWorkspace
                    )
                },
                cleanupSplitLeaves: { chunks in
                    Self.cleanup(chunks, in: transientWorkspace)
                },
                checkpoint: onChunkCheckpoint
            )

            let mergedTranscript = result.transcripts
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let usedChunks = initialChunks.contains(where: \.usesChunkFields) || result.didSplitRejectedLeaf

            guard usedChunks else {
                return mergedTranscript
            }


            if let onMergedRawTranscript {
                try await onMergedRawTranscript(mergedTranscript)
                try Task.checkCancellation()
            }

            guard onMergedRawTranscript != nil,
                  let cleanupMergedTranscript
            else { return mergedTranscript }

            DebugLog.info("Applying one cleanup pass to merged chunk transcript", context: "OpenAIClient")
            do {
                let cleaned = try await cleanupMergedTranscript(mergedTranscript)
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? mergedTranscript : trimmed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DebugLog.warning("Merged transcript cleanup failed; returning raw transcript", context: "OpenAIClient")
                return mergedTranscript
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as AppleAudioHTTPRecovery.Failure {
            throw OpenAIError.transcriptionFailure(failure)
        } catch let error as OpenAIError {
            throw error
        } catch {
            DebugLog.error("Could not prepare audio for transcription: \(error)", context: "OpenAIClient")
            // Durable checkpoint/store callbacks deliberately throw their own
            // actionable storage error. Preserve it so the caller can stop the
            // attempt truthfully instead of misreporting an audio encode issue.
            throw error
        }
    }

    private func transcribeSinglePart(
        audioURL: URL,
        endpointURL url: URL,
        effectiveModel: String,
        prompt: String? = nil,
        language: String? = nil,
        keywords: [String] = [],
        languages: [String] = [],
        sttPrompt: String? = nil,
        postProcessingPrompt: String? = nil,
        postProcessingEnabled: Bool = true
    ) async throws -> String {

        let startTime = CFAbsoluteTimeGetCurrent()
        DebugLog.api("Starting transcription", endpoint: config.transcriptionEndpoint)
        DebugLog.info("Model: \(effectiveModel), Language: \(language ?? "auto-detect"), promptLength: \(prompt?.count ?? 0), sttPromptLength: \(sttPrompt?.count ?? 0), postProcessingPromptLength: \(postProcessingPrompt?.count ?? 0), postProcessingEnabled: \(postProcessingEnabled)", context: "OpenAIClient")

        // Create multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let isChatGPTBatch = Self.isChatGPTBatchEndpoint(url)
        if isChatGPTBatch {
            let credentials = try await CodexTranscriptionAuthentication.shared.credentials()
            request.setValue(
                "Bearer \(credentials.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            if let accountID = credentials.accountID, !accountID.isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            request.setValue("Codex Desktop", forHTTPHeaderField: "OpenAI-Intent")
            request.setValue("Codex Desktop/AIDictation", forHTTPHeaderField: "User-Agent")
        } else if !config.apiKey.isEmpty, config.apiKey != "not-needed" {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Add custom headers
        for (key, value) in config.customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Read audio file data
        let audioData = try Data(contentsOf: audioURL)
        DebugLog.info("Audio file size: \(audioData.count) bytes", context: "OpenAIClient")

        // Build multipart body
        var body = Data()

        func appendFormField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // Add file parameter (required)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(Self.uploadFileName(for: audioURL))\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(Self.contentType(for: audioURL))\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        if isChatGPTBatch {
            if let language, !language.isEmpty {
                appendFormField(name: "language", value: language)
            }
        } else {
            appendFormField(name: "model", value: effectiveModel)
            appendFormField(name: "temperature", value: "0")

            if Self.usesModernTranscriptionContext(model: effectiveModel) {
                if let prompt, !prompt.isEmpty {
                    appendFormField(name: "prompt", value: prompt)
                }
                if !keywords.isEmpty,
                   let encoded = Self.jsonArrayString(keywords)
                {
                    appendFormField(name: "keywords", value: encoded)
                }
                if !languages.isEmpty,
                   let encoded = Self.jsonArrayString(languages)
                {
                    appendFormField(name: "languages", value: encoded)
                }
            } else {
                if let language, !language.isEmpty {
                    appendFormField(name: "language", value: language)
                }
                if let prompt, !prompt.isEmpty {
                    appendFormField(name: "prompt", value: prompt)
                }
                if let sttPrompt, !sttPrompt.isEmpty {
                    appendFormField(name: "stt_prompt", value: sttPrompt)
                }
            }

            if let postProcessingPrompt, !postProcessingPrompt.isEmpty {
                appendFormField(name: "post_processing_prompt", value: postProcessingPrompt)
            }
            if !postProcessingEnabled {
                appendFormField(name: "post_processing", value: "false")
            }
            appendFormField(name: "response_format", value: "text")
        }

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let text = try await AppleAudioHTTPRecovery.transcribe { attempt in
            try Task.checkCancellation()
            let response = try await AppleAudioHTTPTransport.shared.response(for: request)

            DebugLog.api("Response status: \(response.statusCode), attempt: \(attempt)")
            let proxyRequestId = response.headers["x-aidictation-request-id"]
            let proxyTotalMs = response.headers["x-aidictation-total-ms"]
            if proxyRequestId != nil || proxyTotalMs != nil {
                DebugLog.info("Proxy timing: requestId=\(proxyRequestId ?? "n/a"), totalMs=\(proxyTotalMs ?? "n/a")", context: "OpenAIClient")
            }
            guard isChatGPTBatch,
                  response.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: response.body)
                    as? [String: Any],
                  let transcript = object["text"] as? String,
                  let normalized = try? JSONSerialization.data(
                    withJSONObject: ["text": transcript]
                  )
            else { return response }

            return AppleAudioHTTPRecovery.Response(
                statusCode: response.statusCode,
                headers: ["content-type": "application/json"],
                body: normalized
            )
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        DebugLog.info("Transcription successful in \(String(format: "%.2f", duration))s", context: "OpenAIClient")
        print("⏱️ [Transcription] \(String(format: "%.2f", duration))s - \(effectiveModel)")
        return text
    }

    private static func makeUploadChunks(
        for audioURL: URL,
        workspace: MacTransientWorkspace
    ) async throws -> [AudioUploadChunk] {
        let fileBytes = fileSize(at: audioURL)
        guard fileBytes > maxSingleUploadAudioBytes else {
            return [AudioUploadChunk(url: audioURL, isTemporary: false, usesChunkFields: false)]
        }

        let asset = AVURLAsset(url: audioURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite,
              duration >= rejectedLeafMinimumDuration * 2
        else {
            // Never fall back to materializing an already-oversized source.
            throw AppleAudioHTTPRecovery.Failure.splitLimitReached
        }

        let bytesPerSecond = Double(fileBytes) / duration
        var segmentDuration = min(
            maxChunkDuration,
            max(rejectedLeafMinimumDuration, (Double(maxSingleUploadAudioBytes) / max(bytesPerSecond, 1)) * chunkDurationSafetyFactor)
        )

        for _ in 0..<5 {
            let chunks = try await exportChunks(
                for: asset,
                sourceDuration: duration,
                segmentDuration: segmentDuration,
                workspace: workspace
            )

            let oversizedBytes = chunks.map { fileSize(at: $0.url) }.max() ?? 0
            if oversizedBytes <= maxSingleUploadAudioBytes {
                return chunks
            }

            cleanup(chunks, in: workspace)
            segmentDuration *= 0.75
            if segmentDuration < rejectedLeafMinimumDuration {
                break
            }
        }

        throw AppleAudioHTTPRecovery.Failure.splitLimitReached
    }

    private static func splitRejectedLeaf(
        _ leaf: AudioUploadChunk,
        workspace: MacTransientWorkspace
    ) async throws -> [AudioUploadChunk] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: leaf.url)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite,
              duration >= rejectedLeafMinimumDuration * 2
        else {
            throw AppleAudioHTTPRecovery.Failure.splitLimitReached
        }

        return try await exportChunks(
            for: asset,
            sourceDuration: duration,
            segmentDuration: duration / 2,
            workspace: workspace
        )
    }

    private static func exportChunks(
        for asset: AVAsset,
        sourceDuration: TimeInterval,
        segmentDuration: TimeInterval,
        workspace: MacTransientWorkspace
    ) async throws -> [AudioUploadChunk] {
        var chunks: [AudioUploadChunk] = []

        do {
            let segments = try AppleAudioHTTPRecovery.segments(
                sourceDuration: sourceDuration,
                maximumSegmentDuration: segmentDuration
            )
            for segment in segments {
                try Task.checkCancellation()

                let outputURL = try workspace.makeOutputURL()

                let startTime = CMTime(seconds: segment.start, preferredTimescale: 600)
                let endTime = CMTime(
                    seconds: segment.start + segment.duration,
                    preferredTimescale: 600
                )
                do {
                    try await exportChunk(
                        asset: asset,
                        timeRange: CMTimeRangeFromTimeToTime(start: startTime, end: endTime),
                        outputURL: outputURL
                    )
                } catch {
                    workspace.removeOutput(outputURL)
                    throw error
                }

                do {
                    try workspace.validateCompletedOutput(outputURL)
                    chunks.append(AudioUploadChunk(url: outputURL, isTemporary: true, usesChunkFields: true))
                } catch {
                    workspace.removeOutput(outputURL)
                    throw OpenAIError.encodingError
                }

            }

            guard chunks.count >= 2 else {
                throw AppleAudioHTTPRecovery.Failure.splitLimitReached
            }

            return chunks
        } catch {
            cleanup(chunks, in: workspace)
            throw error
        }
    }

    private static func exportChunk(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) async throws {
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw OpenAIError.encodingError
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = timeRange
        exporter.shouldOptimizeForNetworkUse = true

        let operation = MacBoundedNativeOperation<Void>(
            cancelNative: { exporter.cancelExport() }
        )
        do {
            _ = try await operation.run(
                timeoutNanoseconds: chunkExportTimeoutNanoseconds
            ) { completion in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed:
                        completion(.success(()))
                    case .cancelled:
                        completion(.failure(CancellationError()))
                    case .failed:
                        completion(.failure(exporter.error ?? OpenAIError.encodingError))
                    default:
                        completion(.failure(OpenAIError.encodingError))
                    }
                }
            }
        } catch is MacNativeOperationDeadlineError {
            throw OpenAIError.encodingError
        }
        try Task.checkCancellation()
    }

    private static func shouldUseChunkedUpload(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "writingmate.ai" || host.hasSuffix(".writingmate.ai")
    }

    private static func usesModernTranscriptionContext(model: String) -> Bool {
        model == "gpt-transcribe" || model == "gpt-live-transcribe"
    }

    private static func jsonArrayString(_ values: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isChatGPTBatchEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "chatgpt.com"
            && url.path == "/backend-api/transcribe"
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "aac":
            return "audio/aac"
        default:
            return "audio/m4a"
        }
    }

    private static func uploadFileName(for url: URL) -> String {
        let fileName = url.lastPathComponent
        return fileName.isEmpty ? "audio.m4a" : fileName
    }

    private static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func cleanup(
        _ chunks: [AudioUploadChunk],
        in workspace: MacTransientWorkspace
    ) {
        for chunk in chunks where chunk.isTemporary {
            workspace.removeOutput(chunk.url)
        }
    }

    // MARK: - Chat Completion

    func chatCompletion(
        messages: [[String: String]],
        temperature: Double = 0.0,
        maxTokens: Int = 1000,
        model: String? = nil
    ) async throws -> String {
        let effectiveModel = model ?? config.chatCompletionModel

        guard let url = URL(string: config.chatCompletionEndpoint) else {
            throw OpenAIError.invalidURL
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        DebugLog.api("Chat completion request", endpoint: config.chatCompletionEndpoint)
        DebugLog.info("Model: \(effectiveModel)", context: "OpenAIClient")

        // Build the request payload
        let payload: [String: Any] = [
            "model": effectiveModel,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw OpenAIError.encodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let apiKey = config.chatCompletionApiKey ?? config.apiKey
        if !apiKey.isEmpty, apiKey != "not-needed" {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add custom headers
        for (key, value) in config.customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = jsonData

        // Send request
        do {
            let (data, response) = try await Self.urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenAIError.invalidResponse
            }

            DebugLog.api("Response status: \(httpResponse.statusCode)")

            if httpResponse.statusCode != 200 {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                DebugLog.error("API Error: \(errorMessage)", context: "OpenAIClient")
                throw OpenAIError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }

            let result: String
            do {
                result = try AppleAudioHTTPRecovery.completeChatContent(from: data)
            } catch {
                throw OpenAIError.invalidResponse
            }

            let endTime = CFAbsoluteTimeGetCurrent()
            let duration = endTime - startTime
            DebugLog.info("Chat completion successful in \(String(format: "%.2f", duration))s", context: "OpenAIClient")
            print("⏱️ [Chat Completion] \(String(format: "%.2f", duration))s - \(effectiveModel)")

            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAIError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            DebugLog.error("Network error: \(error)", context: "OpenAIClient")
            throw OpenAIError.networkError(error)
        }
    }

    // MARK: - Combined Workflow

    /// Transcribe audio and optionally apply formatting rules
    func transcribeAndFormat(
        audioURL: URL,
        transientWorkspace: MacTransientWorkspace,
        prompt: String? = nil,
        formattingRules: [String] = [],
        languageCodes _: String? = nil,
        appContext: String? = nil,
        llmApiKey _: String? = nil,
        clipboardContent: String? = nil,
        screenContext: String? = nil
    ) async throws -> String {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Build prompt with formatting rules and clipboard content if provided
        var combinedPrompt = prompt ?? ""

        if !formattingRules.isEmpty {
            let rulesText = formattingRules.joined(separator: "\n")
            if combinedPrompt.isEmpty {
                combinedPrompt = rulesText
            } else {
                combinedPrompt += "\n\n" + rulesText
            }

            if let appContext = appContext {
                combinedPrompt += "\n\nContext: The user is currently in \(appContext)."
            }

            // Add screen context if present (OCR of active window)
            if let screenContext = screenContext, !screenContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combinedPrompt += "\n\nScreen Context (OCR of active window):\n\(screenContext)"
            }

            // Add clipboard content if present
            if let clipboardContent = clipboardContent, !clipboardContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combinedPrompt += "\n\nSelected content to format: \(clipboardContent)"
            }
        }

        // Log prompt shape without dumping user context into logs.
        if !combinedPrompt.isEmpty {
            DebugLog.info("Prompt length being sent to API: \(combinedPrompt.count)", context: "OpenAIClient")
        }

        // Transcribe with formatting rules in prompt
        // The custom API will handle two-stage processing (Whisper + LLM refinement)
        let rawTranscription = try await transcribe(
            audioURL: audioURL,
            prompt: combinedPrompt.isEmpty ? nil : combinedPrompt,
            transientWorkspace: transientWorkspace
        )

        // Check if transcription is empty
        let trimmed = rawTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DebugLog.warning("Empty transcription", context: "OpenAIClient")
            return rawTranscription
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let totalDuration = endTime - startTime
        DebugLog.info("Transcription completed in \(String(format: "%.2f", totalDuration))s", context: "OpenAIClient")
        print("⏱️ [Total Pipeline] \(String(format: "%.2f", totalDuration))s")

        return rawTranscription
    }

    /// Apply formatting rules to transcription using chat completion
    func applyFormattingRules(transcription: String, rules: [String], languageCodes: String? = nil, appContext: String? = nil, screenContext: String? = nil, clipboardContent: String? = nil) async throws -> String {
        // Check if transcription is empty or whitespace-only
        let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscription.isEmpty else {
            DebugLog.warning("Empty transcription - skipping formatting rules", context: "OpenAIClient")
            return transcription
        }

        let hasClipboardContent = clipboardContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let systemPrompt = TranscriptionCleanupPrompt.systemPrompt(
            formattingContext: rules,
            languageContext: languageCodes,
            appContext: appContext,
            screenContext: screenContext,
            hasSelectedContent: hasClipboardContent
        )
        let userMessage = TranscriptionCleanupPrompt.userMessage(
            transcription: transcription,
            selectedContent: clipboardContent
        )

        let messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMessage],
        ]

        DebugLog.info("LLM post-processing request prepared", context: "OpenAIClient")
        let result = try await chatCompletion(messages: messages, maxTokens: 8192)
        DebugLog.info("LLM post-processing completed", context: "OpenAIClient")
        return result
    }

    func applyNotesFormatting(transcription: String, rules: [String] = [], languageCodes: String? = nil, appContext: String? = nil) async throws -> String {
        let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscription.isEmpty else {
            return transcription
        }

        let systemPrompt = TranscriptionCleanupPrompt.systemPrompt(
            formattingContext: rules,
            languageContext: languageCodes,
            appContext: appContext,
            hasSelectedContent: false,
            transformationInstruction: TranscriptionOutputMode.notesPostProcessingInstruction
        )
        let userMessage = TranscriptionCleanupPrompt.userMessage(
            transcription: transcription,
            selectedContent: nil
        )

        let messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMessage],
        ]

        DebugLog.info("Notes post-processing request prepared", context: "OpenAIClient")
        let result = try await chatCompletion(messages: messages, maxTokens: 8192)
        DebugLog.info("Notes post-processing completed", context: "OpenAIClient")
        return result
    }

    func applyMeetingFormatting(transcription: String, rules: [String] = [], languageCodes: String? = nil, appContext: String? = nil) async throws -> String {
        let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscription.isEmpty else {
            return transcription
        }

        let systemPrompt = TranscriptionCleanupPrompt.systemPrompt(
            formattingContext: rules,
            languageContext: languageCodes,
            appContext: appContext,
            hasSelectedContent: false,
            transformationInstruction: ContextRulesManager.meetingsPostProcessingInstruction
        )
        let userMessage = TranscriptionCleanupPrompt.userMessage(
            transcription: transcription,
            selectedContent: nil
        )

        let messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMessage],
        ]

        DebugLog.info("Meeting post-processing request prepared", context: "OpenAIClient")
        let result = try await chatCompletion(messages: messages, maxTokens: 8192)
        DebugLog.info("Meeting post-processing completed", context: "OpenAIClient")
        return result
    }
}
