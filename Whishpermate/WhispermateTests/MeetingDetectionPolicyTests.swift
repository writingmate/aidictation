import XCTest

final class MeetingDetectionPolicyTests: XCTestCase {
    private let call = MeetingDetectionPolicy.Candidate(appBundleID: "us.zoom.xos", appName: "Zoom", title: "Zoom Meeting")

    func testRequiresStableEvidenceBeforeOfferingNotes() {
        var policy = MeetingDetectionPolicy()
        let now = Date()
        XCTAssertNil(policy.observe(.call(call), now: now))
        XCTAssertNil(policy.observe(.call(call), now: now.addingTimeInterval(3)))
        XCTAssertEqual(policy.observe(.call(call), now: now.addingTimeInterval(6)), .detected(call))
        XCTAssertNil(policy.observe(.call(call), now: now.addingTimeInterval(9)))
    }

    func testTemporaryLossDoesNotEndCallAndTwentySecondsOfAbsenceDoes() {
        var policy = MeetingDetectionPolicy()
        let now = Date()
        _ = policy.observe(.call(call), now: now)
        _ = policy.observe(.call(call), now: now.addingTimeInterval(6))
        XCTAssertNil(policy.observe(.absent, now: now.addingTimeInterval(7)))
        XCTAssertNil(policy.observe(.call(call), now: now.addingTimeInterval(10)))
        XCTAssertNil(policy.observe(.absent, now: now.addingTimeInterval(11)))
        XCTAssertNil(policy.observe(.absent, now: now.addingTimeInterval(30)))
        XCTAssertEqual(policy.observe(.absent, now: now.addingTimeInterval(32)), .ended(call))
        XCTAssertNil(policy.current)
    }

    func testUnreadableWindowCannotTriggerAutomaticStop() {
        var policy = MeetingDetectionPolicy()
        let now = Date()
        _ = policy.observe(.call(call), now: now)
        _ = policy.observe(.call(call), now: now.addingTimeInterval(6))
        _ = policy.observe(.absent, now: now.addingTimeInterval(10))
        XCTAssertNil(policy.observe(.unknown, now: now.addingTimeInterval(35)))
        XCTAssertNotNil(policy.current)
        XCTAssertNil(policy.observe(.absent, now: now.addingTimeInterval(36)))
    }

    func testMeetingHomepageAndMicrophoneSettingsAreNotCalls() {
        XCTAssertFalse(MeetingDetectionPolicy.isCallWindow(appBundleID: "com.google.Chrome", title: "Google Meet", controls: ["New meeting", "Join"]))
        XCTAssertFalse(MeetingDetectionPolicy.isCallWindow(appBundleID: "us.zoom.xos", title: "Settings", controls: ["Test microphone"]))
        XCTAssertTrue(MeetingDetectionPolicy.isCallWindow(appBundleID: "com.google.Chrome", title: "Daily sync", controls: ["Leave call"]))
        XCTAssertTrue(MeetingDetectionPolicy.isCallWindow(appBundleID: "com.tinyspeck.slackmacgap", title: "Slack", controls: ["Leave huddle"]))
    }
}
