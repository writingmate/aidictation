import AVFoundation
import SwiftUI
import WhisperMateShared

struct RecordingSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audioRecorder = AudioRecorder()
    @ObservedObject var historyManager: HistoryManager
    @ObservedObject var dictionaryManager: DictionaryManager
    @ObservedObject var toneStyleManager: ToneStyleManager
    @ObservedObject var shortcutManager: ShortcutManager

    @State private var sheetState: SheetState = .recording
    @State private var transcription = ""
    @State private var errorMessage = ""
    @State private var recordingStartTime: Date?
    @State private var showCopiedNotification = false
    @State private var currentRecording: Recording?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false

    enum SheetState {
        case recording
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
        VStack(spacing: 0) {
            if sheetState == .viewing {
                NavigationView {
                    viewingStateView
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    dismiss()
                                }
                            }
                        }
                }
            } else {
                // Fullscreen for recording and processing states
                ZStack {
                    Color.black.opacity(0.01)
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        // Top bar with cancel button
                        HStack {
                            Button(action: handleCancel) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.white)
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .padding(.top, 16)
                            .padding(.leading, 20)
                            Spacer()
                        }

                        Spacer()

                        // Main content based on state
                        if sheetState == .recording {
                            recordingStateView
                        } else {
                            processingStateView
                        }

                        Spacer()

                        // Bottom button (stop button for recording state)
                        if sheetState == .recording {
                            Button(action: stopRecording) {
                                ZStack {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 70, height: 70)
                                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white)
                                        .frame(width: 24, height: 24)
                                }
                            }
                            .padding(.bottom, 50)
                        }
                    }
                }
                .background(Color.black)
            }
        }
        .onAppear {
            if sheetState == .recording {
                startRecording()
            }
        }
    }

    // MARK: - State Views

    private var recordingStateView: some View {
        VStack(spacing: 20) {
            AudioVisualizationView(audioLevel: audioRecorder.audioLevel, color: .blue)
                .frame(height: 280)
                .padding(.horizontal, 40)
        }
    }

    private var processingStateView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
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
                            .foregroundColor(.blue)
                    }

                    if let duration = currentRecording?.duration {
                        Text(formatDuration(duration))
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color(.systemBackground))

                Divider()
            }

            // Transcription content
            ScrollView {
                VStack(spacing: 0) {
                    Text(transcription)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.primary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                }
            }
            .background(Color(.systemGroupedBackground))

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
                Divider()

                Button(action: copyTranscription) {
                    Label(showCopiedNotification ? "Copied" : "Copy",
                          systemImage: showCopiedNotification ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(showCopiedNotification ? .green : .blue)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .background(Color(.systemBackground))
        }
    }

    // MARK: - Actions

    private func handleCancel() {
        if audioRecorder.isRecording {
            _ = audioRecorder.stopRecording()
        }
        dismiss()
    }

    private func startRecording() {
        recordingStartTime = Date()

        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    audioRecorder.startRecording()
                } else {
                    errorMessage = "Microphone permission denied. Please enable it in Settings."
                    sheetState = .viewing
                }
            }
        }
    }

    private func stopRecording() {
        // Check recording duration - skip if too short (< 0.3 seconds)
        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)

            if duration < 0.3 {
                DebugLog.info("Recording too short (\(duration)s), skipping transcription", context: "RecordingSheetView")
                dismiss()
                return
            }
        }

        // Stop recording and get audio file
        guard let audioURL = audioRecorder.stopRecording() else {
            errorMessage = "Failed to save recording"
            sheetState = .viewing
            return
        }

        // Check if audio file exists and has content
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0

            if fileSize < 1000 {
                errorMessage = "No audio detected"
                try? FileManager.default.removeItem(at: audioURL)
                dismiss()
                return
            }
        } catch {
            errorMessage = "Failed to verify recording"
            sheetState = .viewing
            return
        }

        transcribeAudio(audioURL: audioURL)
    }

    private func transcribeAudio(audioURL: URL) {
        // Get API key from Secrets.plist or keychain
        let apiKey = KeychainHelper.get(key: "custom_transcription_api_key") ?? SecretsLoader.transcriptionKey(for: .custom)
        let endpoint = SecretsLoader.customTranscriptionEndpoint() ?? "https://writingmate.ai/api/openai/v1/audio/transcriptions"
        let model = SecretsLoader.customTranscriptionModel() ?? "groq/whisper-large-v3-turbo"

        guard let apiKey = apiKey else {
            errorMessage = "API key not configured"
            sheetState = .viewing
            return
        }

        sheetState = .processing

        Task {
            do {
                let config = OpenAIClient.Configuration(
                    transcriptionEndpoint: endpoint,
                    transcriptionModel: model,
                    chatCompletionEndpoint: SecretsLoader.aidictationPostProcessingEndpoint() ?? "https://writingmate.ai/api/openai/v1/chat/completions",
                    chatCompletionModel: "openai/gpt-oss-20b",
                    apiKey: apiKey,
                    chatCompletionApiKey: SecretsLoader.aidictationPostProcessingKey() ?? apiKey
                )

                let openAIClient = OpenAIClient(config: config)

                // Combine prompts from all sources
                var promptComponents: [String] = []

                // Add dictionary hints for better recognition
                let dictionaryHints = dictionaryManager.transcriptionHints
                if !dictionaryHints.isEmpty {
                    promptComponents.append("Vocabulary: \(dictionaryHints)")
                }

                // Add shortcut triggers for recognition
                let shortcutHints = shortcutManager.transcriptionHints
                if !shortcutHints.isEmpty {
                    promptComponents.append("Phrases: \(shortcutHints)")
                }

                // Add tone/style instructions (all enabled styles for iOS)
                let styleInstructions = toneStyleManager.allInstructions
                if !styleInstructions.isEmpty {
                    promptComponents.append(styleInstructions)
                }

                let promptText = promptComponents.joined(separator: ". ")

                let result = try await openAIClient.transcribe(
                    audioURL: audioURL,
                    prompt: promptText.isEmpty ? nil : promptText
                )

                // Apply post-processing: dictionary replacements and shortcut expansion
                var processedResult = result
                processedResult = dictionaryManager.applyReplacements(to: processedResult)
                processedResult = shortcutManager.expandShortcuts(in: processedResult)

                await MainActor.run {
                    transcription = processedResult
                    sheetState = .viewing
                    errorMessage = ""

                    // Calculate duration
                    let duration = recordingStartTime.map { Date().timeIntervalSince($0) }

                    // Create recording with unique ID
                    let recordingID = UUID()

                    // Save audio file to persistent storage
                    let permanentAudioURL = historyManager.saveAudioFile(from: audioURL, for: recordingID)

                    // Save to history with audio file URL
                    let recording = Recording(
                        id: recordingID,
                        transcription: result,
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
                    errorMessage = "Transcription failed: \(error.localizedDescription)"
                }
            }
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
