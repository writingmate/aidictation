import AppKit
import WhisperMateShared
internal import Combine

/// Manages global hotkey registration and event handling
class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    // MARK: - Published Properties

    @Published var currentHotkey: Hotkey? {
        didSet { syncResolvers() }
    }

    @Published var commandHotkey: Hotkey? {
        didSet { syncResolvers() }
    }
    @Published var isPushToTalk: Bool {
        didSet {
            AppDefaults.shared.set(isPushToTalk, forKey: Keys.pushToTalk)
            syncResolvers()
        }
    }

    // MARK: - Public Callbacks

    var onHotkeyPressed: (() -> Void)?
    var onHotkeyReleased: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onCommandHotkeyPressed: (() -> Void)?
    var onCommandHotkeyReleased: (() -> Void)?

    // MARK: - Private Properties

    private enum Keys {
        static let hotkeyKeycode = "hotkey_keycode"
        static let hotkeyModifiers = "hotkey_modifiers"
        static let hotkeyMouseButton = "hotkey_mouse_button"
        static let commandHotkeyKeycode = "command_hotkey_keycode"
        static let commandHotkeyModifiers = "command_hotkey_modifiers"
        static let commandHotkeyMouseButton = "command_hotkey_mouse_button"
        static let pushToTalk = "pushToTalk"
    }

    private enum Constants {
        static let doubleTapInterval: TimeInterval = 0.3 // 300ms
        static let eventTapHealthInterval: TimeInterval = 5.0
        // Command mode has not been shipped publicly yet. Keep any saved value
        // untouched, but do not register it until the feature is enabled.
        static let commandHotkeyEnabled = false
    }

    private enum Diagnostics {
        static let functionKeyStateDefaultsKey = "com.apple.keyboard.fnState"
        static let trackedFunctionKeyCodes: Set<UInt16> = [96, 118] // F5, F4
        static let functionModifierRawValue = NSEvent.ModifierFlags.function.rawValue
    }

    private var functionKeyStateValue: Any {
        UserDefaults.standard.object(forKey: Diagnostics.functionKeyStateDefaultsKey) ?? "nil"
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyUpMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var previousFunctionKeyState = false
    private var fnKeyMonitor: FnKeyMonitor?
    private var deferRegistration = false
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var flagsMonitor: Any?
    private var screenWakeObserver: NSObjectProtocol?
    private var systemWakeObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var eventTapHealthTimer: Timer?
    private var accessibilityRetryScheduled = false
    private var accessibilityRetryAttempts = 0

    // All press/release/double-tap/toggle state lives in these two resolvers, one
    // per channel. See HotkeyGestureResolver — it is covered by unit tests, this
    // class is only the event-tap plumbing around it.
    private var dictationResolver = HotkeyGestureResolver(supportsDoubleTap: true)
    private var commandResolver = HotkeyGestureResolver(supportsDoubleTap: false)

    // MARK: - Initialization

    private init() {
        // Load push-to-talk setting (default true)
        isPushToTalk = AppDefaults.shared.object(forKey: Keys.pushToTalk) as? Bool ?? true
        DebugLog.info("HotkeyManager init - loading hotkeys", context: "HotkeyManager LOG")
        loadHotkey()
        loadCommandHotkey()
        syncResolvers()
        DebugLog.info("HotkeyManager init complete - dictation=\(currentHotkey?.displayString ?? "none"), command=\(commandHotkey?.displayString ?? "none")", context: "HotkeyManager LOG")

        // Re-register hotkeys after system wake from sleep/hibernation.
        // macOS can invalidate CGEvent taps during hibernation, so we need to
        // tear down and recreate them on wake.
        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleHotkeyReregistrationAfterWake(reason: "screens did wake")
        }

        systemWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleHotkeyReregistrationAfterWake(reason: "system did wake")
        }

        // Granting Accessibility happens in System Settings, so the app is
        // inactive while it happens and comes back active right after. The
        // short retry poll only covers the first seconds after launch; without
        // this the hotkey would stay dead until the next launch.
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reregisterFnHotkeyIfAccessibilityRecovered()
        }
    }

    /// Re-arms the Fn monitor once Accessibility comes back, so a grant made
    /// after launch takes effect without restarting the app.
    private func reregisterFnHotkeyIfAccessibilityRecovered() {
        guard let hotkey = currentHotkey, isFnOnlyHotkey(hotkey), !deferRegistration else { return }
        guard AXIsProcessTrusted(), fnKeyMonitor?.consumePureFnEvents == false else { return }

        DebugLog.info(
            "Accessibility permission restored while the app was away; re-registering Fn hotkey",
            context: "HotkeyManager LOG"
        )
        accessibilityRetryScheduled = false
        accessibilityRetryAttempts = 0
        registerHotkey()
    }

    // MARK: - Public API

    func setDeferRegistration(_ shouldDefer: Bool) {
        DebugLog.info("setDeferRegistration(\(shouldDefer)) - currentHotkey=\(currentHotkey?.displayString ?? "nil")", context: "HotkeyManager LOG")
        deferRegistration = shouldDefer
        if shouldDefer {
            // Unregister hotkey so the event tap doesn't consume events
            // (e.g., during onboarding, FnKeyMonitor needs to see fn key events)
            DebugLog.info("setDeferRegistration: Calling unregisterHotkey()", context: "HotkeyManager LOG")
            unregisterHotkey()
        } else if currentHotkey != nil || commandHotkey != nil {
            // Registration was deferred but now enabled - register the hotkey
            DebugLog.info("setDeferRegistration: Calling registerHotkey()", context: "HotkeyManager LOG")
            registerHotkey()
        }
    }

    func setHotkey(_ hotkey: Hotkey) {
        currentHotkey = hotkey
        saveHotkey()

        if Diagnostics.trackedFunctionKeyCodes.contains(hotkey.keyCode) {
            logFunctionKeyDiagnostic(
                "Configured dictation hotkey=\(hotkey.displayString) keyCode=\(hotkey.keyCode) modifiers=\(hotkey.modifiers.rawValue) fnState=\(functionKeyStateValue)"
            )
        }

        // Only register if not deferred
        if !deferRegistration {
            registerHotkey()
        }
    }

    func clearHotkey() {
        currentHotkey = nil
        AppDefaults.shared.removeObject(forKey: Keys.hotkeyKeycode)
        AppDefaults.shared.removeObject(forKey: Keys.hotkeyModifiers)
        AppDefaults.shared.removeObject(forKey: Keys.hotkeyMouseButton)
        unregisterHotkey()
    }

    /// Temporarily suppress Fn key detection (call after paste to avoid spurious events from Cmd+V)
    func suppressFnKeyDetection() {
        fnKeyMonitor?.suppressTemporarily()
    }

    func setCommandHotkey(_ hotkey: Hotkey) {
        guard Constants.commandHotkeyEnabled else {
            commandHotkey = nil
            DebugLog.info("setCommandHotkey: Command hotkey ignored because command mode is disabled", context: "HotkeyManager LOG")
            return
        }

        commandHotkey = hotkey
        saveCommandHotkey()

        // Re-register hotkeys to include both
        if !deferRegistration {
            registerHotkey()
        }
    }

    func clearCommandHotkey() {
        commandHotkey = nil
        AppDefaults.shared.removeObject(forKey: Keys.commandHotkeyKeycode)
        AppDefaults.shared.removeObject(forKey: Keys.commandHotkeyModifiers)
        AppDefaults.shared.removeObject(forKey: Keys.commandHotkeyMouseButton)
        // Re-register to update event tap
        if !deferRegistration {
            registerHotkey()
        }
    }

    // MARK: - Private Methods

    private func loadHotkey() {
        // Check for mouse button hotkey first
        if let mouseButton = AppDefaults.shared.value(forKey: Keys.hotkeyMouseButton) as? Int32 {
            currentHotkey = Hotkey(keyCode: 0, modifiers: [], mouseButton: mouseButton)
            registerHotkey()
            return
        }

        // Load keyboard hotkey
        guard let keyCode = AppDefaults.shared.value(forKey: Keys.hotkeyKeycode) as? UInt16,
              let modifiers = AppDefaults.shared.value(forKey: Keys.hotkeyModifiers) as? UInt
        else {
            return
        }

        currentHotkey = Hotkey(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers))
        registerHotkey()
    }

    private func saveHotkey() {
        guard let hotkey = currentHotkey else { return }

        if let mouseButton = hotkey.mouseButton {
            // Save mouse button hotkey
            AppDefaults.shared.set(mouseButton, forKey: Keys.hotkeyMouseButton)
            AppDefaults.shared.removeObject(forKey: Keys.hotkeyKeycode)
            AppDefaults.shared.removeObject(forKey: Keys.hotkeyModifiers)
        } else {
            // Save keyboard hotkey
            AppDefaults.shared.set(hotkey.keyCode, forKey: Keys.hotkeyKeycode)
            AppDefaults.shared.set(hotkey.modifiers.rawValue, forKey: Keys.hotkeyModifiers)
            AppDefaults.shared.removeObject(forKey: Keys.hotkeyMouseButton)
        }
    }

    private func loadCommandHotkey() {
        DebugLog.info("loadCommandHotkey: Loading command hotkey from UserDefaults", context: "HotkeyManager LOG")

        guard Constants.commandHotkeyEnabled else {
            commandHotkey = nil
            DebugLog.info("loadCommandHotkey: Command hotkey disabled; skipping saved/default command shortcut", context: "HotkeyManager LOG")
            return
        }

        // Check for mouse button hotkey first
        if let mouseButton = AppDefaults.shared.value(forKey: Keys.commandHotkeyMouseButton) as? Int32 {
            commandHotkey = Hotkey(keyCode: 0, modifiers: [], mouseButton: mouseButton)
            DebugLog.info("loadCommandHotkey: Loaded mouse button \(mouseButton)", context: "HotkeyManager LOG")
            return
        }

        // Load keyboard hotkey
        if let keyCode = AppDefaults.shared.value(forKey: Keys.commandHotkeyKeycode) as? UInt16,
           let modifiers = AppDefaults.shared.value(forKey: Keys.commandHotkeyModifiers) as? UInt
        {
            commandHotkey = Hotkey(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers))
            DebugLog.info("loadCommandHotkey: Loaded keyCode=\(keyCode), modifiers=\(modifiers)", context: "HotkeyManager LOG")
            return
        }

        commandHotkey = nil
        DebugLog.info("loadCommandHotkey: No command hotkey configured", context: "HotkeyManager LOG")
    }

    private func saveCommandHotkey() {
        guard let hotkey = commandHotkey else { return }

        if let mouseButton = hotkey.mouseButton {
            // Save mouse button hotkey
            AppDefaults.shared.set(mouseButton, forKey: Keys.commandHotkeyMouseButton)
            AppDefaults.shared.removeObject(forKey: Keys.commandHotkeyKeycode)
            AppDefaults.shared.removeObject(forKey: Keys.commandHotkeyModifiers)
        } else {
            // Save keyboard hotkey
            AppDefaults.shared.set(hotkey.keyCode, forKey: Keys.commandHotkeyKeycode)
            AppDefaults.shared.set(hotkey.modifiers.rawValue, forKey: Keys.commandHotkeyModifiers)
            AppDefaults.shared.removeObject(forKey: Keys.commandHotkeyMouseButton)
        }
    }

    private func registerHotkey() {
        // Always unregister first to ensure clean state
        unregisterHotkey()

        // Check what hotkeys are configured
        let dictationHotkey = currentHotkey
        let cmdHotkey = commandHotkey

        // If no hotkeys configured, nothing to do
        guard dictationHotkey != nil || cmdHotkey != nil else {
            DebugLog.info("registerHotkey: No hotkeys configured", context: "HotkeyManager LOG")
            return
        }

        DebugLog.info("registerHotkey: dictation=\(dictationHotkey?.displayString ?? "none"), command=\(cmdHotkey?.displayString ?? "none")", context: "HotkeyManager LOG")

        // Determine which event monitoring to use based on configured hotkeys.
        // Fn/Globe alone is special: on several macOS/keyboard combinations it
        // does not behave like a normal key and is more reliably handled through
        // the dedicated flags monitor used by onboarding.
        let needsDictationFnMonitor = dictationHotkey.map(isFnOnlyHotkey) ?? false
        let needsMouseTap = (dictationHotkey?.isMouseButton == true) || (cmdHotkey?.isMouseButton == true)
        let needsKeyTap = (dictationHotkey != nil && dictationHotkey?.isMouseButton != true && !needsDictationFnMonitor) ||
            (cmdHotkey != nil && cmdHotkey?.isMouseButton != true)

        if let dictationHotkey, Diagnostics.trackedFunctionKeyCodes.contains(dictationHotkey.keyCode) {
            logFunctionKeyDiagnostic(
                "registerHotkey for \(dictationHotkey.displayString) keyCode=\(dictationHotkey.keyCode) modifiers=\(dictationHotkey.modifiers.rawValue) needsKeyTap=\(needsKeyTap) needsMouseTap=\(needsMouseTap) AXTrusted=\(AXIsProcessTrusted())",
            )
        }

        // Setup mouse event tap if needed
        if needsMouseTap {
            DebugLog.info("========================================", context: "HotkeyManager LOG")
            DebugLog.info("Using mouse button path with CGEventTap", context: "HotkeyManager LOG")
            DebugLog.info("========================================", context: "HotkeyManager LOG")
            setupMouseEventTap()
        }

        if needsDictationFnMonitor {
            setupFnOnlyMonitor()
        }

        // Setup keyboard event tap if needed
        if needsKeyTap {
            DebugLog.info("Using regular key path with CGEventTap for global consumption", context: "HotkeyManager LOG")
            setupEventTap()
        }

        setupSystemDefinedDiagnosticsIfNeeded(dictationHotkey: dictationHotkey)
    }

    private func logFunctionKeyDiagnostic(_ message: String) {
        DebugLog.info(message, context: "HotkeyDiagnostics")
    }

    private func setupFnOnlyMonitor() {
        DebugLog.info("Using dedicated Fn-only monitor for dictation hotkey", context: "HotkeyManager LOG")

        fnKeyMonitor = FnKeyMonitor()
        fnKeyMonitor?.onFnPressed = { [weak self] in
            guard let self else { return }
            DebugLog.info("Fn-only dictation pressed", context: "HotkeyManager LOG")
            self.handleModifierFlagsStateChange(isModifierPressed: true, isDictation: true)
        }
        fnKeyMonitor?.onFnReleased = { [weak self] in
            guard let self else { return }
            DebugLog.info("Fn-only dictation released", context: "HotkeyManager LOG")
            self.handleModifierFlagsStateChange(isModifierPressed: false, isDictation: true)
        }

        // Check silently. Registering the hotkey happens on launch, so prompting
        // here threw the system Accessibility dialog at anyone who had finished
        // onboarding and later lost the grant — unprompted, before they touched
        // anything. The poller below still notices the moment permission comes
        // back, and Settings › Permissions is where the user asks for the dialog.
        let accessibilityTrusted = AXIsProcessTrusted()
        if !accessibilityTrusted {
            DebugLog.info(
                "Fn dictation hotkey needs Accessibility permission; waiting for the user to grant it",
                context: "HotkeyManager LOG"
            )
            scheduleAccessibilityRetryForFnHotkey()
        } else {
            accessibilityRetryScheduled = false
            accessibilityRetryAttempts = 0
        }

        fnKeyMonitor?.startMonitoring(consumePureFnEvents: accessibilityTrusted)
    }

    private func scheduleAccessibilityRetryForFnHotkey() {
        guard !accessibilityRetryScheduled else { return }

        accessibilityRetryScheduled = true
        accessibilityRetryAttempts = 0
        pollAccessibilityForFnHotkey()
    }

    private func pollAccessibilityForFnHotkey() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard self.accessibilityRetryScheduled else { return }
            guard let currentHotkey = self.currentHotkey, self.isFnOnlyHotkey(currentHotkey), !self.deferRegistration else {
                self.accessibilityRetryScheduled = false
                self.accessibilityRetryAttempts = 0
                return
            }

            if AXIsProcessTrusted() {
                DebugLog.info("Accessibility permission granted; re-registering Fn hotkey", context: "HotkeyManager LOG")
                self.accessibilityRetryScheduled = false
                self.accessibilityRetryAttempts = 0
                self.registerHotkey()
                return
            }

            self.accessibilityRetryAttempts += 1
            if self.accessibilityRetryAttempts < 30 {
                self.pollAccessibilityForFnHotkey()
            } else {
                DebugLog.info("Accessibility permission still missing; Fn hotkey remains inactive", context: "HotkeyManager LOG")
                self.accessibilityRetryScheduled = false
                self.accessibilityRetryAttempts = 0
            }
        }
    }

    private func setupEventTap() {
        // Create event tap that intercepts key events AND flagsChanged (for modifier-only hotkeys like Control)
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        DebugLog.info("setupEventTap: Creating event tap with keyDown, keyUp, and flagsChanged", context: "HotkeyManager LOG")

        // Capture self in the callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                return manager.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            DebugLog.info("Failed to create event tap - accessibility permission may not be granted", context: "HotkeyManager LOG")
            return
        }

        eventTap = tap
        eventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), eventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startEventTapHealthTimer()

        DebugLog.info("Event tap created and enabled (includes flagsChanged for modifier keys)", context: "HotkeyManager LOG")
    }

    private func setupMouseEventTap() {
        // Create event tap for mouse button events (otherMouseDown/Up covers middle and side buttons)
        let eventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                return manager.handleMouseEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            DebugLog.info("Failed to create mouse event tap - accessibility permission may not be granted", context: "HotkeyManager LOG")
            return
        }

        eventTap = tap
        eventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), eventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startEventTapHealthTimer()

        DebugLog.info("Mouse event tap created and enabled", context: "HotkeyManager LOG")
    }

    private func scheduleHotkeyReregistrationAfterWake(reason: String) {
        DebugLog.info("Wake notification (\(reason)) - scheduling hotkey re-registration", context: "HotkeyManager LOG")
        guard !deferRegistration, currentHotkey != nil || commandHotkey != nil else { return }

        // Small delay to let macOS finish rebuilding input devices/event taps after wake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard !self.deferRegistration, self.currentHotkey != nil || self.commandHotkey != nil else { return }
            self.registerHotkey()
        }
    }

    private func startEventTapHealthTimer() {
        stopEventTapHealthTimer()

        let timer = Timer(timeInterval: Constants.eventTapHealthInterval, repeats: true) { [weak self] _ in
            self?.validateEventTapHealth()
        }
        eventTapHealthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopEventTapHealthTimer() {
        eventTapHealthTimer?.invalidate()
        eventTapHealthTimer = nil
    }

    private func validateEventTapHealth() {
        guard let tap = eventTap else { return }

        if !CGEvent.tapIsEnabled(tap: tap) {
            enableEventTap(reason: "health check")
        }
    }

    private func enableEventTap(reason: String) {
        guard let tap = eventTap else { return }

        previousFunctionKeyState = false
        releaseHeldHotkeys(reason: reason)
        CGEvent.tapEnable(tap: tap, enable: true)
        logFunctionKeyDiagnostic("Re-enabled hotkey event tap after \(reason)")
    }

    /// Ends any push-to-talk hold that was in flight when the tap went away.
    /// macOS disables a tap on timeout or on user input, and the key-up that would
    /// have stopped the recording is delivered to nobody, so we have to synthesize
    /// it — otherwise dictation runs until the app is restarted.
    private func releaseHeldHotkeys(reason: String) {
        for isDictation in [true, false] {
            var resolver = isDictation ? dictationResolver : commandResolver
            let outcome = resolver.interrupt()
            store(resolver, isDictation: isDictation)

            if !outcome.actions.isEmpty {
                DebugLog.info(
                    "Releasing held \(isDictation ? "dictation" : "command") hotkey after \(reason)",
                    context: "HotkeyManager LOG"
                )
                apply(outcome, isDictation: isDictation)
            }
        }
    }

    // MARK: - Resolver plumbing

    /// Monotonic clock, so gesture timing is unaffected by the wall clock moving.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Pushes the current hotkeys and mode into the resolvers. Called whenever any
    /// of them changes, so the resolvers are always the single source of truth.
    private func syncResolvers() {
        dictationResolver.binding = currentHotkey.map(HotkeyGestureResolver.Binding.init)
        dictationResolver.isPushToTalk = isPushToTalk
        commandResolver.binding = commandHotkey.map(HotkeyGestureResolver.Binding.init)
        commandResolver.isPushToTalk = isPushToTalk
    }

    private func store(_ resolver: HotkeyGestureResolver, isDictation: Bool) {
        if isDictation {
            dictationResolver = resolver
        } else {
            commandResolver = resolver
        }
    }

    /// Offers an event to the dictation channel, then the command channel, stopping
    /// at whichever consumes it.
    private func dispatch(
        _ resolve: (inout HotkeyGestureResolver) -> HotkeyGestureResolver.Outcome
    ) -> Bool {
        for isDictation in [true, false] {
            var resolver = isDictation ? dictationResolver : commandResolver
            let outcome = resolve(&resolver)
            store(resolver, isDictation: isDictation)
            apply(outcome, isDictation: isDictation)

            if outcome.handled {
                return true
            }
        }

        return false
    }

    private func apply(_ outcome: HotkeyGestureResolver.Outcome, isDictation: Bool) {
        for action in outcome.actions {
            DebugLog.info(
                "\(isDictation ? "Dictation" : "Command") hotkey \(action)",
                context: "HotkeyManager LOG"
            )

            switch (action, isDictation) {
            case (.pressed, true): onHotkeyPressed?()
            case (.released, true): onHotkeyReleased?()
            case (.doubleTap, true): onDoubleTap?()
            case (.pressed, false): onCommandHotkeyPressed?()
            case (.released, false): onCommandHotkeyReleased?()
            case (.doubleTap, false): break
            }
        }
    }

    private func setupSystemDefinedDiagnosticsIfNeeded(dictationHotkey: Hotkey?) {
        guard let dictationHotkey, Diagnostics.trackedFunctionKeyCodes.contains(dictationHotkey.keyCode) else {
            return
        }

        logFunctionKeyDiagnostic("Enabling systemDefined diagnostics monitor for function-key hotkey")

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.logSystemDefinedEvent(event, source: "global")
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.logSystemDefinedEvent(event, source: "local")
            return event
        }
    }

    private func logSystemDefinedEvent(_ event: NSEvent, source: String) {
        guard event.type == .systemDefined else { return }
        let data1 = UInt32(bitPattern: Int32(event.data1))
        let mediaKeyCode = Int((data1 & 0xFFFF0000) >> 16)
        let mediaFlags = Int(data1 & 0x0000FFFF)
        let mediaState = (mediaFlags & 0xFF00) >> 8
        let isDown = mediaState == 0xA
        let isUp = mediaState == 0xB
        logFunctionKeyDiagnostic(
            "systemDefined[\(source)] subtype=\(event.subtype.rawValue) mediaKeyCode=\(mediaKeyCode) mediaFlags=0x\(String(mediaFlags, radix: 16)) isDown=\(isDown) isUp=\(isUp) data1=0x\(String(data1, radix: 16))",
        )
    }

    private func handleMouseEvent(proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

        // Check if this matches dictation hotkey
        if let hotkey = currentHotkey, let targetButton = hotkey.mouseButton, buttonNumber == Int64(targetButton) {
            return handleMouseButtonEvent(type: type, buttonNumber: buttonNumber, isDictation: true)
        }

        // Check if this matches command hotkey
        if let cmdHotkey = commandHotkey, let targetButton = cmdHotkey.mouseButton, buttonNumber == Int64(targetButton) {
            return handleMouseButtonEvent(type: type, buttonNumber: buttonNumber, isDictation: false)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleMouseButtonEvent(type: CGEventType, buttonNumber: Int64, isDictation: Bool) -> Unmanaged<CGEvent>? {
        let button = Int32(buttonNumber)
        var resolver = isDictation ? dictationResolver : commandResolver
        let outcome = type == .otherMouseDown
            ? resolver.mouseDown(button: button, at: now)
            : resolver.mouseUp(button: button, at: now)
        store(resolver, isDictation: isDictation)
        apply(outcome, isDictation: isDictation)

        return nil // Consume the event
    }


    private func handleCGEvent(proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            enableEventTap(reason: "callback disabled event \(type.rawValue)")
            return Unmanaged.passUnretained(event)
        }

        // Check if we have any keyboard hotkey configured
        let hasDictationKey = currentHotkey != nil && currentHotkey?.isMouseButton != true
        let hasCommandKey = commandHotkey != nil && commandHotkey?.isMouseButton != true
        guard hasDictationKey || hasCommandKey else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            // Create NSEvent for compatibility with existing handler
            if let nsEvent = NSEvent(cgEvent: event) {
                if shouldLogFunctionDiagnostics(for: nsEvent) {
                    logFunctionKeyDiagnostic(
                        "Observed keyDown keyCode=\(nsEvent.keyCode) key=\(KeyCodeHelper.string(for: nsEvent.keyCode) ?? "?") modifiers=\(nsEvent.modifierFlags.rawValue) repeat=\(nsEvent.isARepeat)",
                    )
                }
                let shouldConsume = handleKeyDownEvent(nsEvent)
                if shouldLogFunctionDiagnostics(for: nsEvent) {
                    logFunctionKeyDiagnostic("keyDown consume=\(shouldConsume)")
                }
                if shouldConsume {
                    return nil // Consume the event
                }
            }
        } else if type == .keyUp {
            // Create NSEvent for compatibility with existing handler
            if let nsEvent = NSEvent(cgEvent: event) {
                if shouldLogFunctionDiagnostics(for: nsEvent) {
                    logFunctionKeyDiagnostic(
                        "Observed keyUp keyCode=\(nsEvent.keyCode) key=\(KeyCodeHelper.string(for: nsEvent.keyCode) ?? "?") modifiers=\(nsEvent.modifierFlags.rawValue)",
                    )
                }
                let shouldConsume = handleKeyUpEvent(nsEvent)
                if shouldLogFunctionDiagnostics(for: nsEvent) {
                    logFunctionKeyDiagnostic("keyUp consume=\(shouldConsume)")
                }
                if shouldConsume {
                    return nil // Consume the event
                }
            }
        } else if type == .flagsChanged {
            // Handle modifier-only hotkeys (like Control key alone)
            if let nsEvent = NSEvent(cgEvent: event) {
                let shouldConsume = handleFlagsChangedEvent(nsEvent)
                if shouldConsume {
                    return nil // Consume the event
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Handle modifier key press/release (flagsChanged events)
    @discardableResult
    private func handleFlagsChangedEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return dispatch { resolver in
            resolver.flagsChanged(keyCode: event.keyCode, modifiers: modifiers, at: self.now)
        }
    }


    private func unregisterHotkey() {
        DebugLog.info("unregisterHotkey called", context: "HotkeyManager LOG")

        stopEventTapHealthTimer()

        // Disable and remove event tap
        if let tap = eventTap {
            DebugLog.info("Disabling event tap", context: "HotkeyManager LOG")
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventTapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                eventTapRunLoopSource = nil
            }
            eventTap = nil
        }

        if let monitor = globalMonitor {
            DebugLog.info("Removing global monitor", context: "HotkeyManager LOG")
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        if let monitor = localMonitor {
            DebugLog.info("Removing local monitor", context: "HotkeyManager LOG")
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        if let monitor = globalKeyUpMonitor {
            DebugLog.info("Removing global keyUp monitor", context: "HotkeyManager LOG")
            NSEvent.removeMonitor(monitor)
            globalKeyUpMonitor = nil
        }

        if let monitor = keyUpMonitor {
            DebugLog.info("Removing keyUp monitor", context: "HotkeyManager LOG")
            NSEvent.removeMonitor(monitor)
            keyUpMonitor = nil
        }

        if let fnMonitor = fnKeyMonitor {
            DebugLog.info("Stopping Fn key monitor", context: "HotkeyManager LOG")
            fnMonitor.stopMonitoring()
            fnKeyMonitor = nil
        }

        previousFunctionKeyState = false
    }

    @discardableResult
    private func handleKeyDownEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return dispatch { resolver in
            resolver.keyDown(
                keyCode: event.keyCode,
                modifiers: modifiers,
                isARepeat: event.isARepeat,
                at: self.now
            )
        }
    }


    @discardableResult
    private func handleKeyUpEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return dispatch { resolver in
            resolver.keyUp(keyCode: event.keyCode, modifiers: modifiers, at: self.now)
        }
    }


    private func isModifierOnlyHotkey(_ hotkey: Hotkey) -> Bool {
        HotkeyGestureResolver.Binding(hotkey).isModifierOnly
    }

    private func isFnOnlyHotkey(_ hotkey: Hotkey) -> Bool {
        hotkey.modifiers == .function && (hotkey.keyCode == 63 || hotkey.keyCode == 179)
    }

    private func shouldLogFunctionDiagnostics(for event: NSEvent) -> Bool {
        guard let dictationHotkey = currentHotkey, Diagnostics.trackedFunctionKeyCodes.contains(dictationHotkey.keyCode) else {
            return false
        }

        if Diagnostics.trackedFunctionKeyCodes.contains(event.keyCode) {
            return true
        }

        let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if eventModifiers.contains(.function) {
            return true
        }

        return event.keyCode == dictationHotkey.keyCode
    }


    @discardableResult
    private func handleModifierFlagsStateChange(isModifierPressed: Bool, isDictation: Bool) -> Bool {
        // Kept for the Fn-only monitor, which reports an already-decoded press/release.
        var resolver = isDictation ? dictationResolver : commandResolver
        let outcome = isModifierPressed ? resolver.forcePress(at: now) : resolver.forceRelease()
        store(resolver, isDictation: isDictation)
        apply(outcome, isDictation: isDictation)
        return outcome.handled
    }


    deinit {
        unregisterHotkey()
        if let screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenWakeObserver)
        }
        if let systemWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(systemWakeObserver)
        }
    }
}

