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

    @State private var sheetState: SheetState = .idle
    @State private var transcription = ""
    @State private var errorMessage = ""
    @State private var recordingStartTime: Date?
    @State private var showCopiedNotification = false
    @State private var currentRecording: Recording?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var didAutoStartRecording = false

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
            guard currentRecording == nil, !didAutoStartRecording else { return }
            didAutoStartRecording = true
            startRecording()
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

            Button(action: handleCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96), .black.opacity(0.22))
                    .symbolRenderingMode(.palette)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.leading, 20)
        }
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
            VStack(spacing: 0) {
                Button(action: copyTranscription) {
                    Label(showCopiedNotification ? "Copied" : "Copy",
                          systemImage: showCopiedNotification ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(showCopiedNotification ? Color.green : Color.dsPrimary)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .background(Color.white)
        }
        .background(Color.white)
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
            errorMessage = access.reason ?? "Log in to continue transcribing."
            sheetState = .viewing
            return
        }

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

    private func beginRecording() {
        recordingStartTime = Date()
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
                transcribeAudio(audioURL: audioURL)
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

    private func transcribeAudio(audioURL: URL) {
        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            errorMessage = access.reason ?? "Log in to continue transcribing."
            sheetState = .viewing
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            sheetState = .processing
            updateRecordingSurface(animated: false)
        }

        Task {
            do {
                let processedResult = try await SharedTranscriptionService.transcribe(
                    audioURL: audioURL,
                    dictionaryManager: dictionaryManager,
                    toneStyleManager: toneStyleManager,
                    shortcutManager: shortcutManager
                )

                guard !processedResult.isEmpty else {
                    DebugLog.info("Sheet transcription was empty after sanitization; skipping history item", context: "RecordingSheetView")
                    try? FileManager.default.removeItem(at: audioURL)
                    await MainActor.run {
                        transcription = ""
                        sheetState = .idle
                        recordingStartTime = nil
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

                    // Create recording with unique ID
                    let recordingID = UUID()

                    // Save audio file to persistent storage
                    let permanentAudioURL = historyManager.saveAudioFile(from: audioURL, for: recordingID)

                    // Save to history with audio file URL
                    let recording = Recording(
                        id: recordingID,
                        transcription: processedResult,
                        duration: duration,
                        audioFileURL: permanentAudioURL
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
                    errorMessage = "Transcription failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func resetRecordingState() {
        recordingStartTime = nil
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

    private func copyTranscription() {
        guard !transcription.isEmpty else { return }

        UIPasteboard.general.string = transcription

        // Show copied notification
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            showCopiedNotification = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopiedNotification = false
            }
        }
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
