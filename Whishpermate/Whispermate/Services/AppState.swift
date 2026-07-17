import Foundation
import SwiftUI
internal import Combine
import AVFoundation
import WhisperMateShared

/// Central application state - single source of truth for app state
/// Recording works completely independently of view lifecycle
class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - State Enums

    enum RecordingState {
        case idle
        case recording
        case transcribing
        case pasting
    }

    enum AppContext {
        case foreground
        case background
    }

    enum RecordingMode {
        case dictation
        case command
    }

    // MARK: - Published State

    @Published var recordingState: RecordingState = .idle
    @Published var appContext: AppContext = .foreground
    @Published var transcriptionText: String = ""
    @Published var lastOutputText: String = "" // Last text pasted to document (for command mode chaining)
    @Published var errorMessage: String = ""
    @Published var currentRecording: Recording?
    @Published var isProcessing: Bool = false

    // MARK: - Private State

    private var shouldAutoPaste = false
    private var isContinuousRecording = false
    private var recordingStartTime: Date?
    private var capturedAppContext: String?
    private var capturedAppBundleId: String?
    private var capturedWindowTitle: String?
    private var capturedScreenContext: String?
    private var recordingMode: RecordingMode = .dictation
    private var shouldKeepOverlayIdleVisibleAfterCurrentRecording = false
    private var realtimeTranscriptionClient: OpenAIRealtimeTranscriptionClient?
    private var realtimeTranscript: String = ""
    private let diarizationTimeoutSeconds: UInt64 = 75
    private let llmPostProcessingTimeoutSeconds: UInt64 = 45

    // MARK: - Dependencies (singletons)

    private lazy var audioRecorder = AudioRecorder.shared
    private let historyManager = HistoryManager.shared
    private let overlayManager = OverlayWindowManager.shared
    private let vadSettingsManager = VADSettingsManager.shared
    private let onboardingManager = OnboardingManager.shared
    let transcriptionProviderManager = TranscriptionProviderManager.shared
    private let llmProviderManager = LLMProviderManager.shared
    private let dictionaryManager = DictionaryManager.shared
    private let contextRulesManager = ContextRulesManager.shared
    private let shortcutManager = ShortcutManager.shared
    private let languageManager = LanguageManager.shared
    private let screenCaptureManager = ScreenCaptureManager.shared

    private var openAIClient: OpenAIClient?

    private init() {
        // Set up app state observers
        setupAppStateObservers()
    }

    // MARK: - Public API

    /// Start recording audio
    /// - Parameters:
    ///   - continuous: Whether this is continuous recording mode
    ///   - isCommandMode: Whether this is command mode (set by startCommandRecording)
    func startRecording(continuous: Bool = false, isCommandMode: Bool = false, showOverlayControls: Bool = false) {
        DebugLog.info("🎬 AppState.startRecording(continuous: \(continuous), isCommandMode: \(isCommandMode), showOverlayControls: \(showOverlayControls))", context: "AppState")

        // Don't start if already recording
        guard recordingState == .idle else {
            DebugLog.info("⚠️ Already in state: \(recordingState)", context: "AppState")
            return
        }

        // Reset recording mode - command mode is only active when explicitly requested
        if !isCommandMode {
            recordingMode = .dictation
        }

        let shouldShowOverlayControls = showOverlayControls && !isCommandMode
        shouldKeepOverlayIdleVisibleAfterCurrentRecording = shouldShowOverlayControls

        // Set state
        recordingState = .recording
        isContinuousRecording = continuous
        shouldAutoPaste = true // Always auto-paste when hotkey is triggered
        recordingStartTime = Date()

        DebugLog.info("Recording mode: \(recordingMode)", context: "AppState")

        // Clear previous state
        ClipboardManager.cancelLiveDictationInsertion(removeInsertedText: false)
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = ""
            self?.transcriptionText = ""
        }

        // Notify that recording started
        NotificationCenter.default.post(name: .recordingStarted, object: nil)

        // Capture app context for tone/style customization
        if let context = AppContextHelper.getCurrentAppContext() {
            capturedAppContext = context.description
            capturedAppBundleId = context.bundleId
            capturedWindowTitle = context.windowTitle
            DebugLog.info("Captured app context: \(context.description)", context: "AppState")
        }

        // Capture screen context if enabled
        capturedScreenContext = nil
        if screenCaptureManager.includeScreenContext {
            Task {
                if let screenContext = await screenCaptureManager.captureAndExtractText() {
                    await MainActor.run {
                        self.capturedScreenContext = screenContext
                        DebugLog.info("Captured screen context", context: "AppState")
                    }
                }
            }
        }

        // Store previous app for pasting
        ClipboardManager.storePreviousApp()

        startRealtimeTranscriptionIfAvailable()

        // Start audio recording
        overlayManager.initializeAudioObservers()
        audioRecorder.startRecording()

        if audioRecorder.isRecording {
            DebugLog.info("✅ Recording started successfully", context: "AppState")
            if overlayManager.isOverlayMode {
                let isCommand = (recordingMode == .command)
                overlayManager.setRecordingControlsVisible(shouldShowOverlayControls && !isCommand)
                if !shouldShowOverlayControls {
                    overlayManager.setHoverExpanded(true)
                }
                overlayManager.transition(to: .recording(isCommandMode: isCommand))
                DebugLog.info("Overlay transitioned to recording (command: \(isCommand))", context: "AppState")
            }
        } else {
            DebugLog.info("❌ Recording failed to start", context: "AppState")
            let realtimeClient = stopRealtimeTranscription()
            realtimeClient?.close()
            recordingState = .idle
            errorMessage = "Failed to start recording"
            shouldKeepOverlayIdleVisibleAfterCurrentRecording = false
            finishOverlayAfterRecording()
        }
    }

    /// Start recording in command mode - voice instruction to transform text
    func startCommandRecording() {
        DebugLog.info("🎬 AppState.startCommandRecording()", context: "AppState")
        DebugLog.info("🎯 Command mode activated", context: "AppState")
        recordingMode = .command
        // Capture target text (selected text or last dictation) before recording starts
        CommandModeManager.shared.prepareForCommand()
        DebugLog.info("🎯 Target text captured: '\(CommandModeManager.shared.targetText.prefix(100))...'", context: "AppState")
        startRecording(continuous: false, isCommandMode: true, showOverlayControls: false)
    }

    /// Stop recording and begin transcription
    func stopRecording() {
        DebugLog.info("🛑 AppState.stopRecording()", context: "AppState")
        DebugLog.info(
            "Stop requested state=\(recordingState) continuous=\(isContinuousRecording) autoPaste=\(shouldAutoPaste) mode=\(recordingMode)",
            context: "DictationFlow"
        )

        guard recordingState == .recording else {
            DebugLog.info("⚠️ Not recording, current state: \(recordingState)", context: "AppState")
            return
        }

        // Check recording duration
        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)

            if duration < 0.3 {
                DebugLog.info("Recording too short (\(duration)s), skipping", context: "AppState")
                recordingState = .idle
                shouldAutoPaste = false
                recordingStartTime = nil
                recordingMode = .dictation
                _ = audioRecorder.stopRecording()
                let realtimeClient = stopRealtimeTranscription()
                realtimeClient?.close()
                ClipboardManager.cancelLiveDictationInsertion()

                finishOverlayAfterRecording()
                return
            }
        }

        // Stop audio recording
        guard let audioURL = audioRecorder.stopRecording() else {
            DebugLog.info("❌ Failed to get audio URL", context: "AppState")
            let realtimeClient = stopRealtimeTranscription()
            realtimeClient?.close()
            recordingState = .idle
            recordingMode = .dictation
            errorMessage = "Failed to save recording"
            ClipboardManager.cancelLiveDictationInsertion()
            finishOverlayAfterRecording()
            return
        }

        let realtimeClient = stopRealtimeTranscription()
        DebugLog.info("Realtime client captured on stop: \(realtimeClient != nil)", context: "DictationFlow")

        // Check file size
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            DebugLog.info(
                "Recording file ready name=\(audioURL.lastPathComponent) bytes=\(fileSize)",
                context: "DictationFlow"
            )

            if fileSize < 1000 {
                DebugLog.info("Audio file too small (\(fileSize) bytes)", context: "AppState")
                recordingState = .idle
                shouldAutoPaste = false
                recordingMode = .dictation
                try? FileManager.default.removeItem(at: audioURL)
                realtimeClient?.close()
                ClipboardManager.cancelLiveDictationInsertion()
                finishOverlayAfterRecording()
                return
            }
        } catch {
            DebugLog.info("Error checking file: \(error)", context: "AppState")
        }

        // Begin transcription
        transcribe(audioURL: audioURL, realtimeClient: realtimeClient)
    }

    /// Cancel recording, discard captured audio, and return to idle without transcription.
    func cancelRecording() {
        DebugLog.info("✕ AppState.cancelRecording()", context: "AppState")

        guard recordingState == .recording else {
            DebugLog.info("⚠️ Not recording, current state: \(recordingState)", context: "AppState")
            return
        }

        let audioURL = audioRecorder.stopRecording()
        let realtimeClient = stopRealtimeTranscription()
        realtimeClient?.close()
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }

        recordingState = .idle
        isContinuousRecording = false
        shouldAutoPaste = false
        recordingStartTime = nil
        recordingMode = .dictation

        ClipboardManager.cancelLiveDictationInsertion()
        finishOverlayAfterRecording()
    }

    /// Toggle continuous recording mode
    func toggleContinuousRecording() {
        DebugLog.info("🔄 AppState.toggleContinuousRecording()", context: "AppState")

        guard !onboardingManager.showOnboarding else { return }

        if isContinuousRecording, recordingState == .recording {
            // Stop continuous recording
            isContinuousRecording = false
            stopRecording()
        } else if recordingState == .idle {
            // Start continuous recording
            startRecording(continuous: true, showOverlayControls: false)
        }
    }

    /// Re-transcribe a recording from its saved audio file
    func retranscribe(recording: Recording) {
        DebugLog.info("🔄 AppState.retranscribe(id: \(recording.id))", context: "AppState")

        let audioURL = recording.audioFileURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            DebugLog.error("Audio file not found: \(audioURL.path)", context: "AppState")
            var updated = recording
            updated.errorMessage = "Audio file not found"
            updated.status = .failed
            historyManager.updateRecording(updated)
            return
        }

        // Mark as retrying
        var updated = recording
        updated.retryCount += 1
        updated.status = .retrying
        updated.errorMessage = nil
        historyManager.updateRecording(updated)

        Task {
            do {
                let result = try await performTranscription(
                    audioURL: audioURL,
                    appContext: nil,
                    clipboardContent: nil,
                    screenContext: nil,
                    outputMode: recording.outputMode,
                    transcriptionOptions: recording.transcriptionOptions
                )

                let wordCount = result.split(separator: " ").count
                await MainActor.run {
                    var success = recording
                    success.transcription = result
                    success.status = .success
                    success.errorMessage = nil
                    success.retryCount = updated.retryCount
                    success.wordCount = wordCount
                    historyManager.updateRecording(success)
                }
                DebugLog.info("✅ Re-transcription succeeded", context: "AppState")

            } catch {
                DebugLog.error("❌ Re-transcription failed: \(error)", context: "AppState")
                await MainActor.run {
                    var failed = recording
                    failed.status = .failed
                    failed.errorMessage = error.localizedDescription
                    failed.retryCount = updated.retryCount
                    historyManager.updateRecording(failed)
                }
            }
        }
    }

    // MARK: - Private Methods

    private func setupAppStateObservers() {
        // Listen for app going to background/foreground
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appContext = .background
            DebugLog.info("App went to background", context: "AppState")
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appContext = .foreground
            DebugLog.info("App came to foreground", context: "AppState")
        }

    }

    private func transcribe(audioURL: URL, realtimeClient: OpenAIRealtimeTranscriptionClient? = nil) {
        DebugLog.info("📝 AppState.transcribe()", context: "AppState")
        DebugLog.info(
            "Transcribe start audio=\(audioURL.lastPathComponent) realtimeClient=\(realtimeClient != nil) autoPaste=\(shouldAutoPaste) recordingMode=\(recordingMode)",
            context: "DictationFlow"
        )

        recordingState = .transcribing
        isProcessing = true

        if overlayManager.isOverlayMode {
            let isCommand = (recordingMode == .command)
            overlayManager.transition(to: .processing(isCommandMode: isCommand))
        }

        Task {
            do {
                // Check word limit for ALL users (authenticated and anonymous)
                let (canTranscribe, reason) = SubscriptionManager.shared.checkCanTranscribe()
                if !canTranscribe {
                    DebugLog.info("⚠️ Word limit reached: \(reason ?? "unknown")", context: "AppState")
                    await MainActor.run {
                        self.recordingState = .idle
                        self.isProcessing = false
                    }
                    ClipboardManager.cancelLiveDictationInsertion(removeInsertedText: false)
                    try? FileManager.default.removeItem(at: audioURL)
                    finishOverlayAfterRecording()

                    // Open Settings to Account section
                    await MainActor.run {
                        NotificationCenter.default.post(name: .openAccountSettings, object: nil)
                    }
                    return
                }

                let requestedOutputMode = self.requestedOutputMode()
                let transcriptionOptions = self.requestedTranscriptionOptions()
                let activeTransport = requestedOutputMode != .dictation || transcriptionOptions.diarization ? .batch : transcriptionProviderManager.effectiveTransport
                DebugLog.info(
                    "Transcribe routing outputMode=\(requestedOutputMode.rawValue) diarization=\(transcriptionOptions.diarization) activeTransport=\(activeTransport.rawValue) provider=\(transcriptionProviderManager.selectedProvider.rawValue)",
                    context: "DictationFlow"
                )
                let realtimeResult: String?
                if activeTransport == .realtime {
                    let finishTimeout = transcriptionProviderManager.selectedProvider == .custom ? 6.0 : 2.0
                    let result = await realtimeClient?.finish(timeout: finishTimeout)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let result, !result.isEmpty {
                        DebugLog.info("Realtime result accepted length=\(result.count)", context: "DictationFlow")
                        realtimeResult = result
                    } else {
                        DebugLog.warning("Realtime transcription unavailable; falling back to batch cloud transcription", context: "AppState")
                        realtimeClient?.close()
                        realtimeResult = nil
                    }
                } else {
                    DebugLog.info("Closing realtime client because active transport is \(activeTransport.rawValue)", context: "DictationFlow")
                    realtimeClient?.close()
                    realtimeResult = nil
                }

                // VAD check first unless realtime already returned text.
                if (realtimeResult?.isEmpty ?? true), vadSettingsManager.vadEnabled {
                    let vadStart = CFAbsoluteTimeGetCurrent()

                    let hasSpeech = try await VoiceActivityDetector.hasSpeech(
                        in: audioURL,
                        settings: vadSettingsManager
                    )
                    let vadMs = Int((CFAbsoluteTimeGetCurrent() - vadStart) * 1000)
                    DebugLog.info("⏱️ VAD took \(vadMs)ms, hasSpeech=\(hasSpeech)", context: "AppState")

                    if !hasSpeech {
                        DebugLog.info("🔇 No speech detected", context: "AppState")
                        await MainActor.run {
                            self.recordingState = .idle
                            self.isProcessing = false
                            self.shouldAutoPaste = false
                        }
                        ClipboardManager.cancelLiveDictationInsertion(removeInsertedText: false)
                        try? FileManager.default.removeItem(at: audioURL)
                        finishOverlayAfterRecording()
                        return
                    }
                }

                // Get screen context only. Normal dictation must not read or write the clipboard.
                let clipboardContent: String?
                let screenContextForTranscription: String?

                if self.recordingMode == .command {
                    clipboardContent = nil
                    screenContextForTranscription = nil
                    DebugLog.info("Command mode: transcribing voice instruction only", context: "AppState")
                } else {
                    clipboardContent = nil
                    screenContextForTranscription = capturedScreenContext
                }

                let transcriptionStart = CFAbsoluteTimeGetCurrent()
                let result: String
                if let realtimeResult, !realtimeResult.isEmpty {
                    DebugLog.info("Using realtime transcription result", context: "AppState")
                    result = dictionaryManager.applyReplacements(to: TranscriptionOutputFilter.filter(realtimeResult))
                } else {
                    DebugLog.info("Using batch transcription path", context: "DictationFlow")
                    result = try await performTranscription(
                        audioURL: audioURL,
                        appContext: capturedAppContext,
                        clipboardContent: clipboardContent,
                        screenContext: screenContextForTranscription,
                        outputMode: requestedOutputMode,
                        transcriptionOptions: transcriptionOptions
                    )
                }
                let transcriptionMs = Int((CFAbsoluteTimeGetCurrent() - transcriptionStart) * 1000)
                DebugLog.info("⏱️ Transcription took \(transcriptionMs)ms", context: "AppState")
                DebugLog.info("Transcription result length=\(result.count) words=\(result.split(separator: " ").count)", context: "DictationFlow")

                // Success - save to history
                let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

                // Move audio file to persistent storage
                guard let persistentURL = historyManager.copyAudioToPersistentStorage(from: audioURL) else {
                    DebugLog.error("Failed to save audio file", context: "AppState")
                    return
                }

                // Count words in transcription
                let wordCount = result.split(separator: " ").count

                // Update word count (works for both authenticated and anonymous users)
                await SubscriptionManager.shared.recordWords(wordCount)
                DebugLog.info("✅ Updated word count: +\(wordCount) words", context: "AppState")

                var recording = Recording(
                    audioFileURL: persistentURL,
                    transcription: result,
                    status: .success,
                    duration: duration,
                    outputMode: requestedOutputMode,
                    transcriptionOptions: transcriptionOptions
                )
                recording.wordCount = wordCount

                // Capture mode and target before resetting
                let wasCommandMode = self.recordingMode == .command
                let commandTargetText = CommandModeManager.shared.targetText

                // Update common state
                await MainActor.run {
                    self.recordingMode = .dictation // Reset recording mode
                    historyManager.addRecording(recording)
                    self.currentRecording = recording
                    self.transcriptionText = result // Always store raw transcription
                    self.recordingState = .idle
                    self.isProcessing = false
                }

                // Notify recording completed
                NotificationCenter.default.post(name: .recordingCompleted, object: recording)

                // Dispatch to appropriate handler based on mode
                DebugLog.info(
                    "Dispatching transcription result wasCommandMode=\(wasCommandMode) autoPaste=\(shouldAutoPaste) duration=\(duration)",
                    context: "DictationFlow"
                )
                if wasCommandMode {
                    await processCommandResult(instruction: result, targetText: commandTargetText)
                } else {
                    await processDictationResult(transcription: result)
                }

            } catch {
                DebugLog.info("❌ Transcription error: \(error)", context: "AppState")

                // Save failed recording
                let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

                if let persistentURL = historyManager.copyAudioToPersistentStorage(from: audioURL) {
                    let recording = Recording(
                        audioFileURL: persistentURL,
                        transcription: nil,
                        status: .failed,
                        errorMessage: error.localizedDescription,
                        duration: duration,
                        outputMode: self.requestedOutputMode(),
                        transcriptionOptions: self.requestedTranscriptionOptions()
                    )

                    await MainActor.run {
                        historyManager.addRecording(recording)
                        self.errorMessage = error.localizedDescription
                        self.recordingState = .idle
                        self.isProcessing = false
                        self.recordingMode = .dictation // Reset recording mode on error
                        CommandModeManager.shared.reset()
                    }

                    // Notify recording completed (even if failed)
                    NotificationCenter.default.post(name: .recordingCompleted, object: recording)
                }

                if overlayManager.isOverlayMode {
                    finishOverlayAfterRecording()
                }

                if ClipboardManager.hasActiveLiveDictationInsertion {
                    if self.realtimeTranscript.isEmpty {
                        ClipboardManager.cancelLiveDictationInsertion()
                    } else {
                        ClipboardManager.finishLiveDictationInsertion(finalText: self.realtimeTranscript)
                    }
                }
            }

            // Reset state
            shouldAutoPaste = false
            recordingStartTime = nil
        }
    }

    private func finishOverlayAfterRecording() {
        guard overlayManager.isOverlayMode else {
            shouldKeepOverlayIdleVisibleAfterCurrentRecording = false
            return
        }

        if shouldKeepOverlayIdleVisibleAfterCurrentRecording {
            shouldKeepOverlayIdleVisibleAfterCurrentRecording = false
            overlayManager.transitionToVisibleIdle()
        } else {
            overlayManager.transition(to: overlayManager.hideIdleState ? .hidden : .idle)
        }
    }

    private func startRealtimeTranscriptionIfAvailable() {
        realtimeTranscript = ""
        realtimeTranscriptionClient?.close()
        realtimeTranscriptionClient = nil
        audioRecorder.realtimeAudioChunkHandler = nil

        let mode = transcriptionProviderManager.transcriptionMode
        let provider = transcriptionProviderManager.selectedProvider
        let transport = transcriptionProviderManager.effectiveTransport

        if requestedTranscriptionOptions().diarization {
            DebugLog.info("Skipping realtime start because speaker labels require batch transcription", context: "AppState")
            return
        }

        guard mode != .local,
              !provider.isOnDevice,
              transport == .realtime,
              NetworkMonitor.shared.isConnected
        else {
            DebugLog.info("Skipping realtime start for transport=\(transport.rawValue), mode=\(mode.displayName), provider=\(provider.displayName)", context: "AppState")
            return
        }

        let prompt = buildRealtimePrompt()
        let realtimePrompt = prompt.isEmpty ? nil : prompt
        let languageCode = singleAPILanguageCode()
        let client: OpenAIRealtimeTranscriptionClient

        switch provider {
        case .openai:
            guard let apiKey = resolvedTranscriptionApiKey(), !apiKey.isEmpty else {
                return
            }
            client = OpenAIRealtimeTranscriptionClient(
                apiKey: apiKey,
                language: languageCode,
                prompt: realtimePrompt,
                onPartialTranscript: { [weak self] partial in
                    self?.handleRealtimePartial(partial)
                },
                onError: { message in
                    DebugLog.warning(message, context: "AppState")
                }
            )
        case .custom:
            guard let apiKey = resolvedTranscriptionApiKey(), !apiKey.isEmpty else {
                return
            }
            let realtimeModel = resolvedRealtimeTranscriptionModel()

            if let webSocketURL = customRealtimeWebSocketURL() {
                client = OpenAIRealtimeTranscriptionClient(
                    apiKey: apiKey,
                    webSocketURL: webSocketURL,
                    transcriptionModel: realtimeModel,
                    language: languageCode,
                    prompt: realtimePrompt,
                    onPartialTranscript: { [weak self] partial in
                        self?.handleRealtimePartial(partial)
                    },
                    onError: { message in
                        DebugLog.warning(message, context: "AppState")
                    }
                )
            } else {
                guard let endpoint = customRealtimeSessionEndpoint() else {
                    DebugLog.warning("Invalid custom realtime session endpoint", context: "AppState")
                    return
                }

                client = OpenAIRealtimeTranscriptionClient(
                    authorizationProvider: {
                        try await WritingmateRealtimeClientSecretProvider.fetchAuthorization(
                            endpoint: endpoint,
                            apiKey: apiKey,
                            model: realtimeModel,
                            prompt: realtimePrompt,
                            language: languageCode
                        )
                    },
                    prompt: realtimePrompt,
                    transcriptionModel: realtimeModel,
                    language: languageCode,
                    onPartialTranscript: { [weak self] partial in
                        self?.handleRealtimePartial(partial)
                    },
                    onError: { message in
                        DebugLog.warning(message, context: "AppState")
                    }
                )
            }
        case .groq, .parakeet:
            return
        }

        realtimeTranscriptionClient = client
        audioRecorder.realtimeAudioChunkHandler = { [weak client] chunk in
            client?.sendAudio(chunk)
        }
        client.start()
        DebugLog.info("Started realtime transcription stream for \(provider.displayName)", context: "AppState")
    }

    private func customRealtimeSessionEndpoint() -> URL? {
        if let configuredEndpoint = configuredCustomRealtimeEndpoint(),
           !isWebSocketURL(configuredEndpoint)
        {
            return configuredEndpoint
        }

        return WritingmateRealtimeClientSecretProvider.endpoint(
            from: transcriptionProviderManager.effectiveEndpoint
        )
    }

    private func customRealtimeWebSocketURL() -> URL? {
        if let configuredEndpoint = configuredCustomRealtimeEndpoint(),
           isWebSocketURL(configuredEndpoint)
        {
            return configuredEndpoint
        }

        guard let endpoint = URL(string: transcriptionProviderManager.effectiveEndpoint),
              isWebSocketURL(endpoint)
        else {
            return nil
        }
        return endpoint
    }

    private func configuredCustomRealtimeEndpoint() -> URL? {
        guard let configured = SecretsLoader.customTranscriptionRealtimeEndpoint()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        else {
            return nil
        }
        return URL(string: configured)
    }

    private func isWebSocketURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "ws" || scheme == "wss"
    }

    private func resolvedRealtimeTranscriptionModel() -> String {
        if let configuredModel = SecretsLoader.customTranscriptionRealtimeModel()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredModel.isEmpty
        {
            return configuredModel
        }

        let model = transcriptionProviderManager.effectiveModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              !model.contains("/"),
              model != TranscriptionProvider.custom.defaultModel
        else {
            return OpenAIRealtimeTranscriptionClient.defaultTranscriptionModel
        }
        return model
    }

    private func stopRealtimeTranscription() -> OpenAIRealtimeTranscriptionClient? {
        audioRecorder.realtimeAudioChunkHandler = nil
        let client = realtimeTranscriptionClient
        realtimeTranscriptionClient = nil
        return client
    }

    private func handleRealtimePartial(_ partial: String) {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        realtimeTranscript = text
        transcriptionText = text
        DebugLog.info("Realtime transcription partial length=\(text.count)", context: "AppState")
    }

    private func requestedOutputMode() -> TranscriptionOutputMode {
        guard recordingMode != .command else {
            return .dictation
        }
        if contextRulesManager.isMeetingsModeActive(for: capturedAppBundleId, windowTitle: capturedWindowTitle) {
            return .meetings
        }
        if contextRulesManager.isNotesModeActive(for: capturedAppBundleId, windowTitle: capturedWindowTitle) {
            return .notes
        }
        return .dictation
    }

    private func requestedTranscriptionOptions() -> TranscriptionOptions {
        guard recordingMode != .command else {
            return .default
        }
        return contextRulesManager.transcriptionOptions(for: capturedAppBundleId, windowTitle: capturedWindowTitle)
    }

    private func buildTranscriptionPromptComponents() -> [String] {
        var promptComponents: [String] = []

        if let instructions = dictionaryManager.formattingInstructions {
            promptComponents.append(instructions)
        }
        if let instructions = shortcutManager.formattingInstructions {
            promptComponents.append(instructions)
        }
        if let instructions = contextRulesManager.instructions(for: capturedAppBundleId, windowTitle: capturedWindowTitle) {
            promptComponents.append(instructions)
        }

        return promptComponents
    }

    private func buildSTTHintPromptComponents() -> [String] {
        var promptComponents: [String] = []

        if !dictionaryManager.transcriptionHints.isEmpty {
            promptComponents.append(dictionaryManager.transcriptionHints)
        }
        if !shortcutManager.transcriptionHints.isEmpty {
            promptComponents.append(shortcutManager.transcriptionHints)
        }

        return promptComponents
    }

    private func buildRealtimePrompt() -> String {
        buildSTTHintPromptComponents().joined(separator: "\n")
    }

    private func singleAPILanguageCode() -> String? {
        guard let languageCode = languageManager.apiLanguageCode,
              !languageCode.contains(",")
        else {
            return nil
        }
        return languageCode
    }

    /// Core transcription logic shared by live recording and re-transcription
    private func performTranscription(
        audioURL: URL,
        appContext: String?,
        clipboardContent: String?,
        screenContext: String?,
        outputMode: TranscriptionOutputMode,
        transcriptionOptions: TranscriptionOptions = .default
    ) async throws -> String {
        let sttHintPrompt = buildSTTHintPromptComponents().joined(separator: "\n")
        let promptComponents = buildTranscriptionPromptComponents()
        let postProcessingPrompt = promptComponents.joined(separator: "\n")

        let mode = transcriptionProviderManager.transcriptionMode
        var provider = transcriptionProviderManager.selectedProvider
        DebugLog.info("Transcription mode: \(mode.displayName), provider: \(provider.displayName), transport: \(transcriptionProviderManager.effectiveTransport.rawValue), isOnDevice: \(provider.isOnDevice)", context: "AppState")

        if transcriptionOptions.diarization {
            guard ParakeetTranscriptionService.isRuntimeSupported else {
                throw NSError(
                    domain: "AppState",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Speaker labels require offline transcription on macOS 14 or later"]
                )
            }
            DebugLog.info("Using local diarization model for transcription", context: "AppState")
            provider = .parakeet
        }

        // Auto mode: use cloud when online, fall back to local when offline
        if !transcriptionOptions.diarization,
           mode == .auto,
           !provider.isOnDevice,
           !NetworkMonitor.shared.isConnected,
           ParakeetTranscriptionService.isRuntimeSupported
        {
            let parakeetState = await MainActor.run { ParakeetTranscriptionService.shared.state }
            switch parakeetState {
            case .ready, .transcribing:
                DebugLog.info("Auto mode: network unavailable - using on-device Parakeet", context: "AppState")
                provider = .parakeet
            case .notInitialized, .error:
                // Try to initialize Parakeet (model may be cached from a previous download)
                DebugLog.info("Auto mode: network unavailable, initializing Parakeet for fallback", context: "AppState")
                do {
                    try await ParakeetTranscriptionService.shared.initialize()
                    DebugLog.info("Auto mode: Parakeet initialized - using on-device", context: "AppState")
                    provider = .parakeet
                } catch {
                    DebugLog.error("Auto mode: Parakeet init failed (\(error.localizedDescription)) - attempting cloud", context: "AppState")
                }
            case .downloading, .initializing:
                DebugLog.info("Auto mode: network unavailable, Parakeet still loading - attempting cloud", context: "AppState")
            }
        }

        let transport = provider == transcriptionProviderManager.selectedProvider
            ? transcriptionProviderManager.effectiveTransport
            : provider.defaultTransport

        switch transport {
        case .local:
            guard ParakeetTranscriptionService.isRuntimeSupported else {
                throw NSError(
                    domain: "AppState",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: ParakeetTranscriptionService.unavailableMessage]
                )
            }

            DebugLog.info("Using on-device Parakeet transcription", context: "AppState")

            var text: String
            if transcriptionOptions.diarization {
                do {
                    text = try await withTimeout(seconds: diarizationTimeoutSeconds) {
                        try await ParakeetTranscriptionService.shared.transcribeDiarized(audioURL: audioURL)
                    }
                } catch {
                    DebugLog.warning("Speaker labels unavailable within time limit - using offline transcript without speaker labels", context: "AppState")
                    text = try await ParakeetTranscriptionService.shared.transcribe(audioURL: audioURL)
                }
            } else {
                text = try await ParakeetTranscriptionService.shared.transcribe(audioURL: audioURL)
            }
            text = TranscriptionOutputFilter.filter(text)
            text = dictionaryManager.applyReplacements(to: text)
            return try await applyLLMPassWithFallback(
                rawText: text,
                client: openAIClient ?? OpenAIClient(config: .init()),
                promptComponents: promptComponents,
                provider: provider,
                outputMode: outputMode,
                appContext: appContext
            )

        case .realtime:
            DebugLog.warning("Realtime transport reached batch transcription path; using batch cloud fallback", context: "AppState")
            fallthrough

        case .batch:
            DebugLog.info("Using \(provider.displayName) batch transcription", context: "AppState")
            guard let transcriptionApiKey = resolvedTranscriptionApiKey() else {
                throw NSError(domain: "AppState", code: -1, userInfo: [NSLocalizedDescriptionKey: "Please set your \(provider.displayName) API key"])
            }

            let chatCompletionEndpoint: String
            let chatCompletionModel: String
            let chatCompletionApiKey: String?
            if provider == .custom {
                chatCompletionEndpoint = SecretsLoader.aidictationPostProcessingEndpoint() ?? ""
                chatCompletionModel = PostProcessingProvider.aidictationModel
                chatCompletionApiKey = SecretsLoader.aidictationPostProcessingKey() ?? transcriptionApiKey
            } else {
                chatCompletionEndpoint = llmProviderManager.effectiveEndpoint
                chatCompletionModel = llmProviderManager.effectiveModel
                chatCompletionApiKey = nil
            }

            let config = OpenAIClient.Configuration(
                transcriptionEndpoint: transcriptionProviderManager.effectiveEndpoint,
                transcriptionModel: transcriptionProviderManager.effectiveModel,
                chatCompletionEndpoint: chatCompletionEndpoint,
                chatCompletionModel: chatCompletionModel,
                apiKey: transcriptionApiKey,
                chatCompletionApiKey: chatCompletionApiKey
            )

            if openAIClient == nil {
                openAIClient = OpenAIClient(config: config)
            } else {
                openAIClient?.updateConfig(config)
            }

            guard let client = openAIClient else {
                throw NSError(domain: "AppState", code: -1)
            }

            let rawText = try await client.transcribe(
                audioURL: audioURL,
                prompt: sttHintPrompt.isEmpty ? nil : sttHintPrompt,
                language: singleAPILanguageCode(),
                sttPrompt: provider == .custom && !sttHintPrompt.isEmpty ? sttHintPrompt : nil,
                postProcessingPrompt: provider == .custom ? providerPostProcessingPrompt(outputMode: outputMode, basePrompt: postProcessingPrompt) : nil
            )

            if outputMode != .dictation {
                return try await applyLLMPassWithFallback(
                    rawText: rawText,
                    client: client,
                    promptComponents: promptComponents,
                    provider: provider,
                    outputMode: outputMode,
                    appContext: appContext
                )
            }

            let shouldPostProcess = transcriptionProviderManager.enableLLMPostProcessing &&
                provider != .custom &&
                (transcriptionProviderManager.postProcessingProvider == .aidictation || !promptComponents.isEmpty)
            if shouldPostProcess {
                let postProcessor = transcriptionProviderManager.postProcessingProvider

                if postProcessor == .aidictation,
                   let endpoint = SecretsLoader.aidictationPostProcessingEndpoint(),
                   let apiKey = SecretsLoader.aidictationPostProcessingKey()
                {
                    DebugLog.info("Applying AIDictation post-processing", context: "AppState")
                    let llmConfig = OpenAIClient.Configuration(
                        transcriptionEndpoint: transcriptionProviderManager.effectiveEndpoint,
                        transcriptionModel: transcriptionProviderManager.effectiveModel,
                        chatCompletionEndpoint: endpoint,
                        chatCompletionModel: PostProcessingProvider.aidictationModel,
                        apiKey: apiKey
                    )
                    client.updateConfig(llmConfig)
                    return try await client.applyFormattingRules(
                        transcription: rawText, rules: promptComponents,
                        languageCodes: languageManager.apiLanguageCode,
                        appContext: appContext, clipboardContent: nil
                    )
                } else if postProcessor == .customLLM, let llmApiKey = resolvedLLMApiKey() {
                    DebugLog.info("Applying custom LLM post-processing", context: "AppState")
                    let llmConfig = OpenAIClient.Configuration(
                        transcriptionEndpoint: transcriptionProviderManager.effectiveEndpoint,
                        transcriptionModel: transcriptionProviderManager.effectiveModel,
                        chatCompletionEndpoint: llmProviderManager.effectiveEndpoint,
                        chatCompletionModel: llmProviderManager.effectiveModel,
                        apiKey: llmApiKey
                    )
                    client.updateConfig(llmConfig)
                    return try await client.applyFormattingRules(
                        transcription: rawText, rules: promptComponents,
                        languageCodes: languageManager.apiLanguageCode,
                        appContext: appContext, clipboardContent: nil
                    )
                } else if postProcessor == .customLLM && resolvedLLMApiKey() == nil {
                    DebugLog.warning("Custom LLM post-processing enabled but no API key - using raw transcription", context: "AppState")
                }
            }
            return rawText
        }
    }

    private func providerPostProcessingPrompt(outputMode: TranscriptionOutputMode, basePrompt: String) -> String? {
        var components: [String] = []
        if !basePrompt.isEmpty {
            components.append(basePrompt)
        }
        if outputMode == .notes {
            components.append(TranscriptionOutputMode.notesPostProcessingInstruction)
        } else if outputMode == .meetings {
            components.append(TranscriptionOutputMode.meetingsPostProcessingInstruction)
        }
        let prompt = components.joined(separator: "\n\n")
        return prompt.isEmpty ? nil : prompt
    }

    private func applyLLMPassWithFallback(
        rawText: String,
        client: OpenAIClient,
        promptComponents: [String],
        provider: TranscriptionProvider,
        outputMode: TranscriptionOutputMode,
        appContext: String?
    ) async throws -> String {
        do {
            return try await withTimeout(seconds: llmPostProcessingTimeoutSeconds) {
                try await self.applyLLMPassIfNeeded(
                    rawText: rawText,
                    client: client,
                    promptComponents: promptComponents,
                    provider: provider,
                    outputMode: outputMode,
                    appContext: appContext
                )
            }
        } catch {
            DebugLog.warning("\(outputMode.displayName) post-processing unavailable within time limit - using transcript", context: "AppState")
            return rawText
        }
    }

    private func applyLLMPassIfNeeded(
        rawText: String,
        client: OpenAIClient,
        promptComponents: [String],
        provider: TranscriptionProvider,
        outputMode: TranscriptionOutputMode,
        appContext: String?
    ) async throws -> String {
        if outputMode == .dictation {
            return rawText
        }

        if provider == .custom {
            return rawText
        }

        let postProcessor = transcriptionProviderManager.postProcessingProvider
        if postProcessor == .aidictation,
           let endpoint = SecretsLoader.aidictationPostProcessingEndpoint(),
           let apiKey = SecretsLoader.aidictationPostProcessingKey()
        {
            let llmConfig = OpenAIClient.Configuration(
                transcriptionEndpoint: transcriptionProviderManager.effectiveEndpoint,
                transcriptionModel: transcriptionProviderManager.effectiveModel,
                chatCompletionEndpoint: endpoint,
                chatCompletionModel: PostProcessingProvider.aidictationModel,
                apiKey: apiKey
            )
            client.updateConfig(llmConfig)
            return try await applyOutputModeFormatting(
                client: client,
                transcription: rawText,
                outputMode: outputMode,
                rules: promptComponents,
                languageCodes: languageManager.apiLanguageCode,
                appContext: appContext
            )
        }

        if postProcessor == .customLLM, let llmApiKey = resolvedLLMApiKey() {
            let llmConfig = OpenAIClient.Configuration(
                transcriptionEndpoint: transcriptionProviderManager.effectiveEndpoint,
                transcriptionModel: transcriptionProviderManager.effectiveModel,
                chatCompletionEndpoint: llmProviderManager.effectiveEndpoint,
                chatCompletionModel: llmProviderManager.effectiveModel,
                apiKey: llmApiKey
            )
            client.updateConfig(llmConfig)
            return try await applyOutputModeFormatting(
                client: client,
                transcription: rawText,
                outputMode: outputMode,
                rules: promptComponents,
                languageCodes: languageManager.apiLanguageCode,
                appContext: appContext
            )
        }

        DebugLog.warning("\(outputMode.displayName) mode post-processing unavailable - using cleaned transcript", context: "AppState")
        return rawText
    }

    private func applyOutputModeFormatting(
        client: OpenAIClient,
        transcription: String,
        outputMode: TranscriptionOutputMode,
        rules: [String],
        languageCodes: String?,
        appContext: String?
    ) async throws -> String {
        switch outputMode {
        case .dictation:
            return transcription
        case .notes:
            return try await client.applyNotesFormatting(
                transcription: transcription,
                rules: rules,
                languageCodes: languageCodes,
                appContext: appContext
            )
        case .meetings:
            return try await client.applyMeetingFormatting(
                transcription: transcription,
                rules: rules,
                languageCodes: languageCodes,
                appContext: appContext
            )
        }
    }

    private func resolvedTranscriptionApiKey() -> String? {
        let provider = transcriptionProviderManager.selectedProvider

        // Check Secrets.plist first
        if let secretKey = SecretsLoader.transcriptionKey(for: provider), !secretKey.isEmpty {
            return secretKey
        }

        if provider == .custom,
           URL(string: transcriptionProviderManager.effectiveEndpoint)?.host?.lowercased() == "api.openai.com"
        {
            if let openAISecretKey = SecretsLoader.transcriptionKey(for: .openai), !openAISecretKey.isEmpty {
                return openAISecretKey
            }
            if let openAIStoredKey = KeychainHelper.get(key: TranscriptionProvider.openai.apiKeyName), !openAIStoredKey.isEmpty {
                return openAIStoredKey
            }
        }

        if !provider.requiresAPIKey {
            return "not-needed"
        }

        // Then check keychain
        if let storedKey = KeychainHelper.get(key: provider.apiKeyName), !storedKey.isEmpty {
            return storedKey
        }

        // Fallback: try legacy "openai_api_key" for backward compatibility
        if let legacyKey = KeychainHelper.get(key: "openai_api_key"), !legacyKey.isEmpty {
            DebugLog.info("Using legacy openai_api_key", context: "AppState")
            return legacyKey
        }

        return nil
    }

    private func resolvedLLMApiKey() -> String? {
        return llmProviderManager.effectiveApiKey
    }

    // MARK: - Dictation Result Processing

    /// Process dictation result: update state and paste transcribed text
    private func processDictationResult(transcription: String) async {
        DebugLog.info("Processing dictation result...", context: "AppState")
        DebugLog.info(
            "Dictation result metadata length=\(transcription.count) autoPaste=\(shouldAutoPaste) overlayMode=\(overlayManager.isOverlayMode)",
            context: "DictationFlow"
        )

        // Update state
        await MainActor.run {
            self.transcriptionText = transcription
            self.lastOutputText = transcription
        }

        // Paste if needed
        if shouldAutoPaste {
            DebugLog.info("Auto-pasting dictation...", context: "AppState")
            DebugLog.info("Auto-paste branch entered", context: "DictationFlow")
            await MainActor.run {
                self.recordingState = .pasting
            }
            if ClipboardManager.hasActiveLiveDictationInsertion {
                ClipboardManager.finishLiveDictationInsertion(finalText: transcription)
            } else {
                ClipboardManager.copyAndPaste(transcription)
            }
            await MainActor.run {
                self.recordingState = .idle
                self.finishOverlayAfterRecording()
            }
        } else if overlayManager.isOverlayMode {
            // Not auto-pasting, just reset overlay state
            DebugLog.info("Auto-paste disabled; finishing overlay only", context: "DictationFlow")
            finishOverlayAfterRecording()
        }
    }

    // MARK: - Command Result Processing

    /// Process command result: execute LLM instruction and paste result
    private func processCommandResult(instruction: String, targetText: String) async {
        DebugLog.info("Processing command: '\(instruction)'", context: "AppState")

        let targetSource = CommandModeManager.shared.targetSource
        let selectedTextLength = CommandModeManager.shared.selectedTextLength
        let hasTargetText = !targetText.isEmpty

        DebugLog.info("Command mode: source=\(targetSource), targetTextLength=\(targetText.count), selectedTextLength=\(selectedTextLength)", context: "AppState")

        // Build screen context: always include app info, add OCR if available
        var screenContextParts: [String] = []
        if let appContext = capturedAppContext {
            screenContextParts.append("App: \(appContext)")
        }
        if let ocrContext = capturedScreenContext {
            screenContextParts.append("Screen content:\n\(ocrContext)")
        }
        let screenContext: String? = screenContextParts.isEmpty ? nil : screenContextParts.joined(separator: "\n\n")

        // Build context rules (same as transcription)
        var contextRules: [String] = []
        if let instructions = dictionaryManager.formattingInstructions {
            contextRules.append(instructions)
        }
        if let instructions = shortcutManager.formattingInstructions {
            contextRules.append(instructions)
        }
        if let instructions = contextRulesManager.instructions(for: capturedAppBundleId, windowTitle: capturedWindowTitle) {
            contextRules.append(instructions)
        }

        // Execute the command (with or without target text)
        guard let resultText = await CommandModeManager.shared.executeInstruction(
            instruction,
            selectedText: targetText,
            screenContext: screenContext,
            contextRules: contextRules
        ) else {
            DebugLog.error("Command mode: execution failed", context: "AppState")
            await resetCommandModeState()
            return
        }

        DebugLog.info("Command mode: \(hasTargetText ? "transformation" : "generation") complete", context: "AppState")

        // Paste result
        await MainActor.run {
            self.recordingState = .pasting
        }

        // Only replace selected text if Accessibility captured a selection.
        if targetSource == .selectedText, selectedTextLength > 0 {
            // For selected text: move forward to end of selection, delete backwards, then paste
            DebugLog.info("Command mode: replacing \(selectedTextLength) chars of selected text", context: "AppState")
            ClipboardManager.moveForwardAndDelete(characterCount: selectedTextLength) {
                ClipboardManager.replaceSelectionAndPaste(resultText)
            }
        } else {
            // No selection - insert generated text at cursor.
            DebugLog.info("Command mode: pasting at cursor (source: \(targetSource))", context: "AppState")
            ClipboardManager.replaceSelectionAndPaste(resultText)
        }

        // Update state
        await MainActor.run {
            self.lastOutputText = resultText
            self.recordingState = .idle
        }

        // Reset command mode
        await resetCommandModeState()
    }

    /// Reset command mode state and hide overlay
    private func resetCommandModeState() async {
        await MainActor.run {
            self.overlayManager.transition(to: .hidden)
            CommandModeManager.shared.reset()
        }
    }

    private func withTimeout<T>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = AppStateTimeoutGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    do {
                        let result = try await operation()
                        await gate.resume(.success(result), continuation: continuation)
                    } catch {
                        await gate.resume(.failure(error), continuation: continuation)
                    }
                }

                Task {
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    await gate.resume(
                        .failure(NSError(
                            domain: "AppState",
                            code: -1001,
                            userInfo: [NSLocalizedDescriptionKey: "The operation took too long."]
                        )),
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await gate.cancel()
            }
        }
    }
}

private actor AppStateTimeoutGate<T> {
    private var didResume = false

    func resume(_ result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
        guard !didResume else { return }
        didResume = true

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        didResume = true
    }
}
