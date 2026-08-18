import Foundation

/// Pure decision logic behind `FnKeyMonitor`.
///
/// The rules here follow the shape that open-source macOS dictation apps have
/// converged on for a modifier-only hotkey (VoiceInk's `ShortcutMonitor` /
/// `Shortcut.shouldReleaseModifierEvent`, speak2's `HotkeyManager`):
///
/// * **Strict on press** — only a bare Fn/Globe press arms the gesture, so Fn used
///   as a real modifier (Fn+arrow, Fn+F-key) never starts dictation.
/// * **Loose on release** — once armed, *any* `flagsChanged` carrying the Fn keycode
///   releases it, and so does any event that reports the Fn flag cleared. Gating the
///   release on "no other modifier held" (or on a suppression window) is what wedges
///   the latch: one dropped release and every later press is a no-op.
///
/// Kept AppKit-free so `FnKeyGestureResolverTests` can drive it directly.
struct FnKeyGestureResolver {
    // MARK: - Types

    /// One `flagsChanged` observation, reduced to what the state machine needs.
    struct Event {
        let keyCode: UInt16
        let isFnFlagSet: Bool
        let hasOtherModifiers: Bool
        let isSuppressed: Bool

        init(keyCode: UInt16, isFnFlagSet: Bool, hasOtherModifiers: Bool, isSuppressed: Bool = false) {
            self.keyCode = keyCode
            self.isFnFlagSet = isFnFlagSet
            self.hasOtherModifiers = hasOtherModifiers
            self.isSuppressed = isSuppressed
        }
    }

    struct Outcome: Equatable {
        /// Fire `onFnPressed`.
        var pressed = false
        /// Fire `onFnReleased`.
        var released = false
        /// Event belongs to the Fn gesture and may be swallowed in consuming mode.
        var handled = false
    }

    private enum Constants {
        /// `kVK_Function` on built-in keyboards, Globe on newer/external ones.
        static let fnKeyCodes: Set<UInt16> = [63, 179]
    }

    // MARK: - Private Properties

    private(set) var isFnDown = false

    // MARK: - Public API

    mutating func resolve(_ event: Event) -> Outcome {
        let isFnKey = Constants.fnKeyCodes.contains(event.keyCode)

        if isFnDown {
            // Release on the Fn keycode whatever the flags say, and on any other
            // event that reports Fn as no longer held.
            guard isFnKey || !event.isFnFlagSet else {
                return Outcome()
            }

            if isFnKey, event.isFnFlagSet, !event.hasOtherModifiers {
                // Still held: a repeat of the same press.
                return Outcome(pressed: false, released: false, handled: true)
            }

            isFnDown = false
            return Outcome(pressed: false, released: true, handled: isFnKey)
        }

        // Press must be Fn on its own, and is the only thing the suppression window
        // (opened after a simulated paste) is allowed to swallow.
        guard isFnKey, event.isFnFlagSet, !event.hasOtherModifiers, !event.isSuppressed else {
            return Outcome()
        }

        isFnDown = true
        return Outcome(pressed: true, released: false, handled: true)
    }

    /// Ends an in-flight gesture when the event stream itself goes away — a tap
    /// disabled by timeout or user input, or the monitor being torn down. Returns
    /// `true` when the caller still owes an `onFnReleased`; without it a recording
    /// started by the lost press would run forever.
    mutating func interrupt() -> Bool {
        guard isFnDown else { return false }
        isFnDown = false
        return true
    }
}
