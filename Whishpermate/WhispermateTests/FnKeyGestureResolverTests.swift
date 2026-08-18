import XCTest

/// Regression tests for the Fn/Globe dictation gesture.
///
/// The failure these guard against: a release the monitor filters out or never
/// receives leaves the latch stuck "down", after which every Fn press is a no-op
/// and dictation looks dead until the app is restarted.
final class FnKeyGestureResolverTests: XCTestCase {
    private let fnKey: UInt16 = 63
    private let globeKey: UInt16 = 179
    private let commandKey: UInt16 = 55

    private var resolver = FnKeyGestureResolver()

    override func setUp() {
        super.setUp()
        resolver = FnKeyGestureResolver()
    }

    // MARK: - Helpers

    private func down(
        _ keyCode: UInt16? = nil,
        others: Bool = false,
        suppressed: Bool = false
    ) -> FnKeyGestureResolver.Event {
        .init(keyCode: keyCode ?? fnKey, isFnFlagSet: true, hasOtherModifiers: others, isSuppressed: suppressed)
    }

    private func up(
        _ keyCode: UInt16? = nil,
        others: Bool = false,
        suppressed: Bool = false
    ) -> FnKeyGestureResolver.Event {
        .init(keyCode: keyCode ?? fnKey, isFnFlagSet: false, hasOtherModifiers: others, isSuppressed: suppressed)
    }

    private var pressed: FnKeyGestureResolver.Outcome { .init(pressed: true, released: false, handled: true) }
    private var released: FnKeyGestureResolver.Outcome { .init(pressed: false, released: true, handled: true) }
    private var heldOnly: FnKeyGestureResolver.Outcome { .init(pressed: false, released: false, handled: true) }
    private var ignored: FnKeyGestureResolver.Outcome { .init() }

    // MARK: - Press and release

    func testPressThenReleaseRoundTrip() {
        XCTAssertEqual(resolver.resolve(down()), pressed)
        XCTAssertTrue(resolver.isFnDown)
        XCTAssertEqual(resolver.resolve(up()), released)
        XCTAssertFalse(resolver.isFnDown)
    }

    func testGlobeKeycodeBehavesLikeFn() {
        XCTAssertEqual(resolver.resolve(down(globeKey)), pressed)
        XCTAssertEqual(resolver.resolve(up(globeKey)), released)
    }

    func testRepeatedPressDoesNotRetrigger() {
        XCTAssertEqual(resolver.resolve(down()), pressed)
        XCTAssertEqual(resolver.resolve(down()), heldOnly)
        XCTAssertEqual(resolver.resolve(up()), released)
    }

    func testFnHeldWithAnotherModifierNeverStartsDictation() {
        XCTAssertEqual(resolver.resolve(down(others: true)), ignored)
        XCTAssertEqual(resolver.resolve(up(others: true)), ignored)
        XCTAssertFalse(resolver.isFnDown)
    }

    func testUnrelatedModifierTrafficIsIgnoredWhileFnIsUp() {
        XCTAssertEqual(resolver.resolve(up(commandKey)), ignored)
        XCTAssertEqual(resolver.resolve(down()), pressed)
    }

    // MARK: - The ways the latch used to wedge

    func testReleaseIsHonouredWhenAnotherModifierIsStillHeld() {
        XCTAssertEqual(resolver.resolve(down()), pressed)
        XCTAssertEqual(resolver.resolve(up(others: true)), released)

        // And the gesture is immediately usable again.
        XCTAssertEqual(resolver.resolve(down()), pressed)
        XCTAssertEqual(resolver.resolve(up()), released)
    }

    func testReleaseArrivingOnANonFnFlagsEventStillReleases() {
        XCTAssertEqual(resolver.resolve(down()), pressed)
        XCTAssertEqual(
            resolver.resolve(up(commandKey)),
            .init(pressed: false, released: true, handled: false)
        )
        XCTAssertEqual(resolver.resolve(down()), pressed)
    }

    func testSuppressionBlocksPressesButNeverSwallowsARelease() {
        XCTAssertEqual(resolver.resolve(down(suppressed: true)), ignored)

        XCTAssertEqual(resolver.resolve(down()), pressed)
        XCTAssertEqual(resolver.resolve(up(suppressed: true)), released)
        XCTAssertEqual(resolver.resolve(down()), pressed)
    }

    // MARK: - Interruption

    func testInterruptEndsAnInFlightGestureExactlyOnce() {
        XCTAssertEqual(resolver.resolve(down()), pressed)

        XCTAssertTrue(resolver.interrupt(), "an in-flight gesture still owes a release")
        XCTAssertFalse(resolver.interrupt(), "a second interrupt must not fire another release")
        XCTAssertFalse(resolver.isFnDown)
    }

    func testInterruptIsANoOpWhenNothingIsHeld() {
        XCTAssertFalse(resolver.interrupt())
    }

    func testGestureRearmsAfterInterruption() {
        XCTAssertEqual(resolver.resolve(down()), pressed)
        XCTAssertTrue(resolver.interrupt())
        XCTAssertEqual(resolver.resolve(down()), pressed)
    }
}
