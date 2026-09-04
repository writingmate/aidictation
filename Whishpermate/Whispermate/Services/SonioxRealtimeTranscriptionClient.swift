import Foundation
import WhisperMateShared

nonisolated final class SonioxRealtimeTranscriptionClient: @unchecked Sendable, RealtimeTranscriptionStreaming {
    typealias AuthorizationProvider = @Sendable () async throws -> WritingmateRealtimeClientSecretProvider.Authorization

    private struct QueuedMessage {
        let message: URLSessionWebSocketTask.Message
        let audioByteCount: Int
    }

    private static let maximumPendingAudioBytes = 16 * 1024 * 1024

    private let authorizationProvider: AuthorizationProvider
    private let languages: [String]
    private let keywords: [String]
    private let prompt: String?
    private let onPartialTranscript: @MainActor @Sendable (String) -> Void
    private let onError: @MainActor @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "ai.writingmate.soniox-realtime")
    private let session = URLSession(configuration: .default)
    private let finishGate: RealtimeTranscriptionFinishGate

    private var authorizationTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var outboundMessages: [QueuedMessage] = []
    private var isSending = false
    private var pendingAudioBytes = 0
    private var transcriptState = SonioxRealtimeTranscriptState()
    private var isClosed = false
    private var didRequestFinish = false
    private var finishRequestedAt: ContinuousClock.Instant?

    init(
        authorizationProvider: @escaping AuthorizationProvider,
        languages: [String],
        keywords: [String],
        prompt: String?,
        onPartialTranscript: @escaping @MainActor @Sendable (String) -> Void,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.authorizationProvider = authorizationProvider
        self.languages = languages
        self.keywords = keywords
        self.prompt = prompt
        self.onPartialTranscript = onPartialTranscript
        self.onError = onError
        finishGate = RealtimeTranscriptionFinishGate(queue: queue)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.authorizationTask == nil, !self.isClosed else { return }
            self.finishGate.reset()
            self.authorizationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let authorization = try await self.authorizationProvider()
                    try Task.checkCancellation()
                    self.queue.async { [weak self] in
                        self?.openSocket(authorization: authorization)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    let message = self.authorizationFailureMessage(for: error)
                    self.queue.async { [weak self] in
                        self?.failOnQueue(message)
                    }
                }
            }
        }
    }

    func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.isClosed, !self.didRequestFinish else { return }
            self.pendingAudioBytes += audioData.count
            guard self.pendingAudioBytes <= Self.maximumPendingAudioBytes else {
                self.failOnQueue("Fast streaming could not keep up with the recording.")
                return
            }
            self.enqueue(.data(audioData), audioByteCount: audioData.count)
        }
    }

    func requestFinish(timeout: TimeInterval) {
        queue.async { [weak self] in
            guard let self, !self.isClosed, !self.didRequestFinish else { return }
            self.didRequestFinish = true
            self.finishRequestedAt = ContinuousClock.now
            self.finishGate.begin(timeout: timeout) { [weak self] in
                guard let self else { return }
                DebugLog.info(
                    "Soniox finalization timed out; discarding unproven stream",
                    context: "SonioxRealtime"
                )
                self.abandonTransportOnQueue()
            }
            let finalizationSilence = SonioxRealtimeProtocol.finalizationSilence
            self.pendingAudioBytes += finalizationSilence.count
            self.enqueue(
                .data(finalizationSilence),
                audioByteCount: finalizationSilence.count
            )
            self.enqueue(.string(String(decoding: SonioxRealtimeProtocol.finalizeMessage, as: UTF8.self)))
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

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.abandonTransportOnQueue()
            self.finishGate.resolve(with: nil)
        }
    }

    private func openSocket(
        authorization: WritingmateRealtimeClientSecretProvider.Authorization
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard socket == nil, !isClosed else { return }

        let socket = session.webSocketTask(with: authorization.webSocketURL)
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
                    self.failOnQueue("Fast streaming disconnected before the transcript was complete.")
                }
            }
        }

        do {
            let configuration = try SonioxRealtimeProtocol.configurationData(
                temporaryAPIKey: authorization.token,
                languages: languages,
                keywords: keywords,
                prompt: prompt
            )
            enqueue(.string(String(decoding: configuration, as: UTF8.self)), atFront: true)
        } catch {
            failOnQueue("Fast streaming could not configure the recording.")
        }
    }

    private func enqueue(
        _ message: URLSessionWebSocketTask.Message,
        audioByteCount: Int = 0,
        atFront: Bool = false
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        let queuedMessage = QueuedMessage(
            message: message,
            audioByteCount: audioByteCount
        )
        if atFront {
            outboundMessages.insert(queuedMessage, at: 0)
        } else {
            outboundMessages.append(queuedMessage)
        }
        sendNextIfNeeded()
    }

    private func sendNextIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isSending, let socket, !outboundMessages.isEmpty else { return }
        isSending = true
        let queuedMessage = outboundMessages.removeFirst()
        socket.send(queuedMessage.message) { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.isSending = false
                self.pendingAudioBytes = max(
                    0,
                    self.pendingAudioBytes - queuedMessage.audioByteCount
                )
                if error != nil {
                    self.failOnQueue("Fast streaming could not send the recording.")
                } else {
                    self.sendNextIfNeeded()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }

        let data: Data
        switch message {
        case .string(let value):
            data = Data(value.utf8)
        case .data(let value):
            data = value
        @unknown default:
            failOnQueue("Fast streaming returned an unreadable response.")
            return
        }

        do {
            guard let update = try transcriptState.consume(data) else { return }
            if !update.transcript.isEmpty {
                Task { @MainActor [onPartialTranscript] in
                    onPartialTranscript(update.transcript)
                }
            }
            if update.isFinalizationComplete {
                let elapsedMilliseconds = finishRequestedAt.map {
                    let components = $0.duration(to: .now).components
                    return Int(components.seconds) * 1_000
                        + Int(components.attoseconds / 1_000_000_000_000_000)
                }
                DebugLog.info(
                    "Soniox finalization completed keyUpToFinalMs=\(elapsedMilliseconds ?? -1) transcriptLength=\(update.transcript.count)",
                    context: "SonioxRealtime"
                )
                let transcript = update.transcript.isEmpty ? nil : update.transcript
                abandonTransportOnQueue()
                finishGate.resolve(with: transcript)
            }
        } catch let error as SonioxRealtimeProtocolError {
            switch error {
            case .invalidResponse:
                failOnQueue("Fast streaming returned an unreadable response.")
            case .upstream(let type, _):
                DebugLog.warning(
                    "Soniox realtime upstream error type=\(type)",
                    context: "SonioxRealtime"
                )
                failOnQueue("Fast streaming could not complete this recording.")
            }
        } catch {
            failOnQueue("Fast streaming could not read the transcript.")
        }
    }

    private func authorizationFailureMessage(for error: Error) -> String {
        if let realtimeError = error as? OpenAIRealtimeTranscriptionClientError,
           case .clientSecretRequestFailed(let detail) = realtimeError,
           !detail.isEmpty
        {
            return detail
        }
        return "Fast streaming could not start."
    }

    private func failOnQueue(_ message: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        abandonTransportOnQueue()
        finishGate.resolve(with: nil)
        Task { @MainActor [onError] in onError(message) }
    }

    private func abandonTransportOnQueue() {
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
        pendingAudioBytes = 0
    }
}
