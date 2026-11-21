import XCTest

/// Lifetime is no longer sold, but accounts that already have it must keep
/// reading as paid, unlimited and named "Lifetime".
final class SubscriptionTierTests: XCTestCase {
    func testLifetimeAccountsStayPaidAndUnlimited() {
        XCTAssertEqual(SubscriptionTier(rawValue: "lifetime"), .lifetime)
        XCTAssertTrue(SubscriptionTier.lifetime.isPaid)
        XCTAssertEqual(SubscriptionTier.lifetime.wordLimit, Int.max)
        XCTAssertEqual(SubscriptionTier.lifetime.displayName, "Lifetime")
    }

    func testFreeAccountsAreNotPaid() {
        XCTAssertFalse(SubscriptionTier.free.isPaid)
        XCTAssertEqual(SubscriptionTier.free.wordLimit, UsageLimits.freeTrialWordLimit)
    }
}
