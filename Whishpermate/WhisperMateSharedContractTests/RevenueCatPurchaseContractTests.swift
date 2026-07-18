import Foundation
import RevenueCat
import class StoreKit.SKProduct
import class StoreKit.SKProductSubscriptionPeriod
import XCTest
@testable import WhisperMateShared

final class RevenueCatPurchaseContractTests: XCTestCase {
    func testBillingPeriodsMapToTheProductionPackageContract() {
        let expectations: [(RevenueCatBillingPeriod, PackageType, String)] = [
            (.monthly, .monthly, "$rc_monthly"),
            (.annual, .annual, "$rc_annual"),
            (.lifetime, .lifetime, "$rc_lifetime"),
        ]

        for (period, packageType, identifier) in expectations {
            XCTAssertEqual(RevenueCatPurchaseContract.packageType(for: period), packageType)
            XCTAssertEqual(RevenueCatPurchaseContract.packageIdentifier(for: period), identifier)
        }
    }

    func testOfferingAcceptsOnlyExactPackagesAndBuildsMatchingOptions() {
        let monthly = validPackage(for: .monthly)
        let annual = validPackage(for: .annual)
        let lifetime = validPackage(for: .lifetime)
        let offering = offering(with: [lifetime, monthly, annual])

        XCTAssertIdentical(RevenueCatPurchaseContract.package(in: offering, for: .monthly), monthly)
        XCTAssertIdentical(RevenueCatPurchaseContract.package(in: offering, for: .annual), annual)
        XCTAssertIdentical(RevenueCatPurchaseContract.package(in: offering, for: .lifetime), lifetime)
        XCTAssertEqual(
            RevenueCatPurchaseContract.purchaseOptions(in: offering).map(\.period),
            [.monthly, .annual, .lifetime]
        )
    }

