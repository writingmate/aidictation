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

        DebugLog.info("viewDidLoad fullAccess=\(hasFullAccess) bundle=\(Bundle.main.bundleIdentifier ?? "nil")", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("keyboard viewDidLoad fullAccess=\(hasFullAccess) bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        setupUI()
        checkInitialPermissions()
        checkForPendingDictationText()
        restoreActiveRecordingIfNeeded()
        startPendingTextTimer()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkForPendingDictationText()
        restoreActiveRecordingIfNeeded()
        startPendingTextTimer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkForPendingDictationText()
        restoreActiveRecordingIfNeeded()
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
        DebugLog.info("primary button pressed state=\(keyboardState)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("primary button pressed state=\(keyboardState)")
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
        KeyboardDictationHandoff.publish(command: .start, sessionID: sessionID)
        DebugLog.info("startRecording requested sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("startRecording requested sessionID=\(sessionID)")
        activeHandoffSessionID = sessionID
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        statusLabel.text = ""
        statusLabel.isHidden = true

        guard let url = KeyboardDictationHandoff.makeDictationURL(sessionID: sessionID) else {
            DebugLog.info("failed to build dictation URL sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("failed to build dictation URL sessionID=\(sessionID)")
            keyboardState = .idle
            updateKeyboardView(animated: true)
            showError("Could not open AI Dictation.")
            return
        }

        openContainingApp(url) { [weak self] didOpen in
            guard let self else { return }
            DebugLog.info("openContainingApp result didOpen=\(didOpen) sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("openContainingApp result didOpen=\(didOpen) sessionID=\(sessionID)")

            guard didOpen else {
                KeyboardDictationHandoff.clearActiveSession()
                self.activeHandoffSessionID = nil
                self.stopRecordingMeter()
                self.keyboardState = .idle
                self.updateKeyboardView(animated: true)
                self.showError("Could not open AI Dictation.")
                return
            }

            self.keyboardState = .recording
            self.updateKeyboardView(animated: true)
            self.startRecordingMeter()
        }
    }

    private func openContainingApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        if let extensionContext {
            extensionContext.open(url) { [weak self] didOpen in
                DispatchQueue.main.async {
                    if didOpen {
                        DebugLog.info("Opened keyboard dictation deep link via extension context", context: "KeyboardViewController")
                        KeyboardDictationHandoff.appendDiagnostic("opened containing app via extension context")
                        completion(true)
                    } else {
                        KeyboardDictationHandoff.appendDiagnostic("extension context open failed; trying application fallback")
                        self?.openContainingAppViaApplication(url, completion: completion)
                    }
                }
            }
            return
        }

        openContainingAppViaApplication(url, completion: completion)
    }

    private func openContainingAppViaApplication(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard let applicationClass = NSClassFromString("UIApplication") as? NSObjectProtocol,
              applicationClass.responds(to: sel_registerName("sharedApplication")),
              let unmanagedApplication = applicationClass.perform(sel_registerName("sharedApplication")),
              let application = unmanagedApplication.takeUnretainedValue() as? NSObject
        else {
            DebugLog.info("Failed to access UIApplication fallback for keyboard deep link", context: "KeyboardViewController")
            KeyboardDictationHandoff.appendDiagnostic("failed to access UIApplication fallback")
            completion(false)
            return
        }

        let modernSelector = sel_registerName("openURL:options:completionHandler:")
        if application.responds(to: modernSelector) {
            typealias OpenIMP = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, @escaping (Bool) -> Void) -> Void
            let implementation = application.method(for: modernSelector)
            let open = unsafeBitCast(implementation, to: OpenIMP.self)
            open(application, modernSelector, url as NSURL, [:] as NSDictionary) { didOpen in
                DispatchQueue.main.async {
                    DebugLog.info("UIApplication fallback open result didOpen=\(didOpen)", context: "KeyboardViewController")
                    KeyboardDictationHandoff.appendDiagnostic("UIApplication fallback open result didOpen=\(didOpen)")
                    completion(didOpen)
                }
            }
            return
        }

        let legacySelector = sel_registerName("openURL:")
        guard application.responds(to: legacySelector) else {
            DebugLog.info("UIApplication fallback does not respond to openURL", context: "KeyboardViewController")
            KeyboardDictationHandoff.appendDiagnostic("UIApplication fallback does not respond to openURL")
            completion(false)
            return
        }

        typealias LegacyOpenIMP = @convention(c) (AnyObject, Selector, NSURL) -> Bool
        let implementation = application.method(for: legacySelector)
        let open = unsafeBitCast(implementation, to: LegacyOpenIMP.self)
        let didOpen = open(application, legacySelector, url as NSURL)
        DebugLog.info("UIApplication legacy fallback open result didOpen=\(didOpen)", context: "KeyboardViewController")
        KeyboardDictationHandoff.appendDiagnostic("UIApplication legacy fallback open result didOpen=\(didOpen)")
        completion(didOpen)
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
        KeyboardDictationHandoff.publish(command: .stop, sessionID: sessionID)
        DebugLog.info("stopRecording requested sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("stopRecording requested sessionID=\(sessionID)")
        stopRecordingMeter()
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        updateKeyboardView(animated: true)

        openContainingApp(url) { [weak self] didOpen in
            guard let self else { return }
            DebugLog.info("openContainingApp stop result didOpen=\(didOpen) sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("openContainingApp stop result didOpen=\(didOpen) sessionID=\(sessionID)")

            guard didOpen else {
                self.keyboardState = .recording
                self.startRecordingMeter()
                self.updateKeyboardView(animated: true)
                self.showError("Could not stop recording.")
                return
            }
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

        DebugLog.info("inserting pending text sessionID=\(sessionID ?? "nil") length=\(text.count)", context: "KEYBOARD_DIAG")
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

    private func restoreActiveRecordingIfNeeded() {
        guard keyboardState == .idle,
              let sessionID = KeyboardDictationHandoff.activeSessionID()
        else { return }

        guard KeyboardDictationHandoff.consumeMeter(for: sessionID) != nil else {
            DebugLog.info("skip restoring stale keyboard recording sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("skip restoring stale keyboard recording sessionID=\(sessionID)")
            return
        }

        activeHandoffSessionID = sessionID
        keyboardState = .recording
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        statusLabel.text = ""
        statusLabel.isHidden = true
        DebugLog.info("restoring active keyboard recording sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("restoring active keyboard recording sessionID=\(sessionID)")
        updateKeyboardView(animated: true)
        startRecordingMeter()
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

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        checkForPendingDictationText()
    }

    private func startRecordingMeter() {
        stopRecordingMeter()
        DebugLog.info("start meter polling sessionID=\(activeHandoffSessionID ?? "nil")", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("start meter polling sessionID=\(activeHandoffSessionID ?? "nil")")
        pollRecordingMeter()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollRecordingMeter()
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingMeterTimer = timer
    }

    private func pollRecordingMeter() {
        guard keyboardState == .recording else { return }
        let sessionID = activeHandoffSessionID ?? KeyboardDictationHandoff.activeSessionID()
        guard let meter = KeyboardDictationHandoff.consumeMeter(for: sessionID) else {
            return
        }
        if meter.audioLevel > 0.02 {
            DebugLog.info("consume meter sessionID=\(sessionID ?? "nil") level=\(String(format: "%.3f", meter.audioLevel)) bands=\(meter.frequencyBands.count)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("consume meter sessionID=\(sessionID ?? "nil") level=\(String(format: "%.3f", meter.audioLevel)) bands=\(meter.frequencyBands.count)")
        }
        displayedFrequencyBands = meter.frequencyBands
        displayedAudioLevel = meter.audioLevel
        updateKeyboardView(animated: false)
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
