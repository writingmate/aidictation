import AVFoundation
import Combine
import SwiftUI
import UIKit
import WhisperMateShared

class KeyboardViewController: UIInputViewController {
    // MARK: - Properties

    private var audioRecorder: AudioRecorder!
    private var openAIClient: OpenAIClient!
    private var hostingController: UIHostingController<KeyboardRecordingView>!
    private var statusLabel: UILabel!
    private var cancellables = Set<AnyCancellable>()
    private let dictionaryManager = DictionaryManager.shared
    private let shortcutManager = ShortcutManager.shared
    private let languageManager = LanguageManager()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupAudioRecorder()
        setupOpenAIClient()
        setupUI()
        checkInitialPermissions()
    }

    private func checkInitialPermissions() {
        let micPermission = AVAudioSession.sharedInstance().recordPermission

        switch micPermission {
        case .denied:
            statusLabel.text = "⚠️ Microphone access needed. Tap record to enable."
            statusLabel.textColor = UIColor.systemOrange
        case .undetermined:
            statusLabel.text = "Tap record button to get started"
            statusLabel.textColor = UIColor.label // Better visibility
        case .granted:
            statusLabel.text = ""
        @unknown default:
            break
        }
    }

    // MARK: - Setup

    private func setupAudioRecorder() {
        audioRecorder = AudioRecorder()

        // Observe recording state
        audioRecorder.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.updateRecordingState(isRecording)
            }
            .store(in: &cancellables)

        // Observe audio levels for visualization
        audioRecorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.updateAudioLevel(level)
            }
            .store(in: &cancellables)
    }

    private func setupOpenAIClient() {
        // Try keychain first, then fall back to Secrets.plist
        let apiKey = KeychainHelper.get(key: "custom_transcription_api_key") ?? SecretsLoader.transcriptionKey(for: .custom)
        let endpoint = SecretsLoader.customTranscriptionEndpoint() ?? "https://writingmate.ai/api/openai/v1/audio/transcriptions"
        let model = SecretsLoader.customTranscriptionModel() ?? "gpt-4o-transcribe"

        guard let apiKey = apiKey else {
            DebugLog.info("No API key found", context: "KeyboardViewController")
            return
        }

        let config = OpenAIClient.Configuration(
            transcriptionEndpoint: endpoint,
            transcriptionModel: model,
            chatCompletionEndpoint: "",
            chatCompletionModel: "",
            apiKey: apiKey
        )

        openAIClient = OpenAIClient(config: config)
    }

    private func setupUI() {
        // Create SwiftUI view
        let recordingView = KeyboardRecordingView(
            isRecording: false,
            audioLevel: 0.0,
            onStopRecording: { [weak self] in
                self?.stopRecordingAndTranscribe()
            }
        )

        // Host it in a UIHostingController
        hostingController = UIHostingController(rootView: recordingView)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        // Add tap gesture to start recording when not recording
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        hostingController.view.addGestureRecognizer(tapGesture)

        // Create status label for transcription status (overlay)
        statusLabel = UILabel()
        statusLabel.text = ""
        statusLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = UIColor.label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Layout constraints
        let minKeyboardHeight: CGFloat = 200

        NSLayoutConstraint.activate([
            // Hosting controller fills the view
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.heightAnchor.constraint(greaterThanOrEqualToConstant: minKeyboardHeight),

            // Status label at bottom
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    @objc private func handleTap() {
        if !audioRecorder.isRecording {
            startRecording()
        }
    }

    // MARK: - Actions

    private func startRecording() {
        // Check current permission status
        let permission = AVAudioSession.sharedInstance().recordPermission

        switch permission {
        case .granted:
            // Permission already granted, start recording
            audioRecorder.startRecording()

        case .denied:
            // Permission was denied, show error with instructions
            showError("Microphone access denied. Open Settings → WhisperMate to enable.")

        case .undetermined:
            // Request permission for the first time
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.audioRecorder.startRecording()
                    } else {
                        self?.showError("Microphone permission denied. Please enable it in Settings.")
                    }
                }
            }

        @unknown default:
            showError("Unable to check microphone permission.")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let recordingURL = audioRecorder.stopRecording() else {
            showError("Failed to stop recording")
            return
        }

        statusLabel.text = "Transcribing..."
        statusLabel.textColor = UIColor.label // Ensure visibility

        Task {
            do {
                // Build prompt with language, dictionary, and shortcut hints
                var promptComponents: [String] = []

                if let languageCodes = languageManager.apiLanguageCode {
                    promptComponents.append("Language: \(languageCodes)")
                }

                let dictionaryHints = dictionaryManager.transcriptionHints
                if !dictionaryHints.isEmpty {
                    promptComponents.append("Vocabulary: \(dictionaryHints)")
                }

                let shortcutHints = shortcutManager.transcriptionHints
                if !shortcutHints.isEmpty {
                    promptComponents.append("Phrases: \(shortcutHints)")
                }

                let promptText = promptComponents.joined(separator: ". ")

                var transcription = try await openAIClient.transcribe(
                    audioURL: recordingURL,
                    prompt: promptText.isEmpty ? nil : promptText
                )

                // Apply post-processing
                transcription = dictionaryManager.applyReplacements(to: transcription)
                transcription = shortcutManager.expandShortcuts(in: transcription)

                // Track word count
                let wordCount = transcription.split(separator: " ").count
                await SubscriptionManager.shared.recordWords(wordCount)

                // Insert transcription into text field
                await MainActor.run {
                    self.textDocumentProxy.insertText(transcription)
                    self.statusLabel.text = "Transcribed"
                    self.statusLabel.textColor = UIColor.systemGreen

                    // Save to history
                    let historyManager = HistoryManager()
                    let recording = Recording(transcription: transcription)
                    historyManager.addRecording(recording)

                    // Clear status after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.statusLabel.text = ""
                        self.statusLabel.textColor = UIColor.label
                    }
                }

                // Delete audio file after successful transcription
                try? FileManager.default.removeItem(at: recordingURL)
            } catch {
                await MainActor.run {
                    self.showError("Transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - UI Updates

    private func updateRecordingState(_ isRecording: Bool) {
        // Update SwiftUI view
        let newView = KeyboardRecordingView(
            isRecording: isRecording,
            audioLevel: audioRecorder.audioLevel,
            onStopRecording: { [weak self] in
                self?.stopRecordingAndTranscribe()
            }
        )
        hostingController.rootView = newView

        // Update status label
        if isRecording {
            statusLabel.text = ""
        }
    }

    private func updateAudioLevel(_ level: Float) {
        // Update SwiftUI view with new audio level
        if audioRecorder.isRecording {
            let newView = KeyboardRecordingView(
                isRecording: true,
                audioLevel: level,
                onStopRecording: { [weak self] in
                    self?.stopRecordingAndTranscribe()
                }
            )
            hostingController.rootView = newView
        }
    }

    private func showError(_ message: String) {
        statusLabel.text = "❌ \(message)"
        statusLabel.textColor = UIColor.systemRed

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.statusLabel.text = ""
            self.statusLabel.textColor = UIColor.label
        }
    }

    // MARK: - Memory Management

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Keyboard extensions have strict memory limits (~40MB)
        // Clean up if needed
        DebugLog.info("Memory warning received", context: "KeyboardViewController")
    }
}
