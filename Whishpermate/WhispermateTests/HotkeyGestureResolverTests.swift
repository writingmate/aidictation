import AppKit
import XCTest

/// Covers every hotkey binding kind the app offers: key + modifiers,
/// modifier-only keys, and mouse buttons, in push-to-talk and toggle mode.
final class HotkeyGestureResolverTests: XCTestCase {
    private typealias Binding = HotkeyGestureResolver.Binding

    private let keyK: UInt16 = 40
    private let fnKey: UInt16 = 63
    private let globeKey: UInt16 = 179
    private let rightOption: UInt16 = 61
    private let f5: UInt16 = 96
    private let middleClick: Int32 = 2

    private var resolver = HotkeyGestureResolver(supportsDoubleTap: true)

    override func setUp() {
        super.setUp()
        resolver = HotkeyGestureResolver(supportsDoubleTap: true)
    }

    private var pressed: HotkeyGestureResolver.Outcome { .init(actions: [.pressed], handled: true) }
    private var released: HotkeyGestureResolver.Outcome { .init(actions: [.released], handled: true) }
    private var doubleTap: HotkeyGestureResolver.Outcome { .init(actions: [.doubleTap], handled: true) }
    private var consumedOnly: HotkeyGestureResolver.Outcome { .init(actions: [], handled: true) }

    // MARK: - Key + modifier bindings

