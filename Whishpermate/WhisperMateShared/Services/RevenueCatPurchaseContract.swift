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
        switch packageType(for: period) {
        case .monthly:
            return offering.monthly
        case .annual:
            return offering.annual
        case .lifetime:
            return offering.lifetime
        default:
            return nil
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
