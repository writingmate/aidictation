import Foundation

public enum OpenAIRealtimeTranscriptionClientError: LocalizedError {
    case missingClientSecret
    case invalidClientSecretEndpoint
    case clientSecretRequestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientSecret:
            return "Realtime transcription session did not return a client secret"
        case .invalidClientSecretEndpoint:
            return "Invalid realtime transcription session endpoint"
        case .clientSecretRequestFailed(let message):
            return message
        }
    }
}

public struct WritingmateRealtimeClientSecretProvider {
    public struct Authorization {
        public let token: String
        public let webSocketURL: URL

        public init(token: String, webSocketURL: URL) {
            self.token = token
            self.webSocketURL = webSocketURL
        }
    }

    public static func endpoint(from transcriptionEndpoint: String) -> URL? {
        guard var components = URLComponents(string: transcriptionEndpoint) else { return nil }
        let scheme = components.scheme?.lowercased()
        if scheme == "ws" || scheme == "wss" {
            return nil
        }
        // Newer Foundation parses almost any string as a relative URL; only a
        // real absolute http(s) endpoint can derive a client_secrets URL.
        guard scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        let path = components.path

        if path.hasSuffix("/audio/transcriptions") {
            components.path = String(path.dropLast("/audio/transcriptions".count)) + "/realtime/client_secrets"
        } else {
            components.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/realtime/client_secrets"
            if !components.path.hasPrefix("/") {
                components.path = "/" + components.path
            }
        }

        return components.url
    }

