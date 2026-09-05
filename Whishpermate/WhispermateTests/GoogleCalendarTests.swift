import XCTest

final class GoogleCalendarTests: XCTestCase {
    func testAutomaticRefreshUsesCachedMeetingsForFifteenMinutes() {
        let now = Date()
        XCTAssertTrue(GoogleCalendarSync.shouldRefresh(lastSynced: nil, now: now))
        XCTAssertFalse(GoogleCalendarSync.shouldRefresh(lastSynced: now.addingTimeInterval(-120), now: now))
        XCTAssertTrue(GoogleCalendarSync.shouldRefresh(lastSynced: now.addingTimeInterval(-900), now: now))
    }

    func testManagedSignInRejectsLookalikeAndInsecureURLs() {
        XCTAssertTrue(GoogleCalendarSync.isManagedAuthorizationURL(URL(string: "https://connect.composio.dev/link/one")!))
        for url in ["http://connect.composio.dev/link/one", "https://connect.composio.dev.evil.test/link/one", "https://user@connect.composio.dev/link/one"] {
            XCTAssertFalse(GoogleCalendarSync.isManagedAuthorizationURL(URL(string: url)!))
        }
    }

    func testCallbackRejectsOtherAttemptsAndProductionDevCrossover() {
        let nonce = UUID()
        let valid = URL(string: "aidictation-dev://google-calendar?state=\(nonce.uuidString)&status=success")!
        XCTAssertTrue(GoogleCalendarSync.isAuthorizationCallback(valid, scheme: "aidictation-dev", nonce: nonce))
        XCTAssertFalse(GoogleCalendarSync.isAuthorizationCallback(valid, scheme: "aidictation", nonce: nonce))
        XCTAssertFalse(GoogleCalendarSync.isAuthorizationCallback(valid, scheme: "aidictation-dev", nonce: UUID()))
        let duplicate = URL(string: valid.absoluteString + "&state=\(nonce.uuidString)")!
        XCTAssertFalse(GoogleCalendarSync.isAuthorizationCallback(duplicate, scheme: "aidictation-dev", nonce: nonce))
    }

    func testExplicitlyDeselectingEveryCalendarStaysEmpty() {
        let calendars = [GoogleCalendarSummary(id: "primary", summary: "Work", selected: true, primary: true, backgroundColor: nil)]
        XCTAssertEqual(GoogleCalendarSync.selectedIDs(calendars: calendars, saved: nil), ["primary"])
        XCTAssertTrue(GoogleCalendarSync.selectedIDs(calendars: calendars, saved: []).isEmpty)
    }

    func testDeletedCalendarsAreRemovedFromSelection() {
        let calendars = [GoogleCalendarSummary(id: "one", summary: "Work", selected: false, primary: false, backgroundColor: nil)]
        XCTAssertEqual(GoogleCalendarSync.selectedIDs(calendars: calendars, saved: ["one", "deleted"]), ["one"])
    }

    func testCalendarDatesRespectOffsetsAndFractionalSeconds() throws {
        let event = try decode(#"{"id":"one","start":{"dateTime":"2026-09-04T12:00:00.000-07:00"},"end":{"dateTime":"2026-09-04T12:30:00-07:00"}}"#)
        XCTAssertEqual(event.interval?.duration, 1800)
    }

    func testCancelledDeclinedAndAllDayEventsDoNotBecomeCalls() throws {
        XCTAssertNil(try decode(#"{"id":"cancelled","status":"cancelled"}"#).interval)
        XCTAssertNil(try decode(#"{"id":"all-day","start":{"date":"2026-09-04"},"end":{"date":"2026-09-05"}}"#).interval)
        XCTAssertNil(try decode(#"{"id":"declined","start":{"dateTime":"2026-09-04T12:00:00-07:00"},"end":{"dateTime":"2026-09-04T12:30:00-07:00"},"attendees":[{"self":true,"responseStatus":"declined"}]}"#).interval)
    }

    private func decode(_ json: String) throws -> GoogleCalendarEvent {
        try JSONDecoder().decode(GoogleCalendarEvent.self, from: Data(json.utf8))
    }
}
