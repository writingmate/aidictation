import AVFoundation
import Combine
import SwiftUI
import WhisperMateShared

struct RecordingSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audioRecorderSlot = IOSRetirableResourceSlot(factory: AudioRecorder.init)
    @StateObject private var recordingViewModel = AIDictationRecordingViewModel()
    @ObservedObject var historyManager: HistoryManager
    @ObservedObject var dictionaryManager: DictionaryManager
    @ObservedObject var toneStyleManager: ToneStyleManager
    @ObservedObject var shortcutManager: ShortcutManager
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var transcriptionProviderManager = TranscriptionProviderManager()
    @StateObject private var parakeetService = SharedParakeetTranscriptionService.shared

    @State private var sheetState: SheetState = .idle
    @State private var transcription = ""
    @State private var errorMessage = ""
    @State private var recordingStartTime: Date?
    @State private var showShareSheet = false
    @State private var currentRecording: Recording?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var selectedOutputMode: TranscriptionOutputMode = .dictation
    @State private var activeOutputMode: TranscriptionOutputMode?
    @State private var activeTranscriptionOptions: TranscriptionOptions?
    @State private var activeTranscriptionRequest: SharedTranscriptionService.RequestSnapshot?
    @State private var showCloudTranscriptionConsent = false
    @State private var activeAttempt: MobileAudioProcessingStore.Lease?
    @State private var activeAttemptTask: Task<Void, Never>?
    @State private var captureDeadlineTask: Task<Void, Never>?
    @State private var currentRecoverySnapshot: MobileAudioProcessingStore.Snapshot?
    @State private var cancellationReconciliationStarted = false

    private let processingStore = MobileAudioProcessingStore.shared
    private var audioRecorder: AudioRecorder { audioRecorderSlot.current }

    private var selectedPreset: ContextRule? {
        recordingPreset(for: selectedOutputMode, manager: toneStyleManager)
    }

    private let minimumRecordingDuration: TimeInterval = 0.35
    private let minimumAudioFileBytes: Int64 = 1000
    private let recordingStartDeadline: TimeInterval = 5
    private let minimumFinalizationDeadline: TimeInterval = 15
    private let maximumFinalizationDeadline: TimeInterval = 120
    private let maximumRecordingDuration: TimeInterval = 4 * 60 * 60

    enum SheetState {
        case idle
        case recording
        case paused
        case processing
        case viewing
    }

    init(historyManager: HistoryManager, dictionaryManager: DictionaryManager, toneStyleManager: ToneStyleManager, shortcutManager: ShortcutManager, recording: Recording? = nil) {
        self.historyManager = historyManager
        self.dictionaryManager = dictionaryManager
        self.toneStyleManager = toneStyleManager
        self.shortcutManager = shortcutManager
        if let recording = recording {
            _sheetState = State(initialValue: .viewing)
            _transcription = State(initialValue: recording.transcription)
            _currentRecording = State(initialValue: recording)
        }
    }

    var body: some View {
        ZStack {
            if sheetState == .viewing {
                detailsSheetView
                    .zIndex(2)
                    .transition(detailsTransition)
            } else {
                recordingControlView
                    .zIndex(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.46, dampingFraction: 0.86, blendDuration: 0.08), value: sheetState)
        .onAppear {
            updateRecordingSurface(animated: false)
            prepareSelectedModeIfNeeded()
            if let recording = currentRecording {
                Task { @MainActor in
                    await refreshRecoveryState(recordingID: recording.id)
                }
            }
        }
        .onChange(of: selectedOutputMode) { _ in
            errorMessage = ""
            prepareSelectedModeIfNeeded()
        }
        .onDisappear {
            cancelActiveAttemptOnDisappear()
        }
        .onReceive(audioRecorder.$isRecording.dropFirst()) { isRecording in
            updateRecordingState(isRecording)
        }
        .onReceive(audioRecorder.$audioLevel) { level in
            updateAudioLevel(level)
        }
        .onReceive(audioRecorder.$frequencyBands) { bands in
            updateFrequencyBands(bands)
        }
        .onReceive(audioRecorder.$managedAttemptFailure.compactMap { $0 }) { failure in
            handleCaptureFailure(failure)
        }
        .alert(CloudTranscriptionConsent.alertTitle, isPresented: $showCloudTranscriptionConsent) {
            Button("Allow Cloud Transcription") {
                CloudTranscriptionConsent.grant()
                startRecording()
            }
            Button("Use Offline Mode") {
                useOfflineModeFromCloudConsent()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(CloudTranscriptionConsent.disclosureMessage)
        }
    }

    // MARK: - State Views

    private var detailsSheetView: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.78), Color(uiColor: .secondarySystemFill))
                        .symbolRenderingMode(.palette)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .background(Color.white)

            viewingStateView
        }
        .background(Color.white.ignoresSafeArea())
    }

    private var detailsTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.985, anchor: .bottom)),
            removal: .opacity
        )
    }

    private var recordingControlView: some View {
        ZStack(alignment: .topLeading) {
            AIDictationRecordingSurface(
                model: recordingViewModel,
                onPrimaryAction: handlePrimaryAction,
                onPauseAction: togglePauseRecording
            )
            .ignoresSafeArea()

            if currentRecording == nil {
                VStack(spacing: 8) {
                    if sheetState == .idle || sheetState == .recording || sheetState == .paused {
                        RecordingSheetModeSelector(selectedMode: $selectedOutputMode)
                    } else {
                        RecordingSheetActiveModePill(mode: activeOutputMode ?? selectedOutputMode)
                    }

                    if sheetState != .viewing, let modelCueText {
                        modelStatusBar(text: modelCueText)
                    }

                    if !errorMessage.isEmpty, sheetState != .processing, sheetState != .viewing {
                        Text(errorMessage)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.74))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .padding(.horizontal, 56)
                .zIndex(3)
            }

            Button(action: handleCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96), .black.opacity(0.22))
                    .symbolRenderingMode(.palette)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.leading, 20)
            .zIndex(4)
        }
    }

    private func modelStatusBar(text: String) -> some View {
        HStack(spacing: 7) {
            if modelCueShowsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: modelCueIconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.white)

            if modelCueShowsProgress {
                IndeterminateCapsuleProgressBar()
                .frame(height: 4)
                .frame(maxWidth: 72)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.54))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var viewingStateView: some View {
        VStack(spacing: 0) {
            // Audio playback button (if audio file exists)
            if let audioURL = currentRecording?.audioFileURL {
                HStack(spacing: 12) {
                    Button(action: {
                        togglePlayback(audioURL: audioURL)
                    }) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Color.dsPrimary)
                    }
                    .buttonStyle(.plain)

                    if let duration = currentRecording?.duration {
                        Text(formatDuration(duration))
                            .font(.system(size: 15))
                            .foregroundColor(.gray)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color.white)
            }

            // Transcription content
            ScrollView {
                VStack(spacing: 0) {
                    if currentRecording?.outputMode == .notes {
                        Label("Notes", systemImage: "note.text")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                    }

                    Text(transcription)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.black)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                }
            }
            .background(Color.white)

            // Error message
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 15))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }

            // Bottom toolbar
            VStack(spacing: 12) {
                if currentRecording != nil, currentRecordingCanRetry {
                    Button(action: retryCurrentRecording) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.dsPrimary)
                    .controlSize(.large)
                    .padding(.horizontal, 20)
                }

                Button(action: shareTranscription) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.dsPrimary)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .disabled(transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.bottom, 20)
                .padding(.top, 16)
            }
            .background(Color.white)
        }
        .background(Color.white)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [transcription])
        }
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
        switch sheetState {
        case .idle:
            startRecording()
        case .recording, .paused:
            stopRecording()
        case .processing, .viewing:
            break
        }
    }

    private var currentRecordingCanRetry: Bool {
        guard let snapshot = currentRecoverySnapshot,
              snapshot.sourceIntegrity == .complete
        else { return false }
        return snapshot.stage == .failed || snapshot.stage == .cancelled
    }

    @MainActor
    private func refreshRecoveryState(recordingID: UUID) async {
        do {
            let snapshot = try await processingStore.snapshot(recordingID: recordingID)
            guard currentRecording?.id == recordingID else { return }
            currentRecoverySnapshot = snapshot
            if snapshot?.stage == .failed || snapshot?.stage == .cancelled {
                errorMessage = snapshot?.userMessage ?? "Processing did not finish. Your recording was kept."
            }
        } catch {
            guard currentRecording?.id == recordingID else { return }
            errorMessage = "This saved recording could not be checked. Restart the app and try again."
        }
    }

    private func retryCurrentRecording() {
        guard let recording = currentRecording,
              currentRecoverySnapshot?.recordingID == recording.id,
              currentRecordingCanRetry
        else { return }

        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            errorMessage = access.reason ?? "Log in to continue transcribing."
            return
        }

        let preset = recordingPreset(for: recording.outputMode, manager: toneStyleManager)
        let options = recording.transcriptionOptions
        let request: SharedTranscriptionService.RequestSnapshot
        do {
            request = try SharedTranscriptionService.RequestSnapshot.capture(
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
                outputMode: recording.outputMode,
                transcriptionOptions: options,
                selectedPreset: preset
            )
        } catch {
            errorMessage = userMessage(for: error)
            return
        }

        let duration = recording.duration ?? 0
        let deadline = max(90, min(600, (duration * 2) + 60))
        activeOutputMode = recording.outputMode
        activeTranscriptionOptions = options
        activeTranscriptionRequest = request
        sheetState = .processing
        errorMessage = ""
        updateRecordingSurface(animated: true)

        activeAttemptTask?.cancel()
        activeAttemptTask = Task { @MainActor in
            do {
                let lease = try await processingStore.beginRetry(
                    recordingID: recording.id,
                    attemptID: UUID(),
                    deadlineAt: Date().addingTimeInterval(deadline)
                )
                activeAttempt = lease
                guard !Task.isCancelled else { throw CancellationError() }
                await transcribeAudio(
                    audioURL: lease.sourceURL,
                    lease: lease,
                    duration: duration,
                    outputMode: recording.outputMode,
                    transcriptionOptions: options,
                    request: request
                )
            } catch {
                guard activeAttempt == nil else { return }
                activeAttemptTask = nil
                activeOutputMode = nil
                activeTranscriptionOptions = nil
                activeTranscriptionRequest = nil
                sheetState = .viewing
                errorMessage = error is CancellationError ? "Processing cancelled." : userMessage(for: error)
                updateRecordingSurface(animated: true)
            }
        }
    }

    private func handleCancel() {
        cancelAndReconcileActiveAttempt(dismissAfterStart: true)
    }

    private func startRecording() {
        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            errorMessage = access.reason ?? "Log in to continue transcribing."
            sheetState = .viewing
            return
        }

        guard ensureCloudTranscriptionAllowedForRecording() else { return }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            errorMessage = "Microphone permission denied. Please enable it in Settings."
            sheetState = .viewing
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        beginRecording()
                    } else {
                        errorMessage = "Microphone permission denied. Please enable it in Settings."
                        sheetState = .viewing
                    }
                }
            }
        @unknown default:
            errorMessage = "Unable to check microphone permission."
            sheetState = .viewing
        }
    }

    private func ensureCloudTranscriptionAllowedForRecording() -> Bool {
        guard !transcriptionProviderManager.shouldUseOnDeviceTranscription,
              !CloudTranscriptionConsent.isGranted
        else {
            return true
        }

        showCloudTranscriptionConsent = true
        return false
    }

    private func useOfflineModeFromCloudConsent() {
        guard TranscriptionMode.offline.isAvailable else {
            errorMessage = SharedParakeetTranscriptionService.unavailableMessage
            return
        }

        transcriptionProviderManager.setTranscriptionMode(.offline)
        prepareSelectedModeIfNeeded()
    }

    private var needsOfflineRuntimeForSelectedMode: Bool {
        transcriptionProviderManager.shouldUseOnDeviceTranscription || selectedOutputMode == .meetings
    }

    private var modelCueText: String? {
        guard SharedParakeetTranscriptionService.isRuntimeSupported else {
            guard needsOfflineRuntimeForSelectedMode else { return nil }
            return SharedParakeetTranscriptionService.unavailableMessage
        }

        switch parakeetService.state {
        case .downloading:
            return selectedOutputMode == .meetings ? "Downloading speaker detection" : "Downloading offline model"
        case .initializing:
            return selectedOutputMode == .meetings ? "Preparing speaker detection" : "Preparing offline model"
        case .error(let message):
            guard needsOfflineRuntimeForSelectedMode else { return nil }
            return message
        case .transcribing:
            return nil
        case .ready, .notInitialized:
            break
        }

        guard needsOfflineRuntimeForSelectedMode else { return nil }

        if parakeetService.isModelDownloaded {
            return selectedOutputMode == .meetings ? "Speaker detection ready" : "Offline mode ready"
        }

        switch parakeetService.state {
        case .notInitialized:
            return selectedOutputMode == .meetings ? "Speaker detection needs download" : "Offline model needs download"
        case .ready:
            return selectedOutputMode == .meetings ? "Speaker detection ready" : "Offline mode ready"
        case .downloading, .initializing, .error, .transcribing:
            return nil
        }
    }

    private var modelCueShowsProgress: Bool {
        switch parakeetService.state {
        case .downloading, .initializing:
            return true
        default:
            return false
        }
    }

    private var modelCueIconName: String {
        if parakeetService.isModelDownloaded {
            return "checkmark.circle.fill"
        }
        switch parakeetService.state {
        case .error:
            return "exclamationmark.triangle.fill"
        default:
            return "arrow.down.circle.fill"
        }
    }

    private func prepareSelectedModeIfNeeded() {
        guard sheetState != .viewing, needsOfflineRuntimeForSelectedMode else { return }
        guard SharedParakeetTranscriptionService.isRuntimeSupported else { return }
        guard !parakeetService.isModelDownloaded else { return }

        switch parakeetService.state {
        case .downloading, .initializing:
            return
        default:
            Task {
                do {
                    try await parakeetService.initialize()
                    await MainActor.run {
                        if sheetState != .viewing {
                            errorMessage = ""
                        }
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func beginRecording() {
        let startOutputMode = selectedOutputMode
        let startPreset = recordingPreset(for: startOutputMode, manager: toneStyleManager)
        let startOptions = transcriptionOptions(for: startOutputMode, preset: startPreset)
        let request: SharedTranscriptionService.RequestSnapshot
        do {
            request = try SharedTranscriptionService.RequestSnapshot.capture(
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
                outputMode: startOutputMode,
                transcriptionOptions: startOptions,
                selectedPreset: startPreset
            )
        } catch {
            resetRecordingState(message: userMessage(for: error))
            return
        }

        activeOutputMode = startOutputMode
        activeTranscriptionOptions = startOptions
        activeTranscriptionRequest = request
        errorMessage = ""
        sheetState = .processing
        updateRecordingSurface(animated: true)

        let recordingID = UUID()
        let attemptID = UUID()
        let recorder = audioRecorder
        activeAttemptTask?.cancel()
        activeAttemptTask = Task { @MainActor in
            var lease: MobileAudioProcessingStore.Lease?
            do {
                let prepared = try await processingStore.beginNewAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID,
                    outputModeRaw: startOutputMode.rawValue,
                    transcriptionOptions: startOptions,
                    deadlineAt: Date().addingTimeInterval(recordingStartDeadline)
                )
                lease = prepared
                guard !Task.isCancelled else { throw CancellationError() }
                activeAttempt = prepared

                _ = try await IOSAudioProcessingDeadline.run(seconds: recordingStartDeadline) {
                    try await recorder.startRecording(
                        at: prepared.sourceURL,
                        attemptID: prepared.attemptID
                    )
                }
                let captureDeadline = Date().addingTimeInterval(maximumRecordingDuration)
                try await processingStore.captureBecameReady(
                    prepared,
                    deadlineAt: captureDeadline
                )
                guard activeAttempt == prepared, !Task.isCancelled else {
                    throw CancellationError()
                }

                recordingStartTime = Date()
                sheetState = .recording
                errorMessage = ""
                activeAttemptTask = nil
                scheduleCaptureDeadline(for: prepared, deadlineAt: captureDeadline)
                updateRecordingSurface(animated: true)
            } catch {
                if let lease {
                    _ = audioRecorderSlot.retire(ifCurrent: recorder)
                    if error is CancellationError || error as? IOSAudioProcessingDeadlineError == .cancelled {
                        try? await processingStore.markCancelled(lease)
                    } else {
                        try? await processingStore.markFailed(
                            lease,
                            message: userMessage(for: error),
                            integrity: .unfinalized
                        )
                    }
                    Task {
                        await recorder.abandonRecording(
                            attemptID: lease.attemptID,
                            deactivateAudioSession: false
                        )
                        try? await processingStore.purgePayloadsIfDeleted(recordingID: lease.recordingID)
                    }
                }
                guard activeAttempt?.attemptID == attemptID || activeAttempt == nil else { return }
                activeAttempt = nil
                activeAttemptTask = nil
                resetRecordingState(message: error is CancellationError ? nil : userMessage(for: error))
            }
        }
    }

    private func scheduleCaptureDeadline(
        for lease: MobileAudioProcessingStore.Lease,
        deadlineAt: Date
    ) {
        captureDeadlineTask?.cancel()
        captureDeadlineTask = Task { @MainActor in
            let remaining = max(0, deadlineAt.timeIntervalSinceNow)
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return
            }
            guard activeAttempt == lease,
                  sheetState == .recording || sheetState == .paused
            else { return }
            stopRecording()
        }
    }

    private func togglePauseRecording() {
        switch sheetState {
        case .recording:
            audioRecorder.pauseRecording()
            sheetState = .paused
            updateRecordingSurface(animated: true)
        case .paused:
            audioRecorder.resumeRecording()
            sheetState = .recording
            updateRecordingSurface(animated: true)
        case .idle, .processing, .viewing:
            break
        }
    }

    private func stopRecording() {
        guard let activeAttempt,
              let request = activeTranscriptionRequest,
              let transcriptionOptions = activeTranscriptionOptions
        else {
            resetRecordingState(message: "Recording could not be finished. Please try again.")
            return
        }
        let stopOutputMode = activeOutputMode ?? selectedOutputMode
        activeOutputMode = stopOutputMode
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        sheetState = .processing
        updateRecordingSurface(animated: true)

        let recorder = audioRecorder
        let capturedDuration = max(0, Date().timeIntervalSince(recordingStartTime ?? Date()))
        let finalizationSeconds = max(
            minimumFinalizationDeadline,
            min(maximumFinalizationDeadline, 10 + (capturedDuration * 0.05))
        )
        let finalizationDeadlineAt = Date().addingTimeInterval(finalizationSeconds)
        activeAttemptTask?.cancel()
        activeAttemptTask = Task { @MainActor in
            var recorderClosed = false
            do {
                try await processingStore.beginFinalization(
                    activeAttempt,
                    deadlineAt: finalizationDeadlineAt
                )
                let partialURL = try await IOSAudioProcessingDeadline.run(
                    seconds: finalizationSeconds
                ) {
                    try await recorder.stopRecording(
                        attemptID: activeAttempt.attemptID,
                        deactivateAudioSession: true
                    )
                }
                recorderClosed = true
                guard self.activeAttempt == activeAttempt, !Task.isCancelled else {
                    throw CancellationError()
                }

                guard partialURL == activeAttempt.sourceURL else {
                    throw MobileAudioProcessingStore.StoreError.sourceConflict
                }
                let proof = try await processingStore.proveFinalizedSource(
                    activeAttempt,
                    minimumBytes: minimumAudioFileBytes,
                    minimumDuration: minimumRecordingDuration
                )
                try await processingStore.checkpointFinalizedSourceProof(
                    activeAttempt,
                    proof: proof
                )
                let finalized = try await processingStore.acceptFinalizedSource(
                    activeAttempt,
                    proof: proof
                )
                guard self.activeAttempt == activeAttempt, !Task.isCancelled else {
                    throw CancellationError()
                }

                await transcribeAudio(
                    audioURL: finalized.url,
                    lease: activeAttempt,
                    duration: finalized.duration,
                    outputMode: stopOutputMode,
                    transcriptionOptions: transcriptionOptions,
                    request: request
                )
            } catch {
                if !recorderClosed {
                    _ = audioRecorderSlot.retire(ifCurrent: recorder)
                }
                if error is CancellationError || error as? IOSAudioProcessingDeadlineError == .cancelled {
                    try? await processingStore.markCancelled(activeAttempt)
                } else {
                    let integrity: MobileAudioProcessingStore.SourceIntegrity =
                        recorderClosed
                            || (error as? MobileAudioProcessingStore.StoreError) == .sourceIncomplete
                        ? .knownIncomplete
                        : .unfinalized
                    try? await processingStore.markFailed(
                        activeAttempt,
                        message: userMessage(for: error),
                        integrity: integrity
                    )
                }
                Task {
                    await recorder.abandonRecording(
                        attemptID: activeAttempt.attemptID,
                        deactivateAudioSession: false
                    )
                    try? await processingStore.purgePayloadsIfDeleted(
                        recordingID: activeAttempt.recordingID
                    )
                }
                guard self.activeAttempt == activeAttempt else { return }
                if recorderClosed {
                    await showTerminalRecording(
                        lease: activeAttempt,
                        audioURL: activeAttempt.sourceURL,
                        duration: capturedDuration,
                        outputMode: stopOutputMode,
                        transcriptionOptions: transcriptionOptions,
                        fallbackMessage: error is CancellationError
                            ? "Processing cancelled."
                            : userMessage(for: error)
                    )
                    return
                }
                self.activeAttempt = nil
                activeAttemptTask = nil
                resetRecordingState(message: error is CancellationError ? nil : userMessage(for: error))
            }
        }
    }

    private func transcribeAudio(
        audioURL: URL,
        lease: MobileAudioProcessingStore.Lease,
        duration: TimeInterval,
        outputMode: TranscriptionOutputMode,
        transcriptionOptions: TranscriptionOptions,
        request: SharedTranscriptionService.RequestSnapshot
    ) async {
        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            let message = access.reason ?? "Log in to continue transcribing."
            try? await processingStore.markFailed(lease, message: message, integrity: .complete)
            guard activeAttempt == lease else { return }
            await showTerminalRecording(
                lease: lease,
                audioURL: audioURL,
                duration: duration,
                outputMode: outputMode,
                transcriptionOptions: transcriptionOptions,
                fallbackMessage: message
            )
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            sheetState = .processing
            updateRecordingSurface(animated: false)
        }

        do {
            let deadline = max(90, min(600, (duration * 2) + 60))
            let recognitionURL = try await processingStore.beginRecognition(
                lease,
                deadlineAt: Date().addingTimeInterval(deadline)
            )
            let processedResult = try await IOSAudioProcessingDeadline.runOnMainActor(
                seconds: deadline
            ) {
                try await SharedTranscriptionService.transcribe(
                    audioURL: recognitionURL,
                    request: request,
                    onRecognitionCheckpoint: { checkpoint in
                        try await self.processingStore.checkpointRecognitionPartial(checkpoint, lease: lease)
                    },
                    onRawTranscript: { raw in
                        try await self.processingStore.checkpointRawTranscript(raw, lease: lease)
                    },
                    onCleanupStarted: {
                        try await self.processingStore.cleanupStarted(lease)
                    }
                )
            }
            guard activeAttempt == lease, !Task.isCancelled else {
                throw CancellationError()
            }

            let durableResult = try await processingStore.checkpointFinalText(
                processedResult,
                lease: lease
            )

            let recording = Recording(
                id: lease.recordingID,
                transcription: durableResult,
                duration: duration,
                audioFileURL: audioURL,
                outputMode: outputMode,
                transcriptionOptions: transcriptionOptions
            )
            try await processingStore.markSucceeded(lease)
            guard activeAttempt == lease, !Task.isCancelled else { return }
            replaceHistoryRecording(recording)
            currentRecoverySnapshot = try? await processingStore.snapshot(recordingID: lease.recordingID)

            transcription = durableResult
            sheetState = .viewing
            errorMessage = ""
            recordingStartTime = nil
            activeOutputMode = nil
            activeTranscriptionOptions = nil
            activeTranscriptionRequest = nil
            activeAttempt = nil
            activeAttemptTask = nil
            captureDeadlineTask = nil
            currentRecording = recording
            // Completion is already durable and visible before this await.
            await MobileAudioUsageAccounting.flush(
                recordingID: lease.recordingID,
                store: processingStore,
                subscriptionManager: subscriptionManager
            )
        } catch {
            if error is CancellationError || error as? IOSAudioProcessingDeadlineError == .cancelled {
                try? await processingStore.markCancelled(lease)
            } else {
                try? await processingStore.markFailed(
                    lease,
                    message: userMessage(for: error),
                    integrity: .complete
                )
            }
            guard activeAttempt == lease else { return }
            await showTerminalRecording(
                lease: lease,
                audioURL: audioURL,
                duration: duration,
                outputMode: outputMode,
                transcriptionOptions: transcriptionOptions,
                fallbackMessage: error is CancellationError
                    ? "Processing cancelled."
                    : userMessage(for: error)
            )
        }
    }

    private func showTerminalRecording(
        lease: MobileAudioProcessingStore.Lease,
        audioURL: URL,
        duration: TimeInterval,
        outputMode: TranscriptionOutputMode,
        transcriptionOptions: TranscriptionOptions,
        fallbackMessage: String
    ) async {
        let snapshot = try? await processingStore.snapshot(recordingID: lease.recordingID)
        let recoveredText = try? await processingStore.recognizedText(for: lease.recordingID)
        let succeeded = snapshot?.stage == .succeeded
        let message = snapshot?.userMessage ?? fallbackMessage
        let recording = Recording(
            id: lease.recordingID,
            transcription: recoveredText ?? "",
            duration: snapshot?.duration ?? duration,
            audioFileURL: snapshot?.sourceURL ?? audioURL,
            outputMode: outputMode,
            transcriptionOptions: transcriptionOptions
        )
        replaceHistoryRecording(recording)
        transcription = recoveredText ?? ""
        currentRecording = recording
        currentRecoverySnapshot = snapshot
        sheetState = .viewing
        errorMessage = succeeded ? "" : message
        recordingStartTime = nil
        activeOutputMode = nil
        activeTranscriptionOptions = nil
        activeTranscriptionRequest = nil
        activeAttempt = nil
        activeAttemptTask = nil
        captureDeadlineTask = nil
        updateRecordingSurface(animated: true)
        if succeeded {
            await MobileAudioUsageAccounting.flush(
                recordingID: lease.recordingID,
                store: processingStore,
                subscriptionManager: subscriptionManager
            )
        }
    }

    private func replaceHistoryRecording(_ recording: Recording) {
        if let existing = historyManager.recordings.first(where: { $0.id == recording.id }) {
            historyManager.deleteRecording(existing)
        }
        historyManager.addRecording(recording)
    }

    private func transcriptionOptions(for outputMode: TranscriptionOutputMode, preset: ContextRule?) -> TranscriptionOptions {
        if outputMode == .meetings {
            return TranscriptionOptions(diarization: true)
        }
        return preset?.transcriptionOptions ?? .default
    }

    private func resetRecordingState(message: String?) {
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        recordingStartTime = nil
        activeOutputMode = nil
        activeTranscriptionOptions = nil
        activeTranscriptionRequest = nil
        sheetState = .idle
        errorMessage = message ?? ""
        recordingViewModel.audioLevel = 0.0
        recordingViewModel.frequencyBands = Array(repeating: 0.0, count: 10)
        updateRecordingSurface(animated: true)
    }

    private func updateRecordingState(_ isRecording: Bool) {
        // Managed start/finalization tasks own UI state. The recorder's publication is only a
        // visualization signal; accepting it here would let a late native callback revive an
        // abandoned attempt.
        guard activeAttempt != nil, isRecording, sheetState == .recording else { return }
        updateRecordingSurface(animated: false)
    }

    private func updateAudioLevel(_ level: Float) {
        if sheetState == .recording {
            recordingViewModel.audioLevel = level
        }
    }

    private func updateFrequencyBands(_ bands: [Float]) {
        if sheetState == .recording {
            recordingViewModel.frequencyBands = bands
        }
    }

    private func handleCaptureFailure(_ failure: ManagedAudioRecordingFailure) {
        guard let lease = activeAttempt,
              lease.attemptID == failure.attemptID,
              sheetState == .recording || sheetState == .paused
        else { return }

        activeAttemptTask?.cancel()
        captureDeadlineTask?.cancel()
        let abandonedRecorder = audioRecorder
        _ = audioRecorderSlot.retire(ifCurrent: abandonedRecorder)
        activeAttempt = nil
        activeAttemptTask = nil
        resetRecordingState(message: failure.error.localizedDescription)

        Task {
            try? await processingStore.markFailed(
                lease,
                message: failure.error.localizedDescription,
                integrity: .knownIncomplete
            )
            await abandonedRecorder.abandonRecording(
                attemptID: lease.attemptID,
                deactivateAudioSession: false
            )
            try? await processingStore.purgePayloadsIfDeleted(recordingID: lease.recordingID)
        }
    }

    private func cancelActiveAttemptOnDisappear() {
        cancelAndReconcileActiveAttempt(dismissAfterStart: false)
    }

    private func cancelAndReconcileActiveAttempt(dismissAfterStart: Bool) {
        guard !cancellationReconciliationStarted else { return }
        guard let activeAttempt else {
            if dismissAfterStart { dismiss() }
            return
        }

        cancellationReconciliationStarted = true
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        activeAttemptTask?.cancel()
        let recorder = audioRecorder
        let outputMode = activeOutputMode ?? selectedOutputMode
        let transcriptionOptions = activeTranscriptionOptions
            ?? self.transcriptionOptions(for: outputMode, preset: selectedPreset)
        let fallbackDuration = max(0, Date().timeIntervalSince(recordingStartTime ?? Date()))
        _ = audioRecorderSlot.retire(ifCurrent: recorder)
        self.activeAttempt = nil
        activeAttemptTask = nil
        resetRecordingState(message: nil)
        if dismissAfterStart { dismiss() }

        Task { @MainActor in
            try? await processingStore.markCancelled(activeAttempt)
            let snapshot = try? await processingStore.snapshot(recordingID: activeAttempt.recordingID)
            let recoveredText = try? await processingStore.recognizedText(
                for: activeAttempt.recordingID
            )
            Task {
                await recorder.abandonRecording(
                    attemptID: activeAttempt.attemptID,
                    deactivateAudioSession: false
                )
                try? await processingStore.purgePayloadsIfDeleted(
                    recordingID: activeAttempt.recordingID
                )
            }
            guard snapshot?.stage == .succeeded,
                  let recoveredText,
                  !recoveredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }

            let recording = Recording(
                id: activeAttempt.recordingID,
                transcription: recoveredText,
                duration: snapshot?.duration ?? fallbackDuration,
                audioFileURL: snapshot?.sourceURL ?? activeAttempt.sourceURL,
                outputMode: outputMode,
                transcriptionOptions: snapshot?.transcriptionOptions ?? transcriptionOptions
            )
            replaceHistoryRecording(recording)
            await MobileAudioUsageAccounting.flush(
                recordingID: activeAttempt.recordingID,
                store: processingStore,
                subscriptionManager: subscriptionManager
            )
        }
    }

    private func userMessage(for error: Error) -> String {
        if let deadlineError = error as? IOSAudioProcessingDeadlineError {
            return deadlineError.localizedDescription
        }
        if let recorderError = error as? ManagedAudioRecordingError {
            return recorderError.localizedDescription
        }
        if let storeError = error as? MobileAudioProcessingStore.StoreError {
            return storeError.localizedDescription
        }
        if let openAIError = error as? OpenAIError {
            return openAIError.localizedDescription
        }
        if let httpFailure = error as? AppleAudioHTTPRecovery.Failure {
            return httpFailure.localizedDescription
        }
        return "Transcription failed. Your recording was kept. Please try again."
    }

    private func updateRecordingSurface(animated: Bool) {
        let updates = {
            recordingViewModel.state = recordingSurfaceState
            if sheetState == .idle {
                recordingViewModel.audioLevel = 0.0
                recordingViewModel.frequencyBands = Array(repeating: 0.0, count: 10)
            }
        }

        if animated {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82, blendDuration: 0.06), updates)
        } else {
            updates()
        }
    }

    private var recordingSurfaceState: AIDictationRecordingState {
        switch sheetState {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .paused:
            return .paused
        case .processing:
            return .processing
        case .viewing:
            return .idle
        }
    }

    private func shareTranscription() {
        guard !transcription.isEmpty else { return }
        showShareSheet = true
    }

    private func togglePlayback(audioURL: URL) {
        if isPlaying {
            audioPlayer?.pause()
            isPlaying = false
        } else {
            do {
                // Configure audio session for playback
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)

                // Create and play audio player
                audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
                audioPlayer?.play()
                isPlaying = true

                // Monitor when playback finishes
                DispatchQueue.main.asyncAfter(deadline: .now() + (audioPlayer?.duration ?? 0)) {
                    if !(audioPlayer?.isPlaying ?? false) {
                        isPlaying = false
                    }
                }
            } catch {
                DebugLog.info("Failed to play audio: \(error)", context: "RecordingSheetView")
                errorMessage = "Failed to play audio"
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "0:%02d", seconds)
        }
    }
}

