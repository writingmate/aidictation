import AVFoundation
import Combine
import SwiftUI
import UIKit
import WhisperMateShared

class KeyboardViewController: UIInputViewController {
    // MARK: - Properties

    private var audioRecorder: AudioRecorder?
    private var hostingController: UIHostingController<KeyboardRecordingView>!
    private var statusLabel: UILabel!
    private let recordingViewModel = KeyboardRecordingViewModel()
    private var keyboardState: KeyboardRecordingState = .idle
    private var displayedAudioLevel: Float = 0.0
    private var displayedFrequencyBands: [Float] = Array(repeating: 0.0, count: 10)
    private var recordingStartTime: Date?
    private var isProcessingTranscription = false
    private var isShifted = false
    private var cancellables = Set<AnyCancellable>()
    private var keyboardHeightConstraint: NSLayoutConstraint?

    private let minimumRecordingDuration: TimeInterval = 0.35
    private let minimumAudioFileBytes: Int64 = 1000
    private let keyboardHeight: CGFloat = 260
    private let microphoneSettingsURL = URL(string: "aidictation://microphone-settings")

    // MARK: - Lifecycle

    override func loadView() {
        let inputView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
        inputView.backgroundColor = KeyboardPalette.backgroundColor
        view = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()
        checkInitialPermissions()
    }

    private func checkInitialPermissions() {
        statusLabel.text = ""
        statusLabel.isHidden = true
    }

    // MARK: - Setup

    private func ensureAudioRecorder() -> AudioRecorder {
        if let audioRecorder {
            return audioRecorder
        }

        let recorder = AudioRecorder()
        audioRecorder = recorder

        // Observe recording state
        recorder.$isRecording
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.updateRecordingState(isRecording)
            }
            .store(in: &cancellables)

