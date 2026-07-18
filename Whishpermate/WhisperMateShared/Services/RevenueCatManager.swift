import Combine
import Foundation
import RevenueCat
#if os(macOS)
    import AppKit
#endif

public enum RevenueCatBillingPeriod: String, CaseIterable, Identifiable {
    case monthly
    case annual
    case lifetime

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .monthly:
            return "Monthly"
        case .annual:
            return "Annual"
        case .lifetime:
            return "Lifetime"
        }
    }

    public var detailText: String {
        switch self {
        case .monthly:
            return "Pay month to month"
        case .annual:
            return "One payment each year"
        case .lifetime:
            return "Pay once"
        }
    }
}

public struct RevenueCatPurchaseOption: Identifiable {
    public let period: RevenueCatBillingPeriod
    public let price: String?

    public var id: String { period.id }

    public var detailText: String {
        guard let price else {
            return period.detailText
        }

        switch period {
        case .monthly:
            return "\(price) per month"
        case .annual:
            return "\(price) per year"
        case .lifetime:
            return "\(price), one-time payment"
        }
    }
}

public enum RevenueCatEntitlementStatus: Equatable, Sendable {
    case inactive
    case pro
    case lifetime

    var isActive: Bool {
        self != .inactive
    }

    var subscriptionStatus: String? {
        switch self {
        case .inactive:
            return nil
        case .pro:
            return "pro"
        case .lifetime:
            return "lifetime"
        }
    }
}

public enum RevenueCatIdentificationResult: Equatable, Sendable {
    case unavailable
    case confirmed(RevenueCatEntitlementStatus)
    case failed
}

/// Owns the RevenueCat SDK lifecycle for both Apple apps.
@MainActor
public final class RevenueCatManager: NSObject, ObservableObject {
    public static let shared = RevenueCatManager()

    @Published public private(set) var isConfigured = false
    @Published public private(set) var isPurchasing = false
    @Published public private(set) var isPro = false
    @Published public private(set) var errorMessage: String?

    private var externalPurchasePending = false
    private var confirmedAppUserID: String?
    private var confirmedEntitlement: RevenueCatEntitlementStatus?
    #if !os(macOS)
        /// RevenueCat has process-wide identity. MainActor methods are reentrant at
        /// every await, so billing must explicitly lease that identity until the
        /// StoreKit operation has returned.
        private var identityLeaseHeld = false
        private var identityLeaseWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    public func clearError() {
        errorMessage = nil
    }

    public func configure() {
        guard !isConfigured else { return }
        #if os(macOS)
            guard let purchaseLink = SecretsLoader.getValue(for: "REVENUECAT_WEB_PURCHASE_LINK"),
                  RevenueCatPurchaseContract.validatedWebPurchaseLink(purchaseLink) != nil
            else {
                DebugLog.warning("Purchases are not configured in this build", context: "RevenueCat")
                return
            }
            isConfigured = true
            return
        #else
        guard let apiKey = SecretsLoader.getValue(for: "REVENUECAT_APPLE_API_KEY"),
              RevenueCatPurchaseContract.isPublicAppleSDKKey(apiKey)
        else {
            DebugLog.warning("Purchases are not configured in this build", context: "RevenueCat")
            return
        }

        #if DEBUG
            Purchases.logLevel = .debug
        #endif
        Purchases.configure(withAPIKey: apiKey)
        Purchases.shared.delegate = self
        isConfigured = true

        #endif
    }

    @discardableResult
    public func identify(userID: UUID, email: String) async -> RevenueCatIdentificationResult {
        configure()
        guard isConfigured else { return .unavailable }
        #if os(macOS)
            return .unavailable
        #else
            await acquireIdentityLease()
            defer { releaseIdentityLease() }
            guard !Task.isCancelled,
                  await AuthManager.shared.hasActiveSession(for: userID)
            else { return .failed }

            return await identifyWhileHoldingLease(userID: userID, email: email)
        #endif
    }