private struct RecordingSheetModeSelector: View {
    @Binding var selectedMode: TranscriptionOutputMode

    var body: some View {
        Picker(selection: $selectedMode) {
            ForEach(TranscriptionOutputMode.allCases) { mode in
                Label(mode.displayName, systemImage: iconName(for: mode))
                    .tag(mode)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: iconName(for: selectedMode))
                    .font(.system(size: 13, weight: .semibold))

                Text(selectedMode.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.72)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.34))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
        }
        .pickerStyle(.menu)
        .buttonStyle(.plain)
    }

    private func iconName(for mode: TranscriptionOutputMode) -> String {
        switch mode {
        case .dictation:
            return "text.cursor"
        case .notes:
            return "note.text"
        case .meetings:
            return "person.2.fill"
        }
    }
}

private struct RecordingSheetActiveModePill: View {
    let mode: TranscriptionOutputMode

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName(for: mode))
                .font(.system(size: 13, weight: .semibold))

            Text(mode.displayName)
                .font(.system(size: 13, weight: .semibold))

            Text("locked")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.34))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
    }

    private func iconName(for mode: TranscriptionOutputMode) -> String {
        switch mode {
        case .dictation:
            return "text.cursor"
        case .notes:
            return "note.text"
        case .meetings:
            return "person.2.fill"
        }
    }
}
