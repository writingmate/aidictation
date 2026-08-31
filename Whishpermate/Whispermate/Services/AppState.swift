import Foundation
import SwiftUI
internal import Combine
import AVFoundation
import WhisperMateShared

private nonisolated struct MacCapturedAttemptContext: Sendable {
    let description: String
    let bundleID: String?
    let windowTitle: String?
}

/// Central application state - single source of truth for app state
/// Recording works completely independently of view lifecycle
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - State Enums

    enum RecordingState {
        case idle
        case starting
        case recording
        case finalizing
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
    @Published private(set) var isHistoryMutationInProgress = false

    // MARK: - Private State

    private var shouldAutoPaste = false
    private var isContinuousRecording = false
    private var recordingStartTime: Date?
    private var finalizedRecordingDuration: TimeInterval?
    private var capturedAppContext: String?
    private var capturedAppBundleId: String?
    private var capturedWindowTitle: String?
    private var capturedScreenContext: String?
    private var recordingMode: RecordingMode = .dictation
    private var shouldKeepOverlayIdleVisibleAfterCurrentRecording = false
    private var activeRecordingID: UUID?
    private var recordingAttemptID: UUID?
    private var activeCaptureLease: MacAudioProcessingStore.Lease?
    private var activeTranscriptionSnapshot: MacTranscriptionAttemptSnapshot?
    private var captureDeadlineTask: Task<Void, Never>?
    private var retranscriptionAttemptIDs: [UUID: UUID] = [:]
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingPreparationStoreIDs: [UUID: UUID] = [:]
    private var terminationBarrierActive = false
    private var terminationOwnedStoreIDs: Set<UUID> = []
    private var terminationOwnedNativeIDs: Set<UUID> = []
    private var terminationFinalizationTask: Task<Bool, Never>?
    private let processingAttemptFence = MacProcessingAttemptFence()
    private var realtimeTranscriptionClient: (any RealtimeTranscriptionStreaming)?
    private var activeRealtimeFinishRequest: (
        recordingID: UUID,
        attemptID: UUID,
        request: RealtimeTranscriptionFinishRequest
    )?
    private var realtimeTranscript: String = ""
    private let diarizationTimeoutSeconds: UInt64 = 75
    private let llmPostProcessingTimeoutSeconds: UInt64 = 45
    private let commandDeliveryTimeoutSeconds: UInt64 = 45
    private let minimumRecognitionTimeoutSeconds: UInt64 = 90
    private let maximumRecognitionTimeoutSeconds: UInt64 = 600
    private let maximumCaptureDurationSeconds: UInt64 = 8 * 60 * 60
    private let recordingPreparationStoreDeadlineSeconds: UInt64 = 10
    private let recordingFinalizationStoreDeadlineSeconds: UInt64 = 60

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

    private init() {
        // Set up app state observers
        setupAppStateObservers()
        audioRecorder.captureFailureHandler = { [weak self] message in
            self?.handleCaptureFailure(message)
        }
        Task { [weak self] in
            await self?.reconcileAudioProcessingStore()
        }
    }

    // MARK: - Public API

    /// Start recording audio
    /// - Parameters:
    ///   - continuous: Whether this is continuous recording mode
    ///   - isCommandMode: Whether this is command mode (set by startCommandRecording)
    func startRecording(continuous: Bool = false, isCommandMode: Bool = false, showOverlayControls: Bool = false) {
        DebugLog.info("🎬 AppState.startRecording(continuous: \(continuous), isCommandMode: \(isCommandMode), showOverlayControls: \(showOverlayControls))", context: "AppState")

        // One app-wide owner keeps capture, local recognition, and retries from
        // competing for the same audio/model resources.
        guard recordingState == .idle,
              retranscriptionAttemptIDs.isEmpty,
              !terminationBarrierActive else {
            DebugLog.info("⚠️ Already in state: \(recordingState)", context: "AppState")
            return
        }

        guard !overlayManager.showMissingPermissionIfNeeded() else {
            DebugLog.info("Recording blocked by missing system permission", context: "AppState")
            return
        }

        // Reset recording mode - command mode is only active when explicitly requested
        if !isCommandMode {
            recordingMode = .dictation
        }

        let shouldShowOverlayControls = showOverlayControls && !isCommandMode
        shouldKeepOverlayIdleVisibleAfterCurrentRecording = shouldShowOverlayControls

        capturedAppContext = nil
        capturedAppBundleId = nil
        capturedWindowTitle = nil
        capturedScreenContext = nil
        let recordingID = UUID()
        let attemptID = UUID()
        let attemptContextTask = beginAttemptContextCapture()
        let attemptSnapshot = makeTranscriptionAttemptSnapshot(
            outputMode: .dictation,
            transcriptionOptions: .default,
            appContext: nil,
            screenContext: nil,
            usesContextRules: recordingMode != .command
        )

        guard historyManager.registerActiveRecording(id: recordingID) else {
            errorMessage = "A recording is already being handled. Please try again."
            return
        }

        activeRecordingID = recordingID
        recordingAttemptID = attemptID
        pendingPreparationStoreIDs[recordingID] = attemptID
        activeCaptureLease = nil
        activeTranscriptionSnapshot = attemptSnapshot
        recordingState = .starting
        isContinuousRecording = continuous
        shouldAutoPaste = true // Always auto-paste when hotkey is triggered
        recordingStartTime = nil
        finalizedRecordingDuration = nil

        DebugLog.info("Recording mode: \(recordingMode)", context: "AppState")

        // Clear previous state
        ClipboardManager.cancelLiveDictationInsertion(removeInsertedText: false)
        errorMessage = ""
        transcriptionText = ""

        // Show the recording bubble before anything else. None of the work below
        // — context capture, screen OCR, CoreAudio engine start — is needed to
        // draw it, and putting it last is what made the overlay lag the key
        // press by ~2s. Audio starts behind the UI, not in front of it.
        DictationActivityAssertion.acquire()
        DictationStopwatch.begin()
        // Before the mic starts, so the cue cannot bleed into the recording.
        SoundEffectManager.shared.playStart()
        if overlayManager.isOverlayMode {
            let isCommand = recordingMode == .command
            overlayManager.setRecordingControlsVisible(shouldShowOverlayControls && !isCommand)
            if !shouldShowOverlayControls {
                overlayManager.setHoverExpanded(true)
            }
            overlayManager.transition(to: .recording(isCommandMode: isCommand))
        }
        DictationStopwatch.mark("overlay visible")

        // Open the connection to the transcription host now, while the user is
        // still speaking, so the upload at key-release skips the handshake.
        // Local models have no endpoint and need no warming.
        let prewarmEndpoint = transcriptionProviderManager.effectiveEndpoint
        if !prewarmEndpoint.isEmpty {
            TranscriptionPrewarmer.shared.prewarm(endpoint: prewarmEndpoint)
        }

        // Capture screen context if enabled
        if screenCaptureManager.includeScreenContext {
            Task {
                if let screenContext = await screenCaptureManager.captureAndExtractText() {
                    await MainActor.run {
                        guard self.recordingAttemptID == attemptID,
                              self.processingAttemptFence.allows(attemptID)
                        else { return }
                        self.capturedScreenContext = screenContext
                        DebugLog.info("Captured screen context", context: "AppState")
                    }
                }
            }
        }

        // Store previous app for pasting
        ClipboardManager.storePreviousApp()

        Task { [weak self] in
            await self?.beginPreparedCapture(
                recordingID: recordingID,
                attemptID: attemptID,
                attemptSnapshot: attemptSnapshot,
                attemptContextTask: attemptContextTask,
                shouldShowOverlayControls: shouldShowOverlayControls
            )
        }
    }

    private func beginAttemptContextCapture() -> Task<MacCapturedAttemptContext?, Never> {
        Task.detached(priority: .userInitiated) {
            let operation = MacBoundedNativeOperation<MacCapturedAttemptContext?>(
                cancelNative: {}
            )
            return try? await operation.run(
                timeoutNanoseconds: 1_000_000_000
            ) { completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    let context = AppContextHelper.getCurrentAppContext()
                    completion(.success(context.map {
                        MacCapturedAttemptContext(
                            description: $0.description,
                            bundleID: $0.bundleId,
                            windowTitle: $0.windowTitle
                        )
                    }))
                }
            }
        }
    }

    private func beginPreparedCapture(
        recordingID: UUID,
        attemptID: UUID,
        attemptSnapshot: MacTranscriptionAttemptSnapshot,
        attemptContextTask: Task<MacCapturedAttemptContext?, Never>,
        shouldShowOverlayControls: Bool
    ) async {
        defer { pendingPreparationStoreIDs.removeValue(forKey: recordingID) }
        let store = await MacAudioProcessingStoreProvider.shared()
        guard ownsProcessingAttempt(
            recordingID: recordingID,
            attemptID: attemptID
        ) else { return }
        do {
            let deadline = Date().addingTimeInterval(
                TimeInterval(recordingPreparationStoreDeadlineSeconds)
            )
            let prepared = try await store.prepare(
                recordingID: recordingID,
                attemptID: attemptID,
                deadline: deadline
            )
            guard activeRecordingID == recordingID,
                  recordingAttemptID == attemptID,
                  recordingState == .starting,
                  processingAttemptFence.allows(attemptID),
                  !terminationBarrierActive
            else {
                if terminationBarrierActive {
                    _ = try? await store.fail(
                        prepared.lease,
                        message: "Recording stopped because the app was closing. Any captured audio was kept."
                    )
                } else {
                    _ = try? await store.tombstone(recordingID: recordingID)
                }
                return
            }
            let attemptContext = await attemptContextTask.value
            guard activeRecordingID == recordingID,
                  recordingAttemptID == attemptID,
                  recordingState == .starting,
                  processingAttemptFence.allows(attemptID),
                  !terminationBarrierActive else { return }
            capturedAppContext = attemptContext?.description
            capturedAppBundleId = attemptContext?.bundleID
            capturedWindowTitle = attemptContext?.windowTitle
            if let attemptContext {
                DebugLog.info(
                    "Captured app context: \(attemptContext.description)",
                    context: "AppState"
                )
            }
            let resolvedAttemptSnapshot = attemptSnapshot.withContext(
                appContext: attemptContext?.description,
                screenContext: capturedScreenContext,
                appBundleID: attemptContext?.bundleID,
                windowTitle: attemptContext?.windowTitle
            )
            activeTranscriptionSnapshot = resolvedAttemptSnapshot

            let provisional = Recording(
                id: recordingID,
                audioFileURL: store.partialURL(for: recordingID),
                status: .processing,
                outputMode: resolvedAttemptSnapshot.outputMode,
                transcriptionOptions: resolvedAttemptSnapshot.transcriptionOptions,
                sourceIntegrity: .unfinalized
            )
            guard historyManager.upsertRecording(provisional) else {
                _ = try? await store.tombstone(recordingID: recordingID)
                finishRecordingWithoutTranscription(
                    recordingID: recordingID,
                    message: "Recording couldn’t start because its recovery information couldn’t be displayed.",
                    removeMetadata: true
                )
                return
            }

            activeCaptureLease = prepared.lease
            overlayManager.initializeAudioObservers()
            // Install realtime delivery before native capture starts. The
            // preparation buffer that proves the recorder is ready must be in
            // both the durable source and the realtime stream.
            startRealtimeTranscriptionIfAvailable(
                recordingID: recordingID,
                attemptID: attemptID,
                snapshot: resolvedAttemptSnapshot
            )
            audioRecorder.startRecording(
                recordingID: attemptID,
                recordingURL: store.partialURL(for: recordingID)
            ) { [weak self] terminal in
                Task { @MainActor [weak self] in
                    await self?.handleRecorderStartTerminal(
                        terminal,
                        store: store,
                        recordingID: recordingID,
                        attemptID: attemptID,
                        shouldShowOverlayControls: shouldShowOverlayControls
                    )
                }
            }
        } catch {
            guard activeRecordingID == recordingID,
                  recordingAttemptID == attemptID,
                  processingAttemptFence.allows(attemptID),
                  !terminationBarrierActive
            else { return }
            finishRecordingWithoutTranscription(
                recordingID: recordingID,
                message: error.localizedDescription,
                removeMetadata: true
            )
        }
    }

    private func ownsProcessingAttempt(recordingID: UUID, attemptID: UUID) -> Bool {
        activeRecordingID == recordingID
            && recordingAttemptID == attemptID
            && processingAttemptFence.allows(attemptID)
            && !terminationBarrierActive
    }

    private func handleRecorderStartTerminal(
        _ terminal: RecordingPreparationAttempt.Terminal,
        store: MacAudioProcessingStore,
        recordingID: UUID,
        attemptID: UUID,
        shouldShowOverlayControls: Bool
    ) async {
        guard ownsProcessingAttempt(recordingID: recordingID, attemptID: attemptID),
              recordingState == .starting
        else { return }

        switch terminal {
        case .ready:
            guard let lease = activeCaptureLease else {
                await abortCaptureAfterStoreFailure(
                    store: store,
                    recordingID: recordingID,
                    attemptID: attemptID,
                    message: "Recording ownership could not be confirmed. The available audio was kept."
                )
                return
            }
            do {
                let recording = try await store.markRecording(
                    lease,
                    captureDeadline: Date().addingTimeInterval(
                        TimeInterval(maximumCaptureDurationSeconds)
                    )
                )
                guard ownsProcessingAttempt(recordingID: recordingID, attemptID: attemptID),
                      recordingState == .starting
                else { return }
                activeCaptureLease = recording.lease
                recordingState = .recording
                recordingStartTime = Date()
                guard let frozenSnapshot = activeTranscriptionSnapshot else {
                    throw MacAudioProcessingStore.StoreError.invalidTransition
                }
                let snapshot = frozenSnapshot.withContext(
                    appContext: capturedAppContext,
                    screenContext: capturedScreenContext,
                    appBundleID: capturedAppBundleId,
                    windowTitle: capturedWindowTitle
                )
                activeTranscriptionSnapshot = snapshot
                scheduleCaptureDeadline(recordingID: recordingID, attemptID: attemptID)
                NotificationCenter.default.post(name: .recordingStarted, object: nil)

                DebugLog.info("✅ Recording started successfully", context: "AppState")
                DictationStopwatch.mark("capture pipeline ready (store lease + context)")
                // The bubble was already shown at key-press. Only transition here
                // if that early call was skipped, so a late overlay-mode switch
                // still lands in the right state.
                if overlayManager.isOverlayMode, overlayManager.overlayState != .recording(isCommandMode: recordingMode == .command) {
                    let isCommand = recordingMode == .command
                    overlayManager.setRecordingControlsVisible(shouldShowOverlayControls && !isCommand)
                    if !shouldShowOverlayControls {
                        overlayManager.setHoverExpanded(true)
                    }
                    overlayManager.transition(to: .recording(isCommandMode: isCommand))
                }
            } catch {
                guard ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else { return }
                await abortCaptureAfterStoreFailure(
                    store: store,
                    recordingID: recordingID,
                    attemptID: attemptID,
                    message: error.localizedDescription
                )
            }

        case .failed(let message):
            closeLiveRealtimeTranscription()
            _ = try? await store.tombstone(recordingID: recordingID)
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: attemptID
            ) else { return }
            finishRecordingStart(recordingID: recordingID, terminalMessage: message)
        case .timedOut:
            closeLiveRealtimeTranscription()
            _ = try? await store.tombstone(recordingID: recordingID)
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: attemptID
            ) else { return }
            finishRecordingStart(
                recordingID: recordingID,
                terminalMessage: "Recording didn’t start. Check your microphone and try again."
            )
        case .invalidated:
            closeLiveRealtimeTranscription()
            _ = try? await store.tombstone(recordingID: recordingID)
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: attemptID
            ) else { return }
            finishRecordingStart(
                recordingID: recordingID,
                terminalMessage: "Your microphone changed before recording started. Please try again."
            )
        case .cancelled:
            closeLiveRealtimeTranscription()
            _ = try? await store.tombstone(recordingID: recordingID)
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: attemptID
            ) else { return }
            finishRecordingStart(recordingID: recordingID, terminalMessage: nil)
        @unknown default:
            closeLiveRealtimeTranscription()
            _ = try? await store.tombstone(recordingID: recordingID)
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: attemptID
            ) else { return }
            finishRecordingStart(
                recordingID: recordingID,
                terminalMessage: "Recording couldn’t start. Please try again."
            )
        }
    }

    private func abortCaptureAfterStoreFailure(
        store: MacAudioProcessingStore,
        recordingID: UUID,
        attemptID: UUID,
        message: String
    ) async {
        let lease = activeCaptureLease
        closeLiveRealtimeTranscription()
        audioRecorder.stopRecording(disposition: .submitIfValid) { _ in }
        if let lease {
            _ = try? await store.fail(lease, message: message)
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: attemptID
            ) else { return }
        }
        let sourceURL = store.partialURL(for: recordingID)
        _ = persistActiveRecording(
            recordingID: recordingID,
            audioURL: sourceURL,
            status: .failed,
            errorMessage: message,
            sourceIntegrity: .unfinalized
        )
        finishRecordingWithoutTranscription(recordingID: recordingID, message: message)
    }

    private func scheduleCaptureDeadline(recordingID: UUID, attemptID: UUID) {
        captureDeadlineTask?.cancel()
        let deadlineNanoseconds = maximumCaptureDurationSeconds * 1_000_000_000
        captureDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: deadlineNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.ownsProcessingAttempt(
                      recordingID: recordingID,
                      attemptID: attemptID
                  ),
                  self.recordingState == .recording
            else { return }
            self.finalizeRecording(
                disposition: .submitIfValid,
                terminalMessage: "Recording reached the maximum length. The captured audio was kept."
            )
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

        if recordingState == .starting {
            cancelStartingCapture()
            return
        }

        guard recordingState == .recording else {
            DebugLog.info("⚠️ Not recording, current state: \(recordingState)", context: "AppState")
            return
        }

        if let startTime = recordingStartTime,
           Date().timeIntervalSince(startTime) < 0.3
        {
            let duration = Date().timeIntervalSince(startTime)
            DebugLog.info("Recording too short (\(duration)s), skipping", context: "AppState")
            finalizeRecording(disposition: .discard, terminalMessage: nil)
            return
        }

        finalizeRecording(disposition: .submitIfValid, terminalMessage: nil)
    }

    /// Cancel recording, discard captured audio, and return to idle without transcription.
    func cancelRecording() {
        DebugLog.info("✕ AppState.cancelRecording()", context: "AppState")

        if recordingState == .starting {
            cancelStartingCapture()
            return
        }

        guard recordingState == .recording else {
            DebugLog.info("⚠️ Not recording, current state: \(recordingState)", context: "AppState")
            return
        }

        finalizeRecording(disposition: .discard, terminalMessage: nil)
    }

    private func cancelStartingCapture() {
        guard let recordingID = activeRecordingID,
              let attemptID = recordingAttemptID
        else { return }
        recordingState = .finalizing
        closeLiveRealtimeTranscription()
        Task { [weak self] in
            guard let self else { return }
            let store = await MacAudioProcessingStoreProvider.shared()
            guard self.ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: attemptID
            ) else { return }
            _ = try? await store.tombstone(recordingID: recordingID)
            guard self.ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: attemptID
            )
            else { return }
            self.audioRecorder.cancelPendingOrActiveCapture(recordingID: attemptID)
            _ = self.historyManager.removeRecordingMetadata(id: recordingID)
            self.finishRecordingWithoutTranscription(recordingID: recordingID, message: nil)
        }
    }

    private func finalizeRecording(
        disposition: AudioRecorder.StopDisposition,
        terminalMessage: String?
    ) {
        guard let recordingID = activeRecordingID,
              let attemptID = recordingAttemptID,
              let lease = activeCaptureLease
        else {
            finishRecordingWithoutTranscription(
                recordingID: activeRecordingID,
                message: terminalMessage ?? "Recording couldn’t be saved. Please try again."
            )
            return
        }

        recordingState = .finalizing
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        finalizedRecordingDuration = recordingStartTime.map { Date().timeIntervalSince($0) }
        recordingStartTime = nil
        if overlayManager.isOverlayMode {
            overlayManager.transition(
                to: .processing(isCommandMode: recordingMode == .command)
            )
        }
        let snapshot = activeTranscriptionSnapshot
        let shouldFinishRealtime = disposition == .submitIfValid
            && terminalMessage == nil
            && snapshot?.outputMode == .dictation
            && snapshot?.transcriptionOptions.diarization == false
            && snapshot?.transport == .realtime
        let realtimeFinishTimeout = snapshot?.provider == .aidictation
            ? 6.0
            : 2.0
        let realtimeFinishRequest = takeRealtimeTranscription(
            recordingID: recordingID,
            attemptID: attemptID,
            drainDeadline: shouldFinishRealtime ? realtimeFinishTimeout : nil
        )
        if !shouldFinishRealtime {
            audioRecorder.detachRealtimeAudioChunkHandlerAndDrain {}
            realtimeFinishRequest?.close()
        }
        DebugLog.info(
            "Realtime finish requested on stop: \(realtimeFinishRequest != nil && shouldFinishRealtime)",
            context: "DictationFlow"
        )
        let afterRealtimeAudioDrained: (@Sendable (Bool) -> Void)?
        if shouldFinishRealtime {
            afterRealtimeAudioDrained = { [realtimeFinishRequest] coverageIsComplete in
                if coverageIsComplete {
                    realtimeFinishRequest?.requestFinish(
                        timeout: realtimeFinishTimeout
                    )
                } else {
                    // The durable source contains audio the realtime stream
                    // could not encode. Close the speculative result and let
                    // the proven finalized file use batch recognition.
                    realtimeFinishRequest?.close()
                }
            }
        } else {
            afterRealtimeAudioDrained = nil
        }

        Task { [weak self] in
            guard let self else { return }
            let store = await MacAudioProcessingStoreProvider.shared()
            guard self.ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: attemptID
            ) else {
                realtimeFinishRequest?.close()
                return
            }
            do {
                if disposition == .discard {
                    _ = try await store.tombstone(recordingID: recordingID)
                    guard self.ownsProcessingAttempt(
                        recordingID: recordingID,
                        attemptID: attemptID
                    ) else {
                        realtimeFinishRequest?.close()
                        return
                    }
                } else {
                    let finalizing = try await store.beginFinalization(
                        lease,
                        deadline: Date().addingTimeInterval(
                            TimeInterval(recordingFinalizationStoreDeadlineSeconds)
                        )
                    )
                    guard self.ownsProcessingAttempt(
                              recordingID: recordingID,
                              attemptID: attemptID
                          ),
                          self.recordingState == .finalizing
                    else {
                        realtimeFinishRequest?.close()
                        return
                    }
                    self.activeCaptureLease = finalizing.lease
                }

                guard self.ownsProcessingAttempt(
                          recordingID: recordingID,
                          attemptID: attemptID
                      ),
                      self.recordingState == .finalizing
                else {
                    realtimeFinishRequest?.close()
                    return
                }
                self.audioRecorder.stopRecording(
                    disposition: disposition,
                    afterRealtimeAudioDrained: afterRealtimeAudioDrained
                ) { [weak self] terminal in
                    Task { @MainActor [weak self] in
                        await self?.handleRecorderFinalizationTerminal(
                            terminal,
                            store: store,
                            recordingID: recordingID,
                            attemptID: attemptID,
                            disposition: disposition,
                            terminalMessage: terminalMessage,
                            realtimeFinishRequest: realtimeFinishRequest
                        )
                    }
                }
            } catch {
                guard self.ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else {
                    realtimeFinishRequest?.close()
                    return
                }
                self.audioRecorder.stopRecording(disposition: .submitIfValid) { _ in }
                self.scheduleLateNativeCloseReconciliation(
                    store: store,
                    recordingID: recordingID,
                    attemptID: attemptID
                )
                _ = try? await store.fail(lease, message: error.localizedDescription)
                guard self.ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else {
                    realtimeFinishRequest?.close()
                    return
                }
                realtimeFinishRequest?.close()
                _ = self.persistActiveRecording(
                    recordingID: recordingID,
                    audioURL: store.partialURL(for: recordingID),
                    status: .failed,
                    errorMessage: error.localizedDescription,
                    sourceIntegrity: .unfinalized
                )
                self.finishRecordingWithoutTranscription(
                    recordingID: recordingID,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func handleRecorderFinalizationTerminal(
        _ terminal: RecordingFinalizationAttempt.Terminal,
        store: MacAudioProcessingStore,
        recordingID: UUID,
        attemptID: UUID,
        disposition: AudioRecorder.StopDisposition,
        terminalMessage: String?,
        realtimeFinishRequest: RealtimeTranscriptionFinishRequest?
    ) async {
        guard ownsProcessingAttempt(recordingID: recordingID, attemptID: attemptID),
              recordingState == .finalizing
        else {
            realtimeFinishRequest?.close()
            return
        }

        switch terminal {
        case .finalized:
            guard case .confirmed(let nativeCloseAttestation) =
                audioRecorder.nativeCloseState(recordingID: attemptID)
            else {
                realtimeFinishRequest?.close()
                let message =
                    "Recording is still finishing. The available audio was kept for recovery."
                if let lease = activeCaptureLease {
                    _ = try? await store.fail(lease, message: message)
                    guard ownsProcessingAttempt(
                        recordingID: recordingID,
                        attemptID: attemptID
                    ) else { return }
                }
                _ = persistActiveRecording(
                    recordingID: recordingID,
                    audioURL: store.partialURL(for: recordingID),
                    status: .failed,
                    errorMessage: message,
                    sourceIntegrity: .unfinalized
                )
                scheduleLateNativeCloseReconciliation(
                    store: store,
                    recordingID: recordingID,
                    attemptID: attemptID
                )
                finishRecordingWithoutTranscription(
                    recordingID: recordingID,
                    message: message
                )
                return
            }
            audioRecorder.acknowledgeConfirmedClose(recordingID: attemptID)
            guard let lease = activeCaptureLease else {
                realtimeFinishRequest?.close()
                finishRecordingWithoutTranscription(
                    recordingID: recordingID,
                    message: "Recording ownership could not be confirmed. The available audio was kept."
                )
                return
            }
            var closedAudioWasCheckpointed = false
            do {
                // AudioRecorder delivers `.finalized` only after the exact
                // session has drained writes and released its AVAudioFile.
                DictationStopwatch.mark("proveClosedAudio start")
                let proof = try await store.proveClosedAudio(
                    lease,
                    nativeCloseAttestation: nativeCloseAttestation
                )
                DictationStopwatch.mark("proveClosedAudio done")
                guard ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else {
                    realtimeFinishRequest?.close()
                    return
                }
                let checkpoint = try await store.checkpointClosedAudio(lease, proof: proof)
                DictationStopwatch.mark("checkpointClosedAudio done")
                guard ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else {
                    realtimeFinishRequest?.close()
                    return
                }
                closedAudioWasCheckpointed = true
                activeCaptureLease = checkpoint.lease
                let ready = try await store.finishFinalization(checkpoint.lease, proof: proof)
                DictationStopwatch.mark("finishFinalization done")
                guard ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else {
                    realtimeFinishRequest?.close()
                    return
                }
                activeCaptureLease = ready.lease
                let finalURL = store.finalURL(for: recordingID)

                if let terminalMessage {
                    let failed = try await store.fail(ready.lease, message: terminalMessage)
                    guard ownsProcessingAttempt(
                        recordingID: recordingID,
                        attemptID: attemptID
                    ) else {
                        realtimeFinishRequest?.close()
                        return
                    }
                    activeCaptureLease = failed.lease
                    _ = persistActiveRecording(
                        recordingID: recordingID,
                        audioURL: finalURL,
                        status: .failed,
                        errorMessage: terminalMessage,
                        sourceIntegrity: .complete
                    )
                    realtimeFinishRequest?.close()
                    finishRecordingWithoutTranscription(
                        recordingID: recordingID,
                        message: terminalMessage
                    )
                    return
                }

                _ = persistActiveRecording(
                    recordingID: recordingID,
                    audioURL: finalURL,
                    status: .processing,
                    errorMessage: nil,
                    sourceIntegrity: .complete
                )
                await beginLiveTranscription(
                    store: store,
                    ready: ready,
                    recordingID: recordingID,
                    captureAttemptID: attemptID,
                    realtimeFinishRequest: realtimeFinishRequest
                )
            } catch {
                realtimeFinishRequest?.close()
                guard ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else { return }
                var failedRecord: MacAudioProcessingStore.Record?
                if let lease = activeCaptureLease {
                    let failureMutation = try? await store.fail(
                        lease,
                        message: error.localizedDescription
                    )
                    guard ownsProcessingAttempt(
                        recordingID: recordingID,
                        attemptID: attemptID
                    ) else { return }
                    failedRecord = failureMutation?.record
                }
                if failedRecord == nil {
                    failedRecord = await store.record(for: recordingID)
                    guard ownsProcessingAttempt(
                        recordingID: recordingID,
                        attemptID: attemptID
                    ) else { return }
                }
                let partialURL = store.partialURL(for: recordingID)
                let finalURL = store.finalURL(for: recordingID)
                let partialExists = FileManager.default.fileExists(atPath: partialURL.path)
                let finalExists = FileManager.default.fileExists(atPath: finalURL.path)
                let finalIsCheckpointed = finalExists && !partialExists &&
                    (closedAudioWasCheckpointed || failedRecord?.audioIntegrity != nil)
                _ = persistActiveRecording(
                    recordingID: recordingID,
                    audioURL: finalIsCheckpointed ? finalURL : partialURL,
                    status: .failed,
                    errorMessage: error.localizedDescription,
                    sourceIntegrity: finalIsCheckpointed ? .complete : .unfinalized
                )
                finishRecordingWithoutTranscription(
                    recordingID: recordingID,
                    message: error.localizedDescription
                )
            }

        case .failed(let message, let recoverableURL):
            audioRecorder.acknowledgeConfirmedClose(recordingID: attemptID)
            realtimeFinishRequest?.close()
            let displayedMessage = terminalMessage ?? message
            if let lease = activeCaptureLease {
                _ = try? await store.fail(lease, message: displayedMessage)
                guard ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else { return }
            }
            _ = persistActiveRecording(
                recordingID: recordingID,
                audioURL: recoverableURL,
                status: .failed,
                errorMessage: displayedMessage,
                sourceIntegrity: .knownIncomplete
            )
            finishRecordingWithoutTranscription(recordingID: recordingID, message: displayedMessage)

        case .timedOut(let recoverableURL):
            realtimeFinishRequest?.close()
            scheduleLateNativeCloseReconciliation(
                store: store,
                recordingID: recordingID,
                attemptID: attemptID
            )
            if disposition == .discard {
                _ = historyManager.removeRecordingMetadata(id: recordingID)
                finishRecordingWithoutTranscription(
                    recordingID: recordingID,
                    message: terminalMessage
                )
                return
            }
            let displayedMessage = terminalMessage ?? (disposition == .discard
                ? nil
                : "Recording took too long to save. The audio was kept for recovery.")
            if let lease = activeCaptureLease {
                _ = try? await store.timeOut(lease)
                guard ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else { return }
            }
            _ = persistActiveRecording(
                recordingID: recordingID,
                audioURL: recoverableURL,
                status: .failed,
                errorMessage: displayedMessage,
                sourceIntegrity: .unfinalized
            )
            finishRecordingWithoutTranscription(recordingID: recordingID, message: displayedMessage)

        case .discarded:
            audioRecorder.acknowledgeConfirmedClose(recordingID: attemptID)
            realtimeFinishRequest?.close()
            _ = historyManager.removeRecordingMetadata(id: recordingID)
            finishRecordingWithoutTranscription(recordingID: recordingID, message: terminalMessage)

        case .unavailable(let message):
            // If the normal close completed just before this callback lookup,
            // retain and acknowledge its proof instead of treating that gap as
            // evidence that the writer was never closed.
            audioRecorder.acknowledgeConfirmedClose(recordingID: attemptID)
            realtimeFinishRequest?.close()
            if disposition == .discard {
                scheduleLateNativeCloseReconciliation(
                    store: store,
                    recordingID: recordingID,
                    attemptID: attemptID
                )
                _ = historyManager.removeRecordingMetadata(id: recordingID)
                finishRecordingWithoutTranscription(
                    recordingID: recordingID,
                    message: terminalMessage
                )
                return
            }
            let displayedMessage = terminalMessage ?? message
            if let lease = activeCaptureLease {
                _ = try? await store.fail(lease, message: displayedMessage)
                guard ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else { return }
            }
            _ = persistActiveRecording(
                recordingID: recordingID,
                audioURL: store.partialURL(for: recordingID),
                status: .failed,
                errorMessage: displayedMessage,
                sourceIntegrity: .unfinalized
            )
            finishRecordingWithoutTranscription(recordingID: recordingID, message: displayedMessage)

        @unknown default:
            realtimeFinishRequest?.close()
            let message = terminalMessage ?? "Recording couldn’t be saved. Please try again."
            if let lease = activeCaptureLease {
                _ = try? await store.fail(lease, message: message)
                guard ownsProcessingAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID
                ) else { return }
            }
            finishRecordingWithoutTranscription(recordingID: recordingID, message: message)
        }
    }

    /// A native cleanup queue may outlive the UI finalization deadline. Observe
    /// the exact capture proof without holding the UI, then checkpoint only if
    /// the same failed partial still owns the same revision. Tombstone/Clear
    /// therefore wins, and this path never recreates History metadata.
    private func scheduleLateNativeCloseReconciliation(
        store: MacAudioProcessingStore,
        recordingID: UUID,
        attemptID: UUID
    ) {
        audioRecorder.observeNativeClose(recordingID: attemptID) {
            [weak self] attestation in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.audioRecorder.acknowledgeConfirmedClose(
                        recordingID: attemptID
                    )
                }
                guard let record = await store.record(for: recordingID),
                      record.stage == .failed,
                      record.source == .partial,
                      record.attemptID == attemptID,
                      record.nativeCloseAttestedAttemptID != attemptID
                else { return }
                let deadline = Date().addingTimeInterval(
                    TimeInterval(self.recordingFinalizationStoreDeadlineSeconds)
                )
                do {
                    let proof = try await store.proveRecoverablePartial(
                        recordingID: recordingID,
                        expectedRevision: record.revision,
                        expectedClearGeneration: record.clearGeneration,
                        deadline: deadline,
                        nativeCloseAttestation: attestation
                    )
                    _ = try await store.checkpointRecoverablePartial(
                        recordingID: recordingID,
                        expectedRevision: record.revision,
                        expectedClearGeneration: record.clearGeneration,
                        proof: proof,
                        deadline: deadline,
                        nativeCloseAttestation: attestation
                    )
                } catch {
                    // Invalid/incomplete audio stays failed and non-promotable.
                    // A stale lease means Delete, Clear, or another attempt won.
                }
            }
        }
    }

    private func finishRecordingWithoutTranscription(
        recordingID: UUID?,
        message: String?,
        removeMetadata: Bool = false
    ) {
        DictationActivityAssertion.release()
        closeLiveRealtimeTranscription()
        closeActiveRealtimeFinishRequest(recordingID: recordingID)
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        var metadataRemovalFailed = false
        if let recordingID {
            if removeMetadata {
                metadataRemovalFailed = !historyManager.removeRecordingMetadata(id: recordingID)
            }
            historyManager.unregisterActiveRecording(id: recordingID)
            if activeRecordingID == recordingID {
                activeRecordingID = nil
                recordingAttemptID = nil
                activeCaptureLease = nil
                activeTranscriptionSnapshot = nil
            }
        }
        recordingState = .idle
        isContinuousRecording = false
        shouldAutoPaste = false
        recordingStartTime = nil
        finalizedRecordingDuration = nil
        recordingMode = .dictation
        if metadataRemovalFailed {
            errorMessage = "Recording stopped, but its recovery information couldn’t be updated."
        } else if let message {
            errorMessage = message
        }
        CommandModeManager.shared.reset()
        ClipboardManager.cancelLiveDictationInsertion()
        finishOverlayAfterRecording()
    }

    private func finishRecordingStart(recordingID: UUID, terminalMessage: String?) {
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        closeLiveRealtimeTranscription()
        closeActiveRealtimeFinishRequest(recordingID: recordingID)
        let removedMetadata = historyManager.removeRecordingMetadata(id: recordingID)
        historyManager.unregisterActiveRecording(id: recordingID)
        if activeRecordingID == recordingID {
            activeRecordingID = nil
            recordingAttemptID = nil
            activeCaptureLease = nil
            activeTranscriptionSnapshot = nil
        }
        recordingState = .idle
        isContinuousRecording = false
        shouldAutoPaste = false
        recordingStartTime = nil
        finalizedRecordingDuration = nil
        recordingMode = .dictation
        shouldKeepOverlayIdleVisibleAfterCurrentRecording = false
        if !removedMetadata {
            errorMessage = "Recording didn’t start, and its recovery information couldn’t be updated."
        } else if let terminalMessage {
            errorMessage = terminalMessage
        }
        CommandModeManager.shared.reset()
        ClipboardManager.cancelLiveDictationInsertion()
        finishOverlayAfterRecording()
    }

    @discardableResult
    private func persistActiveRecording(
        recordingID: UUID,
        audioURL: URL,
        status: TranscriptionStatus,
        errorMessage: String?,
        sourceIntegrity: RecordingSourceIntegrity,
        transcription: String? = nil,
        wordCount: Int? = nil,
        outputMode: TranscriptionOutputMode? = nil,
        transcriptionOptions: TranscriptionOptions? = nil
    ) -> Recording? {
        guard activeRecordingID == recordingID else { return nil }

        let previous = historyManager.recording(id: recordingID)
        let recording = Recording(
            id: recordingID,
            timestamp: previous?.timestamp ?? Date(),
            audioFileURL: audioURL,
            transcription: transcription,
            status: status,
            errorMessage: errorMessage,
            retryCount: previous?.retryCount ?? 0,
            duration: finalizedRecordingDuration ?? previous?.duration,
            wordCount: wordCount,
            outputMode: outputMode
                ?? previous?.outputMode
                ?? activeTranscriptionSnapshot?.outputMode
                ?? requestedOutputMode(),
            transcriptionOptions: transcriptionOptions
                ?? previous?.transcriptionOptions
                ?? activeTranscriptionSnapshot?.transcriptionOptions
                ?? requestedTranscriptionOptions(),
            sourceIntegrity: sourceIntegrity,
            legacyAudioFilePath: previous?.legacyAudioFilePath
        )
        return historyManager.upsertRecording(recording) ? recording : nil
    }

    private func handleCaptureFailure(_ message: String) {
        guard recordingState == .recording else { return }
        finalizeRecording(disposition: .submitIfValid, terminalMessage: message)
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
    func retranscribe(
        recording: Recording,
        mode: TranscriptionMode? = nil,
        onlineProvider: TranscriptionProvider? = nil
    ) {
        DebugLog.info("🔄 AppState.retranscribe(id: \(recording.id))", context: "AppState")

        guard recordingState == .idle,
              retranscriptionAttemptIDs.isEmpty,
              !recording.isInProgress,
              !terminationBarrierActive
        else { return }

        let attemptID = UUID()
        guard historyManager.registerActiveRecording(id: recording.id) else { return }
        retranscriptionAttemptIDs[recording.id] = attemptID

        var retrying = recording
        retrying.retryCount += 1
        retrying.status = .retrying
        retrying.errorMessage = nil
        let snapshot = makeTranscriptionAttemptSnapshot(
            outputMode: retrying.outputMode,
            transcriptionOptions: retrying.transcriptionOptions,
            appContext: nil,
            screenContext: nil,
            usesContextRules: false,
            modeOverride: mode,
            onlineProviderOverride: onlineProvider,
            isRetranscription: true
        )

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRetranscription(
                recording: retrying,
                attemptID: attemptID,
                snapshot: snapshot
            )
        }
        transcriptionTasks[recording.id] = task
    }

    private func runRetranscription(
        recording: Recording,
        attemptID: UUID,
        snapshot: MacTranscriptionAttemptSnapshot
    ) async {
        let store = await MacAudioProcessingStoreProvider.shared()
        guard isCurrentAttempt(
            recordingID: recording.id,
            attemptID: attemptID,
            isLiveRecording: false
        ) else { return }
        do {
            var record = await store.record(for: recording.id)
            guard isCurrentAttempt(
                recordingID: recording.id,
                attemptID: attemptID,
                isLiveRecording: false
            ) else { return }
            var legacyAudioFilePath = recording.legacyAudioFilePath
            if record == nil {
                guard FileManager.default.fileExists(atPath: recording.audioFileURL.path) else {
                    throw NSError(
                        domain: "AppState",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "The saved audio could not be found."]
                    )
                }
                let generation = await store.view().clearGeneration
                guard isCurrentAttempt(
                    recordingID: recording.id,
                    attemptID: attemptID,
                    isLiveRecording: false
                ) else { return }
                let adopted = try await store.adoptFinalizedSource(
                    recordingID: recording.id,
                    attemptID: UUID(),
                    sourceURL: recording.audioFileURL,
                    expectedClearGeneration: generation,
                    deadline: Date().addingTimeInterval(
                        TimeInterval(recognitionTimeoutSeconds(for: recording.duration))
                    )
                )
                guard isCurrentAttempt(
                    recordingID: recording.id,
                    attemptID: attemptID,
                    isLiveRecording: false
                ) else { return }
                record = adopted.record
                legacyAudioFilePath = recording.audioFileURL.path
            }

            guard var durableRecord = record else {
                throw MacAudioProcessingStore.StoreError.recordingNotFound
            }
            if durableRecord.stage == .failed, durableRecord.source == .partial {
                let nativeCloseAttestation:
                    MacAudioProcessingStore.NativeWriterCloseAttestation?
                if durableRecord.nativeCloseAttestedAttemptID == durableRecord.attemptID
                    || durableRecord.writerProcessID
                        != MacAudioProcessingStore.currentProcessID {
                    nativeCloseAttestation = nil
                } else {
                    switch audioRecorder.nativeCloseState(
                        recordingID: durableRecord.attemptID
                    ) {
                    case .confirmed(let attestation):
                        nativeCloseAttestation = attestation
                    case .pending:
                        throw MacAudioProcessingStore.StoreError.writerStillOpen
                    case .unknown:
                        throw MacAudioProcessingStore.StoreError.writerCloseUnknown
                    }
                }
                let salvageDeadline = Date().addingTimeInterval(
                    TimeInterval(recognitionTimeoutSeconds(for: recording.duration))
                )
                let proof = try await store.proveRecoverablePartial(
                    recordingID: recording.id,
                    expectedRevision: durableRecord.revision,
                    expectedClearGeneration: durableRecord.clearGeneration,
                    deadline: salvageDeadline,
                    nativeCloseAttestation: nativeCloseAttestation
                )
                guard isCurrentAttempt(
                    recordingID: recording.id,
                    attemptID: attemptID,
                    isLiveRecording: false
                ) else { return }
                let closeCheckpoint = try await store.checkpointRecoverablePartial(
                    recordingID: recording.id,
                    expectedRevision: durableRecord.revision,
                    expectedClearGeneration: durableRecord.clearGeneration,
                    proof: proof,
                    deadline: salvageDeadline,
                    nativeCloseAttestation: nativeCloseAttestation
                )
                guard isCurrentAttempt(
                    recordingID: recording.id,
                    attemptID: attemptID,
                    isLiveRecording: false
                ) else { return }
                durableRecord = closeCheckpoint.record
                let salvaged = try await store.salvageFinalizedPartial(
                    recordingID: recording.id,
                    salvageAttemptID: UUID(),
                    expectedRevision: durableRecord.revision,
                    expectedClearGeneration: durableRecord.clearGeneration,
                    deadline: salvageDeadline,
                    proof: proof
                )
                guard isCurrentAttempt(
                    recordingID: recording.id,
                    attemptID: attemptID,
                    isLiveRecording: false
                ) else { return }
                durableRecord = salvaged.record
            }

            let recognition = try await store.beginRecognition(
                recordingID: recording.id,
                attemptID: attemptID,
                expectedRevision: durableRecord.revision,
                deadline: Date().addingTimeInterval(
                    TimeInterval(recognitionTimeoutSeconds(for: recording.duration))
                )
            )
            guard isCurrentAttempt(
                recordingID: recording.id,
                attemptID: attemptID,
                isLiveRecording: false
            ) else { return }
            let transientWorkspace = try await store.makeTransientWorkspace(
                recognition.lease
            )
            guard isCurrentAttempt(
                recordingID: recording.id,
                attemptID: attemptID,
                isLiveRecording: false
            ) else {
                transientWorkspace.cleanup()
                return
            }
            let session = MacStoreTranscriptionSession(
                store: store,
                mutation: recognition,
                attemptIsCurrent: { @MainActor [weak self] in
                    self?.isCurrentAttempt(
                        recordingID: recording.id,
                        attemptID: attemptID,
                        isLiveRecording: false
                    ) ?? false
                }
            )
            let finalURL = store.finalURL(for: recording.id)
            var projected = recording
            projected.audioFileURL = finalURL
            projected.sourceIntegrity = .complete
            projected.legacyAudioFilePath = legacyAudioFilePath
            projected.status = .retrying
            projected.errorMessage = nil
            _ = historyManager.upsertRecording(projected)

            await executeTranscriptionAttempt(
                recording: projected,
                attemptID: attemptID,
                session: session,
                audioURL: finalURL,
                transientWorkspace: transientWorkspace,
                snapshot: snapshot,
                realtimeFinishRequest: nil,
                isLiveRecording: false
            )
        } catch {
            await finishRetranscriptionFailure(
                recording: recording,
                attemptID: attemptID,
                message: error.localizedDescription
            )
        }
    }

    func deleteRecording(_ recording: Recording) async -> String? {
        guard !isHistoryMutationInProgress else {
            return "Another History change is still finishing."
        }
        isHistoryMutationInProgress = true
        defer { isHistoryMutationInProgress = false }

        let store = await MacAudioProcessingStoreProvider.shared()
        let managedRecord = await store.record(for: recording.id)
        var managedCleanupFailed = false
        if managedRecord != nil {
            do {
                let cleanup = try await store.tombstone(recordingID: recording.id)
                managedCleanupFailed = !cleanup.completed
            } catch {
                return error.localizedDescription
            }
        }

        transcriptionTasks[recording.id]?.cancel()
        transcriptionTasks.removeValue(forKey: recording.id)
        retranscriptionAttemptIDs.removeValue(forKey: recording.id)
        historyManager.unregisterActiveRecording(id: recording.id)

        if activeRecordingID == recording.id {
            let nativeCaptureAttemptID = recordingAttemptID
            captureDeadlineTask?.cancel()
            captureDeadlineTask = nil
            activeRecordingID = nil
            recordingAttemptID = nil
            activeCaptureLease = nil
            activeTranscriptionSnapshot = nil
            closeActiveRealtimeFinishRequest(recordingID: recording.id)
            let realtime = stopRealtimeTranscription()
            realtime?.close()
            if recordingState == .starting {
                if let nativeCaptureAttemptID {
                    audioRecorder.cancelPendingOrActiveCapture(
                        recordingID: nativeCaptureAttemptID
                    )
                }
            } else if recordingState == .recording || recordingState == .finalizing {
                audioRecorder.stopRecording(disposition: .discard) { _ in }
            }
            resetProcessingUIAfterDeletion()
        }

        let legacyURL = recording.legacyAudioFileURL
            ?? (managedRecord == nil ? recording.audioFileURL : nil)
        var legacyCleanupFailed = false
        if let legacyURL {
            switch MacHistoryAudioDeletion.remove(
                recordingID: recording.id,
                candidateURL: legacyURL
            ) {
            case .removed, .absent:
                break
            case .refused, .failed:
                legacyCleanupFailed = true
            }
        }
        guard historyManager.removeRecordingMetadata(id: recording.id) else {
            return "The recording was deleted, but History couldn’t be updated."
        }
        return managedCleanupFailed || legacyCleanupFailed
            ? "The recording was removed from History, but one saved audio file couldn’t be deleted."
            : nil
    }

    func clearHistory() async -> String? {
        guard !isHistoryMutationInProgress else {
            return "Another History change is still finishing."
        }
        isHistoryMutationInProgress = true
        defer { isHistoryMutationInProgress = false }

        let cachedRecordings = historyManager.recordings
        let store = await MacAudioProcessingStoreProvider.shared()
        let managedRecordingIDs = Set((await store.view()).records.map(\.recordingID))
        let managedCleanupFailed: Bool
        do {
            let cleanup = try await store.clearAll()
            managedCleanupFailed = !cleanup.completed
        } catch {
            return error.localizedDescription
        }

        for task in transcriptionTasks.values { task.cancel() }
        transcriptionTasks.removeAll()
        retranscriptionAttemptIDs.removeAll()
        for recording in cachedRecordings {
            historyManager.unregisterActiveRecording(id: recording.id)
        }

        let nativeCaptureAttemptID = recordingAttemptID
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        activeRecordingID = nil
        recordingAttemptID = nil
        activeCaptureLease = nil
        activeTranscriptionSnapshot = nil
        closeActiveRealtimeFinishRequest()
        let realtime = stopRealtimeTranscription()
        realtime?.close()
        if recordingState == .starting {
            if let nativeCaptureAttemptID {
                audioRecorder.cancelPendingOrActiveCapture(
                    recordingID: nativeCaptureAttemptID
                )
            }
        } else if recordingState == .recording || recordingState == .finalizing {
            audioRecorder.stopRecording(disposition: .discard) { _ in }
        }
        resetProcessingUIAfterDeletion()

        var legacyDeleteFailed = false
        for recording in cachedRecordings {
            let legacyURL = recording.legacyAudioFileURL
                ?? (managedRecordingIDs.contains(recording.id) ? nil : recording.audioFileURL)
            guard let legacyURL else { continue }
            switch MacHistoryAudioDeletion.remove(
                recordingID: recording.id,
                candidateURL: legacyURL
            ) {
            case .removed, .absent:
                break
            case .refused, .failed:
                legacyDeleteFailed = true
            }
        }

        guard historyManager.clearMetadata() else {
            return "Recordings were cleared, but History couldn’t be updated."
        }
        return managedCleanupFailed || legacyDeleteFailed
            ? "History was cleared, but one saved audio file couldn’t be removed."
            : nil
    }

    private func resetProcessingUIAfterDeletion() {
        recordingState = .idle
        isProcessing = false
        isContinuousRecording = false
        shouldAutoPaste = false
        recordingStartTime = nil
        finalizedRecordingDuration = nil
        recordingMode = .dictation
        CommandModeManager.shared.reset()
        ClipboardManager.cancelLiveDictationInsertion()
        finishOverlayAfterRecording()
    }

    private func reconcileAudioProcessingStore() async {
        let store = await MacAudioProcessingStoreProvider.shared()
        let view = await store.view()
        guard case .healthy = view.health else {
            errorMessage = "Saved recordings need attention. No files were changed."
            for recording in historyManager.recordings where recording.isInProgress {
                var failed = recording
                failed.status = .failed
                failed.errorMessage = "Processing was interrupted. The saved files were preserved."
                historyManager.showUnsavedTerminalState(failed)
            }
            return
        }

        let durableIDs = Set(view.records.map(\.recordingID))
        for cached in historyManager.recordings
            where cached.isInProgress && !durableIDs.contains(cached.id) {
            var failed = cached
            failed.status = .failed
            failed.errorMessage = "Processing was interrupted. Retry will safely import the saved recording."
            _ = historyManager.upsertRecording(failed)
        }

        for initialRecord in view.records {
            var record = initialRecord
            if record.stage == .rawResultReady || record.stage == .cleaning,
               let raw = record.rawText {
                let lease = MacAudioProcessingStore.Lease(
                    recordingID: record.recordingID,
                    attemptID: record.attemptID,
                    clearGeneration: record.clearGeneration,
                    revision: record.revision
                )
                if let result = try? await store.useRawResult(
                    lease,
                    message: "Cleanup was interrupted. The complete raw transcript was kept."
                ) {
                    record = result.record
                    if record.resultText == nil { record.resultText = raw }
                }
            }

            if record.stage == .deleted {
                _ = historyManager.removeRecordingMetadata(id: record.recordingID)
                continue
            }
            let existing = historyManager.recording(id: record.recordingID)
            let sourceURL: URL
            switch record.source {
            case .final: sourceURL = store.finalURL(for: record.recordingID)
            case .partial, .both, .missing: sourceURL = store.partialURL(for: record.recordingID)
            }
            let resultIsComplete = record.stage == .resultReady || record.stage == .succeeded
            let wordCount = (record.resultText ?? record.rawText)?.split(separator: " ").count
            let projected = Recording(
                id: record.recordingID,
                timestamp: existing?.timestamp ?? record.updatedAt,
                audioFileURL: sourceURL,
                transcription: record.resultText ?? record.rawText ?? existing?.transcription,
                status: resultIsComplete ? .success : .failed,
                errorMessage: resultIsComplete ? nil : (record.failureMessage
                    ?? "Processing was interrupted. Your recording is available to retry."),
                retryCount: existing?.retryCount ?? 0,
                duration: existing?.duration ?? record.audioIntegrity?.duration,
                wordCount: wordCount,
                outputMode: existing?.outputMode ?? .dictation,
                transcriptionOptions: existing?.transcriptionOptions ?? .default,
                sourceIntegrity: record.source == .final && record.audioIntegrity != nil
                    ? .complete
                    : (record.source == .missing ? .knownIncomplete : .unfinalized),
                legacyAudioFilePath: existing?.legacyAudioFilePath
            )
            guard historyManager.upsertRecording(projected) else {
                historyManager.showUnsavedTerminalState(projected)
                continue
            }

            if record.stage == .resultReady {
                let lease = MacAudioProcessingStore.Lease(
                    recordingID: record.recordingID,
                    attemptID: record.attemptID,
                    clearGeneration: record.clearGeneration,
                    revision: record.revision
                )
                guard let success = try? await store.markSucceeded(
                    lease,
                    pendingUsageWordCount: wordCount
                ) else { continue }
                record = success.record
            }
            if record.stage == .succeeded {
                do {
                    if let claimed = try await store.claimPendingUsage(
                        recordingID: record.recordingID,
                        expectedRevision: record.revision
                    ) {
                        await SubscriptionManager.shared.recordWords(claimed)
                    }
                } catch {
                    // Leave the durable unclaimed event for the next launch.
                }
            }
        }
    }

    /// Bounded, repeatable Quit handoff. Native writer-close proof is retained
    /// by AudioRecorder, while store IDs that have not reached the recorder yet
    /// remain owned through pendingPreparationStoreIDs.
    func prepareForTermination(closeTimeout: TimeInterval = 4.5) async -> Bool {
        terminationBarrierActive = true
        terminationOwnedStoreIDs.formUnion(pendingPreparationStoreIDs.keys)
        if let activeRecordingID {
            terminationOwnedStoreIDs.insert(activeRecordingID)
        }
        terminationOwnedStoreIDs.formUnion(retranscriptionAttemptIDs.keys)
        terminationOwnedNativeIDs.formUnion(pendingPreparationStoreIDs.values)
        if recordingState == .starting
            || recordingState == .recording
            || recordingState == .finalizing,
           let recordingAttemptID {
            terminationOwnedNativeIDs.insert(recordingAttemptID)
        }

        // Fence every admitted processing generation before the first await.
        // Native close ownership is deliberately narrower, but recognition and
        // retry work can also ignore cancellation and resume after Quit.
        var attemptsToAbandon = Set(pendingPreparationStoreIDs.values)
        if let recordingAttemptID {
            attemptsToAbandon.insert(recordingAttemptID)
        }
        attemptsToAbandon.formUnion(retranscriptionAttemptIDs.values)
        processingAttemptFence.abandon(attemptsToAbandon)

        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        for task in transcriptionTasks.values { task.cancel() }
        closeActiveRealtimeFinishRequest()
        let realtime = stopRealtimeTranscription()
        realtime?.close()

        let nativeProofs = audioRecorder.beginTerminationClose(
            recordingIDs: terminationOwnedNativeIDs
        )
        terminationOwnedNativeIDs.formUnion(nativeProofs.keys)
        let deadline = Date().addingTimeInterval(closeTimeout)
        let closed = await waitForTerminationOwnership(
            nativeProofs: nativeProofs,
            deadline: deadline
        )
        if let existingFinalization = terminationFinalizationTask {
            return closed ? await existingFinalization.value : false
        }
        guard closed else {
            // Keep the barrier and ownership intact. When a native operation
            // that ignored cancellation eventually closes, finish the same
            // handoff in the background so recording can become available
            // again after AppKit has truthfully refused this Quit.
            if terminationFinalizationTask == nil {
                terminationFinalizationTask = Task { @MainActor [weak self] in
                    guard let self else { return false }
                    while !Task.isCancelled {
                        let proofs = self.audioRecorder.beginTerminationClose(
                            recordingIDs: self.terminationOwnedNativeIDs
                        )
                        if await self.waitForTerminationOwnership(
                            nativeProofs: proofs,
                            deadline: Date().addingTimeInterval(0.25)
                        ) {
                            return await self.finishTerminationOwnership()
                        }
                    }
                    return false
                }
            }
            return false
        }
        return await finishTerminationOwnership()
    }

    private func waitForTerminationOwnership(
        nativeProofs: [UUID: MacNativeRecorderCloseProof],
        deadline: Date
    ) async -> Bool {
        while Date() < deadline {
            let nativeClosed = nativeProofs.values.allSatisfy(\.isConfirmedClosed)
            if nativeClosed && pendingPreparationStoreIDs.isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nativeProofs.values.allSatisfy(\.isConfirmedClosed)
            && pendingPreparationStoreIDs.isEmpty
    }

    private func finishTerminationOwnership() async -> Bool {
        let store = await MacAudioProcessingStoreProvider.shared()
        var terminalStatePersisted = true

        for recordingID in terminationOwnedStoreIDs {
            guard var record = await store.record(for: recordingID) else { continue }
            var recordTerminalPersisted = true
            switch record.stage {
            case .rawResultReady, .cleaning:
                let lease = MacAudioProcessingStore.Lease(
                    recordingID: record.recordingID,
                    attemptID: record.attemptID,
                    clearGeneration: record.clearGeneration,
                    revision: record.revision
                )
                do {
                    let result = try await store.useRawResult(
                        lease,
                        message: "Cleanup stopped because the app was closing. The complete raw transcript was kept."
                    )
                    record = result.record
                } catch {
                    terminalStatePersisted = false
                    recordTerminalPersisted = false
                    DebugLog.error(
                        "Could not persist raw-result recovery while closing: \(error.localizedDescription)",
                        context: "AppState"
                    )
                }

            case .preparing, .recording, .finalizing, .readyForRecognition, .recognizing:
                let lease = MacAudioProcessingStore.Lease(
                    recordingID: record.recordingID,
                    attemptID: record.attemptID,
                    clearGeneration: record.clearGeneration,
                    revision: record.revision
                )
                do {
                    let failed = try await store.fail(
                        lease,
                        message: "Processing stopped because the app was closing. Your recording was kept."
                    )
                    record = failed.record
                } catch {
                    terminalStatePersisted = false
                    recordTerminalPersisted = false
                    DebugLog.error(
                        "Could not persist interrupted processing while closing: \(error.localizedDescription)",
                        context: "AppState"
                    )
                }

            case .resultReady, .succeeded, .failed, .deleted:
                break
            }

            // Do not manufacture a terminal History projection when its owning
            // journal transition failed. The source and nonterminal journal
            // remain available for recovery on the next attempt or launch.
            guard recordTerminalPersisted else { continue }

            let existing = historyManager.recording(id: recordingID)
            if record.stage == .deleted {
                _ = historyManager.removeRecordingMetadata(id: recordingID)
                continue
            }
            let completeResult = record.stage == .resultReady || record.stage == .succeeded
            // Never replace a durable success projection with a failure merely
            // because this Quit was refused or raced a final callback.
            if existing?.status == .success && !completeResult {
                continue
            }
            let sourceURL = record.source == .final
                ? store.finalURL(for: recordingID)
                : store.partialURL(for: recordingID)
            let text = record.resultText ?? record.rawText ?? existing?.transcription
            let projected = Recording(
                id: recordingID,
                timestamp: existing?.timestamp ?? record.updatedAt,
                audioFileURL: sourceURL,
                transcription: text,
                status: completeResult ? .success : .failed,
                errorMessage: completeResult ? nil : record.failureMessage,
                retryCount: existing?.retryCount ?? 0,
                duration: existing?.duration ?? record.audioIntegrity?.duration,
                wordCount: text?.split(separator: " ").count,
                outputMode: existing?.outputMode ?? .dictation,
                transcriptionOptions: existing?.transcriptionOptions ?? .default,
                sourceIntegrity: record.source == .final && record.audioIntegrity != nil
                    ? .complete
                    : .unfinalized,
                legacyAudioFilePath: existing?.legacyAudioFilePath
            )
            if !historyManager.upsertRecording(projected) {
                historyManager.showUnsavedTerminalState(projected)
            }
        }

        let nativeOwnershipReleased = audioRecorder.releaseTerminationBarrierIfClosed(
            recordingIDs: terminationOwnedNativeIDs
        )
        let settlement = MacTerminationSettlement.evaluate(
            nativeOwnershipReleased: nativeOwnershipReleased,
            terminalStatePersisted: terminalStatePersisted
        )
        guard settlement.shouldSettleToIdle else {
            terminationFinalizationTask = nil
            return false
        }

        for recordingID in terminationOwnedStoreIDs {
            historyManager.unregisterActiveRecording(id: recordingID)
        }
        terminationOwnedStoreIDs.removeAll()
        terminationOwnedNativeIDs.removeAll()
        pendingPreparationStoreIDs.removeAll()
        activeRecordingID = nil
        recordingAttemptID = nil
        activeCaptureLease = nil
        activeTranscriptionSnapshot = nil
        retranscriptionAttemptIDs.removeAll()
        transcriptionTasks.removeAll()
        recordingState = .idle
        isProcessing = false
        terminationBarrierActive = false
        terminationFinalizationTask = nil
        if let warning = settlement.warning {
            presentTerminationStorageWarning(warning)
        }
        return settlement.shouldAllowTermination
    }

    private func presentTerminationStorageWarning(_ warning: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Your Recording Was Kept"
        alert.informativeText = warning
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Private Methods

    private func setupAppStateObservers() {
        // Listen for app going to background/foreground
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appContext = .background
                DebugLog.info("App went to background", context: "AppState")
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appContext = .foreground
                DebugLog.info("App came to foreground", context: "AppState")
            }
        }

    }

    private func beginLiveTranscription(
        store: MacAudioProcessingStore,
        ready: MacAudioProcessingStore.Mutation,
        recordingID: UUID,
        captureAttemptID: UUID,
        realtimeFinishRequest: RealtimeTranscriptionFinishRequest?
    ) async {
        guard ownsProcessingAttempt(
            recordingID: recordingID,
            attemptID: captureAttemptID
        ) else {
            realtimeFinishRequest?.close()
            return
        }

        recordingState = .transcribing
        isProcessing = true
        if overlayManager.isOverlayMode {
            overlayManager.transition(to: .processing(isCommandMode: recordingMode == .command))
        }

        let recognitionAttemptID = UUID()
        do {
            let recognition = try await store.beginRecognition(
                recordingID: recordingID,
                attemptID: recognitionAttemptID,
                expectedRevision: ready.record.revision,
                deadline: Date().addingTimeInterval(
                    TimeInterval(recognitionTimeoutSeconds(for: finalizedRecordingDuration))
                )
            )
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: captureAttemptID
            ) else {
                realtimeFinishRequest?.close()
                return
            }
            let transientWorkspace = try await store.makeTransientWorkspace(
                recognition.lease
            )
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: captureAttemptID
            ) else {
                transientWorkspace.cleanup()
                realtimeFinishRequest?.close()
                return
            }
            recordingAttemptID = recognitionAttemptID
            let session = MacStoreTranscriptionSession(
                store: store,
                mutation: recognition,
                attemptIsCurrent: { @MainActor [weak self] in
                    self?.isCurrentAttempt(
                        recordingID: recordingID,
                        attemptID: recognitionAttemptID,
                        isLiveRecording: true
                    ) ?? false
                }
            )
            guard let snapshot = activeTranscriptionSnapshot else {
                transientWorkspace.cleanup()
                throw MacAudioProcessingStore.StoreError.invalidTransition
            }
            let projected = historyManager.recording(id: recordingID) ?? Recording(
                id: recordingID,
                audioFileURL: store.finalURL(for: recordingID),
                status: .processing,
                outputMode: snapshot.outputMode,
                transcriptionOptions: snapshot.transcriptionOptions,
                sourceIntegrity: .complete
            )
            let task = Task { [weak self] in
                guard let self else { return }
                await self.executeTranscriptionAttempt(
                    recording: projected,
                    attemptID: recognitionAttemptID,
                    session: session,
                    audioURL: store.finalURL(for: recordingID),
                    transientWorkspace: transientWorkspace,
                    snapshot: snapshot,
                    realtimeFinishRequest: realtimeFinishRequest,
                    isLiveRecording: true
                )
            }
            transcriptionTasks[recordingID] = task
        } catch {
            realtimeFinishRequest?.close()
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: captureAttemptID
            ) else { return }
            _ = try? await store.fail(ready.lease, message: error.localizedDescription)
            guard ownsProcessingAttempt(
                recordingID: recordingID,
                attemptID: captureAttemptID
            ) else { return }
            finishActiveTranscriptionFailure(
                recordingID: recordingID,
                audioURL: store.finalURL(for: recordingID),
                message: error.localizedDescription
            )
        }
    }

    private func executeTranscriptionAttempt(
        recording: Recording,
        attemptID: UUID,
        session: MacStoreTranscriptionSession,
        audioURL: URL,
        transientWorkspace: MacTransientWorkspace,
        snapshot: MacTranscriptionAttemptSnapshot,
        realtimeFinishRequest: RealtimeTranscriptionFinishRequest? = nil,
        isLiveRecording: Bool
    ) async {
        defer { transientWorkspace.cleanup() }
        defer { finishRealtimeRequest(realtimeFinishRequest) }
        do {
            try Task.checkCancellation()
            DictationStopwatch.mark("transcription attempt entered")
            let (canTranscribe, reason) = SubscriptionManager.shared.checkCanTranscribe()
            guard canTranscribe else {
                throw NSError(
                    domain: "AppState",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: reason ?? "Your usage limit was reached. Your recording is saved."]
                )
            }

            let requestedOutputMode = snapshot.outputMode
            let transcriptionOptions = snapshot.transcriptionOptions
            let activeTransport = requestedOutputMode != .dictation || transcriptionOptions.diarization
                ? TranscriptionTransport.batch
                : snapshot.transport

            let realtimeResult: String?
            if isLiveRecording, activeTransport == .realtime {
                let result = await realtimeFinishRequest?.finish()?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if result?.isEmpty == false {
                    realtimeResult = result
                } else {
                    realtimeFinishRequest?.close()
                    realtimeResult = nil
                }
            } else {
                realtimeResult = nil
            }

            let recognitionSnapshot: MacTranscriptionAttemptSnapshot
            let usedBatchFallback: Bool
            if realtimeResult == nil,
               snapshot.provider == .soniox,
               let fallback = snapshot.usingBatchFallback()
            {
                recognitionSnapshot = fallback
                usedBatchFallback = true
                DebugLog.warning(
                    "Fast streaming did not complete; using cloud fallback",
                    context: "SonioxRealtime"
                )
            } else {
                recognitionSnapshot = snapshot
                usedBatchFallback = false
            }

            if activeTransport == .realtime,
               (snapshot.mode != .auto || snapshot.networkWasConnected),
               realtimeResult == nil,
               !usedBatchFallback
            {
                throw NSError(
                    domain: "AppState",
                    code: -9,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Realtime transcription did not complete. Your recording is saved."
                    ]
                )
            }

            let result = try await withTimeout(
                seconds: recognitionTimeoutSeconds(for: recording.duration)
            ) {
                if realtimeResult == nil, snapshot.vadEnabled {
                    do {
                        let hasSpeech = try await VoiceActivityDetector.hasSpeech(
                            in: audioURL,
                            threshold: snapshot.vadThreshold
                        )
                        guard hasSpeech else {
                            throw NSError(
                                domain: "AppState",
                                code: -6,
                                userInfo: [NSLocalizedDescriptionKey: "No speech was detected. Your recording is saved."]
                            )
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as NSError where error.domain == "AppState" && error.code == -6 {
                        throw error
                    } catch {
                        // VAD is only a rejection optimization. Model, decode, or
                        // inference failures must fail open to recognition.
                        await MainActor.run {
                            DebugLog.warning(
                                "Speech check unavailable; continuing with transcription",
                                context: "VAD"
                            )
                        }
                    }
                }
                if let realtimeResult {
                    try await session.checkpoint(realtimeResult)
                    try await session.markRawResultReady(realtimeResult)
                    try await session.beginCleanup()
                    if snapshot.provider == .soniox {
                        let cleanupStartedAt = CFAbsoluteTimeGetCurrent()
                        let cleaned = try await self.applyLLMPassWithFallback(
                            rawText: realtimeResult,
                            client: OpenAIClient(config: .init()),
                            snapshot: snapshot
                        )
                        let cleanupMilliseconds = Int(
                            (CFAbsoluteTimeGetCurrent() - cleanupStartedAt) * 1_000
                        )
                        DebugLog.info(
                            "Soniox cleanup completed durationMs=\(cleanupMilliseconds) rawLength=\(realtimeResult.count) cleanedLength=\(cleaned.count)",
                            context: "SonioxRealtime"
                        )
                        return cleaned
                    }
                    return realtimeResult
                }
                return try await self.performTranscription(
                    audioURL: audioURL,
                    clipboardContent: nil,
                    transientWorkspace: transientWorkspace,
                    snapshot: recognitionSnapshot,
                    onRecognitionCheckpoint: { text in
                        try await session.checkpoint(text)
                    },
                    onRawTranscript: { text in
                        try await session.markRawResultReady(text)
                    },
                    onCleanupStarted: {
                        try await session.beginCleanup()
                    }
                )
            }
            try Task.checkCancellation()
            guard isCurrentAttempt(
                recordingID: recording.id,
                attemptID: attemptID,
                isLiveRecording: isLiveRecording
            ) else { return }
            DictationStopwatch.mark("recognition returned")
            let resultReady = try await session.finishCleanup(result)
            DictationStopwatch.mark("store finishCleanup")
            let durableText = resultReady.record.resultText ?? resultReady.record.rawText ?? result
            await commitTranscriptionSuccess(
                recording: recording,
                attemptID: attemptID,
                session: session,
                storeRecord: resultReady.record,
                text: durableText,
                isLiveRecording: isLiveRecording
            )
        } catch {
            await finishStoredTranscriptionFailure(
                recording: recording,
                attemptID: attemptID,
                session: session,
                message: error.localizedDescription,
                isLiveRecording: isLiveRecording
            )
        }
    }

    private func commitTranscriptionSuccess(
        recording: Recording,
        attemptID: UUID,
        session: MacStoreTranscriptionSession,
        storeRecord: MacAudioProcessingStore.Record,
        text: String,
        isLiveRecording: Bool
    ) async {
        guard isCurrentAttempt(
            recordingID: recording.id,
            attemptID: attemptID,
            isLiveRecording: isLiveRecording
        ) else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Recognition succeeded and returned nothing — the normal result for
            // a silent recording that VAD let through (VAD fails open on error
            // or timeout). This used to return here, which left the attempt
            // half-finished: no message, the overlay stuck in processing, the
            // recording still owned, and the App Nap assertion still held. Treat
            // it as a terminal outcome instead. The audio stays on disk and the
            // store record stays recoverable, so a retry can still use it.
            DebugLog.info(
                "Recognition returned an empty transcript; ending the attempt",
                context: "DictationFlow"
            )
            finishEmptyTranscription(
                recordingID: recording.id,
                isLiveRecording: isLiveRecording
            )
            return
        }
        var success = recording
        let store = await MacAudioProcessingStoreProvider.shared()
        guard isCurrentAttempt(
            recordingID: recording.id,
            attemptID: attemptID,
            isLiveRecording: isLiveRecording
        ) else { return }
        success.audioFileURL = store.finalURL(for: recording.id)
        success.transcription = trimmed
        success.status = .success
        success.errorMessage = storeRecord.failureMessage
        success.wordCount = trimmed.split(separator: " ").count
        success.sourceIntegrity = .complete
        let usageWordCount = success.wordCount ?? 0
        DictationStopwatch.mark("commit entered")
        let historyWasPersisted = historyManager.upsertRecording(success)
        DictationStopwatch.mark("history upsert")
        if !historyWasPersisted {
            historyManager.showUnsavedTerminalState(success)
            errorMessage = "The transcript is safe, but History couldn’t be updated."
        }

        if historyWasPersisted, !isLiveRecording {
            do {
                if let claimed = try await session.markSucceededAndClaimUsage(
                    wordCount: usageWordCount
                ) {
                    Task {
                        await SubscriptionManager.shared.recordWords(claimed)
                    }
                }
            } catch {
                errorMessage = "The transcript is safe, but its retry status couldn’t be finalized."
                return
            }
        }

        // Usage accounting is deliberately not awaited here. The claim writes a
        // journal entry with full power-loss durability before touching the
        // non-idempotent billing sink, which is correct but cost ~1.6s measured
        // — all of it spent after the transcript was already in hand, with the
        // user waiting on a billing write before their text could paste.
        //
        // The ordering guarantee that matters is claim-before-sink, and that is
        // preserved: both still happen inside this task, in the same order. Only
        // the paste no longer waits on them. A crash in the window loses the
        // usage claim, never the transcript, and startup recovery re-resolves
        // the record from the store.
        if historyWasPersisted, isLiveRecording {
            Task { [weak self] in
                do {
                    if let claimed = try await session.markSucceededAndClaimUsage(
                        wordCount: usageWordCount
                    ) {
                        DictationStopwatch.mark("usage claimed (off critical path)")
                        await SubscriptionManager.shared.recordWords(claimed)
                    }
                } catch {
                    await MainActor.run {
                        self?.errorMessage =
                            "The transcript is safe, but its recovery status couldn’t be finalized."
                    }
                }
            }
        }

        guard isCurrentAttempt(
            recordingID: recording.id,
            attemptID: attemptID,
            isLiveRecording: isLiveRecording
        ) else { return }
        currentRecording = success
        transcriptionText = trimmed
        isProcessing = false
        transcriptionTasks.removeValue(forKey: recording.id)
        if isLiveRecording {
            releaseActiveRecordingOwnership(recording.id)
            recordingState = .idle
            finishOverlayAfterRecording()
        } else {
            retranscriptionAttemptIDs.removeValue(forKey: recording.id)
            historyManager.unregisterActiveRecording(id: recording.id)
        }
        NotificationCenter.default.post(name: .recordingCompleted, object: success)

        if isLiveRecording {
            let wasCommandMode = recordingMode == .command
            let commandTargetText = CommandModeManager.shared.targetText
            if wasCommandMode {
                await processCommandResult(instruction: trimmed, targetText: commandTargetText)
            } else {
                await processDictationResult(transcription: trimmed)
            }
            recordingMode = .dictation
            shouldAutoPaste = false
            recordingStartTime = nil
            finalizedRecordingDuration = nil
        }

    }

    /// Ends an attempt that recognized successfully but produced no text.
    ///
    /// Mirrors the tail of `commitTranscriptionSuccess` without publishing a
    /// transcript: return the UI to idle, drop ownership, and release the
    /// activity assertion so the process can nap again.
    private func finishEmptyTranscription(recordingID: UUID, isLiveRecording: Bool) {
        errorMessage = "No speech was detected. Your recording is saved."
        isProcessing = false
        transcriptionTasks.removeValue(forKey: recordingID)
        if isLiveRecording {
            releaseActiveRecordingOwnership(recordingID)
            recordingState = .idle
            finishOverlayAfterRecording()
            recordingMode = .dictation
            shouldAutoPaste = false
            recordingStartTime = nil
            finalizedRecordingDuration = nil
        } else {
            retranscriptionAttemptIDs.removeValue(forKey: recordingID)
            historyManager.unregisterActiveRecording(id: recordingID)
        }
        DictationActivityAssertion.release()
        AudioRecorder.shared.prewarmEngine()
    }

    private func finishStoredTranscriptionFailure(
        recording: Recording,
        attemptID: UUID,
        session: MacStoreTranscriptionSession,
        message: String,
        isLiveRecording: Bool
    ) async {
        guard isCurrentAttempt(
            recordingID: recording.id,
            attemptID: attemptID,
            isLiveRecording: isLiveRecording
        ) else { return }

        do {
            let terminal = try await session.fail(message)
            if terminal.record.stage == .resultReady,
               let raw = terminal.record.resultText ?? terminal.record.rawText {
                await commitTranscriptionSuccess(
                    recording: recording,
                    attemptID: attemptID,
                    session: session,
                    storeRecord: terminal.record,
                    text: raw,
                    isLiveRecording: isLiveRecording
                )
                return
            }
        } catch {
            // A persisted tombstone/Clear or newer attempt owns the recording.
            guard isCurrentAttempt(
                recordingID: recording.id,
                attemptID: attemptID,
                isLiveRecording: isLiveRecording
            ) else { return }
        }

        if isLiveRecording {
            finishActiveTranscriptionFailure(
                recordingID: recording.id,
                audioURL: recording.audioFileURL,
                message: message
            )
        } else {
            await finishRetranscriptionFailure(
                recording: recording,
                attemptID: attemptID,
                message: message
            )
        }
    }

    private func finishRetranscriptionFailure(
        recording: Recording,
        attemptID: UUID,
        message: String
    ) async {
        guard isCurrentAttempt(
            recordingID: recording.id,
            attemptID: attemptID,
            isLiveRecording: false
        ) else { return }
        var failed = recording
        failed.status = .failed
        failed.errorMessage = message
        if !historyManager.upsertRecording(failed) {
        DictationActivityAssertion.release()
            historyManager.showUnsavedTerminalState(failed)
            errorMessage = "The recording is safe, but History couldn’t be updated."
        }
        transcriptionTasks.removeValue(forKey: recording.id)
        retranscriptionAttemptIDs.removeValue(forKey: recording.id)
        historyManager.unregisterActiveRecording(id: recording.id)
    }

    private func isCurrentAttempt(
        recordingID: UUID,
        attemptID: UUID,
        isLiveRecording: Bool
    ) -> Bool {
        guard !terminationBarrierActive,
              processingAttemptFence.allows(attemptID)
        else { return false }
        if isLiveRecording {
            return activeRecordingID == recordingID && recordingAttemptID == attemptID
        }
        return retranscriptionAttemptIDs[recordingID] == attemptID
    }

    private func finishActiveTranscriptionFailure(
        recordingID: UUID,
        audioURL: URL,
        message: String
    ) {
        DictationActivityAssertion.release()
        guard activeRecordingID == recordingID else { return }
        closeActiveRealtimeFinishRequest(recordingID: recordingID)

        let recording = persistActiveRecording(
            recordingID: recordingID,
            audioURL: audioURL,
            status: .failed,
            errorMessage: message,
            sourceIntegrity: .complete
        )
        errorMessage = recording == nil
            ? "Your recording was kept, but its status couldn’t be saved."
            : message
        recordingState = .idle
        isProcessing = false
        recordingMode = .dictation
        shouldAutoPaste = false
        recordingStartTime = nil
        finalizedRecordingDuration = nil
        releaseActiveRecordingOwnership(recordingID)
        CommandModeManager.shared.reset()
        finishOverlayAfterRecording()

        if let recording {
            NotificationCenter.default.post(name: .recordingCompleted, object: recording)
        }
        // A failure must never paste an incomplete realtime prefix or bypass a
        // usage denial. Remove any live insertion and leave the saved source.
        ClipboardManager.cancelLiveDictationInsertion()
    }

    private func releaseActiveRecordingOwnership(_ recordingID: UUID) {
        historyManager.unregisterActiveRecording(id: recordingID)
        guard activeRecordingID == recordingID else { return }
        activeRecordingID = nil
        recordingAttemptID = nil
        activeCaptureLease = nil
        activeTranscriptionSnapshot = nil
    }

    private func recognitionTimeoutSeconds(for duration: TimeInterval?) -> UInt64 {
        let proportional = UInt64(max(0, duration ?? 0) * 2) + 60
        return min(
            maximumRecognitionTimeoutSeconds,
            max(minimumRecognitionTimeoutSeconds, proportional)
        )
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

    private func startRealtimeTranscriptionIfAvailable(
        recordingID: UUID,
        attemptID: UUID,
        snapshot: MacTranscriptionAttemptSnapshot
    ) {
        realtimeTranscript = ""
        realtimeTranscriptionClient?.close()
        realtimeTranscriptionClient = nil
        audioRecorder.realtimeAudioChunkHandler = nil

        let mode = snapshot.mode
        let provider = snapshot.provider
        let transport = snapshot.transport

        if snapshot.outputMode != .dictation || snapshot.transcriptionOptions.diarization {
            DebugLog.info(
                "Skipping realtime start because this output requires batch transcription",
                context: "AppState"
            )
            return
        }

        guard mode != .local,
              !provider.isOnDevice,
              transport == .realtime,
              snapshot.networkWasConnected
        else {
            DebugLog.info("Skipping realtime start for transport=\(transport.rawValue), mode=\(mode.displayName), provider=\(provider.displayName)", context: "AppState")
            return
        }

        let realtimePrompt = snapshot.recordingPrompt
        let languageCode = snapshot.languageCode
        let client: any RealtimeTranscriptionStreaming

        switch provider {
        case .codex:
            client = CodexRealtimeTranscriptionClient(
                onTranscript: { [weak self] transcript in
                    Task { @MainActor [weak self] in
                        self?.handleRealtimePartial(
                            transcript,
                            recordingID: recordingID,
                            attemptID: attemptID
                        )
                    }
                },
                onError: { message in
                    Task { @MainActor in
                        DebugLog.warning(message, context: "CodexRealtime")
                    }
                }
            )
        case .soniox:
            guard let endpoint = URL(string: snapshot.transcriptionEndpoint) else {
                DebugLog.warning("Invalid fast streaming session endpoint", context: "AppState")
                return
            }
            client = SonioxRealtimeTranscriptionClient(
                authorizationProvider: {
                    let accessToken = try await AuthManager.shared.accessToken()
                    return try await WritingmateRealtimeClientSecretProvider.fetchAuthorization(
                        endpoint: endpoint,
                        apiKey: accessToken,
                        model: SonioxRealtimeProtocol.model,
                        prompt: realtimePrompt,
                        language: languageCode,
                        keywords: snapshot.transcriptionKeywords,
                        languages: snapshot.languageCodes
                    )
                },
                languages: snapshot.languageCodes,
                keywords: snapshot.transcriptionKeywords,
                prompt: realtimePrompt,
                onPartialTranscript: { [weak self] partial in
                    self?.handleRealtimePartial(
                        partial,
                        recordingID: recordingID,
                        attemptID: attemptID
                    )
                },
                onError: { message in
                    DebugLog.warning(message, context: "SonioxRealtime")
                }
            )
        case .aidictation:
            let realtimeModel = resolvedRealtimeTranscriptionModel(
                configuredModel: snapshot.transcriptionModel,
                overrideModel: snapshot.customRealtimeModel
            )

            if let webSocketURL = customRealtimeWebSocketURL(
                configuredEndpoint: snapshot.transcriptionEndpoint,
                overrideEndpoint: snapshot.customRealtimeEndpoint
            ) {
                guard let apiKey = snapshot.transcriptionAPIKey, !apiKey.isEmpty else {
                    return
                }
                client = OpenAIRealtimeTranscriptionClient(
                    apiKey: apiKey,
                    webSocketURL: webSocketURL,
                    transcriptionModel: realtimeModel,
                    language: languageCode,
                    keywords: snapshot.transcriptionKeywords,
                    languages: snapshot.languageCodes,
                    prompt: realtimePrompt,
                    onPartialTranscript: { [weak self] partial in
                        self?.handleRealtimePartial(
                            partial,
                            recordingID: recordingID,
                            attemptID: attemptID
                        )
                    },
                    onError: { message in
                        DebugLog.warning(message, context: "AppState")
                    }
                )
            } else {
                guard let endpoint = customRealtimeSessionEndpoint(
                    configuredEndpoint: snapshot.transcriptionEndpoint,
                    overrideEndpoint: snapshot.customRealtimeEndpoint
                ) else {
                    DebugLog.warning("Invalid custom realtime session endpoint", context: "AppState")
                    return
                }

                client = OpenAIRealtimeTranscriptionClient(
                    authorizationProvider: {
                        let token: String
                        if Self.isWritingmateRealtimeSessionEndpoint(endpoint) {
                            token = try await AuthManager.shared.accessToken()
                        } else if let apiKey = snapshot.transcriptionAPIKey, !apiKey.isEmpty {
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
                            prompt: realtimePrompt,
                            language: languageCode,
                            keywords: snapshot.transcriptionKeywords,
                            languages: snapshot.languageCodes
                        )
                    },
                    prompt: realtimePrompt,
                    transcriptionModel: realtimeModel,
                    language: languageCode,
                    keywords: snapshot.transcriptionKeywords,
                    languages: snapshot.languageCodes,
                    onPartialTranscript: { [weak self] partial in
                        self?.handleRealtimePartial(
                            partial,
                            recordingID: recordingID,
                            attemptID: attemptID
                        )
                    },
                    onError: { message in
                        DebugLog.warning(message, context: "AppState")
                    }
                )
            }
        case .parakeet:
            return
        }

        realtimeTranscriptionClient = client
        client.start()
        audioRecorder.realtimeAudioChunkHandler = { [weak client] chunk in
            client?.sendAudio(chunk)
        }
        DebugLog.info("Started realtime transcription stream for \(provider.displayName)", context: "AppState")
    }

    private func customRealtimeSessionEndpoint(
        configuredEndpoint: String,
        overrideEndpoint: URL?
    ) -> URL? {
        if let overrideEndpoint,
           !isWebSocketURL(overrideEndpoint)
        {
            return overrideEndpoint
        }

        return WritingmateRealtimeClientSecretProvider.endpoint(
            from: configuredEndpoint
        )
    }

    private static func isWritingmateRealtimeSessionEndpoint(_ endpoint: URL) -> Bool {
        let host = endpoint.host?.lowercased()
        return endpoint.scheme?.lowercased() == "https"
            && (host == "writingmate.ai" || host == "www.writingmate.ai")
            && endpoint.path == "/api/openai/v1/realtime/client_secrets"
    }

    private func customRealtimeWebSocketURL(
        configuredEndpoint: String,
        overrideEndpoint: URL?
    ) -> URL? {
        if let overrideEndpoint,
           isWebSocketURL(overrideEndpoint)
        {
            return overrideEndpoint
        }

        guard let endpoint = URL(string: configuredEndpoint),
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

    private func configuredCustomRealtimeModel() -> String? {
        guard let configured = SecretsLoader.customTranscriptionRealtimeModel()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        else {
            return nil
        }
        return configured
    }

    private func isWebSocketURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "ws" || scheme == "wss"
    }

    private func resolvedRealtimeTranscriptionModel(
        configuredModel: String,
        overrideModel: String?
    ) -> String {
        if let overrideModel {
            return overrideModel
        }

        let model = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              !model.contains("/"),
              model != TranscriptionProvider.aidictation.defaultModel
        else {
            return OpenAIRealtimeTranscriptionClient.defaultTranscriptionModel
        }
        return model
    }

    /// Removes AppState's live client ownership without sealing audio delivery.
    /// The normal key-up path carries this request to AudioRecorder, which owns
    /// the only safe durable-write/realtime-admission cutoff.
    private func takeRealtimeTranscription(
        recordingID: UUID? = nil,
        attemptID: UUID? = nil,
        drainDeadline: TimeInterval? = nil
    ) -> RealtimeTranscriptionFinishRequest? {
        let client = realtimeTranscriptionClient
        realtimeTranscriptionClient = nil
        let request = client.map(RealtimeTranscriptionFinishRequest.init(client:))

        if let recordingID, let attemptID, let request {
            activeRealtimeFinishRequest?.request.close()
            activeRealtimeFinishRequest = (recordingID, attemptID, request)
        }
        if let request, let drainDeadline {
            request.armDrainDeadline(timeout: drainDeadline)
        }
        return request
    }

    private func stopRealtimeTranscription() -> RealtimeTranscriptionFinishRequest? {
        let request = takeRealtimeTranscription()
        audioRecorder.detachRealtimeAudioChunkHandlerAndDrain {}
        return request
    }

    private func closeLiveRealtimeTranscription() {
        let request = stopRealtimeTranscription()
        request?.close()
    }

    private func closeActiveRealtimeFinishRequest(recordingID: UUID? = nil) {
        guard let activeRealtimeFinishRequest else { return }
        if let recordingID,
           activeRealtimeFinishRequest.recordingID != recordingID
        {
            return
        }
        self.activeRealtimeFinishRequest = nil
        activeRealtimeFinishRequest.request.close()
    }

    private func finishRealtimeRequest(
        _ request: RealtimeTranscriptionFinishRequest?
    ) {
        guard let request else { return }
        if activeRealtimeFinishRequest?.request === request {
            activeRealtimeFinishRequest = nil
        }
        request.close()
    }

    private func handleRealtimePartial(
        _ partial: String,
        recordingID: UUID,
        attemptID: UUID
    ) {
        guard ownsProcessingAttempt(recordingID: recordingID, attemptID: attemptID),
              recordingState == .recording
        else { return }
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

    private func makeTranscriptionAttemptSnapshot(
        outputMode: TranscriptionOutputMode,
        transcriptionOptions: TranscriptionOptions,
        appContext: String?,
        screenContext: String?,
        usesContextRules: Bool,
        modeOverride: TranscriptionMode? = nil,
        onlineProviderOverride: TranscriptionProvider? = nil,
        isRetranscription: Bool = false
    ) -> MacTranscriptionAttemptSnapshot {
        let mode = modeOverride ?? transcriptionProviderManager.transcriptionMode
        let onlineProvider = onlineProviderOverride
            ?? transcriptionProviderManager.selectedOnlineProvider
        let selectedProvider: TranscriptionProvider = mode == .local ? .parakeet : onlineProvider
        let provider: TranscriptionProvider = isRetranscription && selectedProvider == .soniox
            ? .aidictation
            : selectedProvider
        let endpoint: String
        let model: String
        let transport: TranscriptionTransport
        if provider == .aidictation {
            endpoint = SecretsLoader.customTranscriptionEndpoint()
                ?? provider.defaultEndpoint
            model = isRetranscription
                ? "gpt-transcribe"
                : (SecretsLoader.customTranscriptionRealtimeModel() ?? "gpt-live-transcribe")
            transport = isRetranscription ? .batch : .realtime
        } else if provider == .codex, isRetranscription {
            endpoint = CodexTranscriptionSupport.batchEndpoint.absoluteString
            model = ""
            transport = .batch
        } else {
            endpoint = provider.defaultEndpoint
            model = provider.defaultModel
            transport = provider.defaultTransport
        }
        let sttHintPrompt = buildSTTHintPromptComponents().joined(separator: "\n")
        let cleanupComponents = buildTranscriptionPromptComponents()
        let trimmedAppContext = appContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appContextPrompt = trimmedAppContext.flatMap {
            $0.isEmpty ? nil : "Application context: \($0)"
        }
        let recordingPrompt = [
            sttHintPrompt,
            appContextPrompt,
        ].compactMap { $0 }.joined(separator: "\n\n")
        let contextRules = contextRulesManager.rules.map { rule in
            MacTranscriptionAttemptSnapshot.ContextRuleSnapshot(
                name: rule.name,
                appBundleIDs: rule.appBundleIds,
                titlePatterns: rule.titlePatterns,
                instructions: rule.instructions,
                isEnabled: rule.isEnabled,
                diarization: rule.transcriptionOptions.diarization
            )
        }
        let batchFallback: MacTranscriptionAttemptSnapshot.BatchFallback? =
            provider == .soniox
            ? .init(
                endpoint: SecretsLoader.customTranscriptionEndpoint()
                    ?? TranscriptionProvider.aidictation.defaultEndpoint,
                model: "groq/whisper-large-v3-turbo",
                apiKey: resolvedTranscriptionApiKey(for: .aidictation)
            )
            : nil
        return MacTranscriptionAttemptSnapshot(
            outputMode: outputMode,
            transcriptionOptions: transcriptionOptions,
            mode: mode,
            provider: provider,
            transport: transport,
            transcriptionEndpoint: endpoint,
            transcriptionModel: model,
            transcriptionAPIKey: resolvedTranscriptionApiKey(for: provider),
            customRealtimeEndpoint: configuredCustomRealtimeEndpoint(),
            customRealtimeModel: configuredCustomRealtimeModel(),
            batchFallback: batchFallback,
            llmPostProcessingEnabled: transcriptionProviderManager.enableLLMPostProcessing,
            postProcessingProvider: transcriptionProviderManager.postProcessingProvider,
            llmEndpoint: llmProviderManager.effectiveEndpoint,
            llmModel: llmProviderManager.effectiveModel,
            llmAPIKey: llmProviderManager.effectiveApiKey,
            aidictationPostProcessingEndpoint: SecretsLoader.aidictationPostProcessingEndpoint(),
            aidictationPostProcessingKey: SecretsLoader.aidictationPostProcessingKey(),
            languageCode: singleAPILanguageCode(),
            languageCodes: languageManager.apiLanguageCodes,
            transcriptionKeywords: Array(Set(
                dictionaryManager.transcriptionKeywords
                    + shortcutManager.transcriptionKeywords
            )).sorted(),
            recordingPrompt: recordingPrompt,
            sttHintPrompt: sttHintPrompt,
            cleanupPromptComponents: cleanupComponents,
            baseCleanupPromptComponents: cleanupComponents,
            contextRules: contextRules,
            usesContextRules: usesContextRules,
            appContext: appContext,
            screenContext: screenContext,
            vadEnabled: vadSettingsManager.vadEnabled,
            vadThreshold: vadSettingsManager.sensitivityThreshold,
            networkWasConnected: NetworkMonitor.shared.isConnected
        )
    }

    private func buildTranscriptionPromptComponents() -> [String] {
        var promptComponents: [String] = []

        if !dictionaryManager.transcriptionHints.isEmpty {
            promptComponents.append("Vocabulary: \(dictionaryManager.transcriptionHints)")
        }
        if !shortcutManager.transcriptionHints.isEmpty {
            promptComponents.append("Phrases: \(shortcutManager.transcriptionHints)")
        }
        if let instructions = dictionaryManager.formattingInstructions {
            promptComponents.append(instructions)
        }
        if let instructions = shortcutManager.formattingInstructions {
            promptComponents.append(instructions)
        }
        return promptComponents
    }

    private func buildSTTHintPromptComponents() -> [String] {
        var hints: [String] = []

        if !dictionaryManager.transcriptionHints.isEmpty {
            hints.append(dictionaryManager.transcriptionHints)
        }
        if !shortcutManager.transcriptionHints.isEmpty {
            hints.append(shortcutManager.transcriptionHints)
        }
        if let instructions = dictionaryManager.formattingInstructions {
            hints.append(instructions)
        }
        if let instructions = shortcutManager.formattingInstructions {
            hints.append(instructions)
        }

        return [TranscriptionCleanupPrompt.speechRecognitionPrompt(hints: hints)]
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
        clipboardContent: String?,
        transientWorkspace: MacTransientWorkspace,
        snapshot: MacTranscriptionAttemptSnapshot,
        onRecognitionCheckpoint: @escaping @Sendable (String) async throws -> Void = { _ in },
        onRawTranscript: @escaping @Sendable (String) async throws -> Void = { _ in },
        onCleanupStarted: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> String {
        let sttHintPrompt = snapshot.sttHintPrompt
        let transcriptionOptions = snapshot.transcriptionOptions
        let milestones = TranscriptionMilestoneForwarder(
            onCheckpoint: onRecognitionCheckpoint,
            onRaw: onRawTranscript,
            onCleanup: onCleanupStarted
        )

        let mode = snapshot.mode
        var provider = snapshot.provider
        DebugLog.info("Transcription mode: \(mode.displayName), provider: \(provider.displayName), transport: \(snapshot.transport.rawValue), isOnDevice: \(provider.isOnDevice)", context: "AppState")

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
           !snapshot.networkWasConnected,
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
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    DebugLog.error("Auto mode: Parakeet init failed (\(error.localizedDescription)) - attempting cloud", context: "AppState")
                }
            case .downloading, .initializing:
                DebugLog.info("Auto mode: network unavailable, Parakeet still loading - attempting cloud", context: "AppState")
            }
        }

        let transport = provider == snapshot.provider
            ? snapshot.transport
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

            let text: String
            if transcriptionOptions.diarization {
                text = try await withTimeout(seconds: diarizationTimeoutSeconds) {
                    try await ParakeetTranscriptionService.shared.transcribeDiarized(audioURL: audioURL)
                }
            } else {
                text = try await ParakeetTranscriptionService.shared.transcribe(audioURL: audioURL)
            }
            let durableRaw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !durableRaw.isEmpty else {
                throw NSError(
                    domain: "AppState",
                    code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "No speech was recognized. Your recording was kept."]
                )
            }
            try await milestones.acceptRaw(durableRaw)
            try await milestones.beginCleanup()
            return try await applyLLMPassWithFallback(
                rawText: durableRaw,
                client: OpenAIClient(config: .init()),
                snapshot: snapshot
            )

        case .realtime:
            DebugLog.warning("Realtime transport reached batch transcription path; using batch cloud fallback", context: "AppState")
            fallthrough

        case .batch:
            DebugLog.info("Using \(provider.displayName) batch transcription", context: "AppState")
            guard let transcriptionApiKey = snapshot.transcriptionAPIKey else {
                throw NSError(domain: "AppState", code: -1, userInfo: [NSLocalizedDescriptionKey: "Please set your \(provider.displayName) API key"])
            }

            let chatCompletionEndpoint: String
            let chatCompletionModel: String
            let chatCompletionApiKey: String?
            if provider == .aidictation {
                chatCompletionEndpoint = snapshot.aidictationPostProcessingEndpoint ?? ""
                chatCompletionModel = PostProcessingProvider.aidictationModel
                chatCompletionApiKey = snapshot.aidictationPostProcessingKey ?? transcriptionApiKey
            } else {
                chatCompletionEndpoint = snapshot.llmEndpoint
                chatCompletionModel = snapshot.llmModel
                chatCompletionApiKey = nil
            }

            let config = OpenAIClient.Configuration(
                transcriptionEndpoint: snapshot.transcriptionEndpoint,
                transcriptionModel: snapshot.transcriptionModel,
                chatCompletionEndpoint: chatCompletionEndpoint,
                chatCompletionModel: chatCompletionModel,
                apiKey: transcriptionApiKey,
                chatCompletionApiKey: chatCompletionApiKey
            )

            // Configuration is attempt-local. Concurrent retry/live attempts must
            // never mutate a shared client out from under one another.
            let client = OpenAIClient(config: config)
            let checkpointAccumulator = OrderedRecognitionCheckpointAccumulator(
                callback: { text in
                    try await milestones.checkpoint(text)
                }
            )
            let rawText = try await client.transcribe(
                audioURL: audioURL,
                prompt: snapshot.transcriptionModel == "gpt-transcribe"
                    ? snapshot.recordingPrompt
                    : (sttHintPrompt.isEmpty ? nil : sttHintPrompt),
                language: snapshot.languageCode,
                keywords: snapshot.transcriptionKeywords,
                languages: snapshot.languageCodes,
                sttPrompt: provider == .aidictation
                    && snapshot.transcriptionModel != "gpt-transcribe"
                    && !sttHintPrompt.isEmpty
                        ? sttHintPrompt
                        : nil,
                postProcessingPrompt: nil,
                serverPostProcessingEnabledByDefault: false,
                postProcessingEnabled: provider != .aidictation,
                transientWorkspace: transientWorkspace,
                onChunkCheckpoint: { completedLeafIndex, transcript in
                    try await checkpointAccumulator.accept(
                        completedLeafIndex: completedLeafIndex,
                        transcript: transcript
                    )
                },
                onMergedRawTranscript: { mergedRaw in
                    try await milestones.acceptRaw(mergedRaw)
                },
                cleanupMergedTranscript: nil
            )

            let checkpointedRaw = await checkpointAccumulator.latestText
            let candidateRaw = (await milestones.rawText) ?? checkpointedRaw ?? rawText
            let durableRaw = candidateRaw
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !durableRaw.isEmpty else {
                throw NSError(
                    domain: "AppState",
                    code: -8,
                    userInfo: [NSLocalizedDescriptionKey: "No speech was recognized. Your recording was kept."]
                )
            }
            try await milestones.acceptRaw(durableRaw)
            try await milestones.beginCleanup()

            if provider == .aidictation {
                return durableRaw
            }

            return try await applyLLMPassWithFallback(
                rawText: durableRaw,
                client: client,
                snapshot: snapshot
            )
        }
    }

    private func providerPostProcessingPrompt(
        outputMode: TranscriptionOutputMode,
        basePrompt: String,
        languageContext: String?,
        appContext: String?
    ) -> String {
        let transformationInstruction: String?
        switch outputMode {
        case .dictation:
            transformationInstruction = nil
        case .notes:
            transformationInstruction = TranscriptionOutputMode.notesPostProcessingInstruction
        case .meetings:
            transformationInstruction = TranscriptionOutputMode.meetingsPostProcessingInstruction
        @unknown default:
            transformationInstruction = nil
        }

        return TranscriptionCleanupPrompt.systemPrompt(
            formattingContext: basePrompt.isEmpty ? [] : [basePrompt],
            languageContext: languageContext,
            appContext: appContext,
            hasSelectedContent: false,
            transformationInstruction: transformationInstruction
        )
    }

    private func applyLLMPassWithFallback(
        rawText: String,
        client: OpenAIClient,
        snapshot: MacTranscriptionAttemptSnapshot
    ) async throws -> String {
        try await cleanupWithRawFallback(
            rawText: rawText,
            label: "\(snapshot.outputMode.displayName) post-processing"
        ) {
            try await self.applyLLMPass(
                rawText: rawText,
                client: client,
                snapshot: snapshot
            )
        }
    }

    private func cleanupWithRawFallback(
        rawText: String,
        label: String,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        do {
            let cleaned = try await withTimeout(
                seconds: llmPostProcessingTimeoutSeconds,
                operation: operation
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                DebugLog.warning("\(label) returned no text - using transcript", context: "AppState")
                return rawText
            }
            return cleaned
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DebugLog.warning("\(label) unavailable within time limit - using transcript", context: "AppState")
            return rawText
        }
    }

    /// Every path that reaches this method has already produced and durably
    /// checkpointed a complete raw transcript. Cleanup is core infrastructure
    /// for these two-stage paths, so the legacy optional UI toggle must not
    /// bypass personal vocabulary, phrases, replacements, or formatting rules.
    private func applyLLMPass(
        rawText: String,
        client: OpenAIClient,
        snapshot: MacTranscriptionAttemptSnapshot
    ) async throws -> String {
        let outputMode = snapshot.outputMode
        let promptComponents = snapshot.cleanupPromptComponents
        let postProcessor = snapshot.postProcessingProvider

        if postProcessor == .aidictation,
           let endpoint = snapshot.aidictationPostProcessingEndpoint,
           let apiKey = snapshot.aidictationPostProcessingKey
        {
            let llmConfig = OpenAIClient.Configuration(
                transcriptionEndpoint: snapshot.transcriptionEndpoint,
                transcriptionModel: snapshot.transcriptionModel,
                chatCompletionEndpoint: endpoint,
                chatCompletionModel: PostProcessingProvider.aidictationModel,
                apiKey: apiKey
            )
            client.updateConfig(llmConfig)
            if outputMode == .dictation {
                return try await client.applyFormattingRules(
                    transcription: rawText,
                    rules: promptComponents,
                    languageCodes: snapshot.languageCode,
                    appContext: snapshot.appContext,
                    screenContext: snapshot.screenContext,
                    clipboardContent: nil
                )
            }
            return try await applyOutputModeFormatting(
                client: client,
                transcription: rawText,
                outputMode: outputMode,
                rules: promptComponents,
                languageCodes: snapshot.languageCode,
                appContext: snapshot.appContext
            )
        }

        if postProcessor == .customLLM, let llmApiKey = snapshot.llmAPIKey {
            let llmConfig = OpenAIClient.Configuration(
                transcriptionEndpoint: snapshot.transcriptionEndpoint,
                transcriptionModel: snapshot.transcriptionModel,
                chatCompletionEndpoint: snapshot.llmEndpoint,
                chatCompletionModel: snapshot.llmModel,
                apiKey: llmApiKey
            )
            client.updateConfig(llmConfig)
            if outputMode == .dictation {
                return try await client.applyFormattingRules(
                    transcription: rawText,
                    rules: promptComponents,
                    languageCodes: snapshot.languageCode,
                    appContext: snapshot.appContext,
                    screenContext: snapshot.screenContext,
                    clipboardContent: nil
                )
            }
            return try await applyOutputModeFormatting(
                client: client,
                transcription: rawText,
                outputMode: outputMode,
                rules: promptComponents,
                languageCodes: snapshot.languageCode,
                appContext: snapshot.appContext
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
        @unknown default:
            return transcription
        }
    }

    private func resolvedTranscriptionApiKey(
        for provider: TranscriptionProvider? = nil
    ) -> String? {
        let provider = provider ?? transcriptionProviderManager.selectedProvider
        // Check Secrets.plist first
        if let secretKey = SecretsLoader.transcriptionKey(for: provider), !secretKey.isEmpty {
            return secretKey
        }

        return "not-needed"
    }

    private func resolvedLLMApiKey() -> String? {
        return llmProviderManager.effectiveApiKey
    }

    // MARK: - Dictation Result Processing

    /// Process dictation result: update state and paste transcribed text
    private func processDictationResult(transcription: String) async {
        DictationStopwatch.mark("transcript received")
        DictationActivityAssertion.release()
        AudioRecorder.shared.prewarmEngine()
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
        if !dictionaryManager.transcriptionHints.isEmpty {
            contextRules.append("Vocabulary: \(dictionaryManager.transcriptionHints)")
        }
        if !shortcutManager.transcriptionHints.isEmpty {
            contextRules.append("Phrases: \(shortcutManager.transcriptionHints)")
        }
        if let instructions = dictionaryManager.formattingInstructions {
            contextRules.append(instructions)
        }
        if let instructions = shortcutManager.formattingInstructions {
            contextRules.append(instructions)
        }
        if let instructions = contextRulesManager.instructions(for: capturedAppBundleId, windowTitle: capturedWindowTitle) {
            contextRules.append(instructions)
        }
        let immutableContextRules = contextRules

        // Execute the command (with or without target text)
        let resultText: String?
        do {
            resultText = try await withTimeout(seconds: commandDeliveryTimeoutSeconds) {
                await CommandModeManager.shared.executeInstruction(
                    instruction,
                    selectedText: targetText,
                    screenContext: screenContext,
                    contextRules: immutableContextRules
                )
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Your dictation was saved, but the requested change took too long."
            }
            await resetCommandModeState()
            return
        }

        guard let resultText else {
            DebugLog.error("Command mode: execution failed", context: "AppState")
            await MainActor.run {
                self.errorMessage = "Your dictation was saved, but the requested change couldn’t be completed."
            }
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
                    await gate.install(continuation)
                }

                let operationTask = Task {
                    do {
                        let result = try await operation()
                        await gate.resolve(.success(result))
                    } catch {
                        await gate.resolve(.failure(error))
                    }
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    } catch {
                        return
                    }
                    await gate.resolve(
                        .failure(NSError(
                            domain: "AppState",
                            code: -1001,
                            userInfo: [NSLocalizedDescriptionKey: "The operation took too long."]
                        ))
                    )
                }

                Task {
                    await gate.installTasks(
                        operation: operationTask,
                        timeout: timeoutTask
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

private actor MacStoreTranscriptionSession {
    private let store: MacAudioProcessingStore
    private var mutation: MacAudioProcessingStore.Mutation
    private let attemptIsCurrent: @MainActor @Sendable () -> Bool

    init(
        store: MacAudioProcessingStore,
        mutation: MacAudioProcessingStore.Mutation,
        attemptIsCurrent: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.store = store
        self.mutation = mutation
        self.attemptIsCurrent = attemptIsCurrent
    }

    private func requireCurrentAttempt() async throws {
        guard await attemptIsCurrent() else {
            throw CancellationError()
        }
    }

    func checkpoint(_ text: String) async throws {
        try await requireCurrentAttempt()
        let next = try await store.checkpointRecognition(
            mutation.lease,
            partialText: text
        )
        try await requireCurrentAttempt()
        mutation = next
    }

    func markRawResultReady(_ text: String) async throws {
        try await requireCurrentAttempt()
        let next = try await store.markRawResultReady(mutation.lease, rawText: text)
        try await requireCurrentAttempt()
        mutation = next
    }

    func beginCleanup() async throws {
        try await requireCurrentAttempt()
        let next = try await store.beginCleanup(mutation.lease)
        try await requireCurrentAttempt()
        mutation = next
    }

    func finishCleanup(_ text: String?) async throws -> MacAudioProcessingStore.Mutation {
        try await requireCurrentAttempt()
        let next = try await store.finishCleanup(mutation.lease, cleanedText: text)
        try await requireCurrentAttempt()
        mutation = next
        return mutation
    }

    func markSucceededAndClaimUsage(wordCount: Int) async throws -> Int? {
        try await requireCurrentAttempt()
        let next = try await store.markSucceeded(
            mutation.lease,
            pendingUsageWordCount: wordCount > 0 ? wordCount : nil
        )
        try await requireCurrentAttempt()
        mutation = next
        let claimed = try await store.claimPendingUsage(
            recordingID: next.record.recordingID,
            expectedRevision: next.record.revision
        )
        try await requireCurrentAttempt()
        return claimed
    }

    func fail(_ message: String) async throws -> MacAudioProcessingStore.Mutation {
        try await requireCurrentAttempt()
        let next = try await store.fail(mutation.lease, message: message)
        try await requireCurrentAttempt()
        mutation = next
        return mutation
    }
}

private actor OrderedRecognitionCheckpointAccumulator {
    private let callback: @Sendable (String) async throws -> Void
    private var leaves: [String] = []
    private(set) var latestText: String?

    init(callback: @escaping @Sendable (String) async throws -> Void) {
        self.callback = callback
    }

    func accept(completedLeafIndex: Int, transcript: String) async throws {
        guard completedLeafIndex == leaves.count else {
            throw NSError(
                domain: "AppState",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "Audio parts completed out of order. Your recording was kept."]
            )
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NSError(
                domain: "AppState",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "An audio part returned no text. Your recording was kept."]
            )
        }
        let cumulative = (leaves + [text]).joined(separator: " ")
        try await callback(cumulative)
        leaves.append(text)
        latestText = cumulative
    }
}

private actor TranscriptionMilestoneForwarder {
    private let onCheckpoint: @Sendable (String) async throws -> Void
    private let onRaw: @Sendable (String) async throws -> Void
    private let onCleanup: @Sendable () async throws -> Void
    private var lastCheckpoint: String?
    private(set) var rawText: String?
    private var cleanupStarted = false

    init(
        onCheckpoint: @escaping @Sendable (String) async throws -> Void,
        onRaw: @escaping @Sendable (String) async throws -> Void,
        onCleanup: @escaping @Sendable () async throws -> Void
    ) {
        self.onCheckpoint = onCheckpoint
        self.onRaw = onRaw
        self.onCleanup = onCleanup
    }

    func checkpoint(_ text: String) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != lastCheckpoint else { return }
        try await onCheckpoint(normalized)
        lastCheckpoint = normalized
    }

    func acceptRaw(_ text: String) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if rawText == nil {
            try await checkpoint(normalized)
            try await onRaw(normalized)
            rawText = normalized
        }
    }

    func beginCleanup() async throws {
        guard rawText != nil, !cleanupStarted else { return }
        try await onCleanup()
        cleanupStarted = true
    }
}

private actor AppStateTimeoutGate<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?
    private var didResolve = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func installTasks(
        operation: Task<Void, Never>,
        timeout: Task<Void, Never>
    ) {
        guard !didResolve else {
            operation.cancel()
            timeout.cancel()
            return
        }
        operationTask = operation
        timeoutTask = timeout
    }

    func install(_ continuation: CheckedContinuation<T, Error>) {
        if let pendingResult {
            self.pendingResult = nil
            resume(continuation, with: pendingResult)
            return
        }
        guard !didResolve else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
    }

    func resolve(_ result: Result<T, Error>) {
        guard !didResolve else { return }
        didResolve = true
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil

        guard let continuation else {
            pendingResult = result
            return
        }
        self.continuation = nil
        resume(continuation, with: result)
    }

    private func resume(
        _ continuation: CheckedContinuation<T, Error>,
        with result: Result<T, Error>
    ) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }
}
