import Foundation

/// Owns one iOS cloud-mode realtime stream: client_secrets, WebSocket, and
/// PCM delivery into the shared recorder. Batch upload remains the fallback
/// when this session is missing or returns an empty transcript.
@MainActor
public final class IOSRealtimeTranscriptionCoordinator {
    private var client: (any RealtimeTranscriptionStreaming)?
    private var finishRequest: RealtimeTranscriptionFinishRequest?

    public init() {}

    public var isActive: Bool {
        client != nil || finishRequest != nil
    }

    public func startIfAvailable(
        recorder: AudioRecorder,
        request: SharedTranscriptionService.RequestSnapshot
    ) {
        cancel(recorder: recorder)

        guard request.prefersRealtimeRecognition,
              CloudTranscriptionConsent.isGranted,
              let context = request.realtimeContext
        else {
            DebugLog.info(
                "Skipping realtime start transport=\(request.prefersRealtimeRecognition ? "realtime" : "batch")",
                context: "IOSRealtime"
            )
            return
        }

        let realtimeModel = WritingmateRealtimeSessionSupport.resolvedModel(
            configuredModel: context.configuredModel,
            overrideModel: context.customRealtimeModel
        )
        let overrideEndpoint = context.customRealtimeEndpoint
        let client: OpenAIRealtimeTranscriptionClient

        if let webSocketURL = WritingmateRealtimeSessionSupport.webSocketURL(
            configuredEndpoint: context.transcriptionEndpoint,
            overrideEndpoint: overrideEndpoint
        ) {
            guard !context.apiKey.isEmpty else { return }
            client = OpenAIRealtimeTranscriptionClient(
                apiKey: context.apiKey,
                webSocketURL: webSocketURL,
                transcriptionModel: realtimeModel,
                language: context.language,
                keywords: context.keywords,
                languages: context.languages,
                prompt: context.prompt,
                onPartialTranscript: { _ in },
                onError: { message in
                    DebugLog.warning(message, context: "IOSRealtime")
                }
            )
        } else {
            guard let endpoint = WritingmateRealtimeSessionSupport.sessionEndpoint(
                configuredEndpoint: context.transcriptionEndpoint,
                overrideEndpoint: overrideEndpoint
            ) else {
                DebugLog.warning("Invalid custom realtime session endpoint", context: "IOSRealtime")
                return
            }

            // Writingmate realtime needs a signed-in first-party session. Without
            // one the token fetch always fails; skip the doomed stream and let
            // batch upload (free local quota) carry the recording.
            if WritingmateRealtimeSessionSupport.isWritingmateSessionEndpoint(endpoint),
               !AuthManager.shared.isAuthenticated {
                DebugLog.info("Skipping realtime start: not signed in; using batch upload", context: "IOSRealtime")
                return
            }

            let prompt = context.prompt
            let language = context.language
            let keywords = context.keywords
            let languages = context.languages
            let apiKey = context.apiKey
            client = OpenAIRealtimeTranscriptionClient(
                authorizationProvider: {
                    let token: String
                    if WritingmateRealtimeSessionSupport.isWritingmateSessionEndpoint(endpoint) {
                        token = try await AuthManager.shared.accessToken()
                    } else if !apiKey.isEmpty {
                        token = apiKey
                    } else {
                        throw OpenAIRealtimeTranscriptionClientError.clientSecretRequestFailed(
                            "Cloud transcription credentials are unavailable"
                        )
                    }
                    return try await WritingmateRealtimeClientSecretProvider.fetchAuthorization(
                        endpoint: endpoint,
                        apiKey: token,
                        model: realtimeModel,
                        prompt: prompt,
                        language: language,
                        keywords: keywords,
                        languages: languages
                    )
                },
                prompt: prompt,
                transcriptionModel: realtimeModel,
                language: language,
                keywords: keywords,
                languages: languages,
                onPartialTranscript: { _ in },
                onError: { message in
                    DebugLog.warning(message, context: "IOSRealtime")
                }
            )
        }

        self.client = client
        client.start()
        recorder.realtimeAudioChunkHandler = { [weak client] chunk in
            client?.sendAudio(chunk)
        }
        DebugLog.info("Started realtime transcription stream for cloud dictation", context: "IOSRealtime")
    }

    @discardableResult
    public func beginFinish(
        recorder: AudioRecorder,
        timeout: TimeInterval = WritingmateRealtimeSessionSupport.finishTimeout
    ) -> RealtimeTranscriptionFinishRequest? {
        let request = takeFinishRequest(drainDeadline: timeout)
        if request == nil {
            recorder.detachRealtimeAudioChunkHandlerAndDrain { _ in }
            return nil
        }
        recorder.detachRealtimeAudioChunkHandlerAndDrain { coverageIsComplete in
            if coverageIsComplete {
                request?.requestFinish(timeout: timeout)
            } else {
                request?.close()
            }
        }
        return request
    }

    public func cancel(recorder: AudioRecorder?) {
        recorder?.realtimeAudioChunkHandler = nil
        recorder?.detachRealtimeAudioChunkHandlerAndDrain { _ in }
        finishRequest?.close()
        client?.close()
        finishRequest = nil
        client = nil
    }

    public func completedTranscript() async -> String? {
        let request = finishRequest
        let text = await request?.finish()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if finishRequest === request {
            finishRequest = nil
        }
        if text?.isEmpty == false {
            return text
        }
        request?.close()
        return nil
    }

    public func closeFinishRequest() {
        finishRequest?.close()
        finishRequest = nil
        client = nil
    }

    private func takeFinishRequest(
        drainDeadline: TimeInterval?
    ) -> RealtimeTranscriptionFinishRequest? {
        let client = client
        self.client = nil
        let request = client.map(RealtimeTranscriptionFinishRequest.init(client:))
        if let request {
            finishRequest?.close()
            finishRequest = request
            if let drainDeadline {
                request.armDrainDeadline(timeout: drainDeadline)
            }
        }
        return request
    }
}