    public static func fetchAuthorization(
        endpoint: URL,
        apiKey: String,
        model: String?,
        prompt: String?,
        language: String?,
        keywords: [String] = [],
        languages: [String] = []
    ) async throws -> Authorization {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if !apiKey.isEmpty, apiKey != "not-needed" {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [:]
        if let model, !model.isEmpty {
            payload["model"] = model
        }
        if let prompt, !prompt.isEmpty {
            payload["prompt"] = prompt
        }
        if Self.usesModernTranscriptionContext(model: model) {
            if !keywords.isEmpty {
                payload["keywords"] = keywords
            }
            if !languages.isEmpty {
                payload["languages"] = languages
            }
        } else if let language, !language.isEmpty, !language.contains(",") {
            payload["language"] = language
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIRealtimeTranscriptionClientError.clientSecretRequestFailed("Invalid realtime token response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Realtime token request failed"
            throw OpenAIRealtimeTranscriptionClientError.clientSecretRequestFailed("HTTP \(httpResponse.statusCode): \(message)")
        }

        let decoded = try JSONDecoder().decode(ClientSecretResponse.self, from: data)
        guard let token = decoded.token, !token.isEmpty else {
            throw OpenAIRealtimeTranscriptionClientError.missingClientSecret
        }
        guard let webSocketURL = decoded.webSocketURL ?? OpenAIRealtimeTranscriptionClient.webSocketURL() else {
            throw OpenAIRealtimeTranscriptionClientError.clientSecretRequestFailed("Realtime session did not return a valid WebSocket URL")
        }

        return Authorization(token: token, webSocketURL: webSocketURL)
    }

    private static func usesModernTranscriptionContext(model: String?) -> Bool {
        model == "gpt-live-transcribe" || model == "gpt-transcribe"
    }

    private struct ClientSecretResponse: Decodable {
        let token: String?
        let webSocketURL: URL?

        private enum CodingKeys: String, CodingKey {
            case value
            case token
            case clientSecret = "client_secret"
            case clientSecretCamel = "clientSecret"
            case session
            case webSocketURLString = "websocket_url"
            case webSocketURLCamel = "websocketUrl"
            case webSocketURLPascal = "webSocketURL"
            case url
            case realtimeURLString = "realtime_url"
            case wsURLString = "ws_url"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            token = Self.stringOrSecret(in: container, forKey: .value)
                ?? Self.stringOrSecret(in: container, forKey: .token)
                ?? Self.stringOrSecret(in: container, forKey: .clientSecret)
                ?? Self.stringOrSecret(in: container, forKey: .clientSecretCamel)
                ?? Self.sessionSecret(in: container)

            let urlString = Self.string(in: container, forKey: .webSocketURLString)
                ?? Self.string(in: container, forKey: .webSocketURLCamel)
                ?? Self.string(in: container, forKey: .webSocketURLPascal)
                ?? Self.string(in: container, forKey: .url)
                ?? Self.string(in: container, forKey: .realtimeURLString)
                ?? Self.string(in: container, forKey: .wsURLString)
            webSocketURL = urlString.flatMap(URL.init(string:))
        }

        private static func string(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
            guard let value = try? container.decode(String.self, forKey: key) else {
                return nil
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func stringOrSecret(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
            if let value = string(in: container, forKey: key) {
                return value
            }
            guard let secret = try? container.decode(Secret.self, forKey: key) else {
                return nil
            }
            return secret.value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        private static func sessionSecret(in container: KeyedDecodingContainer<CodingKeys>) -> String? {
            guard let session = try? container.decode(Session.self, forKey: .session) else {
                return nil
            }
            return session.clientSecret
        }
    }

    private struct Session: Decodable {
        let clientSecret: String?

        private enum CodingKeys: String, CodingKey {
            case clientSecret = "client_secret"
            case clientSecretCamel = "clientSecret"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            clientSecret = Self.stringOrSecret(in: container, forKey: .clientSecret)
                ?? Self.stringOrSecret(in: container, forKey: .clientSecretCamel)
        }

        private static func stringOrSecret(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
            if let value = try? container.decode(String.self, forKey: key) {
                return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            guard let secret = try? container.decode(Secret.self, forKey: key) else {
                return nil
            }
            return secret.value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    private struct Secret: Decodable {
        let value: String?
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

public nonisolated final class OpenAIRealtimeTranscriptionClient: @unchecked Sendable, RealtimeTranscriptionStreaming {
    public static let defaultTranscriptionModel = "gpt-live-transcribe"
    private static let realtimeBytesPerSecond = 24_000 * MemoryLayout<Int16>.size
    private static let realtimeCommitByteThreshold = Int(Double(realtimeBytesPerSecond) * 0.8)

    public static func webSocketURL() -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription"),
        ]
        return components.url
    }

    private let authorizationProvider: () async throws -> WritingmateRealtimeClientSecretProvider.Authorization
    private let prompt: String?
    private let transcriptionModel: String
    private let language: String?
    private let keywords: [String]
    private let languages: [String]
    private let shouldSendSessionUpdate: Bool
    private let onPartialTranscript: @MainActor (String) -> Void
    private let onError: @MainActor (String) -> Void
    private let session: URLSession
    private let sendQueue: DispatchQueue
    private let finishGate: RealtimeTranscriptionFinishGate

    private var task: URLSessionWebSocketTask?
    private var authorizationTask: Task<Void, Never>?
    private var pendingEvents: [[String: Any]] = []
    private var isClosed = false
    private var accumulatedTranscript = ""
    private var finalTranscript: String?
    private var failedMessage: String?
    private var didRequestFinish = false
    private var audioChunkCount = 0
    private var audioByteCount = 0
    private var uncommittedAudioByteCount = 0
    private var commitSequence = 0
    private var pendingCommitAcknowledgements = 0
    private var pendingCompletionItemIDs = Set<String>()
    private var completedItemIDs = Set<String>()
    private var trackedItemIDs = Set<String>()
    private var itemOrder: [String] = []
    private var itemTranscripts: [String: String] = [:]

    public init(
        apiKey: String,
        webSocketURL: URL? = nil,
        transcriptionModel: String = OpenAIRealtimeTranscriptionClient.defaultTranscriptionModel,
        language: String? = nil,
        keywords: [String] = [],
        languages: [String] = [],
        prompt: String?,
        onPartialTranscript: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        let model = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendQueue = DispatchQueue(label: "ai.writingmate.openai-realtime-send")
        self.sendQueue = sendQueue
        self.finishGate = RealtimeTranscriptionFinishGate(queue: sendQueue)
        self.authorizationProvider = {
            guard let url = webSocketURL ?? Self.webSocketURL() else {
                throw OpenAIRealtimeTranscriptionClientError.clientSecretRequestFailed("Invalid OpenAI Realtime URL")
            }
            return WritingmateRealtimeClientSecretProvider.Authorization(token: apiKey, webSocketURL: url)
        }
        self.prompt = prompt
        self.transcriptionModel = model.isEmpty ? Self.defaultTranscriptionModel : model
        self.language = language
        self.keywords = keywords
        self.languages = languages
        self.shouldSendSessionUpdate = true
        self.onPartialTranscript = onPartialTranscript
        self.onError = onError
        self.session = URLSession(configuration: .default)
    }

    public init(
        authorizationProvider: @escaping () async throws -> WritingmateRealtimeClientSecretProvider.Authorization,
        prompt: String?,
        transcriptionModel: String = OpenAIRealtimeTranscriptionClient.defaultTranscriptionModel,
        language: String? = nil,
        keywords: [String] = [],
        languages: [String] = [],
        onPartialTranscript: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        let model = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendQueue = DispatchQueue(label: "ai.writingmate.openai-realtime-send")
        self.sendQueue = sendQueue
        self.finishGate = RealtimeTranscriptionFinishGate(queue: sendQueue)
        self.authorizationProvider = authorizationProvider
        self.prompt = prompt
        self.transcriptionModel = model.isEmpty ? Self.defaultTranscriptionModel : model
        self.language = language
        self.keywords = keywords
        self.languages = languages
        self.shouldSendSessionUpdate = false
        self.onPartialTranscript = onPartialTranscript
        self.onError = onError
        self.session = URLSession(configuration: .default)
    }

    public func start() {
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.requireSendQueue()
            self.authorizationTask?.cancel()
            self.finishGate.reset()
            self.isClosed = false
            self.audioChunkCount = 0
            self.audioByteCount = 0
            self.uncommittedAudioByteCount = 0
            self.commitSequence = 0
            self.pendingCommitAcknowledgements = 0
            self.pendingCompletionItemIDs.removeAll()
            self.completedItemIDs.removeAll()
            self.trackedItemIDs.removeAll()
            self.itemOrder.removeAll()
            self.itemTranscripts.removeAll()
            self.accumulatedTranscript = ""
            self.finalTranscript = nil
            self.failedMessage = nil
            self.didRequestFinish = false
            DebugLog.info(
                "Realtime start requested model=\(self.transcriptionModel) language=\(self.language ?? "auto") promptIncluded=\(self.prompt?.isEmpty == false)",
                context: "OpenAIRealtime"
            )
            self.authorizationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let authorization = try await self.authorizationProvider()
                    try Task.checkCancellation()
                    self.openSocket(authorization: authorization)
                } catch is CancellationError {
                    return
                } catch {
                    self.fail("OpenAI Realtime token failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func sendAudio(_ pcm24kMono16: Data) {
        guard !pcm24kMono16.isEmpty else { return }

        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm24kMono16.base64EncodedString(),
        ]
        sendQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isClosed, !self.didRequestFinish else { return }

            self.audioChunkCount += 1
            self.audioByteCount += pcm24kMono16.count
            self.uncommittedAudioByteCount += pcm24kMono16.count
            if self.audioChunkCount == 1 || self.audioChunkCount % 50 == 0 {
                DebugLog.info(
                    "Realtime audio queued chunks=\(self.audioChunkCount) bytes=\(self.audioByteCount) pendingCommitBytes=\(self.uncommittedAudioByteCount) socketReady=\(self.task != nil)",
                    context: "OpenAIRealtime"
                )
            }

            if self.task == nil {
                self.pendingEvents.append(event)
                self.commitAudioBufferIfNeeded(reason: "live")
                return
            }
            self.sendEventOnQueue(event)
            self.commitAudioBufferIfNeeded(reason: "live")
        }
    }

    /// Starts the single final realtime commit without waiting for its result.
    /// Call this only after the recorder's realtime delivery queue has drained.
    public func requestFinish(timeout: TimeInterval = 1.5) {
        sendQueue.async { [weak self] in
            self?.beginFinishOnQueue(timeout: timeout)
        }
    }

    /// Awaits the result of `requestFinish` without owning commit authority.
    /// The recorder's drain callback is the only caller allowed to start the
    /// final commit, so this consumer can never overtake tail conversion.
    public func awaitFinish() async -> String? {
        await withCheckedContinuation { continuation in
            sendQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.finishGate.wait(continuation)
            }
        }
    }

    public func close() {
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.requireSendQueue()
            self.abandonTransportOnQueue()
            self.finishGate.resolve(with: nil)
        }
    }

    private func openSocket(authorization: WritingmateRealtimeClientSecretProvider.Authorization) {
        sendQueue.async { [weak self] in
            guard let self, self.task == nil, !self.isClosed else { return }
            self.requireSendQueue()

            var request = URLRequest(url: authorization.webSocketURL)
            request.setValue("Bearer \(authorization.token)", forHTTPHeaderField: "Authorization")

            let socket = self.session.webSocketTask(with: request)
            self.task = socket
            socket.resume()
            DebugLog.info(
                "Realtime socket opened host=\(authorization.webSocketURL.host ?? "unknown") path=\(authorization.webSocketURL.path) query=\(authorization.webSocketURL.query ?? "") queuedEvents=\(self.pendingEvents.count)",
                context: "OpenAIRealtime"
            )
            self.receiveNextMessage()
            if self.shouldSendSessionUpdate {
                self.sendEventOnQueue(self.sessionUpdateEvent())
            }

            let queuedEvents = self.pendingEvents
            self.pendingEvents.removeAll()
            queuedEvents.forEach { self.sendEventOnQueue($0) }
        }
    }

    private func beginFinishOnQueue(timeout: TimeInterval) {
        requireSendQueue()
        guard !didRequestFinish else { return }
        didRequestFinish = true

        DebugLog.info(
            "Realtime finish requested timeout=\(timeout)s accumulatedLength=\(accumulatedTranscript.count) finalLength=\(finalTranscript?.count ?? 0) failed=\(failedMessage != nil)",
            context: "OpenAIRealtime"
        )
        guard failedMessage == nil, !isClosed else {
            finishGate.resolve(with: nil)
            return
        }
        if isTransportDrained {
            let completedTranscript = finalTranscript
            abandonTransportOnQueue()
            finishGate.resolve(with: completedTranscript)
            return
        }

        finishGate.begin(timeout: timeout) { [weak self] in
            guard let self else { return }
            DebugLog.info(
                "Realtime finish timeout elapsed; discarding unproven stream finalLength=\(self.finalTranscript?.count ?? 0) accumulatedLength=\(self.accumulatedTranscript.count)",
                context: "OpenAIRealtime"
            )
            self.abandonTransportOnQueue()
        }
        DebugLog.info(
            "Realtime commit queued chunks=\(audioChunkCount) bytes=\(audioByteCount) currentLength=\(accumulatedTranscript.count)",
            context: "OpenAIRealtime"
        )
        commitAudioBuffer(reason: "finish")
        resumeFinishIfReady()
    }

    private func sessionUpdateEvent() -> [String: Any] {
        var transcription: [String: Any] = [
            "model": transcriptionModel,
        ]
        if usesModernTranscriptionContext {
            if !keywords.isEmpty {
                transcription["keywords"] = keywords
            }
            if !languages.isEmpty {
                transcription["languages"] = languages
            }
        } else if let language, !language.isEmpty, !language.contains(",") {
            transcription["language"] = language
        }
        if let prompt, !prompt.isEmpty {
            transcription["prompt"] = prompt
        }

        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000,
                        ],
                        "transcription": transcription,
                    ],
                ],
            ],
        ]
    }

