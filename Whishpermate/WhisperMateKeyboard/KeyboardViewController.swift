import SwiftUI
import UIKit
import WhisperMateShared

class KeyboardViewController: UIInputViewController {
    private enum PrimaryButtonState: String {
        case startRequiresApp
        case finishRecording
        case processing
        case startViaReadyApp
    }

    // MARK: - Properties

    private var hostingController: UIHostingController<KeyboardRecordingView>?
    private var statusLabel: UILabel?
    private let recordingViewModel = KeyboardRecordingViewModel()
    private var keyboardState: KeyboardRecordingState = .idle
    private var displayedAudioLevel: Float = 0.0
    private var displayedFrequencyBands: [Float] = Array(repeating: 0.0, count: 10)
    private var isShifted = false
    private var pendingTextTimer: Timer?
    private var recordingMeterTimer: Timer?
    private var startFallbackTimer: Timer?
    private var activeHandoffSessionID: String?
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private var didSetupUI = false

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
        ensureKeyboardUI()
        checkInitialPermissions()
        checkForPendingDictationText()
        restoreActiveRecordingIfNeeded()
        startPendingTextTimer()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ensureKeyboardUI()
        checkForPendingDictationText()
        restoreActiveRecordingIfNeeded()
        startPendingTextTimer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ensureKeyboardUI()
        checkForPendingDictationText()
        restoreActiveRecordingIfNeeded()
        startPendingTextTimer()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        ensureKeyboardUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPendingTextTimer()
        stopRecordingMeter()
        stopStartFallbackTimer()
    }

    private func checkInitialPermissions() {
        statusLabel?.text = ""
        statusLabel?.isHidden = true
    }

    // MARK: - Setup

    private func ensureKeyboardUI() {
        guard didSetupUI else {
            setupUI()
            return
        }

        guard hostingController?.view.superview === view,
              statusLabel?.superview === view
        else {
            teardownUI()
            setupUI()
            return
        }

        keyboardHeightConstraint?.constant = keyboardHeight
    }

    private func setupUI() {
        guard !didSetupUI else { return }

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
        let host = UIHostingController(rootView: recordingView)
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        hostingController = host

        // Create status label for transcription status (overlay)
        let label = UILabel()
        label.text = ""
        label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = UIColor.label
        label.textAlignment = .center
        label.numberOfLines = 2
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        statusLabel = label

        // Layout constraints
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
        keyboardHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            // Hosting controller fills the view
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Status label at bottom
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        didSetupUI = true
    }

    private func teardownUI() {
        keyboardHeightConstraint?.isActive = false
        keyboardHeightConstraint = nil

        statusLabel?.removeFromSuperview()
        statusLabel = nil

        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
        hostingController = nil
        didSetupUI = false
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
        ensureKeyboardUI()
        hostingController?.rootView = KeyboardRecordingView(
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
        let buttonState = primaryButtonState
        DebugLog.info("primary button pressed state=\(keyboardState) buttonState=\(buttonState.rawValue)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("primary button pressed state=\(keyboardState) buttonState=\(buttonState.rawValue)")
        switch buttonState {
        case .startRequiresApp:
            startRecording(openAppIfNeeded: true)
        case .startViaReadyApp:
            startRecording(openAppIfNeeded: false)
        case .finishRecording:
            stopRecordingAndTranscribe()
        case .processing:
            break
        }
    }

    // MARK: - Actions

    private var primaryButtonState: PrimaryButtonState {
        switch keyboardState {
        case .idle:
            return KeyboardDictationHandoff.isAppReady() ? .startViaReadyApp : .startRequiresApp
        case .recording, .paused:
            return .finishRecording
        case .processing:
            return .processing
        @unknown default:
            return .processing
        }
    }

    private func startRecording(openAppIfNeeded: Bool) {
        let sessionID = KeyboardDictationHandoff.beginSession()
        KeyboardDictationHandoff.publish(command: .start, sessionID: sessionID)
        DebugLog.info("startRecording requested sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("startRecording requested sessionID=\(sessionID)")
        activeHandoffSessionID = sessionID
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        statusLabel?.text = ""
        statusLabel?.isHidden = true

        if !openAppIfNeeded {
            DebugLog.info("startRecording using ready app bridge sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("startRecording using ready app bridge sessionID=\(sessionID)")
            keyboardState = .recording
            updateKeyboardView(animated: true)
            startRecordingMeter()
            startAppOpenFallbackTimer(sessionID: sessionID)
            return
        }

        openAppForRecording(sessionID: sessionID)
    }

    private func openAppForRecording(sessionID: String) {
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

    private func startAppOpenFallbackTimer(sessionID: String) {
        stopStartFallbackTimer()
        let timer = Timer(timeInterval: 1.25, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      self.keyboardState == .recording,
                      self.activeHandoffSessionID == sessionID,
                      KeyboardDictationHandoff.consumeMeter(for: sessionID) == nil
                else { return }

                DebugLog.info("ready app bridge did not publish meter; opening app sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
                KeyboardDictationHandoff.appendDiagnostic("ready app bridge did not publish meter; opening app sessionID=\(sessionID)")
                self.openAppForRecording(sessionID: sessionID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        startFallbackTimer = timer
    }

    private func stopStartFallbackTimer() {
        startFallbackTimer?.invalidate()
        startFallbackTimer = nil
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
        guard let sessionID = activeHandoffSessionID ?? KeyboardDictationHandoff.activeSessionID()
        else {
            keyboardState = .idle
            stopRecordingMeter()
            updateKeyboardView(animated: true)
            showError("Could not stop recording.")
            return
        }

        keyboardState = .processing
        stopStartFallbackTimer()
        KeyboardDictationHandoff.publish(command: .stop, sessionID: sessionID)
        DebugLog.info("stopRecording requested sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("stopRecording requested sessionID=\(sessionID)")
        stopRecordingMeter()
        stopStartFallbackTimer()
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        updateKeyboardView(animated: true)
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
        statusLabel?.text = message
        statusLabel?.textColor = UIColor.systemRed
        statusLabel?.isHidden = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.statusLabel?.text = ""
            self.statusLabel?.isHidden = true
            self.statusLabel?.textColor = UIColor.label
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
        statusLabel?.text = ""
        statusLabel?.isHidden = true
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
        statusLabel?.text = ""
        statusLabel?.isHidden = true
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
        stopStartFallbackTimer()
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
