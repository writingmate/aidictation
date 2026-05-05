import AppKit
import WhisperMateShared
internal import Combine

/// Manages global hotkey registration and event handling
class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    // MARK: - Published Properties

    @Published var currentHotkey: Hotkey?
    @Published var commandHotkey: Hotkey?
    @Published var isPushToTalk: Bool {
        didSet {
            AppDefaults.shared.set(isPushToTalk, forKey: Keys.pushToTalk)
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
        // Command mode has not been shipped publicly yet. Keep any saved value
        // untouched, but do not register it until the feature is enabled.
        static let commandHotkeyEnabled = false
    }

    private enum Diagnostics {
        static let functionKeyStateDefaultsKey = "com.apple.keyboard.fnState"
        static let trackedFunctionKeyCodes: Set<UInt16> = [96, 118] // F5, F4
        static let functionModifierRawValue = NSEvent.ModifierFlags.function.rawValue
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
    private var wakeObserver: NSObjectProtocol?

    // Double-tap detection
    private var lastTapTime: Date?
    private var isHoldingKey = false
    private var isHoldingCommandKey = false

    // Toggle mode state (for non-push-to-talk)
    private var isToggleRecording = false
    private var isCommandToggleRecording = false

    // MARK: - Initialization

    private init() {
        // Load push-to-talk setting (default true)
        isPushToTalk = AppDefaults.shared.object(forKey: Keys.pushToTalk) as? Bool ?? true
        DebugLog.info("HotkeyManager init - loading hotkeys", context: "HotkeyManager LOG")
        loadHotkey()
        loadCommandHotkey()
        DebugLog.info("HotkeyManager init complete - dictation=\(currentHotkey?.displayString ?? "none"), command=\(commandHotkey?.displayString ?? "none")", context: "HotkeyManager LOG")

        // Re-register hotkeys after system wake from sleep/hibernation.
        // macOS can invalidate CGEvent taps during hibernation, so we need to
        // tear down and recreate them on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DebugLog.info("System woke from sleep - re-registering hotkeys", context: "HotkeyManager LOG")
            if !self.deferRegistration, self.currentHotkey != nil || self.commandHotkey != nil {
                // Small delay to let the system stabilize after wake
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.registerHotkey()
                }
            }
        }
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
            let fnStateValue = UserDefaults.standard.object(forKey: Diagnostics.functionKeyStateDefaultsKey) ?? "nil"
            DebugLog.error(
                "Configured dictation hotkey=\(hotkey.displayString) keyCode=\(hotkey.keyCode) modifiers=\(hotkey.modifiers.rawValue) fnState=\(fnStateValue)",
                context: "HotkeyDiagnostics"
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

        // Determine which event monitoring to use based on configured hotkeys
        let needsMouseTap = (dictationHotkey?.isMouseButton == true) || (cmdHotkey?.isMouseButton == true)
        let needsKeyTap = (dictationHotkey != nil && dictationHotkey?.isMouseButton != true) ||
            (cmdHotkey != nil && cmdHotkey?.isMouseButton != true)

        if let dictationHotkey, Diagnostics.trackedFunctionKeyCodes.contains(dictationHotkey.keyCode) {
            DebugLog.error(
                "registerHotkey for \(dictationHotkey.displayString) keyCode=\(dictationHotkey.keyCode) modifiers=\(dictationHotkey.modifiers.rawValue) needsKeyTap=\(needsKeyTap) needsMouseTap=\(needsMouseTap) AXTrusted=\(AXIsProcessTrusted())",
                context: "HotkeyDiagnostics"
            )
        }

        // Setup mouse event tap if needed
        if needsMouseTap {
            DebugLog.info("========================================", context: "HotkeyManager LOG")
            DebugLog.info("Using mouse button path with CGEventTap", context: "HotkeyManager LOG")
            DebugLog.info("========================================", context: "HotkeyManager LOG")
            setupMouseEventTap()
        }

        // Setup keyboard event tap if needed
        if needsKeyTap {
            DebugLog.info("Using regular key path with CGEventTap for global consumption", context: "HotkeyManager LOG")
            setupEventTap()
        }

        setupSystemDefinedDiagnosticsIfNeeded(dictationHotkey: dictationHotkey)
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

        DebugLog.info("Mouse event tap created and enabled", context: "HotkeyManager LOG")
    }

    private func setupSystemDefinedDiagnosticsIfNeeded(dictationHotkey: Hotkey?) {
        guard let dictationHotkey, Diagnostics.trackedFunctionKeyCodes.contains(dictationHotkey.keyCode) else {
            return
        }

        DebugLog.error("Enabling systemDefined diagnostics monitor for function-key hotkey", context: "HotkeyDiagnostics")

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
        DebugLog.error(
            "systemDefined[\(source)] subtype=\(event.subtype.rawValue) mediaKeyCode=\(mediaKeyCode) mediaFlags=0x\(String(mediaFlags, radix: 16)) isDown=\(isDown) isUp=\(isUp) data1=0x\(String(data1, radix: 16))",
            context: "HotkeyDiagnostics"
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
        if type == .otherMouseDown {
            DebugLog.info("🖱️ Mouse button \(buttonNumber) pressed (isDictation=\(isDictation))", context: "HotkeyManager LOG")

            let now = Date()

            if isDictation {
                // Dictation hotkey - check for double-tap
                if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < Constants.doubleTapInterval {
                    DebugLog.info("🖱️ DOUBLE-TAP detected - calling onDoubleTap", context: "HotkeyManager LOG")
                    lastTapTime = nil
                    isHoldingKey = false
                    isToggleRecording = false
                    onDoubleTap?()
                    return nil
                }

                if isPushToTalk {
                    DebugLog.info("🖱️ Dictation Push-to-Talk - calling onHotkeyPressed", context: "HotkeyManager LOG")
                    lastTapTime = now
                    isHoldingKey = true
                    onHotkeyPressed?()
                } else {
                    DebugLog.info("🖱️ Dictation Toggle mode - isToggleRecording=\(isToggleRecording)", context: "HotkeyManager LOG")
                    lastTapTime = now
                    if isToggleRecording {
                        isToggleRecording = false
                        onHotkeyReleased?()
                    } else {
                        isToggleRecording = true
                        onHotkeyPressed?()
                    }
                }
            } else {
                // Command hotkey
                if isPushToTalk {
                    DebugLog.info("🖱️ Command Push-to-Talk - calling onCommandHotkeyPressed", context: "HotkeyManager LOG")
                    isHoldingCommandKey = true
                    onCommandHotkeyPressed?()
                } else {
                    DebugLog.info("🖱️ Command Toggle mode - isCommandToggleRecording=\(isCommandToggleRecording)", context: "HotkeyManager LOG")
                    if isCommandToggleRecording {
                        isCommandToggleRecording = false
                        onCommandHotkeyReleased?()
                    } else {
                        isCommandToggleRecording = true
                        onCommandHotkeyPressed?()
                    }
                }
            }
            return nil // Consume the event

        } else if type == .otherMouseUp {
            DebugLog.info("🖱️ Mouse button \(buttonNumber) released (isDictation=\(isDictation))", context: "HotkeyManager LOG")

            if isDictation {
                if isPushToTalk, isHoldingKey {
                    DebugLog.info("🖱️ Dictation Push-to-Talk - calling onHotkeyReleased", context: "HotkeyManager LOG")
                    isHoldingKey = false
                    onHotkeyReleased?()
                }
            } else {
                if isPushToTalk, isHoldingCommandKey {
                    DebugLog.info("🖱️ Command Push-to-Talk - calling onCommandHotkeyReleased", context: "HotkeyManager LOG")
                    isHoldingCommandKey = false
                    onCommandHotkeyReleased?()
                }
            }
            return nil // Consume the event
        }

        return nil
    }

    private func handleCGEvent(proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DebugLog.error("Event tap disabled (\(type.rawValue)); re-enabling", context: "HotkeyDiagnostics")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
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
                    DebugLog.error(
                        "Observed keyDown keyCode=\(nsEvent.keyCode) key=\(KeyCodeHelper.string(for: nsEvent.keyCode) ?? "?") modifiers=\(nsEvent.modifierFlags.rawValue) repeat=\(nsEvent.isARepeat)",
                        context: "HotkeyDiagnostics"
                    )
                }
                let shouldConsume = handleKeyDownEvent(nsEvent)
                if shouldLogFunctionDiagnostics(for: nsEvent) {
                    DebugLog.error("keyDown consume=\(shouldConsume)", context: "HotkeyDiagnostics")
                }
                if shouldConsume {
                    return nil // Consume the event
                }
            }
        } else if type == .keyUp {
            // Create NSEvent for compatibility with existing handler
            if let nsEvent = NSEvent(cgEvent: event) {
                if shouldLogFunctionDiagnostics(for: nsEvent) {
                    DebugLog.error(
                        "Observed keyUp keyCode=\(nsEvent.keyCode) key=\(KeyCodeHelper.string(for: nsEvent.keyCode) ?? "?") modifiers=\(nsEvent.modifierFlags.rawValue)",
                        context: "HotkeyDiagnostics"
                    )
                }
                let shouldConsume = handleKeyUpEvent(nsEvent)
                if shouldLogFunctionDiagnostics(for: nsEvent) {
                    DebugLog.error("keyUp consume=\(shouldConsume)", context: "HotkeyDiagnostics")
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
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var handled = false

        // Check dictation hotkey for modifier-only keys (Fn, Control, Command, etc.)
        if let hotkey = currentHotkey, !hotkey.isMouseButton, isModifierOnlyHotkey(hotkey), flagsChangedKeyMatchesHotkey(eventKeyCode: keyCode, hotkey: hotkey) {
            let isModifierPressed = isRequiredModifierPressed(for: hotkey, eventModifiers: modifiers)
            handled = handleModifierFlagsStateChange(isModifierPressed: isModifierPressed, isDictation: true) || handled
        }

        // Check command hotkey for modifier-only keys
        if !handled,
           let cmdHotkey = commandHotkey,
           !cmdHotkey.isMouseButton,
           isModifierOnlyHotkey(cmdHotkey),
           flagsChangedKeyMatchesHotkey(eventKeyCode: keyCode, hotkey: cmdHotkey)
        {
            let isModifierPressed = isRequiredModifierPressed(for: cmdHotkey, eventModifiers: modifiers)
            handled = handleModifierFlagsStateChange(isModifierPressed: isModifierPressed, isDictation: false) || handled
        }

        return handled
    }

    private func unregisterHotkey() {
        DebugLog.info("unregisterHotkey called", context: "HotkeyManager LOG")

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
        DebugLog.info("handleKeyDownEvent: keyCode=\(event.keyCode), modifiers=\(event.modifierFlags.rawValue), isARepeat=\(event.isARepeat)", context: "HotkeyManager LOG")

        // Check dictation hotkey first
        if let hotkey = currentHotkey, !hotkey.isMouseButton {
            if checkKeyDownMatch(event: event, hotkey: hotkey, isDictation: true) {
                return true
            }
        }

        // Check command hotkey
        if let cmdHotkey = commandHotkey, !cmdHotkey.isMouseButton {
            if checkKeyDownMatch(event: event, hotkey: cmdHotkey, isDictation: false) {
                return true
            }
        }

        return false
    }

    /// Check if event matches hotkey and handle accordingly
    /// - Returns: true if event was consumed
    private func checkKeyDownMatch(event: NSEvent, hotkey: Hotkey, isDictation: Bool) -> Bool {
        // Modifier-only hotkeys are handled via flagsChanged to avoid duplicate triggers.
        if isModifierOnlyHotkey(hotkey) {
            return false
        }

        // Consume key repeat events to prevent typing sounds
        if event.isARepeat {
            DebugLog.info("handleKeyDownEvent: Ignoring key repeat event", context: "HotkeyManager LOG")
            return event.keyCode == hotkey.keyCode
        }

        // Check if the key code matches and required modifiers are present
        let rawEventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let eventModifiers = normalizedEventModifiers(rawEventModifiers, for: hotkey)
        let requiredModifiers = hotkey.modifiers

        // For hotkeys with modifiers, check if all required modifiers are present
        // For hotkeys without modifiers, check for exact match (no modifiers)
        let modifiersMatch: Bool
        if requiredModifiers.isEmpty {
            modifiersMatch = eventModifiers.isEmpty
        } else {
            modifiersMatch = eventModifiers.intersection(requiredModifiers) == requiredModifiers
        }

        if Diagnostics.trackedFunctionKeyCodes.contains(hotkey.keyCode) {
            DebugLog.error(
                "Match check targetKeyCode=\(hotkey.keyCode) eventKeyCode=\(event.keyCode) requiredMods=\(requiredModifiers.rawValue) rawEventMods=\(rawEventModifiers.rawValue) normalizedEventMods=\(eventModifiers.rawValue) modifiersMatch=\(modifiersMatch)",
                context: "HotkeyDiagnostics"
            )
        }

        guard event.keyCode == hotkey.keyCode && modifiersMatch else {
            return false
        }

        let now = Date()

        if isDictation {
            if Diagnostics.trackedFunctionKeyCodes.contains(hotkey.keyCode) {
                DebugLog.error("Dictation function-key MATCH on keyDown", context: "HotkeyDiagnostics")
            }
            // Dictation hotkey handling
            // Check for double-tap
            if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < Constants.doubleTapInterval {
                DebugLog.info("handleKeyDownEvent: DOUBLE-TAP detected - calling onDoubleTap", context: "HotkeyManager LOG")
                lastTapTime = nil
                isHoldingKey = false
                isToggleRecording = false
                onDoubleTap?()
                return true
            }

            if isPushToTalk {
                DebugLog.info("handleKeyDownEvent: Dictation MATCH (Push-to-Talk) - calling onHotkeyPressed", context: "HotkeyManager LOG")
                lastTapTime = now
                isHoldingKey = true
                onHotkeyPressed?()
            } else {
                DebugLog.info("handleKeyDownEvent: Dictation MATCH (Toggle mode) - isToggleRecording=\(isToggleRecording)", context: "HotkeyManager LOG")
                lastTapTime = now
                if isToggleRecording {
                    isToggleRecording = false
                    onHotkeyReleased?()
                } else {
                    isToggleRecording = true
                    onHotkeyPressed?()
                }
            }
        } else {
            // Command hotkey handling
            DebugLog.info("🎯 COMMAND HOTKEY DETECTED - keyCode=\(event.keyCode), modifiers=\(event.modifierFlags.rawValue)", context: "HotkeyManager LOG")
            if isPushToTalk {
                DebugLog.info("🎯 Command MATCH (Push-to-Talk) - calling onCommandHotkeyPressed", context: "HotkeyManager LOG")
                isHoldingCommandKey = true
                onCommandHotkeyPressed?()
            } else {
                DebugLog.info("🎯 Command MATCH (Toggle mode) - isCommandToggleRecording=\(isCommandToggleRecording)", context: "HotkeyManager LOG")
                if isCommandToggleRecording {
                    isCommandToggleRecording = false
                    onCommandHotkeyReleased?()
                } else {
                    isCommandToggleRecording = true
                    onCommandHotkeyPressed?()
                }
            }
        }
        return true
    }

    @discardableResult
    private func handleKeyUpEvent(_ event: NSEvent) -> Bool {
        DebugLog.info("handleKeyUpEvent: keyCode=\(event.keyCode), modifiers=\(event.modifierFlags.rawValue)", context: "HotkeyManager LOG")

        // Check dictation hotkey
        if let hotkey = currentHotkey, !hotkey.isMouseButton, !isModifierOnlyHotkey(hotkey), event.keyCode == hotkey.keyCode {
            // Only consume if modifiers match, OR we're already holding the key (push-to-talk where
            // modifier may have been released slightly before the main key).
            let rawEventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let eventModifiers = normalizedEventModifiers(rawEventModifiers, for: hotkey)
            let requiredModifiers = hotkey.modifiers
            let modifiersMatch: Bool
            if requiredModifiers.isEmpty {
                modifiersMatch = eventModifiers.isEmpty
            } else {
                modifiersMatch = eventModifiers.intersection(requiredModifiers) == requiredModifiers
            }
            guard modifiersMatch || isHoldingKey else {
                return false
            }

            if Diagnostics.trackedFunctionKeyCodes.contains(hotkey.keyCode) {
                DebugLog.error("Dictation function-key MATCH on keyUp", context: "HotkeyDiagnostics")
            }
            if isPushToTalk && isHoldingKey {
                DebugLog.info("handleKeyUpEvent: Dictation MATCH (Push-to-Talk) - calling onHotkeyReleased", context: "HotkeyManager LOG")
                isHoldingKey = false
                onHotkeyReleased?()
            } else if !isPushToTalk {
                DebugLog.info("handleKeyUpEvent: Dictation Toggle mode - ignoring key release", context: "HotkeyManager LOG")
            }
            return true
        }

        // Check command hotkey
        if let cmdHotkey = commandHotkey, !cmdHotkey.isMouseButton, !isModifierOnlyHotkey(cmdHotkey), event.keyCode == cmdHotkey.keyCode {
            let rawEventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let eventModifiers = normalizedEventModifiers(rawEventModifiers, for: cmdHotkey)
            let requiredModifiers = cmdHotkey.modifiers
            let modifiersMatch: Bool
            if requiredModifiers.isEmpty {
                modifiersMatch = eventModifiers.isEmpty
            } else {
                modifiersMatch = eventModifiers.intersection(requiredModifiers) == requiredModifiers
            }
            guard modifiersMatch || isHoldingCommandKey else {
                return false
            }

            DebugLog.info("🎯 COMMAND HOTKEY RELEASED - keyCode=\(event.keyCode)", context: "HotkeyManager LOG")
            if isPushToTalk && isHoldingCommandKey {
                DebugLog.info("🎯 Command MATCH (Push-to-Talk) - calling onCommandHotkeyReleased", context: "HotkeyManager LOG")
                isHoldingCommandKey = false
                onCommandHotkeyReleased?()
            } else if !isPushToTalk {
                DebugLog.info("🎯 Command Toggle mode - ignoring key release", context: "HotkeyManager LOG")
            }
            return true
        }

        return false
    }

    private func isModifierOnlyHotkey(_ hotkey: Hotkey) -> Bool {
        // These keys generate flagsChanged events instead of regular keyDown/keyUp.
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63, 179]
        return modifierKeyCodes.contains(hotkey.keyCode)
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

    private func normalizedEventModifiers(_ eventModifiers: NSEvent.ModifierFlags, for hotkey: Hotkey) -> NSEvent.ModifierFlags {
        var normalized = eventModifiers
        if hotkey.modifiers.isEmpty, Diagnostics.trackedFunctionKeyCodes.contains(hotkey.keyCode) {
            normalized.remove(NSEvent.ModifierFlags(rawValue: Diagnostics.functionModifierRawValue))
        }
        return normalized
    }

    private func flagsChangedKeyMatchesHotkey(eventKeyCode: UInt16, hotkey: Hotkey) -> Bool {
        // Some keyboards report Fn/Globe as 179 instead of 63.
        if hotkey.modifiers == .function, hotkey.keyCode == 63 {
            return eventKeyCode == 63 || eventKeyCode == 179
        }
        return eventKeyCode == hotkey.keyCode
    }

    private func isRequiredModifierPressed(for hotkey: Hotkey, eventModifiers: NSEvent.ModifierFlags) -> Bool {
        let requiredModifier = hotkey.modifiers.intersection(.deviceIndependentFlagsMask)
        guard !requiredModifier.isEmpty else { return false }
        return eventModifiers.intersection(requiredModifier) == requiredModifier
    }

    @discardableResult
    private func handleModifierFlagsStateChange(isModifierPressed: Bool, isDictation: Bool) -> Bool {
        if isDictation {
            if isModifierPressed && !isHoldingKey {
                let now = Date()

                // Keep double-tap behavior for modifier-only dictation hotkeys.
                if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < Constants.doubleTapInterval {
                    DebugLog.info("handleFlagsChangedEvent: Dictation DOUBLE-TAP detected", context: "HotkeyManager LOG")
                    lastTapTime = nil
                    isHoldingKey = false
                    isToggleRecording = false
                    onDoubleTap?()
                    return true
                }

                if isPushToTalk {
                    DebugLog.info("handleFlagsChangedEvent: Dictation modifier pressed (Push-to-Talk)", context: "HotkeyManager LOG")
                    lastTapTime = now
                    isHoldingKey = true
                    onHotkeyPressed?()
                } else {
                    DebugLog.info("handleFlagsChangedEvent: Dictation modifier pressed (Toggle mode), isToggleRecording=\(isToggleRecording)", context: "HotkeyManager LOG")
                    lastTapTime = now
                    if isToggleRecording {
                        isToggleRecording = false
                        onHotkeyReleased?()
                    } else {
                        isToggleRecording = true
                        onHotkeyPressed?()
                    }
                }
                return true
            } else if !isModifierPressed && isHoldingKey {
                if isPushToTalk {
                    DebugLog.info("handleFlagsChangedEvent: Dictation modifier released (Push-to-Talk)", context: "HotkeyManager LOG")
                    isHoldingKey = false
                    onHotkeyReleased?()
                }
                return true
            }
            return false
        }

        if isModifierPressed && !isHoldingCommandKey {
            if isPushToTalk {
                DebugLog.info("handleFlagsChangedEvent: Command modifier pressed (Push-to-Talk)", context: "HotkeyManager LOG")
                isHoldingCommandKey = true
                onCommandHotkeyPressed?()
            } else {
                DebugLog.info("handleFlagsChangedEvent: Command modifier pressed (Toggle mode), isCommandToggleRecording=\(isCommandToggleRecording)", context: "HotkeyManager LOG")
                if isCommandToggleRecording {
                    isCommandToggleRecording = false
                    onCommandHotkeyReleased?()
                } else {
                    isCommandToggleRecording = true
                    onCommandHotkeyPressed?()
                }
            }
            return true
        } else if !isModifierPressed && isHoldingCommandKey {
            if isPushToTalk {
                DebugLog.info("handleFlagsChangedEvent: Command modifier released (Push-to-Talk)", context: "HotkeyManager LOG")
                isHoldingCommandKey = false
                onCommandHotkeyReleased?()
            }
            return true
        }

        return false
    }

    deinit {
        unregisterHotkey()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
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