    private var usesModernTranscriptionContext: Bool {
        transcriptionModel == "gpt-live-transcribe"
            || transcriptionModel == "gpt-transcribe"
    }
    private func commitAudioBufferIfNeeded(reason: String) {
        // gpt-live-transcribe emits deltas while audio is appended. Committing
        // every 0.8 seconds turns one dictation into unrelated short turns and
        // destroys sentence-level punctuation and word context. Commit it once,
        // after the recorder's delivery queue drains in beginFinishOnQueue.
        guard transcriptionModel != Self.defaultTranscriptionModel else { return }
        guard uncommittedAudioByteCount >= Self.realtimeCommitByteThreshold else { return }
        commitAudioBuffer(reason: reason)
    }

    private func commitAudioBuffer(reason: String) {
        guard uncommittedAudioByteCount > 0 else { return }

        commitSequence += 1
        pendingCommitAcknowledgements += 1
        let committedBytes = uncommittedAudioByteCount
        uncommittedAudioByteCount = 0

        DebugLog.info(
            "Realtime commit sent reason=\(reason) sequence=\(commitSequence) bytes=\(committedBytes) pendingAcks=\(pendingCommitAcknowledgements)",
            context: "OpenAIRealtime"
        )
        sendEventOnQueue(["type": "input_audio_buffer.commit"])
    }