    func testOfferingRejectsPackageIdentifierTypeAndSubscriptionMismatches() {
        let mismatches: [(RevenueCatBillingPeriod, Package)] = [
            (
                .monthly,
                package(
                    identifier: "$rc_annual",
                    packageType: .monthly,
                    productType: .autoRenewableSubscription,
                    subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .month)
                )
            ),
            (
                .monthly,
                package(
                    identifier: "$rc_monthly",
                    packageType: .annual,
                    productType: .autoRenewableSubscription,
                    subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .month)
                )
            ),
            (
                .monthly,
                package(
                    identifier: "$rc_monthly",
                    packageType: .monthly,
                    productType: .nonRenewableSubscription,
                    subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .month)
                )
            ),
            (
                .monthly,
                package(
                    identifier: "$rc_monthly",
                    packageType: .monthly,
                    productType: .autoRenewableSubscription,
                    subscriptionPeriod: SubscriptionPeriod(value: 2, unit: .month)
                )
            ),
            (
                .annual,
                package(
                    identifier: "$rc_annual",
                    packageType: .annual,
                    productType: .autoRenewableSubscription,
                    subscriptionPeriod: SubscriptionPeriod(value: 12, unit: .month)
                )
            ),
        ]

        for (period, package) in mismatches {
            let offering = offering(with: [package])
            XCTAssertNil(RevenueCatPurchaseContract.package(in: offering, for: period))
            XCTAssertTrue(RevenueCatPurchaseContract.purchaseOptions(in: offering).isEmpty)
        }
    }

    func testOfferingRejectsLifetimeProductCategoryAndDurationMismatches() {
        let mismatches = [
            package(
                identifier: "$rc_lifetime",
                packageType: .lifetime,
                productType: .consumable,
                subscriptionPeriod: nil
            ),
            package(
                identifier: "$rc_lifetime",
                packageType: .lifetime,
                productType: .autoRenewableSubscription,
                subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .year)
            ),
            package(
                identifier: "$rc_lifetime",
                packageType: .lifetime,
                productType: .nonConsumable,
                subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .year)
            ),
        ]

        for package in mismatches {
            let offering = offering(with: [package])
            XCTAssertNil(RevenueCatPurchaseContract.package(in: offering, for: .lifetime))
            XCTAssertTrue(RevenueCatPurchaseContract.purchaseOptions(in: offering).isEmpty)
        }
    }

    func testOfferingAcceptsStoreKit1AutoRenewableSubscriptionPackages() {
        let expectations: [(RevenueCatBillingPeriod, Int, SKProduct.PeriodUnit)] = [
            (.monthly, 1, .month),
            (.annual, 1, .year),
            (.annual, 12, .month),
        ]

        for (period, value, unit) in expectations {
            let package = storeKit1Package(
                for: period,
                subscriptionValue: value,
                subscriptionUnit: unit
            )
            let offering = offering(with: [package])

            XCTAssertNotNil(package.storeProduct.sk1Product)
            XCTAssertEqual(package.storeProduct.productType, .nonConsumable)
            XCTAssertIdentical(
                RevenueCatPurchaseContract.package(in: offering, for: period),
                package
            )
            XCTAssertEqual(
                RevenueCatPurchaseContract.purchaseOptions(in: offering).map(\.period),
                [period]
            )
        }
    }

    func testOfferingRejectsStoreKit1ProductsWithoutExactShape() {
        let mismatches: [(RevenueCatBillingPeriod, Package)] = [
            (.lifetime, storeKit1Package(for: .lifetime)),
            (
                .monthly,
                storeKit1Package(
                    for: .monthly,
                    subscriptionValue: 1,
                    subscriptionUnit: .month,
                    subscriptionGroupIdentifier: nil
                )
            ),
            (
                .monthly,
                storeKit1Package(
                    for: .monthly,
                    subscriptionValue: 2,
                    subscriptionUnit: .month
                )
            ),
            (
                .annual,
                storeKit1Package(
                    for: .annual,
                    subscriptionValue: 6,
                    subscriptionUnit: .month
                )
            ),
            (.annual, storeKit1Package(for: .annual)),
        ]

        for (period, package) in mismatches {
            let offering = offering(with: [package])

            XCTAssertNotNil(package.storeProduct.sk1Product)
            XCTAssertNil(RevenueCatPurchaseContract.package(in: offering, for: period))
            XCTAssertTrue(RevenueCatPurchaseContract.purchaseOptions(in: offering).isEmpty)
        }
    }

    func testAppleKeyValidationOnlyAcceptsPublicSDKKeys() {
        XCTAssertTrue(RevenueCatPurchaseContract.isPublicAppleSDKKey("appl_public-key"))
        XCTAssertTrue(RevenueCatPurchaseContract.isPublicAppleSDKKey("appl_a"))

        for value in ["", "appl_", "test_key", "sk_secret", "atk_secret", "apple_key", " appl_key"] {
            XCTAssertFalse(RevenueCatPurchaseContract.isPublicAppleSDKKey(value), value)
        }
    }

    func testHostedCheckoutUsesLowercaseIdentityAndSelectedPackage() throws {
        let userID = try XCTUnwrap(UUID(uuidString: "ABCDEFAB-1234-5678-9ABC-DEF012345678"))
        let expectedUserID = "abcdefab-1234-5678-9abc-def012345678"
        let expectations: [(RevenueCatBillingPeriod, String)] = [
            (.monthly, "$rc_monthly"),
            (.annual, "$rc_annual"),
            (.lifetime, "$rc_lifetime"),
        ]

        for (period, packageID) in expectations {
            let url = try XCTUnwrap(
                RevenueCatPurchaseContract.hostedCheckoutURL(
                    baseLink: "https://pay.rev.cat/production-token",
                    userID: userID,
                    email: "person+checkout@example.com",
                    period: period
                )
            )
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
            )

            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "pay.rev.cat")
            XCTAssertEqual(components.path, "/production-token/\(expectedUserID)")
            XCTAssertEqual(query["email"] ?? nil, "person+checkout@example.com")
            XCTAssertEqual(query["package_id"] ?? nil, packageID)
        }
    }

    func testHostedCheckoutRejectsUnsafeOrMalformedBaseLinks() throws {
        let userID = try XCTUnwrap(UUID(uuidString: "ABCDEFAB-1234-5678-9ABC-DEF012345678"))
        let invalidLinks = [
            "http://pay.rev.cat/token",
            "https://example.com/token",
            "https://user@pay.rev.cat/token",
            "https://pay.rev.cat:443/token",
            "https://pay.rev.cat",
            "https://pay.rev.cat/token/",
            "https://pay.rev.cat/token/extra",
            "https://pay.rev.cat//token",
            "https://pay.rev.cat/token%2Fextra",
            "https://pay.rev.cat/token%2fextra",
            "https://pay.rev.cat/token%5Cextra",
            "https://pay.rev.cat/token%5cextra",
            "https://pay.rev.cat/.",
            "https://pay.rev.cat/..",
            "https://pay.rev.cat/%2e",
            "https://pay.rev.cat/%2e%2e",
            "https://pay.rev.cat/token?package_id=$rc_monthly",
            "https://pay.rev.cat/token#checkout",
        ]

        for link in invalidLinks {
            XCTAssertNil(
                RevenueCatPurchaseContract.hostedCheckoutURL(
                    baseLink: link,
                    userID: userID,
                    email: "person@example.com",
                    period: .monthly
                ),
                link
            )
        }

        XCTAssertNotNil(RevenueCatPurchaseContract.validatedWebPurchaseLink("https://PAY.REV.CAT/token"))
    }

    func testEntitlementStatusUsesTheExactConfiguredEntitlement() {
        let expirationDate = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertEqual(
            RevenueCatPurchaseContract.entitlementStatus(
                from: customerInfo(),
                entitlementID: "pro"
            ),
            .inactive
        )
        XCTAssertEqual(
            RevenueCatPurchaseContract.entitlementStatus(
                from: customerInfo(entitlementID: "pro", isActive: false),
                entitlementID: "pro"
            ),
            .inactive
        )
        XCTAssertEqual(
            RevenueCatPurchaseContract.entitlementStatus(
                from: customerInfo(entitlementID: "premium", isActive: true),
                entitlementID: "pro"
            ),
            .inactive
        )
        XCTAssertEqual(
            RevenueCatPurchaseContract.entitlementStatus(
                from: customerInfo(
                    entitlementID: "pro",
                    isActive: true,
                    expirationDate: expirationDate
                ),
                entitlementID: "pro"
            ),
            .pro
        )
        XCTAssertEqual(
            RevenueCatPurchaseContract.entitlementStatus(
                from: customerInfo(entitlementID: "pro", isActive: true),
                entitlementID: "pro"
            ),
            .lifetime
        )
    }

    func testPaywallOrderingAndDefaultSelectionAreDeterministic() {
        let options = [
            RevenueCatPurchaseOption(period: .lifetime, price: "$199.99"),
            RevenueCatPurchaseOption(period: .monthly, price: "$8.49"),
            RevenueCatPurchaseOption(period: .annual, price: "$84.99"),
        ]
        let ordered = RevenueCatPaywallContract.orderedOptions(options)

        XCTAssertEqual(ordered.map(\.period), [.annual, .monthly, .lifetime])
        XCTAssertEqual(RevenueCatPaywallContract.preferredPeriod(in: ordered), .annual)

        let fallback = RevenueCatPaywallContract.orderedOptions(Array(options.prefix(2)))
        XCTAssertEqual(fallback.map(\.period), [.monthly, .lifetime])
        XCTAssertEqual(RevenueCatPaywallContract.preferredPeriod(in: fallback), .monthly)
        XCTAssertNil(RevenueCatPaywallContract.preferredPeriod(in: []))
    }

    private func customerInfo(
        entitlementID: String? = nil,
        isActive: Bool = false,
        expirationDate: Date? = nil
    ) -> CustomerInfo {
        let requestDate = Date(timeIntervalSince1970: 1_900_000_000)
        var entitlements: [String: EntitlementInfo] = [:]

        if let entitlementID {
            entitlements[entitlementID] = EntitlementInfo(
                identifier: entitlementID,
                isActive: isActive,
                willRenew: expirationDate != nil,
                periodType: .normal,
                expirationDate: expirationDate,
                store: .appStore,
                productIdentifier: "contract-test-product",
                isSandbox: true,
                ownershipType: .purchased
            )
        }

        return CustomerInfo(
            entitlements: EntitlementInfos(entitlements: entitlements),
            requestDate: requestDate,
            firstSeen: requestDate,
            originalAppUserId: "contract-test-user"
        )
    }

    private func validPackage(for period: RevenueCatBillingPeriod) -> Package {
        switch period {
        case .monthly:
            return package(
                identifier: "$rc_monthly",
                packageType: .monthly,
                productType: .autoRenewableSubscription,
                subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .month)
            )
        case .annual:
            return package(
                identifier: "$rc_annual",
                packageType: .annual,
                productType: .autoRenewableSubscription,
                subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .year)
            )
        case .lifetime:
            return package(
                identifier: "$rc_lifetime",
                packageType: .lifetime,
                productType: .nonConsumable,
                subscriptionPeriod: nil
            )
        }
    }

    private func package(
        identifier: String,
        packageType: PackageType,
        productType: StoreProduct.ProductType,
        subscriptionPeriod: SubscriptionPeriod?
    ) -> Package {
        let product = TestStoreProduct(
            localizedTitle: "Contract test product",
            price: Decimal(10),
            currencyCode: "USD",
            localizedPriceString: "$10.00",
            productIdentifier: "contract-test-\(identifier)",
            productType: productType,
            localizedDescription: "Contract test product",
            subscriptionGroupIdentifier: productType == .autoRenewableSubscription
                ? "contract-test-subscriptions"
                : nil,
            subscriptionPeriod: subscriptionPeriod,
            locale: Locale(identifier: "en_US")
        ).toStoreProduct()

        return Package(
            identifier: identifier,
            packageType: packageType,
            storeProduct: product,
            offeringIdentifier: "contract-test-offering",
            webCheckoutUrl: nil
        )
    }

    private func storeKit1Package(
        for period: RevenueCatBillingPeriod,
        subscriptionValue: Int? = nil,
        subscriptionUnit: SKProduct.PeriodUnit? = nil,
        subscriptionGroupIdentifier: String? = "contract-test-subscriptions"
    ) -> Package {
        let product = ContractSK1Product(
            subscriptionValue: subscriptionValue,
            subscriptionUnit: subscriptionUnit,
            subscriptionGroupIdentifier: subscriptionGroupIdentifier
        )

        return Package(
            identifier: RevenueCatPurchaseContract.packageIdentifier(for: period),
            packageType: RevenueCatPurchaseContract.packageType(for: period),
            storeProduct: StoreProduct(sk1Product: product),
            offeringIdentifier: "contract-test-offering",
            webCheckoutUrl: nil
        )
    }

    private func offering(with packages: [Package]) -> Offering {
        Offering(
            identifier: "contract-test-offering",
            serverDescription: "Contract test offering",
            availablePackages: packages,
            webCheckoutUrl: nil
        )
    }
}

