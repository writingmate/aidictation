import Foundation
import RevenueCat

enum RevenueCatPurchaseContract {
    static func isPublicAppleSDKKey(_ key: String) -> Bool {
        key.hasPrefix("appl_") && key.count > "appl_".count
    }

    static func packageIdentifier(for period: RevenueCatBillingPeriod) -> String {
        switch period {
        case .monthly:
            return "$rc_monthly"
        case .annual:
            return "$rc_annual"
        case .lifetime:
            return "$rc_lifetime"
        }
    }

    static func packageType(for period: RevenueCatBillingPeriod) -> PackageType {
        switch period {
        case .monthly:
            return .monthly
        case .annual:
            return .annual
        case .lifetime:
            return .lifetime
        }
    }

    static func package(in offering: Offering, for period: RevenueCatBillingPeriod) -> Package? {
        let package: Package?
        switch period {
        case .monthly:
            package = offering.monthly
        case .annual:
            package = offering.annual
        case .lifetime:
            package = offering.lifetime
        }

        guard let package,
              package.identifier == packageIdentifier(for: period),
              package.packageType == packageType(for: period),
              storeProduct(package.storeProduct, matches: period)
        else {
            return nil
        }
        return package
    }

    static func purchaseOptions(in offering: Offering) -> [RevenueCatPurchaseOption] {
        RevenueCatBillingPeriod.allCases.compactMap { period in
            guard let package = package(in: offering, for: period) else {
                return nil
            }
            return RevenueCatPurchaseOption(period: period, price: package.localizedPriceString)
        }
    }

    static func validatedWebPurchaseLink(_ value: String) -> URL? {
        guard let components = URLComponents(string: value) else {
            return nil
        }
        let percentEncodedPath = components.percentEncodedPath.lowercased()
        let pathSegments = components.path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "pay.rev.cat",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              !percentEncodedPath.contains("%2f"),
              !percentEncodedPath.contains("%5c"),
              !components.path.contains("\\"),
              pathSegments.count == 2,
              pathSegments[0].isEmpty,
              !pathSegments[1].isEmpty,
              pathSegments[1] != ".",
              pathSegments[1] != "..",
              let url = components.url
        else {
            return nil
        }
        return url
    }

    static func hostedCheckoutURL(
        baseLink: String,
        userID: UUID,
        email: String,
        period: RevenueCatBillingPeriod
    ) -> URL? {
        guard let baseURL = validatedWebPurchaseLink(baseLink),
              var components = URLComponents(
                  url: baseURL.appendingPathComponent(userID.uuidString.lowercased()),
                  resolvingAgainstBaseURL: false
              )
        else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "email", value: email),
            URLQueryItem(name: "package_id", value: packageIdentifier(for: period)),
        ]
        return components.url
    }

    static func entitlementStatus(
        from customerInfo: CustomerInfo,
        entitlementID: String
    ) -> RevenueCatEntitlementStatus {
        let entitlement = customerInfo.entitlements.all[entitlementID]
        guard entitlement?.isActive == true else { return .inactive }
        return entitlement?.expirationDate == nil ? .lifetime : .pro
    }

    private static func storeProduct(
        _ product: StoreProduct,
        matches period: RevenueCatBillingPeriod
    ) -> Bool {
        switch period {
        case .monthly:
            return product.productType == .autoRenewableSubscription
                && product.productCategory == .subscription
                && product.subscriptionPeriod?.value == 1
                && product.subscriptionPeriod?.unit == .month
        case .annual:
            return product.productType == .autoRenewableSubscription
                && product.productCategory == .subscription
                && product.subscriptionPeriod?.value == 1
                && product.subscriptionPeriod?.unit == .year
        case .lifetime:
            return product.productType == .nonConsumable
                && product.productCategory == .nonSubscription
                && product.subscriptionPeriod == nil
        }
    }
}

enum RevenueCatPaywallContract {
    static func orderedOptions(_ options: [RevenueCatPurchaseOption]) -> [RevenueCatPurchaseOption] {
        options.sorted { rank($0.period) < rank($1.period) }
    }

    static func preferredPeriod(in options: [RevenueCatPurchaseOption]) -> RevenueCatBillingPeriod? {
        let periods = options.map(\.period)
        return periods.contains(.annual) ? .annual : periods.first
    }

    private static func rank(_ period: RevenueCatBillingPeriod) -> Int {
        switch period {
        case .annual:
            return 0
        case .monthly:
            return 1
        case .lifetime:
            return 2
        }
    }
}