struct Hotkey: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let mouseButton: Int32? // nil for keyboard, 2=middle, 3=side1, 4=side2

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, mouseButton: Int32? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mouseButton = mouseButton
    }

    var isMouseButton: Bool {
        mouseButton != nil
    }

    var displayString: String {
        // Mouse button hotkey
        if let button = mouseButton {
            switch button {
            case 2: return "🖱️ Middle Click"
            case 3: return "🖱️ Side Button 1"
            case 4: return "🖱️ Side Button 2"
            default: return "🖱️ Button \(button)"
            }
        }

        // Special case: just Fn key alone
        if modifiers == .function && (keyCode == 63 || keyCode == 179) {
            return "Fn"
        }

        var parts: [String] = []

        if modifiers.contains(.function) {
            parts.append("Fn")
        }
        if modifiers.contains(.control) {
            parts.append("⌃")
        }
        if modifiers.contains(.option) {
            parts.append("⌥")
        }
        if modifiers.contains(.shift) {
            parts.append("⇧")
        }
        if modifiers.contains(.command) {
            parts.append("⌘")
        }

        if let keyString = KeyCodeHelper.string(for: keyCode) {
            parts.append(keyString)
        }

        return parts.joined()
    }
}

extension HotkeyGestureResolver.Binding {
    init(_ hotkey: Hotkey) {
        self.init(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers, mouseButton: hotkey.mouseButton)
    }
}

class KeyCodeHelper {
    static func string(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Escape"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 179: return "Fn"
        default: return nil
        }
    }
}
