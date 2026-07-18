import Foundation
import RevenueCat
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
}
