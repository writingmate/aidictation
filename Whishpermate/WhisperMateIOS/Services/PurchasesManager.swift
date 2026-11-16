import Combine
import Foundation
import RevenueCat
import WhisperMateShared

/// Manages in-app purchases through RevenueCat: configures the SDK, tracks the `pro`
/// entitlement, ties purchases to the signed-in account and restores them.
@MainActor
final class PurchasesManager: ObservableObject {
    static let shared = PurchasesManager()

    // MARK: - Published Properties

    /// Whether purchases are available in this build. False when no usable API key is configured.
    @Published private(set) var isConfigured = false

    /// Whether the store's `pro` entitlement is active for the current customer.
    @Published private(set) var isProActive = false

    /// Whether a restore is in flight.
    @Published private(set) var isRestoring = false

    /// Set when dictation was blocked by the word limit and the paywall should be shown.
    @Published var isPaywallRequested = false

    /// A message for the user, in plain words, about the last purchase or restore.
    @Published var userMessage: String?

    // MARK: - Private Properties

    private let authManager = AuthManager.shared
    private let subscriptionManager = SubscriptionManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var customerInfoTask: Task<Void, Never>?
    private var identifiedUserID: String?

    // MARK: - Types

    private enum Keys {
        static let apiKey = "REVENUECAT_API_KEY"
    }

    private enum Constants {
        static let entitlementIdentifier = "pro"
        static let testStoreKeyPrefix = "test_"
        static let context = "PurchasesManager"
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Configures RevenueCat once. Does nothing when no key is configured, and ignores a
    /// Test Store key outside DEBUG builds, where the SDK would crash on purpose.
    func start() {
        guard !isConfigured else { return }

        guard let apiKey = Self.usableAPIKey() else {
            // Without a store there is nothing to confirm a purchase against.
            subscriptionManager.setStoreEntitlementActive(false)
            return
        }

        #if DEBUG
            Purchases.logLevel = .info
        #else
            Purchases.logLevel = .warn
        #endif

        let userID = authManager.currentUser?.userId.uuidString.lowercased()
        Purchases.configure(withAPIKey: apiKey, appUserID: userID)
        identifiedUserID = userID
        isConfigured = true
        DebugLog.info("RevenueCat configured, identified=\(userID != nil)", context: Constants.context)

        observeCustomerInfo()
        observeAccount()
    }

    /// Whether there is a paywall to show: purchases are on and Pro is not yet active.
    var canShowPaywall: Bool {
        isConfigured && !isProActive
    }

    /// Asks the main screen for the paywall after dictation was blocked by the word limit.
    /// Does nothing when purchases are unavailable, so the text reason stays the only signal.
    func requestPaywall() {
        guard canShowPaywall else { return }
        isPaywallRequested = true
    }

    /// Applies customer info delivered by the paywall after a purchase or restore.
    func apply(_ customerInfo: CustomerInfo) {
        let isActive = customerInfo.entitlements[Constants.entitlementIdentifier]?.isActive == true
        isProActive = isActive
        subscriptionManager.setStoreEntitlementActive(isActive)
    }

    /// Restores earlier purchases made with this Apple Account.
    func restorePurchases() async {
        guard isConfigured, !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }

        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            apply(customerInfo)
            userMessage = isProActive
                ? "Your purchase was restored. You have Pro."
                : "We couldn't find a purchase to restore for this Apple Account."
        } catch {
            report(error, action: "restore")
        }
    }

    /// Turns a purchase or restore error into a message for the user. Cancelling is not an error.
    func report(_ error: Error, action: String) {
        DebugLog.warning("\(action) failed: \(error.localizedDescription)", context: Constants.context)
        userMessage = Self.plainMessage(for: error)
    }

    // MARK: - Private Methods

    private static func usableAPIKey() -> String? {
        guard let apiKey = SecretsLoader.getValue(for: Keys.apiKey) else {
            DebugLog.info("No RevenueCat key configured, purchases are off", context: Constants.context)
            return nil
        }

        #if !DEBUG
            if apiKey.hasPrefix(Constants.testStoreKeyPrefix) {
                DebugLog.warning("Ignoring a Test Store key in a release build, purchases are off", context: Constants.context)
                return nil
            }
        #endif

        return apiKey
    }

    private func observeCustomerInfo() {
        customerInfoTask?.cancel()
        customerInfoTask = Task { [weak self] in
            for await customerInfo in Purchases.shared.customerInfoStream {
                self?.apply(customerInfo)
            }
        }
    }

    private func observeAccount() {
        authManager.$currentUser
            .map { $0?.userId.uuidString.lowercased() }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userID in
                Task { await self?.syncIdentity(with: userID) }
            }
            .store(in: &cancellables)
    }

    private func syncIdentity(with userID: String?) async {
        guard isConfigured, userID != identifiedUserID else { return }

        do {
            if let userID {
                let result = try await Purchases.shared.logIn(userID)
                identifiedUserID = userID
                apply(result.customerInfo)
                DebugLog.info("RevenueCat logged in", context: Constants.context)
            } else {
                identifiedUserID = nil
                guard !Purchases.shared.isAnonymous else { return }
                apply(try await Purchases.shared.logOut())
                DebugLog.info("RevenueCat logged out", context: Constants.context)
            }
        } catch {
            // Identity is retried on the next account change; the purchase itself is unaffected.
            DebugLog.warning("Identity sync failed: \(error.localizedDescription)", context: Constants.context)
        }
    }

    private static func plainMessage(for error: Error) -> String? {
        let nsError = error as NSError
        let bridgedCode = nsError.domain == RevenueCat.ErrorCode.errorDomain
            ? RevenueCat.ErrorCode(rawValue: nsError.code)
            : nil
        guard let code = (error as? RevenueCat.ErrorCode) ?? bridgedCode else {
            return "Something went wrong with the purchase. Please try again."
        }

        switch code {
        case .purchaseCancelledError:
            return nil
        case .networkError, .offlineConnectionError, .apiEndpointBlockedError, .productRequestTimedOut:
            return "We couldn't reach the store. Check your connection and try again."
        case .purchaseNotAllowedError:
            return "Purchases aren't allowed on this device. Check Screen Time and payment settings."
        case .paymentPendingError:
            return "Your payment is waiting for approval. Pro unlocks as soon as it goes through."
        case .productAlreadyPurchasedError:
            return "You already own this. Tap Restore Purchases to unlock it."
        case .receiptAlreadyInUseError, .receiptInUseByOtherSubscriberError, .purchaseBelongsToOtherUser:
            return "This purchase belongs to a different account. Log in to that account to use it."
        case .productNotAvailableForPurchaseError, .purchaseInvalidError, .ineligibleError:
            return "This plan isn't available right now. Please try another one."
        case .storeProblemError:
            return "The App Store had a problem. Please try again in a moment."
        default:
            return "Something went wrong with the purchase. Please try again."
        }
    }
}
