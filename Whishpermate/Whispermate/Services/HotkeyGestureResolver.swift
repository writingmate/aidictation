import AppKit

/// Pure decision logic behind `HotkeyManager`, covering every binding kind:
/// key + modifiers, modifier-only keys (Fn, Control, Right Option…), and mouse
/// buttons, in both push-to-talk and toggle mode.
///
/// Modelled on VoiceInk's `ShortcutMonitor`: the tap plumbing lives in
/// `HotkeyManager`, every press/release/interrupt transition lives here as a value
/// type, and the current time is passed in rather than read, so double-tap windows
/// are testable without sleeping.
///
/// One resolver instance per channel — dictation and command each own their own
/// hold and toggle state, exactly as the two sets of flags in `HotkeyManager` did.
struct HotkeyGestureResolver {
    // MARK: - Types

    /// The subset of `Hotkey` the state machine needs.
    struct Binding: Equatable {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let mouseButton: Int32?

        init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, mouseButton: Int32? = nil) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.mouseButton = mouseButton
        }

        var isMouseButton: Bool { mouseButton != nil }

        /// These keys arrive as `flagsChanged`, never as keyDown/keyUp.
        var isModifierOnly: Bool {
            !isMouseButton && Constants.modifierKeyCodes.contains(keyCode)
        }

        var isFnOnly: Bool {
            modifiers == .function && Constants.fnKeyCodes.contains(keyCode)
        }
    }

    enum Action: Equatable {
        case pressed
        case released
        case doubleTap
    }

    struct Outcome: Equatable {
        var actions: [Action] = []
        /// The event belongs to this binding and should be consumed.
        var handled = false

        static let ignored = Outcome()
    }

    enum Constants {
        static let doubleTapInterval: TimeInterval = 0.3
        /// Fn on built-in keyboards, Globe on newer/external ones.
        static let fnKeyCodes: Set<UInt16> = [63, 179]
        static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63, 179]
        /// F5/F4 double as the system dictation keys and carry a stray `.function`
        /// flag that must not be treated as a required modifier.
        static let functionRowKeyCodes: Set<UInt16> = [96, 118]
    }

    // MARK: - Public Properties

    var binding: Binding?
    var isPushToTalk = true
    /// Only the dictation channel exposes double-tap.
    var supportsDoubleTap = false

    private(set) var isHolding = false
    private(set) var isToggleRecording = false
    private var lastTapTime: TimeInterval?

    // MARK: - Initialization

    init(supportsDoubleTap: Bool = false) {
        self.supportsDoubleTap = supportsDoubleTap
    }

    // MARK: - Public API

    mutating func keyDown(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isARepeat: Bool,
        at time: TimeInterval
    ) -> Outcome {
        guard let binding, !binding.isMouseButton, !binding.isModifierOnly else {
            return .ignored
        }

        // Swallow auto-repeat so held hotkeys do not retrigger or make typing sounds.
        if isARepeat {
            return Outcome(actions: [], handled: keyCode == binding.keyCode)
        }

        guard keyCode == binding.keyCode, matchesModifiers(modifiers, for: binding) else {
            return .ignored
        }

        return Outcome(actions: beginGesture(at: time), handled: true)
    }

    mutating func keyUp(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, at _: TimeInterval) -> Outcome {
        guard let binding, !binding.isMouseButton, !binding.isModifierOnly, keyCode == binding.keyCode else {
            return .ignored
        }

        // Accept the release even if the modifier came up a moment before the key,
        // which is routine when letting go of a chord.
        guard matchesModifiers(modifiers, for: binding) || isHolding else {
            return .ignored
        }

        return Outcome(actions: endGesture(), handled: true)
    }

    mutating func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, at time: TimeInterval) -> Outcome {
        guard let binding, binding.isModifierOnly, flagsChangedKeyMatches(keyCode, binding: binding) else {
            return .ignored
        }

        let required = binding.modifiers.intersection(.deviceIndependentFlagsMask)
        guard !required.isEmpty else { return .ignored }
        let isPressed = modifiers.intersection(required) == required

        if isPressed, !isHolding {
            return Outcome(actions: beginGesture(at: time), handled: true)
        }

        if !isPressed, isHolding {
            return Outcome(actions: endGesture(), handled: true)
        }

        return .ignored
    }

    mutating func mouseDown(button: Int32, at time: TimeInterval) -> Outcome {
        guard let binding, binding.mouseButton == button else { return .ignored }
        return Outcome(actions: beginGesture(at: time), handled: true)
    }

    mutating func mouseUp(button: Int32, at _: TimeInterval) -> Outcome {
        guard let binding, binding.mouseButton == button else { return .ignored }
        return Outcome(actions: endGesture(), handled: true)
    }

    /// For callers that decode the press/release themselves — the dedicated Fn
    /// monitor, which owns its own event tap and reports a finished transition.
    mutating func forcePress(at time: TimeInterval) -> Outcome {
        guard !isHolding else { return .ignored }
        return Outcome(actions: beginGesture(at: time), handled: true)
    }

    mutating func forceRelease() -> Outcome {
        guard isHolding else { return .ignored }
        return Outcome(actions: endGesture(), handled: true)
    }

    /// Ends an in-flight push-to-talk hold when the event stream itself goes away —
    /// a tap disabled by timeout or user input, or the hotkey being unregistered.
    /// Without this the key-up is delivered to nobody and dictation records forever.
    mutating func interrupt() -> Outcome {
        guard isHolding else { return .ignored }

        isHolding = false
        return Outcome(actions: [.released], handled: false)
    }

    /// Drops all gesture state without emitting anything. For teardown paths where
    /// the callbacks are going away too.
    mutating func reset() {
        isHolding = false
        isToggleRecording = false
        lastTapTime = nil
    }

    // MARK: - Private Methods

    private mutating func beginGesture(at time: TimeInterval) -> [Action] {
        if supportsDoubleTap, let lastTap = lastTapTime, time - lastTap < Constants.doubleTapInterval {
            lastTapTime = nil
            isHolding = false
            isToggleRecording = false
            return [.doubleTap]
        }

        if supportsDoubleTap {
            lastTapTime = time
        }

        if isPushToTalk {
            isHolding = true
            return [.pressed]
        }

        if isToggleRecording {
            isToggleRecording = false
            return [.released]
        }

        isToggleRecording = true
        return [.pressed]
    }

    private mutating func endGesture() -> [Action] {
        // Toggle mode ends on the next press, not on release.
        guard isPushToTalk, isHolding else { return [] }

        isHolding = false
        return [.released]
    }

    private func matchesModifiers(_ eventModifiers: NSEvent.ModifierFlags, for binding: Binding) -> Bool {
        var normalized = eventModifiers.intersection(.deviceIndependentFlagsMask)
        if binding.modifiers.isEmpty, Constants.functionRowKeyCodes.contains(binding.keyCode) {
            normalized.remove(.function)
        }

        let required = binding.modifiers
        return required.isEmpty ? normalized.isEmpty : normalized.intersection(required) == required
    }

    private func flagsChangedKeyMatches(_ eventKeyCode: UInt16, binding: Binding) -> Bool {
        // Some keyboards report Fn/Globe as 179 instead of 63.
        if binding.isFnOnly {
            return Constants.fnKeyCodes.contains(eventKeyCode)
        }
        return eventKeyCode == binding.keyCode
    }
}