final class AuthManagerSessionContractTests: XCTestCase {
    func testAccountSwitchClearsOnlyAPreviouslyPublishedDifferentUser() throws {
        let accountA = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let accountB = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

        XCTAssertFalse(
            AuthManager.shouldClearPublishedUser(
                publishedUserID: nil,
                sessionUserID: accountB
            )
        )
        XCTAssertFalse(
            AuthManager.shouldClearPublishedUser(
                publishedUserID: accountA,
                sessionUserID: accountA
            )
        )
        XCTAssertTrue(
            AuthManager.shouldClearPublishedUser(
                publishedUserID: accountA,
                sessionUserID: accountB
            )
        )
    }

    func testBackendUpdatesRequireTheOriginalPublishedIdentityAndIdentityGeneration() throws {
        let accountA = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let accountB = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

        let matches: (UInt64, UUID?, UUID, Bool) -> Bool = {
            currentIdentityGeneration,
            publishedUserID,
            resultUserID,
            isAuthenticated in
            AuthManager.backendUpdateMatchesActiveIdentity(
                expectedUserID: accountA,
                expectedIdentityGeneration: 7,
                currentIdentityGeneration: currentIdentityGeneration,
                publishedUserID: publishedUserID,
                resultUserID: resultUserID,
                isAuthenticated: isAuthenticated
            )
        }

        XCTAssertTrue(matches(7, accountA, accountA, true))
        XCTAssertFalse(matches(8, accountA, accountA, true))
        XCTAssertFalse(matches(7, nil, accountA, true))
        XCTAssertFalse(matches(7, accountB, accountA, true))
        XCTAssertFalse(matches(7, accountA, accountB, true))
        XCTAssertFalse(matches(7, accountA, accountA, false))
    }

