import Foundation
import WhisperMateShared

nonisolated final class CodexRealtimeTranscriptionClient: @unchecked Sendable, RealtimeTranscriptionStreaming {
    private let queue = DispatchQueue(label: "ai.writingmate.codex-realtime")
    private let finishGate: RealtimeTranscriptionFinishGate
    private let readyGate: RealtimeTranscriptionFinishGate
    private let onTranscript: @Sendable (String) -> Void
    private let onError: @Sendable (String) -> Void

    private var authorizationTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var outboundMessages: [URLSessionWebSocketTask.Message] = []
    private var isSending = false
    private var pendingAudio: [String] = []
    private var pendingAudioBytes = 0
    private var sessionStarted = false
    private var finishRequested = false
    private var isClosed = false
    private var orderedUtteranceIDs: [String] = []
    private var finalTextByUtteranceID: [String: String] = [:]

    private static let maximumPendingAudioBytes = 4 * 1024 * 1024

    init(
        onTranscript: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.onTranscript = onTranscript
        self.onError = onError
        finishGate = RealtimeTranscriptionFinishGate(queue: queue)
        readyGate = RealtimeTranscriptionFinishGate(queue: queue)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isClosed, self.authorizationTask == nil else { return }
            self.finishGate.reset()
            self.readyGate.reset()
            self.readyGate.begin(timeout: 10) { [weak self] in
                self?.fail("ChatGPT streaming did not become ready.")
            }
            self.authorizationTask = Task { [weak self] in
                do {
                    let credentials = try await CodexTranscriptionAuthentication.shared.credentials()
                    self?.queue.async { [weak self] in
                        self?.connect(credentials: credentials)
                    }
                } catch {
                    self?.queue.async { [weak self] in
                        self?.fail("Codex sign-in is unavailable.")
                    }
                }
            }
        }
    }

    func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        let encoded = audioData.base64EncodedString()
        queue.async { [weak self] in
            guard let self, !self.isClosed, !self.finishRequested else { return }
            let message = Self.jsonMessage([
                "type": "audio.append",
                "audio": encoded,
            ])
            if self.sessionStarted {
                self.enqueue(message)
            } else {
                self.pendingAudioBytes += audioData.count
                guard self.pendingAudioBytes <= Self.maximumPendingAudioBytes else {
                    self.fail("Codex streaming audio exceeded the startup buffer.")
                    return
                }
                self.pendingAudio.append(message)
            }
        }
    }

    func requestFinish(timeout: TimeInterval) {
        queue.async { [weak self] in
            guard let self, !self.isClosed, !self.finishRequested else { return }
            self.finishRequested = true
            self.finishGate.begin(timeout: timeout) { [weak self] in
                self?.fail("Codex streaming transcription timed out.")
            }
            if self.sessionStarted {
                self.enqueue(Self.jsonMessage(["type": "session.close"]))
            }
        }
    }

    func awaitFinish() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.finishGate.wait(continuation)
            }
        }
    }

    func awaitReady() async -> Bool {
        let result: String? = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.readyGate.wait(continuation)
            }
        }
        return result != nil
    }

    func close() {
        queue.async { [weak self] in
            self?.closeOnQueue(resolveWith: nil)
        }
    }

    private func connect(
        credentials: CodexTranscriptionAuthentication.Credentials
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed, socket == nil else { return }

        let protocols = [
            "chatgpt-dictation",
            "openai-bearer.\(credentials.accessToken)",
            "codex-desktop",
        ]
        var request = URLRequest(url: CodexTranscriptionSupport.webSocketEndpoint)
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("Codex Desktop/AIDictation", forHTTPHeaderField: "User-Agent")
        request.setValue(
            protocols.joined(separator: ", "),
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receiveTask = Task { [weak self, weak socket] in
            guard let socket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    self?.queue.async { [weak self] in
                        self?.handle(message)
                    }
                }
            } catch {
                self?.queue.async { [weak self] in
                    guard let self, !self.isClosed else { return }
                    self.fail("Codex streaming connection closed before completion.")
                }
            }
        }
        enqueue(Self.sessionStartMessage)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }

        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let value):
            data = value
        @unknown default:
            fail("Codex streaming returned an unsupported message.")
            return
        }

        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else {
            fail("Codex streaming returned an unreadable event.")
            return
        }

        switch type {
        case "session.started":
            sessionStarted = true
            readyGate.resolve(with: "ready")
            let audio = pendingAudio
            pendingAudio.removeAll(keepingCapacity: false)
            pendingAudioBytes = 0
            audio.forEach(enqueue)
            if finishRequested {
                enqueue(Self.jsonMessage(["type": "session.close"]))
            }
        case "transcript.final":
            guard let utteranceID = event["utterance_id"] as? String,
                  let text = event["text"] as? String
            else { return }
            if finalTextByUtteranceID[utteranceID] == nil {
                orderedUtteranceIDs.append(utteranceID)
            }
            finalTextByUtteranceID[utteranceID] = text
            let transcript = completedTranscript
            if !transcript.isEmpty {
                Task { @MainActor [onTranscript] in onTranscript(transcript) }
            }
        case "session.updated":
            let session = event["session"] as? [String: Any]
            guard session?["status"] as? String == "closed" else { return }
            let transcript = completedTranscript
            closeOnQueue(resolveWith: transcript.isEmpty ? nil : transcript)
        case "transcript.failed":
            fail(Self.errorMessage(from: event) ?? "Codex transcription failed.")
        case "session.error":
            if event["fatal"] as? Bool == true {
                fail(Self.errorMessage(from: event) ?? "Codex streaming session failed.")
            }
        case "speech.started", "speech.stopped", "transcript.delta", "transcript.segment":
            break
        default:
            break
        }
    }

    private func enqueue(_ text: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        outboundMessages.append(.string(text))
        sendNextIfNeeded()
    }

    private func sendNextIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isSending, let socket, !outboundMessages.isEmpty else { return }
        isSending = true
        let message = outboundMessages.removeFirst()
        socket.send(message) { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.isSending = false
                if error != nil {
                    self.fail("Codex streaming could not send audio.")
                } else {
                    self.sendNextIfNeeded()
                }
            }
        }
    }

    private func fail(_ message: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        Task { @MainActor [onError] in onError(message) }
        closeOnQueue(resolveWith: nil)
    }

    private func closeOnQueue(resolveWith transcript: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        isClosed = true
        authorizationTask?.cancel()
        authorizationTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        outboundMessages.removeAll()
        pendingAudio.removeAll()
        readyGate.resolve(with: nil)
        finishGate.resolve(with: transcript)
    }

    private var completedTranscript: String {
        orderedUtteranceIDs
            .compactMap { finalTextByUtteranceID[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static var sessionStartMessage: String {
        jsonMessage([
            "type": "session.start",
            "config": [
                "input_audio_format": "pcm16",
                "sample_rate_hz": 24_000,
                "num_channels": 1,
                "max_buffer_size_bytes": maximumPendingAudioBytes,
                "max_utterance_duration_ms": 30_000,
                "session_ttl_ms": 300_000,
                "provider_mode": "streaming_sse",
                "transcript_delivery_mode": "final_only",
                "vad": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500,
                ],
            ],
        ])
    }

    private static func jsonMessage(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorMessage(from event: [String: Any]) -> String? {
        (event["error"] as? [String: Any])?["message"] as? String
    }
}
