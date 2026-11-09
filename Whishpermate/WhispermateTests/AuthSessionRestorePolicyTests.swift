import XCTest

/// Covers the account state shown while a stored session restores. A paid plan
/// must never read as "Free" or signed out because the app relaunched or the
/// keychain was briefly locked.
final class AuthSessionRestorePolicyTests: XCTestCase {
    private struct Profile: Equatable {
        let subscriptionStatus: String
    }

    func testLockedKeychainStillCountsAsAStoredSession() {
        XCTAssertTrue(AuthSessionRestorePolicy.indicatesStoredSession(.found))
        XCTAssertTrue(AuthSessionRestorePolicy.indicatesStoredSession(.temporarilyUnreadable))
        XCTAssertFalse(AuthSessionRestorePolicy.indicatesStoredSession(.notFound))
    }

    func testLaunchShowsTheCachedPaidPlanWhileRestoring() {
        let lifetime = Profile(subscriptionStatus: "lifetime")
        let state = AuthSessionRestorePolicy.launchState(
            hasPersistedSession: true,
            cachedProfile: lifetime
        )

        XCTAssertEqual(state.profile, lifetime)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.isRestorePending)
    }

    func testStaleCacheDoesNotSignInASignedOutUser() {
        let state = AuthSessionRestorePolicy.launchState(
            hasPersistedSession: false,
            cachedProfile: Profile(subscriptionStatus: "pro")
        )

        XCTAssertNil(state.profile)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.isRestorePending)
    }

    func testWithoutACachedProfileTheNetworkRestoreDecides() {
        let state = AuthSessionRestorePolicy.launchState(
            hasPersistedSession: true,
            cachedProfile: Profile?.none
        )

        XCTAssertNil(state.profile)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.isRestorePending)
    }
}