    #if !os(macOS)
        private func identifyWhileHoldingLease(
            userID: UUID,
            email: String
        ) async -> RevenueCatIdentificationResult {

            let appUserID = userID.uuidString.lowercased()
            var lastError: Error?

            if confirmedAppUserID != appUserID {
                confirmedAppUserID = nil
                confirmedEntitlement = nil
                isPro = false
            }

            for attempt in 0 ..< 2 {
                do {
                    let customerInfo: CustomerInfo
                    if Purchases.shared.appUserID == appUserID {
                        customerInfo = try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent)
                    } else {
                        customerInfo = try await Purchases.shared.logIn(appUserID).customerInfo
                    }

                    guard Purchases.shared.appUserID == appUserID else {
                        throw RevenueCatManagerError.identityMismatch
                    }
                    guard await AuthManager.shared.hasActiveSession(for: userID) else {
                        return .failed
                    }

                    Purchases.shared.attribution.setEmail(email)
                    let entitlement = entitlementStatus(from: customerInfo)
                    recordConfirmed(entitlement, appUserID: appUserID)
                    errorMessage = nil
                    return .confirmed(entitlement)
                } catch is CancellationError {
                    return .failed
                } catch {
                    lastError = error
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            }

            errorMessage = "Your subscription could not be refreshed."
            if let lastError {
                DebugLog.warning("Customer identification failed: \(lastError.localizedDescription)", context: "RevenueCat")
            }
            return .failed
        }
    #endif

    public func signOut() async {
        #if os(macOS)
            return
        #else
            guard isConfigured else { return }
            await acquireIdentityLease()
            defer { releaseIdentityLease() }

            defer {
                confirmedAppUserID = nil
                confirmedEntitlement = nil
                isPro = false
            }
            guard !Purchases.shared.isAnonymous else { return }
            do {
                _ = try await Purchases.shared.logOut()
            } catch {
                DebugLog.warning("Customer sign out failed: \(error.localizedDescription)", context: "RevenueCat")
            }
        #endif
    }

    @discardableResult
    public func purchase(_ period: RevenueCatBillingPeriod) async -> Bool {
        errorMessage = nil
        configure()
        guard isConfigured else {
            errorMessage = "Checkout isn’t available right now. Please try again later."
            return false
        }
        guard AuthManager.shared.isAuthenticated,
              let user = AuthManager.shared.currentUser
        else {
            errorMessage = "Sign in to continue to checkout."
            AuthManager.shared.openSignUp()
            return false
        }

        #if os(macOS)
            guard let baseLink = SecretsLoader.getValue(for: "REVENUECAT_WEB_PURCHASE_LINK"),
                  let url = RevenueCatPurchaseContract.hostedCheckoutURL(
                      baseLink: baseLink,
                      userID: user.userId,
                      email: user.email,
                      period: period
                  )
            else {
                errorMessage = "Checkout isn’t available right now. Please try again later."
                return false
            }
            guard NSWorkspace.shared.open(url) else {
                errorMessage = "The purchase page could not be opened."
                return false
            }
            externalPurchasePending = true
            return false
        #else

            isPurchasing = true
            errorMessage = nil
            defer { isPurchasing = false }

            do {
                let entitlement: RevenueCatEntitlementStatus
                do {
                    await acquireIdentityLease()
                    defer { releaseIdentityLease() }
                    guard !Task.isCancelled, hasCurrentAccount(user) else {
                        throw RevenueCatManagerError.identityMismatch
                    }
                    guard await prepareIdentityForPurchaseWhileHoldingLease(user) else {
                        throw RevenueCatManagerError.identityMismatch
                    }
                    let offerings = try await Purchases.shared.offerings()
                    guard hasExactIdentity(for: user) else {
                        throw RevenueCatManagerError.identityMismatch
                    }
                    guard let offering = offerings.current else {
                        throw RevenueCatManagerError.noOffering
                    }
                    let package = RevenueCatPurchaseContract.package(in: offering, for: period)
                    guard let package else { throw RevenueCatManagerError.noPackage }
                    guard await AuthManager.shared.hasActiveSession(for: user.userId),
                          hasExactIdentity(for: user)
                    else {
                        throw RevenueCatManagerError.identityMismatch
                    }

                    let result = try await Purchases.shared.purchase(package: package)
                    if result.userCancelled { return false }
                    guard hasRevenueCatIdentity(for: user) else {
                        throw RevenueCatManagerError.identityMismatch
                    }
                    entitlement = entitlementStatus(from: result.customerInfo)
                    recordConfirmed(entitlement, appUserID: user.userId.uuidString.lowercased())
                }

                await AuthManager.shared.reconcileAndApplyRevenueCatEntitlement(entitlement, for: user.userId)
                await AuthManager.shared.refreshUser()
                guard entitlement.isActive else {
                    errorMessage = "Your purchase is still being confirmed. Please restore your purchases in a moment."
                    return false
                }
                return true
            } catch {
                errorMessage = "Your purchase could not be completed. Please try again."
                DebugLog.warning("Purchase failed: \(error.localizedDescription)", context: "RevenueCat")
                return false
            }
        #endif
    }

