import Foundation

@main
struct ValidateIOSRealtimeTranscription {
    static func main() throws {
        try validateClientSecretEndpointDerivation()
        try validateModelResolution()
        try validateSharedClientContract()
        try validateIOSRecorderStreaming()
        try validateIOSCloudFlowWiring()
        print("iOS realtime transcription uses Writingmate client_secrets/WebSocket with batch fallback")
    }

    private static func validateClientSecretEndpointDerivation() throws {
        let cases: [(String, String)] = [
            (
                "https://writingmate.ai/api/openai/v1/audio/transcriptions",
                "https://writingmate.ai/api/openai/v1/realtime/client_secrets"
            ),
            (
                "https://www.writingmate.ai/api/openai/v1/audio/transcriptions",
                "https://www.writingmate.ai/api/openai/v1/realtime/client_secrets"
            ),
            (
                "https://example.com/v1/audio/transcriptions",
                "https://example.com/v1/realtime/client_secrets"
            ),
        ]
        for (input, expected) in cases {
            let derived = endpoint(from: input)
            precondition(derived == expected, "Derived \(derived ?? "nil") from \(input)")
        }
        precondition(endpoint(from: "wss://api.openai.com/v1/realtime") == nil)
        precondition(endpoint(from: "not a url") == nil)
    }

    private static func validateModelResolution() throws {
        precondition(resolvedModel(configured: "soniox/stt-async-v5", override: nil) == "gpt-live-transcribe")
        precondition(resolvedModel(configured: "", override: nil) == "gpt-live-transcribe")
        precondition(resolvedModel(configured: "gpt-transcribe", override: nil) == "gpt-transcribe")
        precondition(
            resolvedModel(configured: "gpt-transcribe", override: "gpt-live-transcribe")
                == "gpt-live-transcribe"
        )
    }

    private static func validateSharedClientContract() throws {
        let client = try contents(
            "Whishpermate/WhisperMateShared/Services/OpenAIRealtimeTranscriptionClient.swift"
        )
        precondition(client.contains("public static func endpoint(from transcriptionEndpoint: String)"))
        precondition(client.contains("/realtime/client_secrets"))
        precondition(client.contains("func requestFinish(timeout: TimeInterval = 1.5)"))
        precondition(client.contains("func awaitFinish() async -> String?"))
        precondition(client.contains("static let defaultTranscriptionModel = \"gpt-live-transcribe\""))
        precondition(client.contains("input_audio_buffer.append"))
        precondition(client.contains("intent"))
        precondition(client.contains("transcription"))

        let support = try contents(
            "Whishpermate/WhisperMateShared/Services/WritingmateRealtimeSessionSupport.swift"
        )
        precondition(support.contains("isWritingmateSessionEndpoint"))
        precondition(support.contains("/api/openai/v1/realtime/client_secrets"))
        precondition(support.contains("AuthManager") == false)

        let coordinator = try contents(
            "Whishpermate/WhisperMateShared/Services/IOSRealtimeTranscriptionCoordinator.swift"
        )
        precondition(coordinator.contains("WritingmateRealtimeClientSecretProvider.fetchAuthorization"))
        precondition(coordinator.contains("AuthManager.shared.accessToken()"))
        precondition(coordinator.contains("OpenAIRealtimeTranscriptionClient"))
        precondition(coordinator.contains("prefersRealtimeRecognition"))
        precondition(coordinator.contains("CloudTranscriptionConsent.isGranted"))
        precondition(coordinator.contains("recorder.realtimeAudioChunkHandler"))
        precondition(coordinator.contains("detachRealtimeAudioChunkHandlerAndDrain"))
        precondition(coordinator.contains("if coverageIsComplete"))
        precondition(coordinator.contains("request?.requestFinish"))
        precondition(coordinator.contains("request?.close()"))
        precondition(coordinator.contains("armDrainDeadline"))
    }