    private func sendEventOnQueue(_ event: [String: Any]) {
        requireSendQueue()
        guard let task else {
            pendingEvents.append(event)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let message = String(data: data, encoding: .utf8)
        else {
            failOnQueue(
                "Realtime event serialization failed for \((event["type"] as? String) ?? "unknown")"
            )
            return
        }

        let eventType = (event["type"] as? String) ?? "unknown"
        if eventType != "input_audio_buffer.append" {
            DebugLog.info("Realtime send event type=\(eventType)", context: "OpenAIRealtime")
        }
        task.send(.string(message)) { [weak self] error in
            guard let self, let error else { return }
            self.fail("OpenAI Realtime send failed: \(error.localizedDescription)")
        }
    }

    private func receiveNextMessage() {
        requireSendQueue()
        task?.receive { [weak self] result in
            guard let self else { return }
            self.sendQueue.async { [weak self] in
                guard let self, !self.isClosed else { return }
                self.requireSendQueue()
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveNextMessage()
                case .failure(let error):
                    self.failOnQueue(
                        "OpenAI Realtime receive failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        requireSendQueue()
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            data = nil
        }

        guard let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String
        else {
            return
        }

        switch type {
        case "input_audio_buffer.committed":
            if pendingCommitAcknowledgements > 0 {
                pendingCommitAcknowledgements -= 1
            }

            guard let itemID = payload["item_id"] as? String,
                  !itemID.isEmpty
            else {
                failOnQueue("Realtime commit acknowledgement was missing its item ID")
                return
            }
            trackItem(itemID)
            if !completedItemIDs.contains(itemID) {
                pendingCompletionItemIDs.insert(itemID)
            }
            DebugLog.info(
                "Realtime buffer committed itemIDPresent=true pendingAcks=\(pendingCommitAcknowledgements) pendingItems=\(pendingCompletionItemIDs.count)",
                context: "OpenAIRealtime"
            )
            resumeFinishIfReady()
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = payload["delta"] as? String, !delta.isEmpty else { return }
            let itemID = transcriptItemID(from: payload)
            trackItem(itemID)
            itemTranscripts[itemID, default: ""] += delta
            rebuildTranscript()
            DebugLog.info(
                "Realtime delta received deltaLength=\(delta.count) accumulatedLength=\(accumulatedTranscript.count)",
                context: "OpenAIRealtime"
            )
            let transcript = accumulatedTranscript
            Task { @MainActor in
                onPartialTranscript(transcript)
            }
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = payload["transcript"] as? String else { return }
            let itemID = transcriptItemID(from: payload)
            trackItem(itemID)
            itemTranscripts[itemID] = transcript
            completedItemIDs.insert(itemID)
            pendingCompletionItemIDs.remove(itemID)
            rebuildTranscript()
            DebugLog.info(
                "Realtime completed transcriptLength=\(transcript.count) accumulatedLength=\(accumulatedTranscript.count) pendingItems=\(pendingCompletionItemIDs.count)",
                context: "OpenAIRealtime"
            )
            let fullTranscript = accumulatedTranscript
            Task { @MainActor in
                onPartialTranscript(fullTranscript)
            }
            resumeFinishIfReady()
        case "error":
            let error = payload["error"] as? [String: Any]
            let code = (error?["code"] as? String) ?? "unknown"
            let message = (error?["message"] as? String) ?? "OpenAI Realtime error"
            DebugLog.warning("Realtime error event code=\(code) message=\(message)", context: "OpenAIRealtime")
            failOnQueue(message)
        case "session.created", "session.updated":
            DebugLog.info("Realtime event received type=\(type)", context: "OpenAIRealtime")
        default:
            break
        }
    }

    private func transcriptItemID(from payload: [String: Any]) -> String {
        if let itemID = payload["item_id"] as? String, !itemID.isEmpty {
            return itemID
        }
        return "__unidentified_transcript_item"
    }

    private func trackItem(_ itemID: String) {
        guard !trackedItemIDs.contains(itemID) else { return }
        trackedItemIDs.insert(itemID)
        itemOrder.append(itemID)
    }

    private func rebuildTranscript() {
        let pieces = itemOrder.compactMap { itemID -> String? in
            guard let transcript = itemTranscripts[itemID]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty
            else {
                return nil
            }
            return transcript
        }

        accumulatedTranscript = pieces.reduce(into: "") { result, piece in
            appendTranscriptPiece(piece, to: &result)
        }
        finalTranscript = accumulatedTranscript.isEmpty ? nil : accumulatedTranscript
    }

    private func appendTranscriptPiece(_ piece: String, to result: inout String) {
        if result.isEmpty {
            result = piece
            return
        }

        if result.last?.isWhitespace == true || shouldAttachWithoutLeadingSpace(piece) {
            result += piece
        } else {
            result += " " + piece
        }
    }

    private func shouldAttachWithoutLeadingSpace(_ piece: String) -> Bool {
        guard let first = piece.unicodeScalars.first else { return true }
        return CharacterSet(charactersIn: ".,!?;:%)]}").contains(first)
    }

    private func fail(_ message: String) {
        sendQueue.async { [weak self] in
            self?.failOnQueue(message)
        }
    }

    private func failOnQueue(_ message: String) {
        requireSendQueue()
        guard !isClosed else { return }
        if failedMessage != nil {
            return
        }
        failedMessage = message
        CrashReporter.captureError(message, context: "OpenAIRealtime", feature: "transcription")
        DebugLog.warning("Realtime failed message=\(message)", context: "OpenAIRealtime")
        abandonTransportOnQueue()
        finishGate.resolve(with: nil)
        Task { @MainActor in
            onError(message)
        }
    }

    private var isTransportDrained: Bool {
        uncommittedAudioByteCount == 0
            && pendingCommitAcknowledgements == 0
            && pendingCompletionItemIDs.isEmpty
            && trackedItemIDs.isSubset(of: completedItemIDs)
    }

    private func resumeFinishIfReady() {
        requireSendQueue()
        guard didRequestFinish else { return }
        guard isTransportDrained else { return }
        let completedTranscript = finalTranscript
        abandonTransportOnQueue()
        finishGate.resolve(with: completedTranscript)
    }

    private func abandonTransportOnQueue() {
        requireSendQueue()
        isClosed = true
        authorizationTask?.cancel()
        authorizationTask = nil
        pendingEvents.removeAll()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func requireSendQueue() {
        dispatchPrecondition(condition: .onQueue(sendQueue))
    }
}