    public func fetchAvailablePurchaseOptions() async -> [RevenueCatPurchaseOption] {
        configure()
        errorMessage = nil
        guard isConfigured else {
            errorMessage = "Checkout isn’t available right now. Please try again later."
            return []
        }

        #if os(macOS)
            return RevenueCatBillingPeriod.allCases.map {
                RevenueCatPurchaseOption(period: $0, price: nil)
            }
        #else
            do {
                guard let offering = try await Purchases.shared.offerings().current else {
                    throw RevenueCatManagerError.noOffering
                }

                var options: [RevenueCatPurchaseOption] = []
                if let package = offering.monthly {
                    options.append(
                        RevenueCatPurchaseOption(period: .monthly, price: package.localizedPriceString)
                    )
                }
                if let package = offering.annual {
                    options.append(
                        RevenueCatPurchaseOption(period: .annual, price: package.localizedPriceString)
                    )
                }
                if let package = offering.lifetime {
                    options.append(
                        RevenueCatPurchaseOption(period: .lifetime, price: package.localizedPriceString)
                    )
                }
                return options
            } catch {
                errorMessage = "Purchase options are not available right now."
                DebugLog.warning("Offering load failed: \(error.localizedDescription)", context: "RevenueCat")
                return []
            }
        #endif
    }

    @discardableResult
    public func restorePurchases() async -> Bool {
        errorMessage = nil
        configure()
        guard isConfigured else {
            errorMessage = "Checkout isn’t available right now. Please try again later."
            return false
        }
        do {
            #if os(macOS)
                guard AuthManager.shared.isAuthenticated else {
                    errorMessage = "Sign in to restore your purchases."
                    AuthManager.shared.openSignUp()
                    return false
                }
                await AuthManager.shared.refreshUser()
                return AuthManager.shared.currentUser?.subscriptionTier.isPaid == true
            #else
                guard AuthManager.shared.isAuthenticated,
                      let user = AuthManager.shared.currentUser
                else {
                    errorMessage = "Sign in to restore your purchases."
                    AuthManager.shared.openSignUp()
                    return false
                }
                let entitlement: RevenueCatEntitlementStatus
                do {
                    await acquireIdentityLease()
                    defer { releaseIdentityLease() }
                    guard !Task.isCancelled, hasCurrentAccount(user) else {
                        throw RevenueCatManagerError.identityMismatch
                    }
                    guard await prepareIdentityForPurchaseWhileHoldingLease(user) else {
                        throw RevenueCatManagerError.identityMismatch
                    }
                    let customerInfo = try await Purchases.shared.restorePurchases()
                    guard hasRevenueCatIdentity(for: user) else {
                        throw RevenueCatManagerError.identityMismatch
                    }
                    entitlement = entitlementStatus(from: customerInfo)
                    recordConfirmed(entitlement, appUserID: user.userId.uuidString.lowercased())
                }

                await AuthManager.shared.reconcileAndApplyRevenueCatEntitlement(entitlement, for: user.userId)
                await AuthManager.shared.refreshUser()
                return AuthManager.shared.currentUser?.userId == user.userId
                    && AuthManager.shared.currentUser?.subscriptionTier.isPaid == true
            #endif
        } catch {
            errorMessage = "Your purchases could not be restored."
            DebugLog.warning("Restore failed: \(error.localizedDescription)", context: "RevenueCat")
            return false
        }
    }

