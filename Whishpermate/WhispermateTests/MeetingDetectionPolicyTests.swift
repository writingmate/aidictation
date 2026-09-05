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

    func testAnotherAppDoesNotReplaceTheOwnedCallWithoutAnEndEvent() {
        var policy = MeetingDetectionPolicy()
        let now = Date()
        let other = MeetingDetectionPolicy.Candidate(appBundleID: "com.google.Chrome", appName: "Chrome", title: "Meet")
        _ = policy.observe(.call(call), now: now)
        _ = policy.observe(.call(call), now: now.addingTimeInterval(6))
        XCTAssertNil(policy.observe(.call(other), now: now.addingTimeInterval(7)))
        XCTAssertNil(policy.observe(.call(other), now: now.addingTimeInterval(15)))
        XCTAssertEqual(policy.current, call)
        XCTAssertEqual(policy.observe(.call(other), now: now.addingTimeInterval(28)), .ended(call))
        XCTAssertEqual(policy.observe(.call(other), now: now.addingTimeInterval(31)), .detected(other))
    }

    func testReturningOrUnreadableOriginalCallCancelsReplacementGrace() {
        var policy = MeetingDetectionPolicy()
        let now = Date()
        let other = MeetingDetectionPolicy.Candidate(appBundleID: "com.google.Chrome", appName: "Chrome", title: "Meet")
        _ = policy.observe(.call(call), now: now)
        _ = policy.observe(.call(call), now: now.addingTimeInterval(6))
        _ = policy.observe(.call(other), now: now.addingTimeInterval(7))
        XCTAssertNil(policy.observe(.call(call), now: now.addingTimeInterval(15)))
        XCTAssertNil(policy.observe(.call(other), now: now.addingTimeInterval(28)))
        XCTAssertNil(policy.observe(.unknown, now: now.addingTimeInterval(50)))
        XCTAssertNil(policy.observe(.call(other), now: now.addingTimeInterval(53)))
        XCTAssertEqual(policy.current, call)
    }

    func testAutomaticStopRequiresTheExactRecordingThatThePromptStarted() {
        let noteID = UUID(), recordingID = UUID()
        let owner = MeetingDetectionPolicy.RecordingOwner(callID: call.id, noteID: noteID, recordingID: recordingID)
        XCTAssertTrue(owner.matches(call: call, noteID: noteID, recordingID: recordingID))
        XCTAssertFalse(owner.matches(call: call, noteID: noteID, recordingID: UUID()))
        XCTAssertFalse(owner.matches(call: call, noteID: UUID(), recordingID: recordingID))
        XCTAssertFalse(owner.matches(call: call, noteID: noteID, recordingID: nil))
    }

    func testPromptWaitsForThePreviousNoteAndIsOnlyOfferedOnce() {
        var policy = MeetingDetectionPolicy()
        let now = Date()
        _ = policy.observe(.call(call), now: now)
        _ = policy.observe(.call(call), now: now.addingTimeInterval(6))
        XCTAssertNil(policy.claimPrompt(canStartRecording: false))
        _ = policy.observe(.unknown, now: now.addingTimeInterval(7))
        XCTAssertNil(policy.claimPrompt(canStartRecording: true))
        _ = policy.observe(.call(call), now: now.addingTimeInterval(8))
        XCTAssertEqual(policy.claimPrompt(canStartRecording: true), call)
        XCTAssertNil(policy.claimPrompt(canStartRecording: true))
        _ = policy.observe(.unknown, now: now.addingTimeInterval(9))
        _ = policy.observe(.call(call), now: now.addingTimeInterval(12))
        XCTAssertNil(policy.claimPrompt(canStartRecording: true))
        _ = policy.observe(.absent, now: now.addingTimeInterval(15))
        _ = policy.observe(.absent, now: now.addingTimeInterval(36))
        _ = policy.observe(.call(call), now: now.addingTimeInterval(39))
        _ = policy.observe(.call(call), now: now.addingTimeInterval(45))
        XCTAssertEqual(policy.claimPrompt(canStartRecording: true), call)
    }

    func testMeetingHomepageAndMicrophoneSettingsAreNotCalls() {
        XCTAssertFalse(MeetingDetectionPolicy.isCallWindow(appBundleID: "com.google.Chrome", title: "Google Meet", controls: ["New meeting", "Join"]))
        XCTAssertFalse(MeetingDetectionPolicy.isCallWindow(appBundleID: "us.zoom.xos", title: "Settings", controls: ["Test microphone"]))
        XCTAssertTrue(MeetingDetectionPolicy.isCallWindow(appBundleID: "com.google.Chrome", title: "Daily sync", controls: ["Leave call"]))
        XCTAssertTrue(MeetingDetectionPolicy.isCallWindow(appBundleID: "com.tinyspeck.slackmacgap", title: "Slack", controls: ["Leave huddle"]))
    }
}