    func testBackendMutationContextsRequireTheOriginalPublishedIdentity() throws {
        let accountA = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let accountB = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

        let matches: (UInt64, UUID?, Bool) -> Bool = {
            currentIdentityGeneration,
            publishedUserID,
            isAuthenticated in
            AuthManager.backendMutationContextMatchesActiveIdentity(
                expectedUserID: accountA,
                expectedIdentityGeneration: 7,
                currentIdentityGeneration: currentIdentityGeneration,
                publishedUserID: publishedUserID,
                isAuthenticated: isAuthenticated
            )
        }

        XCTAssertTrue(matches(7, accountA, true))
        XCTAssertFalse(matches(8, accountA, true))
        XCTAssertFalse(matches(7, nil, true))
        XCTAssertFalse(matches(7, accountB, true))
        XCTAssertFalse(matches(7, accountA, false))
    }

    func testRefreshCannotOverwriteANewerBackendProfileRevision() {
        XCTAssertTrue(
            AuthManager.refreshCanPublishBackendProfile(
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedProfileRevision: 9,
                currentProfileRevision: 9
            )
        )
        XCTAssertFalse(
            AuthManager.refreshCanPublishBackendProfile(
                expectedGeneration: 4,
                currentGeneration: 5,
                expectedProfileRevision: 9,
                currentProfileRevision: 9
            )
        )
        XCTAssertFalse(
            AuthManager.refreshCanPublishBackendProfile(
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedProfileRevision: 9,
                currentProfileRevision: 10
            )
        )
    }

