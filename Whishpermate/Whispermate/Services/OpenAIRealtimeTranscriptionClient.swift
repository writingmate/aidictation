import Foundation

enum OpenAIRealtimeTranscriptionClientError: LocalizedError {
    case missingClientSecret
    case invalidClientSecretEndpoint
    case clientSecretRequestFailed(String)

    var errorDescription: String? {
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

struct WritingmateRealtimeClientSecretProvider {
    struct Authorization {
        let token: String
        let webSocketURL: URL
    }

    static func endpoint(from transcriptionEndpoint: String) -> URL? {
        guard var components = URLComponents(string: transcriptionEndpoint) else { return nil }
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

    static func fetchAuthorization(
        endpoint: URL,
        apiKey: String,
        prompt: String?,
        language: String?
    ) async throws -> Authorization {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if !apiKey.isEmpty, apiKey != "not-needed" {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: String] = [:]
        if let prompt, !prompt.isEmpty {
            payload["prompt"] = prompt
        }
        if let language, !language.isEmpty, !language.contains(",") {
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
        guard let webSocketURL = decoded.webSocketURL ?? URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
            throw OpenAIRealtimeTranscriptionClientError.clientSecretRequestFailed("Realtime session did not return a valid WebSocket URL")
        }

        return Authorization(token: token, webSocketURL: webSocketURL)
    }

    private struct ClientSecretResponse: Decodable {
        let value: String?
        let clientSecret: Secret?
        let session: Session?
        let webSocketURLString: String?

        var token: String? {
            value ?? clientSecret?.value ?? session?.clientSecret?.value
        }

        var webSocketURL: URL? {
            guard let webSocketURLString else { return nil }
            return URL(string: webSocketURLString)
        }

        private enum CodingKeys: String, CodingKey {
            case value
            case clientSecret = "client_secret"
            case session
            case webSocketURLString = "websocket_url"
        }
    }

    private struct Session: Decodable {
        let clientSecret: Secret?

        private enum CodingKeys: String, CodingKey {
            case clientSecret = "client_secret"
        }
    }

    private struct Secret: Decodable {
        let value: String?
    }
}

final class OpenAIRealtimeTranscriptionClient {
    private let authorizationProvider: () async throws -> WritingmateRealtimeClientSecretProvider.Authorization
    private let prompt: String?
    private let shouldSendSessionUpdate: Bool
    private let onPartialTranscript: @MainActor (String) -> Void
    private let onError: @MainActor (String) -> Void
    private let session: URLSession
    private let sendQueue = DispatchQueue(label: "ai.writingmate.openai-realtime-send")

    private var task: URLSessionWebSocketTask?
    private var pendingEvents: [[String: Any]] = []
    private var isClosed = false
    private var accumulatedTranscript = ""
    private var finalTranscript: String?
    private var failedMessage: String?
    private var finishContinuation: CheckedContinuation<String?, Never>?
    private var finishTimeoutTask: Task<Void, Never>?

    init(
        apiKey: String,
        prompt: String?,
        onPartialTranscript: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        self.authorizationProvider = {
            guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
                throw OpenAIRealtimeTranscriptionClientError.clientSecretRequestFailed("Invalid OpenAI Realtime URL")
            }
            return WritingmateRealtimeClientSecretProvider.Authorization(token: apiKey, webSocketURL: url)
        }
        self.prompt = prompt
        self.shouldSendSessionUpdate = true
        self.onPartialTranscript = onPartialTranscript
        self.onError = onError
        self.session = URLSession(configuration: .default)
    }

    init(
        authorizationProvider: @escaping () async throws -> WritingmateRealtimeClientSecretProvider.Authorization,
        prompt: String?,
        onPartialTranscript: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        self.authorizationProvider = authorizationProvider
        self.prompt = prompt
        self.shouldSendSessionUpdate = false
        self.onPartialTranscript = onPartialTranscript
        self.onError = onError
        self.session = URLSession(configuration: .default)
    }

    func start() {
        sendQueue.async { [weak self] in
            self?.isClosed = false
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await authorizationProvider()
                openSocket(authorization: authorization)
            } catch {
                self.fail("OpenAI Realtime token failed: \(error.localizedDescription)")
            }
        }
    }

    func sendAudio(_ pcm24kMono16: Data) {
        guard !pcm24kMono16.isEmpty else { return }

        sendEvent([
            "type": "input_audio_buffer.append",
            "audio": pcm24kMono16.base64EncodedString(),
        ])
    }

    func finish(timeout: TimeInterval = 1.5) async -> String? {
        if failedMessage != nil {
            return nil
        }

        if let finalTranscript {
            close()
            return finalTranscript
        }

        return await withCheckedContinuation { continuation in
            if let finalTranscript {
                continuation.resume(returning: finalTranscript)
                return
            }
            if failedMessage != nil {
                continuation.resume(returning: nil)
                return
            }

            finishContinuation = continuation
            let currentTranscript = accumulatedTranscript.isEmpty ? nil : accumulatedTranscript
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resumeFinishIfNeeded(with: self?.finalTranscript ?? currentTranscript)
            }
            sendEvent(["type": "input_audio_buffer.commit"])
        }
    }