    private static func validateIOSRecorderStreaming() throws {
        let recorder = try contents(
            "Whishpermate/WhisperMateShared/Services/AudioRecorder.swift"
        )
        precondition(recorder.contains("realtimeAudioChunkHandler"))
        precondition(recorder.contains("RealtimeAudioDeliveryQueue"))
        precondition(recorder.contains("RealtimePCMConverter"))
        precondition(recorder.contains("startRealtimeCaptureTapOnQueueIfNeeded()"))
        precondition(recorder.contains("continuation.resume(returning: recordingURL)"))
        let resumePosition = recorder.range(of: "continuation.resume(returning: recordingURL)")!.lowerBound
        let tapPosition = recorder.range(
            of: "startRealtimeCaptureTapOnQueueIfNeeded()",
            range: resumePosition..<recorder.endIndex
        )?.lowerBound
        precondition(tapPosition != nil, "Realtime tap must start after the start continuation resumes")
        precondition(recorder.contains("Best-effort PCM tap for cloud realtime"))
        precondition(recorder.contains("detachRealtimeAudioChunkHandlerAndDrain"))
        precondition(!recorder.contains("Thread.sleep"))
        precondition(!recorder.contains("usleep("))
        precondition(recorder.contains("AVAudioRecorder owns the encoder"))
    }

    private static func validateIOSCloudFlowWiring() throws {
        let content = try contents("Whishpermate/WhisperMateIOS/ContentView.swift")
        let sheet = try contents("Whishpermate/WhisperMateIOS/RecordingSheetView.swift")
        let shared = try contents(
            "Whishpermate/WhisperMateShared/Services/SharedTranscriptionService.swift"
        )

        for source in [content, sheet] {
            precondition(source.contains("IOSRealtimeTranscriptionCoordinator"))
            precondition(source.contains("startIfAvailable("))
            precondition(source.contains("beginFinish(recorder:"))
            precondition(source.contains("completeRealtimeTranscript("))
            precondition(source.contains("SharedTranscriptionService.transcribe("))
            precondition(source.contains("prefersRealtimeRecognition"))
            precondition(source.contains("realtimeTranscription.cancel(recorder:"))
        }

        let contentStart = try requiredSection(
            content,
            from: "self.realtimeTranscription.startIfAvailable(",
            to: "try await recorder.startRecording("
        )
        precondition(contentStart.contains("startIfAvailable"))

        let sheetStart = try requiredSection(
            sheet,
            from: "realtimeTranscription.startIfAvailable(",
            to: "try await recorder.startRecording("
        )
        precondition(sheetStart.contains("startIfAvailable"))

        precondition(shared.contains("prefersRealtimeRecognition"))
        precondition(shared.contains("outputMode == .dictation"))
        precondition(shared.contains("!transcriptionOptions.diarization"))
        precondition(shared.contains("provider == .custom"))
        precondition(shared.contains("completeRealtimeTranscript("))
        precondition(shared.contains("SecretsLoader.customTranscriptionRealtimeModel()"))
        precondition(
            shared.contains("WritingmateRealtimeSessionSupport.configuredOverrideEndpoint()")
        )

        precondition(content.contains("shouldUseOnDeviceTranscription"))
        precondition(sheet.contains("shouldUseOnDeviceTranscription"))
        precondition(content.contains("SharedParakeetTranscriptionService"))
        precondition(sheet.contains("SharedParakeetTranscriptionService"))
    }

    private static func endpoint(from transcriptionEndpoint: String) -> String? {
        guard var components = URLComponents(string: transcriptionEndpoint) else { return nil }
        let scheme = components.scheme?.lowercased()
        if scheme == "ws" || scheme == "wss" {
            return nil
        }
        let path = components.path
        if path.hasSuffix("/audio/transcriptions") {
            components.path = String(path.dropLast("/audio/transcriptions".count)) + "/realtime/client_secrets"
        } else {
            components.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/realtime/client_secrets"
            if !components.path.hasPrefix("/") {
                components.path = "/" + components.path
            }
        }
        return components.url?.absoluteString
    }

    private static func resolvedModel(configured: String, override: String?) -> String {
        if let override { return override }
        let model = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !model.contains("/"), model != "soniox/stt-async-v5" else {
            return "gpt-live-transcribe"
        }
        return model
    }

    private static func contents(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    private static func requiredSection(
        _ source: String,
        from: String,
        to: String
    ) throws -> String {
        guard let start = source.range(of: from),
              let end = source.range(of: to, range: start.lowerBound..<source.endIndex)
        else {
            throw ValidationFailure.failed("Missing section from \(from) to \(to)")
        }
        return String(source[start.lowerBound..<end.upperBound])
    }
}

private enum ValidationFailure: Error {
    case failed(String)
}