        // Observe audio levels for visualization
        recorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.updateAudioLevel(level)
            }
            .store(in: &cancellables)

        recorder.$frequencyBands
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bands in
                self?.updateFrequencyBands(bands)
            }
            .store(in: &cancellables)

        return recorder
    }

    private func setupUI() {
        view.backgroundColor = KeyboardPalette.backgroundColor
        view.isOpaque = true

        // Create SwiftUI view
        let recordingView = KeyboardRecordingView(
            model: recordingViewModel,
            isShifted: isShifted,
            onPrimaryAction: { [weak self] in
                self?.handlePrimaryAction()
            },
            onPauseAction: { [weak self] in
                self?.togglePauseRecording()
            },
            onKeyPress: { [weak self] text in
                self?.insertKey(text)
            },
            onBackspace: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            onSpace: { [weak self] in
                self?.textDocumentProxy.insertText(" ")
            },
            onReturn: { [weak self] in
                self?.textDocumentProxy.insertText("\n")
            },
            onShift: { [weak self] in
                self?.toggleShift()
            },
            onNextKeyboard: { [weak self] in
                self?.advanceToNextInputMode()
            }
        )

        // Host it in a UIHostingController
        hostingController = UIHostingController(rootView: recordingView)
        hostingController.view.backgroundColor = KeyboardPalette.backgroundColor
        hostingController.view.isOpaque = true
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        // Create status label for transcription status (overlay)
        statusLabel = UILabel()
        statusLabel.text = ""
        statusLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = UIColor.label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Layout constraints
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
        keyboardHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            // Hosting controller fills the view
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Status label at bottom
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func insertKey(_ text: String) {
        textDocumentProxy.insertText(text)
        if isShifted {
            isShifted = false
            refreshKeyboardRootView()
        }
    }

    private func toggleShift() {
        isShifted.toggle()
        refreshKeyboardRootView()
    }

    private func refreshKeyboardRootView() {
        hostingController.rootView = KeyboardRecordingView(
            model: recordingViewModel,
            isShifted: isShifted,
            onPrimaryAction: { [weak self] in self?.handlePrimaryAction() },
            onPauseAction: { [weak self] in self?.togglePauseRecording() },
            onKeyPress: { [weak self] text in self?.insertKey(text) },
            onBackspace: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onSpace: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            onShift: { [weak self] in self?.toggleShift() },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() }
        )
    }

    private func handlePrimaryAction() {
        switch keyboardState {
        case .idle:
            startRecording()
        case .recording, .paused:
            stopRecordingAndTranscribe()
        case .processing:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Actions

    private func startRecording() {
        isProcessingTranscription = false

        let access = SubscriptionManager.shared.checkCanTranscribe()
        guard access.canTranscribe else {
            showError(access.reason ?? "Open AI Dictation to log in and continue.")
            return
        }

        // Check current permission status
        let permission = AVAudioSession.sharedInstance().recordPermission

        switch permission {
        case .granted:
            beginRecording()

        case .denied:
            showError("Enable microphone access in AI Dictation settings.")
            openContainingAppForMicrophoneSettings()

        case .undetermined:
            // Request permission for the first time
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecording()
                    } else {
                        self?.showError("Enable microphone access in AI Dictation settings.")
                        self?.openContainingAppForMicrophoneSettings()
                    }
                }
            }

        @unknown default:
            showError("Unable to check microphone permission.")
        }
    }

    private func openContainingAppForMicrophoneSettings() {
        guard let microphoneSettingsURL else {
            return
        }

        extensionContext?.open(microphoneSettingsURL) { success in
            DebugLog.info(
                "Open microphone settings deep link success=\(success)",
                context: "KeyboardViewController"
            )
        }
    }

    private func beginRecording() {
        recordingStartTime = Date()
        displayedAudioLevel = 0.0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        keyboardState = .recording
        statusLabel.text = ""
        statusLabel.isHidden = true
        updateKeyboardView(animated: true)
        ensureAudioRecorder().startRecording()
    }

    private func togglePauseRecording() {
        guard let audioRecorder else { return }

        switch keyboardState {
        case .recording:
            displayedAudioLevel = audioRecorder.audioLevel
            displayedFrequencyBands = audioRecorder.frequencyBands
            audioRecorder.pauseRecording()
            keyboardState = .paused
            updateKeyboardView(animated: true)
        case .paused:
            audioRecorder.resumeRecording()
            keyboardState = .recording
            updateKeyboardView(animated: true)
        case .idle, .processing:
            break
        @unknown default:
            break
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let audioRecorder else {
            keyboardState = .idle
            updateKeyboardView(animated: true)
            return
        }

        isProcessingTranscription = true
        keyboardState = .processing
        statusLabel.text = ""
        statusLabel.isHidden = true
        updateKeyboardView(animated: true)

        let recordingStartedAt = recordingStartTime

        Task {
            guard let recordingURL = await audioRecorder.stopRecordingAsync(deactivateAudioSession: false) else {
                await MainActor.run {
                    self.isProcessingTranscription = false
                    self.keyboardState = .idle
                    self.updateKeyboardView(animated: true)
                    DebugLog.info("Keyboard recording stopped without an audio URL", context: "KeyboardViewController")
                }
                return
            }

            guard validateRecordingForTranscription(recordingURL, recordingStartTime: recordingStartedAt) else {
                await MainActor.run {
                    self.isProcessingTranscription = false
                    self.keyboardState = .idle
                    self.displayedAudioLevel = 0.0
                    self.displayedFrequencyBands = Array(repeating: 0.0, count: 10)
                    self.recordingStartTime = nil
                    self.updateKeyboardView(animated: true)
                }
                try? FileManager.default.removeItem(at: recordingURL)
                return
            }

            do {
                let access = SubscriptionManager.shared.checkCanTranscribe()
                guard access.canTranscribe else {
                    throw OpenAIError.apiError(access.reason ?? "Open AI Dictation to log in and continue.")
                }

                let transcription = try await SharedTranscriptionService.transcribe(audioURL: recordingURL)

                guard !transcription.isEmpty else {
                    DebugLog.info("Keyboard transcription was empty after sanitization; skipping insert", context: "KeyboardViewController")
                    await MainActor.run {
                        self.isProcessingTranscription = false
                        self.keyboardState = .idle
                        self.displayedAudioLevel = 0.0
                        self.displayedFrequencyBands = Array(repeating: 0.0, count: 10)
                        self.recordingStartTime = nil
                        self.updateKeyboardView(animated: true)
                        self.statusLabel.text = ""
                        self.statusLabel.isHidden = true
                    }
                    try? FileManager.default.removeItem(at: recordingURL)
                    return
                }

                let wordCount = SubscriptionManager.shared.wordCount(for: transcription)
                await SubscriptionManager.shared.recordWords(wordCount)

                // Insert transcription into text field
                await MainActor.run {
                    self.textDocumentProxy.insertText(transcription)
                    self.isProcessingTranscription = false
                    self.keyboardState = .idle
                    self.displayedAudioLevel = 0.0
                    self.displayedFrequencyBands = Array(repeating: 0.0, count: 10)
                    self.recordingStartTime = nil
                    self.updateKeyboardView(animated: true)
                    self.statusLabel.text = ""
                    self.statusLabel.isHidden = true

                    // Save to history
                    let historyManager = HistoryManager()
                    let recording = Recording(transcription: transcription)
                    historyManager.addRecording(recording)

                    // Clear status after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.statusLabel.text = ""
                        self.statusLabel.isHidden = true
                        self.statusLabel.textColor = UIColor.label
                    }
                }

                // Delete audio file after successful transcription
                try? FileManager.default.removeItem(at: recordingURL)
            } catch {
                await MainActor.run {
                    self.isProcessingTranscription = false
                    self.keyboardState = .idle
                    self.displayedAudioLevel = 0.0
                    self.displayedFrequencyBands = Array(repeating: 0.0, count: 10)
                    self.recordingStartTime = nil
                    self.updateKeyboardView(animated: true)
                    self.showError("Transcription failed: \(error.localizedDescription)")
                }
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
            DebugLog.info("Failed to verify keyboard recording file: \(error)", context: "KeyboardViewController")
            return false
        }

        let audioDuration = audioFileDuration(audioURL)
        DebugLog.info(
            "Keyboard recording ready: elapsed=\(String(format: "%.2f", elapsed))s, audioDuration=\(String(format: "%.2f", audioDuration ?? -1))s, fileSize=\(fileSize) bytes",
            context: "KeyboardViewController"
        )

        if elapsed < minimumRecordingDuration || (audioDuration ?? elapsed) < minimumRecordingDuration {
            DebugLog.info("Keyboard recording too short; skipping transcription", context: "KeyboardViewController")
            return false
        }

        if fileSize < minimumAudioFileBytes {
            DebugLog.info("Keyboard recording has no audio payload; skipping transcription", context: "KeyboardViewController")
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
            DebugLog.info("Failed to read keyboard recording duration: \(error)", context: "KeyboardViewController")
            return nil
        }
    }

    // MARK: - UI Updates

    private func updateRecordingState(_ isRecording: Bool) {
        if isProcessingTranscription || keyboardState == .paused {
            return
        }

        // Update SwiftUI view
        keyboardState = isRecording ? .recording : .idle
        updateKeyboardView(animated: false)

        // Update status label
        if isRecording {
            statusLabel.text = ""
            statusLabel.isHidden = true
        }
    }

    private func updateAudioLevel(_ level: Float) {
        // Update SwiftUI view with new audio level
        if keyboardState == .recording {
            displayedAudioLevel = level
            recordingViewModel.audioLevel = level
        }
    }

    private func updateFrequencyBands(_ bands: [Float]) {
        if keyboardState == .recording {
            displayedFrequencyBands = bands
            recordingViewModel.frequencyBands = bands
        }
    }

    private func updateKeyboardView(animated: Bool = false) {
        let updates = {
            self.recordingViewModel.state = self.keyboardState
            self.recordingViewModel.audioLevel = self.displayedAudioLevel
            self.recordingViewModel.frequencyBands = self.displayedFrequencyBands
        }

        if animated {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82, blendDuration: 0.06), updates)
        } else {
            updates()
        }
    }

    private func showError(_ message: String) {
        statusLabel.text = "❌ \(message)"
        statusLabel.textColor = UIColor.systemRed
        statusLabel.isHidden = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.statusLabel.text = ""
            self.statusLabel.isHidden = true
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