    func close() {
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        resumeFinishIfNeeded(with: finalTranscript ?? (accumulatedTranscript.isEmpty ? nil : accumulatedTranscript))
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.isClosed = true
            self.pendingEvents.removeAll()
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
        }
    }

    private func openSocket(authorization: WritingmateRealtimeClientSecretProvider.Authorization) {
        sendQueue.async { [weak self] in
            guard let self, self.task == nil, !self.isClosed else { return }

            var request = URLRequest(url: authorization.webSocketURL)
            request.setValue("Bearer \(authorization.token)", forHTTPHeaderField: "Authorization")

            let socket = self.session.webSocketTask(with: request)
            self.task = socket
            socket.resume()
            self.receiveNextMessage()
            if self.shouldSendSessionUpdate {
                self.sendEventOnQueue(self.sessionUpdateEvent())
            }

            let queuedEvents = self.pendingEvents
            self.pendingEvents.removeAll()
            queuedEvents.forEach { self.sendEventOnQueue($0) }
        }
    }

    private func sessionUpdateEvent() -> [String: Any] {
        var transcription: [String: Any] = [
            "model": "gpt-4o-mini-transcribe",
        ]
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
                        "noise_reduction": [
                            "type": "near_field",
                        ],
                        "transcription": transcription,
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.35,
                            "prefix_padding_ms": 150,
                            "silence_duration_ms": 300,
                        ],
                    ],
                ],
            ],
        ]
    }

    private func sendEvent(_ event: [String: Any]) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isClosed else { return }
            if self.task == nil {
                self.pendingEvents.append(event)
                return
            }
            self.sendEventOnQueue(event)
        }
    }

    private func sendEventOnQueue(_ event: [String: Any]) {
        guard let task else {
            pendingEvents.append(event)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let message = String(data: data, encoding: .utf8)
        else {
            return
        }

        let onError = onError
        task.send(.string(message)) { error in
            if let error {
                Task { @MainActor in
                    onError("OpenAI Realtime send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func receiveNextMessage() {
        task?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveNextMessage()
            case .failure(let error):
                self.fail("OpenAI Realtime receive failed: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
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
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = payload["delta"] as? String, !delta.isEmpty else { return }
            accumulatedTranscript += delta
            let transcript = accumulatedTranscript
            Task { @MainActor in
                onPartialTranscript(transcript)
            }
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = payload["transcript"] as? String else { return }
            finalTranscript = transcript
            accumulatedTranscript = transcript
            Task { @MainActor in
                onPartialTranscript(transcript)
            }
            resumeFinishIfNeeded(with: transcript)
        case "error":
            let message = ((payload["error"] as? [String: Any])?["message"] as? String) ?? "OpenAI Realtime error"
            fail(message)
        default:
            break
        }
    }

    private func fail(_ message: String) {
        if failedMessage != nil {
            return
        }
        failedMessage = message
        resumeFinishIfNeeded(with: nil)
        Task { @MainActor in
            onError(message)
        }
    }

    private func resumeFinishIfNeeded(with transcript: String?) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        continuation.resume(returning: transcript)
    }
}
