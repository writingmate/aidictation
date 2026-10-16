import XCTest

/// Covers the restore policy behind a report where a Lifetime customer saw
/// "Not signed in / Free" after relaunching, because a failed session restore
/// was treated as a sign-out regardless of why it failed.
final class AuthSessionRestorePolicyTests: XCTestCase {
    private typealias Policy = AuthSessionRestorePolicy

    // MARK: - Transient failures keep the user signed in

    func testTransientFailureOnColdLaunchRestoresCachedProfile() {
        let resolution = Policy.resolve(
            failure: .transient,
            hasPersistedSession: true,
            hasCurrentUser: false,
            hasCachedProfile: true
        )

        XCTAssertEqual(resolution, .keepSignedIn(restoreCachedProfile: true))
    }

    func testTransientFailureWithProfileAlreadyLoadedKeepsIt() {
        let resolution = Policy.resolve(
            failure: .transient,
            hasPersistedSession: true,
            hasCurrentUser: true,
            hasCachedProfile: true
        )

        XCTAssertEqual(resolution, .keepSignedIn(restoreCachedProfile: false))
    }

    func testTransientFailureWithoutCacheStillDoesNotSignOut() {
        let resolution = Policy.resolve(
            failure: .transient,
            hasPersistedSession: true,
            hasCurrentUser: false,
            hasCachedProfile: false
        )

        XCTAssertEqual(resolution, .keepSignedIn(restoreCachedProfile: false))
    }

    func testKeychainMissOnLaunchKeepsSignedInWhileSessionIsPersisted() {
        let resolution = Policy.resolve(
            failure: .sessionMissing,
            hasPersistedSession: true,
            hasCurrentUser: false,
            hasCachedProfile: true
        )

        XCTAssertEqual(resolution, .keepSignedIn(restoreCachedProfile: true))
    }

    // MARK: - Definitive failures sign out

    func testServerRejectionSignsOutEvenWithCachedProfile() {
        let resolution = Policy.resolve(
            failure: .rejectedByServer,
            hasPersistedSession: true,
            hasCurrentUser: true,
            hasCachedProfile: true
        )

        XCTAssertEqual(resolution, .signOut)
    }

    func testNothingPersistedSignsOut() {
        for failure in [Policy.Failure.sessionMissing, .transient, .rejectedByServer] {
            let resolution = Policy.resolve(
                failure: failure,
                hasPersistedSession: false,
                hasCurrentUser: false,
                hasCachedProfile: true
            )
            XCTAssertEqual(resolution, .signOut, "\(failure) with no persisted session must sign out")
        }
    }

    // MARK: - HTTP status mapping

    func testClientErrorsAreRejections() {
        XCTAssertEqual(Policy.failure(forHTTPStatus: 400), .rejectedByServer)
        XCTAssertEqual(Policy.failure(forHTTPStatus: 401), .rejectedByServer)
        XCTAssertEqual(Policy.failure(forHTTPStatus: 403), .rejectedByServer)
        XCTAssertEqual(Policy.failure(forHTTPStatus: 404), .rejectedByServer)
    }

    func testRateLimitAndServerErrorsAreTransient() {
        XCTAssertEqual(Policy.failure(forHTTPStatus: 429), .transient)
        XCTAssertEqual(Policy.failure(forHTTPStatus: 500), .transient)
        XCTAssertEqual(Policy.failure(forHTTPStatus: 502), .transient)
        XCTAssertEqual(Policy.failure(forHTTPStatus: 503), .transient)
    }
}