    func testBackendMutationGateSerializesDelayedOperations() async {
        let gate = BackendMutationGate()
        let events = EventRecorder()
        let firstEntered = AsyncSignal()
        let releaseFirst = AsyncSignal()

        let first = Task {
            await gate.acquire()
            await events.append("first-start")
            await firstEntered.open()
            await releaseFirst.wait()
            await events.append("first-end")
            await gate.release()
        }
        await firstEntered.wait()
        let second = Task {
            await gate.acquire()
            await events.append("second")
            await gate.release()
        }

        await releaseFirst.open()
        _ = await (first.value, second.value)
        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["first-start", "first-end", "second"])
    }

    func testQueuedBackendMutationDoesNotStartAfterTheIdentityChanges() async throws {
        let accountA = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let gate = BackendMutationGate()
        let firstEntered = AsyncSignal()
        let releaseFirst = AsyncSignal()
        let identity = TestIdentityState(
            generation: 7,
            publishedUserID: accountA,
            isAuthenticated: true
        )

        let first = Task {
            await gate.acquire()
            await firstEntered.open()
            await releaseFirst.wait()
            await gate.release()
        }
        await firstEntered.wait()

        let second = Task {
            await gate.acquire()
            let state = await identity.snapshot()
            let isCurrent = AuthManager.backendMutationContextMatchesActiveIdentity(
                expectedUserID: accountA,
                expectedIdentityGeneration: 7,
                currentIdentityGeneration: state.generation,
                publishedUserID: state.publishedUserID,
                isAuthenticated: state.isAuthenticated
            )
            guard isCurrent else {
                await gate.release()
                return false
            }

            await identity.markBodyStarted()
            await gate.release()
            return true
        }

        await identity.changeGeneration(to: 8)
        await releaseFirst.open()
        _ = await first.value

        let secondDidStart = await second.value
        let bodyDidStart = await identity.didStartBody
        XCTAssertFalse(secondDidStart)
        XCTAssertFalse(bodyDidStart)
    }
}

private actor EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor AsyncSignal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private actor TestIdentityState {
    private var generation: UInt64
    private var publishedUserID: UUID?
    private var isAuthenticated: Bool
    private(set) var didStartBody = false

    init(generation: UInt64, publishedUserID: UUID?, isAuthenticated: Bool) {
        self.generation = generation
        self.publishedUserID = publishedUserID
        self.isAuthenticated = isAuthenticated
    }

    func snapshot() -> (generation: UInt64, publishedUserID: UUID?, isAuthenticated: Bool) {
        (generation, publishedUserID, isAuthenticated)
    }

    func changeGeneration(to value: UInt64) {
        generation = value
    }

    func markBodyStarted() {
        didStartBody = true
    }
}

private final class ContractSK1Product: SKProduct, @unchecked Sendable {
    private let mockSubscriptionPeriod: SKProductSubscriptionPeriod?
    private let mockSubscriptionGroupIdentifier: String?

    init(
        subscriptionValue: Int?,
        subscriptionUnit: SKProduct.PeriodUnit?,
        subscriptionGroupIdentifier: String?
    ) {
        if let subscriptionValue, let subscriptionUnit {
            mockSubscriptionPeriod = ContractSK1SubscriptionPeriod(
                numberOfUnits: subscriptionValue,
                unit: subscriptionUnit
            )
            mockSubscriptionGroupIdentifier = subscriptionGroupIdentifier
        } else {
            mockSubscriptionPeriod = nil
            mockSubscriptionGroupIdentifier = nil
        }
    }

    override var price: NSDecimalNumber { 10 }
    override var priceLocale: Locale { Locale(identifier: "en_US") }
    override var productIdentifier: String { "contract-test-sk1-product" }
    override var localizedTitle: String { "Contract test product" }
    override var localizedDescription: String { "Contract test product" }
    override var subscriptionPeriod: SKProductSubscriptionPeriod? { mockSubscriptionPeriod }
    override var subscriptionGroupIdentifier: String? { mockSubscriptionGroupIdentifier }
}

private final class ContractSK1SubscriptionPeriod: SKProductSubscriptionPeriod, @unchecked Sendable {
    private let mockNumberOfUnits: Int
    private let mockUnit: SKProduct.PeriodUnit

    init(numberOfUnits: Int, unit: SKProduct.PeriodUnit) {
        mockNumberOfUnits = numberOfUnits
        mockUnit = unit
    }

    override var numberOfUnits: Int { mockNumberOfUnits }
    override var unit: SKProduct.PeriodUnit { mockUnit }
}
