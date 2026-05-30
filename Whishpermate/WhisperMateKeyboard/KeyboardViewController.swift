import SwiftUI
import UIKit
import WhisperMateShared

class KeyboardViewController: UIInputViewController {
    // MARK: - Properties

    private var hostingController: UIHostingController<KeyboardRecordingView>!
    private var statusLabel: UILabel!
    private let recordingViewModel = KeyboardRecordingViewModel()
    private var keyboardState: KeyboardRecordingState = .idle
    private var displayedAudioLevel: Float = 0.0
    private var displayedFrequencyBands: [Float] = Array(repeating: 0.0, count: 10)
    private var isShifted = false
    private var pendingTextTimer: Timer?
    private var recordingMeterTimer: Timer?
    private var activeHandoffSessionID: String?
    private var keyboardHeightConstraint: NSLayoutConstraint?

    private let keyboardHeight: CGFloat = 260

    // MARK: - Lifecycle

    override func loadView() {
        let inputView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
        inputView.backgroundColor = .clear
        inputView.isOpaque = false
        view = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()
        checkInitialPermissions()
        checkForPendingDictationText()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkForPendingDictationText()
        startPendingTextTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPendingTextTimer()
        stopRecordingMeter()
    }

    private func checkInitialPermissions() {
        statusLabel.text = ""
        statusLabel.isHidden = true
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .clear
        view.isOpaque = false

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
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
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
        let sessionID = KeyboardDictationHandoff.beginSession()
        activeHandoffSessionID = sessionID
        keyboardState = .recording
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        updateKeyboardView(animated: true)
        startRecordingMeter()
        statusLabel.text = ""
        statusLabel.isHidden = true

        guard let url = KeyboardDictationHandoff.makeDictationURL(sessionID: sessionID) else {
            stopRecordingMeter()
            keyboardState = .idle
            updateKeyboardView(animated: true)
            showError("Could not open AI Dictation.")
            return
        }

        guard openContainingApp(url) else {
            stopRecordingMeter()
            keyboardState = .idle
            updateKeyboardView(animated: true)
            showError("Could not open AI Dictation.")
            return
        }
    }

    @discardableResult
    private func openContainingApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")

        while let currentResponder = responder {
            if currentResponder.responds(to: selector) {
                currentResponder.perform(selector, with: url)
                DebugLog.info("Open keyboard dictation deep link via responder chain", context: "KeyboardViewController")
                return true
            }

            responder = currentResponder.next
        }

        DebugLog.info("Failed to find responder for keyboard dictation deep link", context: "KeyboardViewController")
        return false
    }

    private func togglePauseRecording() {
        // The keyboard mirrors the app recorder's primary button: record, then stop.
    }

    private func stopRecordingAndTranscribe() {
        guard let sessionID = activeHandoffSessionID ?? KeyboardDictationHandoff.activeSessionID(),
              let url = KeyboardDictationHandoff.makeStopDictationURL(sessionID: sessionID)
        else {
            keyboardState = .idle
            stopRecordingMeter()
            updateKeyboardView(animated: true)
            showError("Could not stop recording.")
            return
        }

        keyboardState = .processing
        stopRecordingMeter()
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        updateKeyboardView(animated: true)

        guard openContainingApp(url) else {
            keyboardState = .recording
            startRecordingMeter()
            updateKeyboardView(animated: true)
            showError("Could not stop recording.")
            return
        }
    }

    // MARK: - UI Updates

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
        statusLabel.text = message
        statusLabel.textColor = UIColor.systemRed
        statusLabel.isHidden = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.statusLabel.text = ""
            self.statusLabel.isHidden = true
            self.statusLabel.textColor = UIColor.label
        }
    }

    private func checkForPendingDictationText() {
        let sessionID = activeHandoffSessionID ?? KeyboardDictationHandoff.activeSessionID()
        guard let text = KeyboardDictationHandoff.consumePendingText(for: sessionID) else {
            return
        }

        textDocumentProxy.insertText(textForInsertion(text))
        activeHandoffSessionID = nil
        keyboardState = .idle
        stopRecordingMeter()
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        statusLabel.text = ""
        statusLabel.isHidden = true
        updateKeyboardView(animated: true)
    }

    private func textForInsertion(_ text: String) -> String {
        guard let previousCharacter = textDocumentProxy.documentContextBeforeInput?.last else {
            return text
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsSpace = (previousCharacter.isLetter || previousCharacter.isNumber)
            && (trimmed.first?.isLetter == true || trimmed.first?.isNumber == true)
        return needsSpace ? " \(text)" : text
    }

    private func startPendingTextTimer() {
        stopPendingTextTimer()
        pendingTextTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForPendingDictationText()
        }
    }

    private func stopPendingTextTimer() {
        pendingTextTimer?.invalidate()
        pendingTextTimer = nil
    }

    private func startRecordingMeter() {
        stopRecordingMeter()
        recordingMeterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, self.keyboardState == .recording else { return }
            let sessionID = self.activeHandoffSessionID ?? KeyboardDictationHandoff.activeSessionID()
            guard let meter = KeyboardDictationHandoff.consumeMeter(for: sessionID) else {
                return
            }
            self.displayedFrequencyBands = meter.frequencyBands
            self.displayedAudioLevel = meter.audioLevel
            self.updateKeyboardView(animated: false)
        }
    }

    private func stopRecordingMeter() {
        recordingMeterTimer?.invalidate()
        recordingMeterTimer = nil
    }

    // MARK: - Memory Management

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Keyboard extensions have strict memory limits (~40MB)
        // Clean up if needed
        DebugLog.info("Memory warning received", context: "KeyboardViewController")
    }
}
