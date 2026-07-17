import AVFoundation
import Combine
import SwiftUI
import WhisperMateShared

struct RecordingSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audioRecorder = AudioRecorder()
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
    @State private var showCloudTranscriptionConsent = false
    @State private var showUpgradePaywall = false

    private var selectedPreset: ContextRule? {
        recordingPreset(for: selectedOutputMode, manager: toneStyleManager)
    }

    private let minimumRecordingDuration: TimeInterval = 0.35
    private let minimumAudioFileBytes: Int64 = 1000

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
        }
        .onChange(of: selectedOutputMode) { _ in
            errorMessage = ""
            prepareSelectedModeIfNeeded()
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
        .sheet(isPresented: $showUpgradePaywall) {
            RevenueCatPaywallView()
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
            .background(Color.dsBackground)

            viewingStateView
        }
        .background(Color.dsBackground.ignoresSafeArea())
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
                .background(Color.dsBackground)
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
                        .font(.body)
                        .foregroundStyle(Color.dsForeground)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                }
            }
            .background(Color.dsBackground)

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
            VStack(spacing: 0) {
                Button(action: shareTranscription) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.dsPrimary)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .background(Color.dsBackground)
        }
        .background(Color.dsBackground)
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

    private func handleCancel() {
        if sheetState == .recording || sheetState == .paused {
            let recorder = audioRecorder
            Task {
                _ = await recorder.stopRecordingAsync(deactivateAudioSession: true)
            }
        }
        dismiss()
    }

    private func startRecording() {
        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            handleTranscriptionLimit(access.reason)
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
        recordingStartTime = Date()
        activeOutputMode = nil
        errorMessage = ""
        sheetState = .recording
        updateRecordingSurface(animated: true)
        audioRecorder.startRecording()
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
        let recordingStartedAt = recordingStartTime
        let stopOutputMode = selectedOutputMode
        activeOutputMode = stopOutputMode
        sheetState = .processing
        updateRecordingSurface(animated: true)

        Task {
            guard let audioURL = await audioRecorder.stopRecordingAsync(deactivateAudioSession: false) else {
                await MainActor.run {
                    resetRecordingState()
                }
                return
            }

            guard validateRecordingForTranscription(audioURL, recordingStartTime: recordingStartedAt) else {
                try? FileManager.default.removeItem(at: audioURL)
                await MainActor.run {
                    resetRecordingState()
                }
                return
            }

            await MainActor.run {
                transcribeAudio(audioURL: audioURL, outputMode: stopOutputMode)
            }
        }
    }

    private func validateRecordingForTranscription(_ audioURL: URL, recordingStartTime: Date?) -> Bool {
        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

        let fileSize: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            fileSize = attributes[.size] as? Int64 ?? 0
        } catch {
            DebugLog.info("Failed to verify sheet recording file: \(error)", context: "RecordingSheetView")
            return false
        }

        let audioDuration = audioFileDuration(audioURL)
        DebugLog.info(
            "Sheet recording ready: elapsed=\(String(format: "%.2f", elapsed))s, audioDuration=\(String(format: "%.2f", audioDuration ?? -1))s, fileSize=\(fileSize) bytes",
            context: "RecordingSheetView"
        )

        if elapsed < minimumRecordingDuration || (audioDuration ?? elapsed) < minimumRecordingDuration {
            DebugLog.info("Sheet recording too short; skipping transcription", context: "RecordingSheetView")
            return false
        }

        if fileSize < minimumAudioFileBytes {
            DebugLog.info("Sheet recording has no audio payload; skipping transcription", context: "RecordingSheetView")
            return false
        }

        return true
    }

    private func audioFileDuration(_ audioURL: URL) -> TimeInterval? {
        do {
            let file = try AVAudioFile(forReading: audioURL)
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0 else { return nil }
            return Double(file.length) / sampleRate
        } catch {
            DebugLog.info("Failed to read sheet recording duration: \(error)", context: "RecordingSheetView")
            return nil
        }
    }

    private func transcribeAudio(audioURL: URL, outputMode: TranscriptionOutputMode) {
        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            try? FileManager.default.removeItem(at: audioURL)
            handleTranscriptionLimit(access.reason)
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            sheetState = .processing
            updateRecordingSurface(animated: false)
        }

        Task {
            do {
                let preset = recordingPreset(for: outputMode, manager: toneStyleManager)
                let transcriptionOptions = transcriptionOptions(for: outputMode, preset: preset)
                let processedResult = try await SharedTranscriptionService.transcribe(
                    audioURL: audioURL,
                    dictionaryManager: dictionaryManager,
                    toneStyleManager: toneStyleManager,
                    shortcutManager: shortcutManager,
                    outputMode: outputMode,
                    transcriptionOptions: transcriptionOptions,
                    selectedPreset: preset
                )

                guard !processedResult.isEmpty else {
                    DebugLog.info("Sheet transcription was empty after sanitization; skipping history item", context: "RecordingSheetView")
                    try? FileManager.default.removeItem(at: audioURL)
                    await MainActor.run {
                        transcription = ""
                        sheetState = .idle
                        recordingStartTime = nil
                        activeOutputMode = nil
                        errorMessage = ""
                        updateRecordingSurface(animated: true)
                    }
                    return
                }

                let wordCount = subscriptionManager.wordCount(for: processedResult)
                await subscriptionManager.recordWords(wordCount)

                await MainActor.run {
                    transcription = processedResult
                    sheetState = .viewing
                    errorMessage = ""

                    // Calculate duration
                    let duration = recordingStartTime.map { Date().timeIntervalSince($0) }
                    recordingStartTime = nil
                    activeOutputMode = nil

                    // Create recording with unique ID
                    let recordingID = UUID()

                    // Save audio file to persistent storage
                    let permanentAudioURL = historyManager.saveAudioFile(from: audioURL, for: recordingID)

                    // Save to history with audio file URL
                    let recording = Recording(
                        id: recordingID,
                        transcription: processedResult,
                        duration: duration,
                        audioFileURL: permanentAudioURL,
                        outputMode: outputMode,
                        transcriptionOptions: transcriptionOptions
                    )
                    historyManager.addRecording(recording)
                    currentRecording = recording

                    // Delete temporary audio file
                    try? FileManager.default.removeItem(at: audioURL)
                }
            } catch {
                await MainActor.run {
                    transcription = ""
                    sheetState = .viewing
                    recordingStartTime = nil
                    activeOutputMode = nil
                    errorMessage = "Transcription failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleTranscriptionLimit(_ reason: String?) {
        errorMessage = reason ?? "Log in to continue transcribing."
        sheetState = .viewing
        if subscriptionManager.shouldOfferUpgradeAfterLimit {
            showUpgradePaywall = true
        }
    }

    private func transcriptionOptions(for outputMode: TranscriptionOutputMode, preset: ContextRule?) -> TranscriptionOptions {
        if outputMode == .meetings {
            return TranscriptionOptions(diarization: true)
        }
        return preset?.transcriptionOptions ?? .default
    }

    private func resetRecordingState() {
        recordingStartTime = nil
        activeOutputMode = nil
        sheetState = .idle
        errorMessage = ""
        recordingViewModel.audioLevel = 0.0
        recordingViewModel.frequencyBands = Array(repeating: 0.0, count: 10)
        updateRecordingSurface(animated: true)
    }

    private func updateRecordingState(_ isRecording: Bool) {
        if sheetState == .processing || sheetState == .paused || sheetState == .viewing {
            return
        }

        sheetState = isRecording ? .recording : .idle
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
