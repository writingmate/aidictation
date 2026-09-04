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
    private var currentLayout = KeyboardViewController.loadCurrentLayout()
    private var previousLayoutCode = KeyboardViewController.loadPreviousLayoutCode()

    private static let layoutCodeKey = "keyboardLayoutCode"
    private static let previousLayoutCodeKey = "keyboardPreviousLayoutCode"
    private static let legacyLayoutKey = "keyboardLayoutLanguage"

    private static func loadCurrentLayout() -> KeyboardTypingLayout {
        if let code = AppDefaults.shared.string(forKey: layoutCodeKey),
           let layout = KeyboardLayoutData.layout(for: code)
        {
            return layout
        }

        // Older builds stored "english"/"russian".
        if let legacy = AppDefaults.shared.string(forKey: legacyLayoutKey) {
            let migrated = legacy == "russian" ? "ru" : "en"
            if let layout = KeyboardLayoutData.layout(for: migrated) {
                return layout
            }
        }

        if let match = preferredLayoutCodes().first,
           let layout = KeyboardLayoutData.layout(for: match)
        {
            return layout
        }

        return KeyboardLayoutData.layouts[0]
    }

    private static func loadPreviousLayoutCode() -> String {
        if let code = AppDefaults.shared.string(forKey: previousLayoutCodeKey),
           KeyboardLayoutData.layout(for: code) != nil
        {
            return code
        }

        let current = loadCurrentLayout().code
        if let second = preferredLayoutCodes().first(where: { $0 != current }) {
            return second
        }
        return current == "en" ? "ru" : "en"
    }

    /// Layout codes matching the user's device language list, in preference order.
    private static func preferredLayoutCodes() -> [String] {
        Locale.preferredLanguages.compactMap { identifier in
            let code = identifier.split(separator: "-").first.map(String.init) ?? identifier
            return KeyboardLayoutData.layout(for: code)?.code
        }
    }
    private var pendingTextTimer: Timer?
    private var recordingMeterTimer: Timer?
    private var startFallbackTimer: Timer?
    private var handoffDeadlineTimer: Timer?
    private var activeHandoffIdentity: KeyboardDictationHandoff.AttemptIdentity?
    private var handoffPhase: KeyboardDictationHandoff.Phase?
    private var armedDeadline: Date?
    private var statusMessageToken = UUID()
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
        stopHandoffDeadlineTimer()
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
            handoffPhase: handoffPhase,
            isShifted: isShifted,
            layout: currentLayout,
            showsGlobeKey: needsInputModeSwitchKey,
            onPrimaryAction: { [weak self] in
                self?.handlePrimaryAction()
            },
            onPauseAction: { [weak self] in
                self?.togglePauseRecording()
            },
            onCancelAction: { [weak self] in
                self?.cancelActiveAttempt()
            },
            onKeyPress: { [weak self] text in
                self?.insertKey(text)
            },
            onAccentPick: { [weak self] text in
                self?.replaceLastCharacter(with: text)
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
            onToggleLayout: { [weak self] in
                self?.toggleLayoutLanguage()
            },
            onSelectLanguage: { [weak self] code in
                self?.selectLayout(code: code)
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

    private func toggleLayoutLanguage() {
        let target = previousLayoutCode
        previousLayoutCode = currentLayout.code
        applyLayout(code: target)
    }

    private func selectLayout(code: String) {
        guard code != currentLayout.code else { return }
        previousLayoutCode = currentLayout.code
        applyLayout(code: code)
    }

    private func applyLayout(code: String) {
        guard let layout = KeyboardLayoutData.layout(for: code) else { return }
        currentLayout = layout
        isShifted = false
        AppDefaults.shared.set(currentLayout.code, forKey: Self.layoutCodeKey)
        AppDefaults.shared.set(previousLayoutCode, forKey: Self.previousLayoutCodeKey)
        refreshKeyboardRootView()
    }

    /// Accent picks replace the base letter the long press already inserted.
    private func replaceLastCharacter(with text: String) {
        textDocumentProxy.deleteBackward()
        insertKey(text)
    }

    private func refreshKeyboardRootView() {
        ensureKeyboardUI()
        hostingController?.rootView = KeyboardRecordingView(
            model: recordingViewModel,
            handoffPhase: handoffPhase,
            isShifted: isShifted,
            layout: currentLayout,
            showsGlobeKey: needsInputModeSwitchKey,
            onPrimaryAction: { [weak self] in self?.handlePrimaryAction() },
            onPauseAction: { [weak self] in self?.togglePauseRecording() },
            onCancelAction: { [weak self] in self?.cancelActiveAttempt() },
            onKeyPress: { [weak self] text in self?.insertKey(text) },
            onAccentPick: { [weak self] text in self?.replaceLastCharacter(with: text) },
            onBackspace: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onSpace: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            onShift: { [weak self] in self?.toggleShift() },
            onToggleLayout: { [weak self] in self?.toggleLayoutLanguage() },
            onSelectLanguage: { [weak self] code in self?.selectLayout(code: code) },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() }
        )
    }

    private func handlePrimaryAction() {
        let buttonState = primaryButtonState
        let startPath = KeyboardDictationHandoff.idleStartPath()
        let quickDictationReady = KeyboardDictationHandoff.isQuickDictationReady()
        DebugLog.info(
            "primary button pressed state=\(keyboardState) buttonState=\(buttonState.rawValue) startPath=\(startPath.rawValue) quickDictationReady=\(quickDictationReady)",
            context: "KEYBOARD_DIAG"
        )
        KeyboardDictationHandoff.appendDiagnostic(
            "primary button pressed state=\(keyboardState) buttonState=\(buttonState.rawValue) startPath=\(startPath.rawValue) quickDictationReady=\(quickDictationReady)"
        )
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
            switch KeyboardDictationHandoff.idleStartPath() {
            case .startViaReadyApp:
                return .startViaReadyApp
            case .startRequiresApp:
                return .startRequiresApp
            }
        case .recording, .paused:
            return .finishRecording
        case .processing:
            return .processing
        @unknown default:
            return .processing
        }
    }

    private func startRecording(openAppIfNeeded: Bool) {
        guard activeHandoffIdentity == nil else { return }

        let identity: KeyboardDictationHandoff.AttemptIdentity
        do {
            identity = try KeyboardDictationHandoff.beginAttempt()
        } catch {
            presentIdleOutcome(
                .persistenceFailed,
                userMessage: "Couldn't save this recording. Try again."
            )
            return
        }
        guard KeyboardDictationHandoff.publish(command: .start, identity: identity) else {
            _ = KeyboardDictationHandoff.cancelAttempt(
                identity: identity,
                reason: "Recording could not start."
            )
            presentIdleOutcome(
                .startFailed,
                userMessage: "Recording couldn't start. Try again."
            )
            return
        }

        DebugLog.info(
            "startRecording requested sessionID=\(identity.sessionID) attemptID=\(identity.attemptID) generation=\(identity.generation)",
            context: "KEYBOARD_DIAG"
        )
        KeyboardDictationHandoff.appendDiagnostic(
            "startRecording requested sessionID=\(identity.sessionID) attemptID=\(identity.attemptID) generation=\(identity.generation)"
        )
        activeHandoffIdentity = identity
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        statusLabel?.text = ""
        statusLabel?.isHidden = true
        setHandoffPhase(.preparing, animated: true)
        reconcileHandoff()

        if !openAppIfNeeded {
            // Quick Dictation is ready - the app is running in standby mode.
            // Wait for the app to pick up the command without opening its UI.
            // Use a longer fallback (8s) because the app should respond quickly from standby.
            DebugLog.info("startRecording using Quick Dictation sessionID=\(identity.sessionID)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("startRecording using Quick Dictation sessionID=\(identity.sessionID)")
            startQuickDictationFallbackTimer(identity: identity)
            return
        }

        // Quick Dictation not ready (cold start or expired) - must open the app
        openAppForRecording(identity: identity)
    }

    /// Fallback timer for Quick Dictation mode.
    /// The app should respond quickly from standby, but if it doesn't within 8 seconds,
    /// we fall back to opening the app.
    private func startQuickDictationFallbackTimer(identity: KeyboardDictationHandoff.AttemptIdentity) {
        stopStartFallbackTimer()
        let fallbackSeconds: TimeInterval = 8.0
        DebugLog.info("starting \(Int(fallbackSeconds))s Quick Dictation fallback timer sessionID=\(identity.sessionID)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("starting \(Int(fallbackSeconds))s Quick Dictation fallback timer sessionID=\(identity.sessionID)")
        let timer = Timer(timeInterval: fallbackSeconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      self.handoffPhase == .preparing,
                      self.activeHandoffIdentity == identity,
                      KeyboardDictationHandoff.snapshot(for: identity)?.phase == .preparing
                else { return }

                if !KeyboardDictationHandoff.shouldOpenAppAfterQuickDictationFallback() {
                    DebugLog.info(
                        "Quick Dictation fallback: host still ready; waiting sessionID=\(identity.sessionID)",
                        context: "KEYBOARD_DIAG"
                    )
                    KeyboardDictationHandoff.appendDiagnostic(
                        "Quick Dictation fallback: host still ready; waiting sessionID=\(identity.sessionID)"
                    )
                    self.startQuickDictationFallbackTimer(identity: identity)
                    return
                }

                DebugLog.info("Quick Dictation fallback: app did not respond; opening app sessionID=\(identity.sessionID)", context: "KEYBOARD_DIAG")
                KeyboardDictationHandoff.appendDiagnostic("Quick Dictation fallback: app did not respond; opening app sessionID=\(identity.sessionID)")
                self.openAppForRecording(identity: identity)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        startFallbackTimer = timer
    }

    private func openAppForRecording(identity: KeyboardDictationHandoff.AttemptIdentity) {
        guard activeHandoffIdentity == identity,
              let url = KeyboardDictationHandoff.makeDictationURL(sessionID: identity.sessionID)
        else {
            DebugLog.info("failed to build dictation URL sessionID=\(identity.sessionID)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("failed to build dictation URL sessionID=\(identity.sessionID)")
            failActiveAttempt(
                identity: identity,
                handoffReason: "The app could not be opened.",
                failure: .openAppFailed,
                userMessage: "Couldn't open AI Dictation. Try again."
            )
            return
        }

        openContainingApp(url) { [weak self] didOpen in
            guard let self else { return }
            guard self.activeHandoffIdentity == identity else { return }
            DebugLog.info("openContainingApp result didOpen=\(didOpen) sessionID=\(identity.sessionID)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("openContainingApp result didOpen=\(didOpen) sessionID=\(identity.sessionID)")

            guard didOpen else {
                self.failActiveAttempt(
                    identity: identity,
                    handoffReason: "The app could not be opened.",
                    failure: .openAppFailed,
                    userMessage: "Couldn't open AI Dictation. Try again."
                )
                return
            }

            // Opening the app is not a recording acknowledgement. The keyboard remains in
            // preparing until the host confirms durable source ownership and recorder readiness.
            self.reconcileHandoff()
        }
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
        guard let applicationClass = NSClassFromString("UIApplication") else {
            DebugLog.info("Failed to access UIApplication fallback for keyboard deep link", context: "KeyboardViewController")
            KeyboardDictationHandoff.appendDiagnostic("failed to access UIApplication fallback")
            completion(false)
            return
        }
        let applicationClassObject = applicationClass as AnyObject
        guard applicationClassObject.responds(to: sel_registerName("sharedApplication")),
              let unmanagedApplication = applicationClassObject.perform(sel_registerName("sharedApplication")),
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
        guard handoffPhase == .recording,
              let identity = activeHandoffIdentity
        else {
            return
        }

        stopStartFallbackTimer()
        guard KeyboardDictationHandoff.publish(command: .stop, identity: identity) else {
            reconcileHandoff()
            if handoffPhase == .recording {
                failActiveAttempt(
                    identity: identity,
                    handoffReason: "The recording could not be finished.",
                    failure: .startFailed,
                    userMessage: "Couldn't finish recording. Try again."
                )
            }
            return
        }

        DebugLog.info("stopRecording requested sessionID=\(identity.sessionID) attemptID=\(identity.attemptID)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("stopRecording requested sessionID=\(identity.sessionID) attemptID=\(identity.attemptID)")
        stopRecordingMeter()
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        setHandoffPhase(.finalizing, animated: true)
        reconcileHandoff()
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

    private func setHandoffPhase(_ phase: KeyboardDictationHandoff.Phase?, animated: Bool) {
        let phaseChanged = handoffPhase != phase
        handoffPhase = phase

        switch phase {
        case .recording:
            keyboardState = .recording
        case .preparing, .finalizing, .processing:
            keyboardState = .processing
        case .succeeded, .failed, .cancelled, .none:
            keyboardState = .idle
        @unknown default:
            keyboardState = .idle
        }

        updateKeyboardView(animated: animated)
        if phaseChanged {
            refreshKeyboardRootView()
        }
    }

    /// Operational status only. Never red — transcription failures must not
    /// paint a scary error on the keyboard chrome.
    private func showOperationalStatus(_ message: String) {
        let token = UUID()
        statusMessageToken = token
        statusLabel?.text = message
        statusLabel?.textColor = UIColor.secondaryLabel
        statusLabel?.isHidden = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.statusMessageToken == token else { return }
            self.statusLabel?.text = ""
            self.statusLabel?.isHidden = true
            self.statusLabel?.textColor = UIColor.label
        }
    }

    private func checkForPendingDictationText() {
        if activeHandoffIdentity == nil {
            restoreActiveRecordingIfNeeded()
        }
        if activeHandoffIdentity == nil,
           KeyboardDictationHandoff.currentSnapshot() == nil,
           let legacySessionID = KeyboardDictationHandoff.activeSessionID(),
           let legacyText = KeyboardDictationHandoff.consumePendingText(for: legacySessionID)
        {
            textDocumentProxy.insertText(textForInsertion(legacyText))
            KeyboardDictationHandoff.clearActiveSession()
            finishAttempt()
            return
        }
        reconcileHandoff()
    }

    private func restoreActiveRecordingIfNeeded() {
        do {
            _ = try KeyboardDictationHandoff.expireStaleAttempt()
        } catch {
            presentIdleOutcome(
                .restoreFailed,
                userMessage: "Couldn't restore this recording. Open AI Dictation to recover it."
            )
            return
        }
        guard activeHandoffIdentity == nil,
              let snapshot = try? KeyboardDictationHandoff.loadCurrentSnapshot()
        else { return }

        switch snapshot.phase {
        case .failed, .cancelled:
            return
        case .succeeded where snapshot.resultConsumed:
            return
        case .preparing, .recording, .finalizing, .processing, .succeeded:
            break
        @unknown default:
            return
        }

        activeHandoffIdentity = snapshot.identity
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        DebugLog.info(
            "restoring keyboard attempt sessionID=\(snapshot.identity.sessionID) attemptID=\(snapshot.identity.attemptID) phase=\(snapshot.phase.rawValue)",
            context: "KEYBOARD_DIAG"
        )
        KeyboardDictationHandoff.appendDiagnostic(
            "restoring keyboard attempt sessionID=\(snapshot.identity.sessionID) attemptID=\(snapshot.identity.attemptID) phase=\(snapshot.phase.rawValue)"
        )
        reconcileHandoff()
    }

    private func reconcileHandoff() {
        guard let identity = activeHandoffIdentity else { return }
        let snapshot: KeyboardDictationHandoff.Snapshot?
        do {
            _ = try KeyboardDictationHandoff.expireStaleAttempt()
            snapshot = try KeyboardDictationHandoff.loadSnapshot(for: identity)
        } catch {
            presentIdleOutcome(
                .persistenceFailed,
                userMessage: "Couldn't update this recording. Open AI Dictation to recover it."
            )
            return
        }
        guard let snapshot else {
            presentIdleOutcome(
                .startFailed,
                userMessage: "This recording is no longer active. Try again."
            )
            return
        }

        if let deadline = snapshot.deadlineAt,
           !snapshot.phase.isTerminal,
           deadline <= Date()
        {
            handleDeadline(for: snapshot)
            return
        }

        switch snapshot.phase {
        case .preparing:
            stopRecordingMeter()
            setHandoffPhase(.preparing, animated: handoffPhase != .preparing)
            armDeadline(for: snapshot)

        case .recording:
            if startFallbackTimer != nil {
                DebugLog.info("app acknowledged recording; cancelling fallback timer sessionID=\(identity.sessionID)", context: "KEYBOARD_DIAG")
                KeyboardDictationHandoff.appendDiagnostic("app acknowledged recording; cancelling fallback timer sessionID=\(identity.sessionID)")
            }
            stopStartFallbackTimer()
            stopHandoffDeadlineTimer()
            setHandoffPhase(.recording, animated: handoffPhase != .recording)
            if recordingMeterTimer == nil {
                startRecordingMeter()
            }

        case .finalizing:
            stopRecordingMeter()
            setHandoffPhase(.finalizing, animated: handoffPhase != .finalizing)
            armDeadline(for: snapshot)

        case .processing:
            stopRecordingMeter()
            setHandoffPhase(.processing, animated: handoffPhase != .processing)
            armDeadline(for: snapshot)

        case .succeeded:
            stopHandoffDeadlineTimer()
            do {
                if let text = try KeyboardDictationHandoff.consumeResultPersisted(for: identity) {
                    DebugLog.info(
                        "inserting keyboard result sessionID=\(identity.sessionID) attemptID=\(identity.attemptID) length=\(text.count)",
                        context: "KEYBOARD_DIAG"
                    )
                    textDocumentProxy.insertText(textForInsertion(text))
                }
            } catch {
                presentIdleOutcome(
                    .insertFailed,
                    userMessage: "Couldn't insert the transcript. It is saved in AI Dictation."
                )
                return
            }
            finishAttempt()

        case .failed:
            stopHandoffDeadlineTimer()
            if snapshot.recordingID == nil {
                // Nothing was captured: the host could not start (audio session,
                // sign-in, mode selection). Tell the user, do not fail silently.
                presentIdleOutcome(
                    .startFailed,
                    userMessage: snapshot.userMessage ?? "Recording couldn't start. Try again."
                )
            } else {
                presentIdleOutcome(
                    .transcriptionFailed,
                    userMessage: snapshot.userMessage ?? "Transcription failed. Your recording is saved in the app."
                )
            }

        case .cancelled:
            stopHandoffDeadlineTimer()
            presentIdleOutcome(
                .cancelled,
                userMessage: snapshot.userMessage ?? "Recording cancelled."
            )
        @unknown default:
            presentIdleOutcome(
                .startFailed,
                userMessage: "This recording couldn't continue. Try again."
            )
        }
    }

    private func cancelActiveAttempt() {
        guard let identity = activeHandoffIdentity else { return }
        guard KeyboardDictationHandoff.cancelAttempt(identity: identity, reason: "Recording cancelled.") else {
            if reconcileTerminalAttemptIfAvailable(identity: identity) {
                return
            }
            presentIdleOutcome(
                .persistenceFailed,
                userMessage: "Couldn't cancel this recording. Open AI Dictation to recover it."
            )
            return
        }
        KeyboardDictationHandoff.appendDiagnostic(
            "keyboard cancelled sessionID=\(identity.sessionID) attemptID=\(identity.attemptID)"
        )
        presentIdleOutcome(.cancelled, userMessage: "Recording cancelled.")
    }

    private func failActiveAttempt(
        identity: KeyboardDictationHandoff.AttemptIdentity,
        handoffReason: String,
        failure: KeyboardDictationHandoff.KeyboardChromeFailure,
        userMessage: String
    ) {
        guard activeHandoffIdentity == identity || activeHandoffIdentity == nil else { return }
        if KeyboardDictationHandoff.cancelAttempt(identity: identity, reason: handoffReason) {
            presentIdleOutcome(failure, userMessage: userMessage)
        } else if reconcileTerminalAttemptIfAvailable(identity: identity) {
            return
        } else {
            presentIdleOutcome(
                .persistenceFailed,
                userMessage: "Couldn't update this recording. Open AI Dictation to recover it."
            )
        }
    }

    private func reconcileTerminalAttemptIfAvailable(
        identity: KeyboardDictationHandoff.AttemptIdentity
    ) -> Bool {
        guard let snapshot = try? KeyboardDictationHandoff.loadSnapshot(for: identity),
              snapshot.phase.isTerminal
        else {
            return false
        }
        activeHandoffIdentity = identity
        reconcileHandoff()
        return true
    }

    private func handleDeadline(for snapshot: KeyboardDictationHandoff.Snapshot) {
        guard activeHandoffIdentity == snapshot.identity else { return }

        let handoffReason: String
        let userMessage: String
        let failure: KeyboardDictationHandoff.KeyboardChromeFailure
        switch snapshot.phase {
        case .preparing:
            handoffReason = "Recording did not start in time."
            userMessage = "Recording didn't start. Try again."
            failure = .startFailed
        case .finalizing:
            handoffReason = "Recording did not finish in time."
            userMessage = snapshot.recordingID == nil
                ? "Recording didn't finish. Try again."
                : "Recording took too long to finish. Your audio is saved in the app."
            failure = snapshot.recordingID == nil ? .startFailed : .transcriptionTimeout
        case .processing:
            handoffReason = "Transcription did not finish in time."
            userMessage = "Transcription took too long. Your recording is saved in the app."
            failure = .transcriptionTimeout
        case .recording, .succeeded, .failed, .cancelled:
            return
        @unknown default:
            return
        }

        KeyboardDictationHandoff.appendDiagnostic(
            "keyboard deadline phase=\(snapshot.phase.rawValue) sessionID=\(snapshot.identity.sessionID) attemptID=\(snapshot.identity.attemptID)"
        )
        failActiveAttempt(
            identity: snapshot.identity,
            handoffReason: handoffReason,
            failure: failure,
            userMessage: userMessage
        )
    }

    private func armDeadline(for snapshot: KeyboardDictationHandoff.Snapshot) {
        guard let deadline = snapshot.deadlineAt, !snapshot.phase.isTerminal else {
            stopHandoffDeadlineTimer()
            return
        }
        if armedDeadline == deadline, handoffDeadlineTimer != nil {
            return
        }

        stopHandoffDeadlineTimer()
        armedDeadline = deadline
        let interval = max(0.01, deadline.timeIntervalSinceNow)
        let identity = snapshot.identity
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      self.activeHandoffIdentity == identity,
                      let current = KeyboardDictationHandoff.snapshot(for: identity)
                else { return }
                if let currentDeadline = current.deadlineAt, currentDeadline <= Date() {
                    self.handleDeadline(for: current)
                } else {
                    self.armDeadline(for: current)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        handoffDeadlineTimer = timer
    }

    private func stopHandoffDeadlineTimer() {
        handoffDeadlineTimer?.invalidate()
        handoffDeadlineTimer = nil
        armedDeadline = nil
    }

    private func finishAttempt() {
        activeHandoffIdentity = nil
        stopStartFallbackTimer()
        stopRecordingMeter()
        stopHandoffDeadlineTimer()
        displayedAudioLevel = 0
        displayedFrequencyBands = Array(repeating: 0.0, count: 10)
        statusMessageToken = UUID()
        statusLabel?.text = ""
        statusLabel?.isHidden = true
        statusLabel?.textColor = UIColor.label
        setHandoffPhase(nil, animated: true)
    }

    private func presentIdleOutcome(
        _ failure: KeyboardDictationHandoff.KeyboardChromeFailure,
        userMessage: String
    ) {
        finishAttempt()
        switch KeyboardDictationHandoff.chromePresentation(for: failure, userMessage: userMessage) {
        case .silentIdle:
            DebugLog.info("keyboard chrome silent failure=\(failure.rawValue)", context: "KEYBOARD_DIAG")
            KeyboardDictationHandoff.appendDiagnostic("keyboard chrome silent failure=\(failure.rawValue)")
        case .operational(let message):
            showOperationalStatus(message)
        }
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
        let timer = Timer(timeInterval: KeyboardDictationHandoff.pollingInterval, repeats: true) { [weak self] _ in
            self?.checkForPendingDictationText()
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingTextTimer = timer
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
        let identityDescription = activeHandoffIdentity.map {
            "sessionID=\($0.sessionID) attemptID=\($0.attemptID) generation=\($0.generation)"
        } ?? "no active attempt"
        DebugLog.info("start meter polling \(identityDescription)", context: "KEYBOARD_DIAG")
        KeyboardDictationHandoff.appendDiagnostic("start meter polling \(identityDescription)")
        pollRecordingMeter()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollRecordingMeter()
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingMeterTimer = timer
    }

    private func pollRecordingMeter() {
        guard handoffPhase == .recording,
              let identity = activeHandoffIdentity,
              let meter = KeyboardDictationHandoff.consumeMeter(for: identity)
        else {
            return
        }
        stopStartFallbackTimer()
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