    func testKeyChordPressAndRelease() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command, .shift])

        XCTAssertEqual(
            resolver.keyDown(keyCode: keyK, modifiers: [.command, .shift], isARepeat: false, at: 0),
            pressed
        )
        XCTAssertEqual(resolver.keyUp(keyCode: keyK, modifiers: [.command, .shift], at: 1), released)
    }

    func testKeyChordIgnoresWrongKeyAndMissingModifier() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])

        XCTAssertEqual(resolver.keyDown(keyCode: 41, modifiers: [.command], isARepeat: false, at: 0), .ignored)
        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [], isARepeat: false, at: 0), .ignored)
        XCTAssertFalse(resolver.isHolding)
    }

    func testBareKeyBindingRequiresNoModifiers() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [])

        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), .ignored)
        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [], isARepeat: false, at: 0), pressed)
    }

    func testAutoRepeatIsConsumedWithoutRetriggering() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])

        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), pressed)
        XCTAssertEqual(
            resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: true, at: 0.1),
            consumedOnly
        )
        XCTAssertEqual(resolver.keyUp(keyCode: keyK, modifiers: [.command], at: 0.2), released)
    }

    func testReleaseIsAcceptedWhenTheModifierCameUpFirst() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])

        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), pressed)
        // Command already let go — without the isHolding fallback this release is lost.
        XCTAssertEqual(resolver.keyUp(keyCode: keyK, modifiers: [], at: 0.4), released)
        XCTAssertFalse(resolver.isHolding)
    }

    func testFunctionRowBindingIgnoresTheStrayFunctionFlag() {
        // F5 carries .function on every event; a bare F5 binding must still match.
        resolver.binding = Binding(keyCode: f5, modifiers: [])

        XCTAssertEqual(resolver.keyDown(keyCode: f5, modifiers: [.function], isARepeat: false, at: 0), pressed)
    }

    // MARK: - Modifier-only bindings

    func testModifierOnlyBindingPressAndRelease() {
        resolver.binding = Binding(keyCode: rightOption, modifiers: [.option])

        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [.option], at: 0), pressed)
        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [], at: 1), released)
    }

    func testModifierOnlyBindingIsNotDrivenByKeyEvents() {
        resolver.binding = Binding(keyCode: rightOption, modifiers: [.option])

        XCTAssertEqual(
            resolver.keyDown(keyCode: rightOption, modifiers: [.option], isARepeat: false, at: 0),
            .ignored
        )
        XCTAssertEqual(resolver.keyUp(keyCode: rightOption, modifiers: [], at: 1), .ignored)
    }

    func testFnBindingAlsoAcceptsTheGlobeKeycode() {
        resolver.binding = Binding(keyCode: fnKey, modifiers: .function)

        XCTAssertEqual(resolver.flagsChanged(keyCode: globeKey, modifiers: .function, at: 0), pressed)
        XCTAssertEqual(resolver.flagsChanged(keyCode: globeKey, modifiers: [], at: 1), released)
    }

    func testRepeatedModifierPressWhileHeldIsIgnored() {
        resolver.binding = Binding(keyCode: rightOption, modifiers: [.option])

        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [.option], at: 0), pressed)
        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [.option], at: 0.1), .ignored)
    }

    // MARK: - Mouse bindings

    func testMouseButtonPressAndRelease() {
        resolver.binding = Binding(keyCode: 0, modifiers: [], mouseButton: middleClick)

        XCTAssertEqual(resolver.mouseDown(button: middleClick, at: 0), pressed)
        XCTAssertEqual(resolver.mouseUp(button: middleClick, at: 1), released)
    }

    func testOtherMouseButtonsAreIgnored() {
        resolver.binding = Binding(keyCode: 0, modifiers: [], mouseButton: middleClick)

        XCTAssertEqual(resolver.mouseDown(button: 4, at: 0), .ignored)
        XCTAssertFalse(resolver.isHolding)
    }

    func testMouseBindingIsNotDrivenByKeyEvents() {
        resolver.binding = Binding(keyCode: 0, modifiers: [], mouseButton: middleClick)

        XCTAssertEqual(resolver.keyDown(keyCode: 0, modifiers: [], isARepeat: false, at: 0), .ignored)
    }

    // MARK: - Toggle mode

    func testToggleModeStartsAndStopsOnSuccessivePresses() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])
        resolver.isPushToTalk = false

        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), pressed)
        // The release must not stop a toggle recording.
        XCTAssertEqual(resolver.keyUp(keyCode: keyK, modifiers: [.command], at: 0.1), consumedOnly)

        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 5), released)
        XCTAssertEqual(resolver.keyUp(keyCode: keyK, modifiers: [.command], at: 5.1), consumedOnly)
    }

    func testToggleModeWorksForModifierOnlyBindings() {
        resolver.binding = Binding(keyCode: rightOption, modifiers: [.option])
        resolver.isPushToTalk = false

        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [.option], at: 0), pressed)
        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [], at: 0.1), .ignored)
        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [.option], at: 5), released)
    }

    // MARK: - Double tap

    func testDoubleTapInsideTheWindow() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])

        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), pressed)
        XCTAssertEqual(resolver.keyUp(keyCode: keyK, modifiers: [.command], at: 0.05), released)
        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0.2), doubleTap)
        XCTAssertFalse(resolver.isHolding, "a double tap must not leave a hold in flight")
    }

    func testTapsOutsideTheWindowAreTwoSeparatePresses() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])

        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), pressed)
        XCTAssertEqual(resolver.keyUp(keyCode: keyK, modifiers: [.command], at: 0.05), released)
        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0.4), pressed)
    }

    func testDoubleTapWorksForModifierOnlyAndMouseBindings() {
        resolver.binding = Binding(keyCode: rightOption, modifiers: [.option])
        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [.option], at: 0), pressed)
        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [], at: 0.05), released)
        XCTAssertEqual(resolver.flagsChanged(keyCode: rightOption, modifiers: [.option], at: 0.2), doubleTap)

        var mouse = HotkeyGestureResolver(supportsDoubleTap: true)
        mouse.binding = Binding(keyCode: 0, modifiers: [], mouseButton: middleClick)
        XCTAssertEqual(mouse.mouseDown(button: middleClick, at: 0), pressed)
        XCTAssertEqual(mouse.mouseUp(button: middleClick, at: 0.05), released)
        XCTAssertEqual(mouse.mouseDown(button: middleClick, at: 0.2), doubleTap)
    }

    func testCommandChannelHasNoDoubleTap() {
        var command = HotkeyGestureResolver(supportsDoubleTap: false)
        command.binding = Binding(keyCode: keyK, modifiers: [.command])

        XCTAssertEqual(command.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), pressed)
        XCTAssertEqual(command.keyUp(keyCode: keyK, modifiers: [.command], at: 0.05), released)
        XCTAssertEqual(
            command.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0.2),
            pressed,
            "a quick second press on the command channel is just another press"
        )
    }

    // MARK: - Interruption

    func testInterruptReleasesAnInFlightHoldExactlyOnce() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])
        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), pressed)

        XCTAssertEqual(resolver.interrupt(), .init(actions: [.released], handled: false))
        XCTAssertEqual(resolver.interrupt(), .ignored)
        XCTAssertFalse(resolver.isHolding)
    }

    func testInterruptDoesNothingWhenIdle() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])
        XCTAssertEqual(resolver.interrupt(), .ignored)
    }

    func testInterruptLeavesToggleRecordingAlone() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])
        resolver.isPushToTalk = false
        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), pressed)

        // A toggle recording is not tied to a held key, so losing the tap must not stop it.
        XCTAssertEqual(resolver.interrupt(), .ignored)
        XCTAssertTrue(resolver.isToggleRecording)
    }

    func testInterruptAppliesToEveryBindingKind() {
        for binding in [
            Binding(keyCode: rightOption, modifiers: [.option]),
            Binding(keyCode: 0, modifiers: [], mouseButton: middleClick),
        ] {
            var subject = HotkeyGestureResolver(supportsDoubleTap: true)
            subject.binding = binding

            if binding.isMouseButton {
                XCTAssertEqual(subject.mouseDown(button: middleClick, at: 0), pressed)
            } else {
                XCTAssertEqual(subject.flagsChanged(keyCode: rightOption, modifiers: [.option], at: 0), pressed)
            }

            XCTAssertEqual(subject.interrupt(), .init(actions: [.released], handled: false))
        }
    }

    func testGestureRearmsAfterInterruption() {
        resolver.binding = Binding(keyCode: keyK, modifiers: [.command])
        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), pressed)
        XCTAssertEqual(resolver.interrupt(), .init(actions: [.released], handled: false))

        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 5), pressed)
    }

    // MARK: - No binding

    func testNoBindingIgnoresEverything() {
        resolver.binding = nil

        XCTAssertEqual(resolver.keyDown(keyCode: keyK, modifiers: [.command], isARepeat: false, at: 0), .ignored)
        XCTAssertEqual(resolver.flagsChanged(keyCode: fnKey, modifiers: .function, at: 0), .ignored)
        XCTAssertEqual(resolver.mouseDown(button: middleClick, at: 0), .ignored)
        XCTAssertEqual(resolver.interrupt(), .ignored)
    }
}
