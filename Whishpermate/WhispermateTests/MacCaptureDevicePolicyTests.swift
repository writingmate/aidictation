import XCTest

/// Covers the capture-device policy behind a report where macOS moved the
/// default input from a USB microphone to the built-in one and every dictation
/// attempt afterwards flashed the overlay for a second and recorded nothing.
final class MacCaptureDevicePolicyTests: XCTestCase {
    private typealias Candidate = MacCaptureDevicePolicy.Candidate
    private typealias Context = MacCaptureDevicePolicy.Context

    private let builtIn = Candidate(uniqueID: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isBuiltIn: true)
    private let usbMic = Candidate(uniqueID: "Yeti-UID", name: "Yeti Stereo Microphone")
    private let headset = Candidate(uniqueID: "Headset-UID", name: "USB Headset")
    private let aggregate = Candidate(uniqueID: "Aggregate-UID", name: "CADeviceAggregate:123")

    // MARK: - Saved device unplugged

    func testSavedDeviceMissingFallsBackToSystemDefaultWithoutReconciliation() {
        let context = Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn],
            systemDefault: builtIn
        )

        let decision = MacCaptureDevicePolicy.captureDecision(context)

        XCTAssertEqual(decision?.device, builtIn)
        XCTAssertEqual(decision?.fallbackReason, .savedDeviceMissing)
        XCTAssertNil(decision?.preferredDevice, "Nothing to reconcile when the default is already the best stand-in")
        XCTAssertEqual(decision?.usedFallback, true)
    }

    func testSavedDeviceMissingPrefersAnotherExternalMicWhenDefaultIsBuiltInOnDesk() {
        let context = Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn, headset],
            systemDefault: builtIn,
            hasActiveExternalDisplay: true
        )

        let decision = MacCaptureDevicePolicy.captureDecision(context)

        XCTAssertEqual(decision?.device, builtIn, "Capture still uses the current default; no route change at record time")
        XCTAssertEqual(decision?.fallbackReason, .savedDeviceMissing)
        XCTAssertEqual(decision?.preferredDevice, headset, "The headset becomes the default after capture ends")
    }

    // MARK: - Default not yet applied

    func testSavedDeviceConnectedButNotDefaultCapturesDefaultAndRequestsReconciliation() {
        let context = Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn, usbMic],
            systemDefault: builtIn
        )

        let decision = MacCaptureDevicePolicy.captureDecision(context)

        XCTAssertEqual(decision?.device, builtIn)
        XCTAssertEqual(decision?.fallbackReason, .routeNotApplied)
        XCTAssertEqual(decision?.preferredDevice, usbMic)
    }

    func testSavedDeviceThatIsDefaultNeedsNoFallback() {
        let context = Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn, usbMic],
            systemDefault: usbMic
        )

        let decision = MacCaptureDevicePolicy.captureDecision(context)

        XCTAssertEqual(decision?.device, usbMic)
        XCTAssertNil(decision?.fallbackReason)
        XCTAssertNil(decision?.preferredDevice)
    }

    // MARK: - Automatic selection

    func testAutomaticModeFollowsSystemDefault() {
        let context = Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [builtIn, usbMic],
            systemDefault: builtIn
        )

        let decision = MacCaptureDevicePolicy.captureDecision(context)

        XCTAssertEqual(decision?.device, builtIn)
        XCTAssertNil(decision?.fallbackReason)
    }

    func testAutomaticModeStillRecordsFromBuiltInWhenLidIsClosedAndNothingElseExists() {
        let context = Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [builtIn],
            systemDefault: builtIn,
            clamshellClosed: true,
            hasActiveBuiltInDisplay: false,
            hasActiveExternalDisplay: true
        )

        XCTAssertEqual(MacCaptureDevicePolicy.bestAutomaticDevice(in: context), builtIn)

        let decision = MacCaptureDevicePolicy.captureDecision(context)
        XCTAssertEqual(decision?.device, builtIn)
        XCTAssertNil(decision?.fallbackReason, "The only microphone is the right one, even if the desk heuristics dislike it")
    }

    func testAutomaticModeAvoidsBuiltInOnDeskWhenExternalMicExists() {
        let context = Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [builtIn, usbMic],
            systemDefault: builtIn,
            hasActiveExternalDisplay: true
        )

        XCTAssertEqual(MacCaptureDevicePolicy.bestAutomaticDevice(in: context), usbMic)

        let decision = MacCaptureDevicePolicy.captureDecision(context)
        XCTAssertEqual(decision?.device, builtIn, "Recording never changes the route itself")
        XCTAssertEqual(decision?.fallbackReason, .routeNotApplied)
        XCTAssertEqual(decision?.preferredDevice, usbMic)
    }

    func testAutomaticModeSkipsVirtualDevicesWhenAPhysicalMicExists() {
        let context = Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [aggregate, usbMic],
            systemDefault: nil
        )

        XCTAssertEqual(MacCaptureDevicePolicy.bestAutomaticDevice(in: context), usbMic)
    }

    // MARK: - Hidden default and no default

    func testHiddenSystemDefaultIsStillUsedForCapture() {
        let context = Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [builtIn],
            systemDefault: aggregate
        )

        let decision = MacCaptureDevicePolicy.captureDecision(context)

        XCTAssertEqual(decision?.device, aggregate)
        XCTAssertEqual(decision?.fallbackReason, .routeNotApplied)
        XCTAssertEqual(decision?.preferredDevice, builtIn)
    }

    func testNoSystemDefaultReturnsNil() {
        let context = Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [],
            systemDefault: nil
        )

        XCTAssertNil(MacCaptureDevicePolicy.captureDecision(context))
    }

    func testNoListedDevicesButDefaultPresentCapturesDefault() {
        let context = Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [],
            systemDefault: builtIn
        )

        let decision = MacCaptureDevicePolicy.captureDecision(context)

        XCTAssertEqual(decision?.device, builtIn)
        XCTAssertNil(decision?.fallbackReason)
    }

    // MARK: - Preference resolution

    func testPreferredDeviceKeepsSavedUIDSemanticsWhenReconnected() {
        let disconnected = Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn],
            systemDefault: builtIn
        )
        XCTAssertEqual(MacCaptureDevicePolicy.preferredDevice(in: disconnected), builtIn)
        XCTAssertFalse(MacCaptureDevicePolicy.isSavedDeviceConnected(in: disconnected))

        let reconnected = Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn, usbMic],
            systemDefault: builtIn
        )
        XCTAssertEqual(MacCaptureDevicePolicy.preferredDevice(in: reconnected), usbMic)
        XCTAssertTrue(MacCaptureDevicePolicy.isSavedDeviceConnected(in: reconnected))
    }

    func testCandidateNameHeuristics() {
        XCTAssertTrue(aggregate.looksVirtual)
        XCTAssertFalse(usbMic.looksVirtual)
        XCTAssertTrue(usbMic.looksLikeMicrophone)
        XCTAssertTrue(builtIn.looksLikeMicrophone)
        XCTAssertFalse(headset.looksLikeMicrophone)
    }
}