    public func refreshCustomerInfo() async {
        guard isConfigured else { return }
        #if os(macOS)
            let attempts = externalPurchasePending ? 12 : 1
            for attempt in 0 ..< attempts {
                await AuthManager.shared.refreshUser()
                if AuthManager.shared.currentUser?.subscriptionTier.isPaid == true {
                    externalPurchasePending = false
                    break
                }
                if attempt + 1 < attempts {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            return
        #else
            guard AuthManager.shared.isAuthenticated,
                  let user = AuthManager.shared.currentUser
            else { return }

            let result = await identify(userID: user.userId, email: user.email)
            if case let .confirmed(entitlement) = result {
                await AuthManager.shared.reconcileAndApplyRevenueCatEntitlement(entitlement, for: user.userId)
            }
        #endif
    }

    #if !os(macOS)
    private func prepareIdentityForPurchaseWhileHoldingLease(_ user: User) async -> Bool {
        guard await AuthManager.shared.hasActiveSession(for: user.userId) else {
            errorMessage = "Your account could not be verified for this purchase. Please try again."
            return false
        }

        let result = await identifyWhileHoldingLease(userID: user.userId, email: user.email)
        guard case .confirmed = result,
              hasExactIdentity(for: user)
        else {
            errorMessage = "Your account could not be verified for this purchase. Please try again."
            return false
        }

        guard await AuthManager.shared.hasActiveSession(for: user.userId) else {
            errorMessage = "Your account could not be verified for this purchase. Please try again."
            return false
        }
        return true
    }

    private func hasCurrentAccount(_ user: User) -> Bool {
        AuthManager.shared.isAuthenticated
            && AuthManager.shared.currentUser?.userId == user.userId
    }

    private func hasExactIdentity(for user: User) -> Bool {
        hasCurrentAccount(user)
            && hasRevenueCatIdentity(for: user)
    }

    private func hasRevenueCatIdentity(for user: User) -> Bool {
        Purchases.shared.appUserID == user.userId.uuidString.lowercased()
    }

    private func entitlementStatus(from customerInfo: CustomerInfo) -> RevenueCatEntitlementStatus {
        let entitlementID = SecretsLoader.getValue(for: "REVENUECAT_ENTITLEMENT_ID") ?? "pro"
        return RevenueCatPurchaseContract.entitlementStatus(
            from: customerInfo,
            entitlementID: entitlementID
        )
    }

    private func acquireIdentityLease() async {
        guard identityLeaseHeld else {
            identityLeaseHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            identityLeaseWaiters.append(continuation)
        }
    }

    private func releaseIdentityLease() {
        guard !identityLeaseWaiters.isEmpty else {
            identityLeaseHeld = false
            return
        }

        identityLeaseWaiters.removeFirst().resume()
    }

    private func recordConfirmed(_ entitlement: RevenueCatEntitlementStatus, appUserID: String) {
        confirmedAppUserID = appUserID
        confirmedEntitlement = entitlement
        isPro = entitlement.isActive
    }

    private func applyDelegateUpdate(sourceAppUserID: String) async {
        guard let user = AuthManager.shared.currentUser else { return }
        let appUserID = user.userId.uuidString.lowercased()
        guard sourceAppUserID == appUserID else {
            DebugLog.warning("Ignored a subscription update for a different account", context: "RevenueCat")
            return
        }

        let entitlement: RevenueCatEntitlementStatus
        do {
            await acquireIdentityLease()
            defer { releaseIdentityLease() }
            guard await AuthManager.shared.hasActiveSession(for: user.userId),
                  hasExactIdentity(for: user)
            else { return }

            // A delegate callback can be delivered after an account switch.
            // Fetch under the identity lease instead of trusting delayed data.
            let currentInfo = try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent)
            guard hasExactIdentity(for: user) else { return }
            entitlement = entitlementStatus(from: currentInfo)
            recordConfirmed(entitlement, appUserID: appUserID)
        } catch {
            DebugLog.warning(
                "Subscription update refresh failed: \(error.localizedDescription)",
                context: "RevenueCat"
            )
            return
        }

        await AuthManager.shared.reconcileAndApplyRevenueCatEntitlement(entitlement, for: user.userId)
    }
    #endif

}

extension RevenueCatManager: PurchasesDelegate {
    nonisolated public func purchases(_ purchases: Purchases, receivedUpdated _: CustomerInfo) {
        let sourceAppUserID = purchases.appUserID
        Task { @MainActor in
            #if !os(macOS)
                await self.applyDelegateUpdate(sourceAppUserID: sourceAppUserID)
            #endif
        }
    }
}

private enum RevenueCatManagerError: LocalizedError {
    case noOffering
    case noPackage
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .noOffering: return "No purchase options are available right now."
        case .noPackage: return "That purchase option is not available right now."
        case .identityMismatch: return "The purchase account could not be verified."
        }
    }
}
