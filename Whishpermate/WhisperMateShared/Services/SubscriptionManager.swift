//
//  SubscriptionManager.swift
//  WhisperMate
//
//  Created by WhisperMate on 2025-01-24.
//

import Combine
import Foundation
#if canImport(AppKit)
    import AppKit
#endif

public class SubscriptionManager: ObservableObject {
    public static let shared = SubscriptionManager()

    // MARK: - Constants

    private enum Keys {
        static let localWordCount = "localWordCount"
        static let storeEntitlementActive = "storeProEntitlementActive"
    }

    private enum Constants {
        /// App group shared with the keyboard extension, which runs in its own process.
        static let appGroupIdentifier = "group.com.whispermate.shared"
    }

    // MARK: - Published Properties

    @Published public var showUpgradeModal: Bool = false
    @Published public var showSignupModal: Bool = false
    @Published public private(set) var usageVersion: Int = 0

    /// Whether an in-app store purchase currently unlocks Pro. The platform purchase layer
    /// reports it through `setStoreEntitlementActive(_:)`; it counts as paid for signed-in
    /// and anonymous users alike.
    @Published public private(set) var hasStoreEntitlement: Bool

    // MARK: - Private Properties

    private let authManager = AuthManager.shared

    /// Storage the keyboard extension can read too. Falls back to the app's own defaults
    /// where the app group is unavailable.
    private static var entitlementDefaults: UserDefaults {
        UserDefaults(suiteName: Constants.appGroupIdentifier) ?? AppDefaults.shared
    }

    // MARK: - Local Word Tracking (for anonymous users)

    public var localWordCount: Int {
        get { AppDefaults.shared.integer(forKey: Keys.localWordCount) }
        set { AppDefaults.shared.set(newValue, forKey: Keys.localWordCount) }
    }

    // MARK: - Initialization

    private init() {
        hasStoreEntitlement = Self.entitlementDefaults.bool(forKey: Keys.storeEntitlementActive)
    }

    // MARK: - Store Entitlement

    /// Records whether an in-app store purchase unlocks Pro. Persisted so the limit check
    /// gives the same answer at next launch, before the store has been reached.
    public func setStoreEntitlementActive(_ isActive: Bool) {
        guard hasStoreEntitlement != isActive else { return }
        Self.entitlementDefaults.set(isActive, forKey: Keys.storeEntitlementActive)
        hasStoreEntitlement = isActive
        usageVersion += 1
        DebugLog.info("Store entitlement active=\(isActive)", context: "SubscriptionManager")
    }

    // MARK: - Subscription

    public func openUpgrade() {
        guard let stripePaymentLink = SecretsLoader.getValue(for: "STRIPE_PAYMENT_LINK") else {
            print("Missing Stripe payment link configuration")
            return
        }

        if let user = authManager.currentUser {
            if user.subscriptionTier.isPaid || user.stripeSubscriptionId != nil {
                DebugLog.info("Upgrade skipped: user already has an active subscription", context: "SubscriptionManager")
                return
            }
        }

        // Add user email to pre-fill Stripe checkout if available
        var urlString = stripePaymentLink
        if let user = authManager.currentUser {
            // URL encode the email
            if let encodedEmail = user.email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "?prefilled_email=\(encodedEmail)"
            }
        }

        #if canImport(AppKit)
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        #endif
    }

    public func handlePaymentSuccess() async {
        // Refresh user data to get updated subscription tier
        await authManager.refreshUser()

        // Hide upgrade modal if shown
        await MainActor.run {
            self.showUpgradeModal = false
        }
    }

    public func handlePaymentCancel() {
        // User cancelled payment, just close modal
        showUpgradeModal = false
    }

    // MARK: - Usage Helpers

    public func getUsageStatus() -> (used: Int, limit: Int, percentage: Double, isPro: Bool) {
        if let user = authManager.currentUser {
            let isPaid = user.subscriptionTier.isPaid || hasStoreEntitlement
            let limit = user.effectiveWordLimit
            let used = user.totalWordsUsed
            let percentage = isPaid ? 0.0 : user.usagePercentage
            return (used, limit, percentage, isPaid)
        } else {
            // Anonymous user - use local tracking
            let limit = UsageLimits.freeTrialWordLimit
            let used = localWordCount
            let percentage = hasStoreEntitlement ? 0.0 : Double(used) / Double(limit)
            return (used, limit, percentage, hasStoreEntitlement)
        }
    }

    public func shouldShowUpgradePrompt(for wordCount: Int) -> Bool {
        guard let user = authManager.currentUser else {
            return false
        }

        // Don't show for paid users
        if user.subscriptionTier.isPaid || hasStoreEntitlement {
            return false
        }

        // Show if they're approaching limit (90%) or over
        let newTotal = user.totalWordsUsed + wordCount
        let limit = user.effectiveWordLimit
        let percentage = Double(newTotal) / Double(limit)

        return percentage >= 0.9
    }

    public func getUpgradeMessage(for user: User) -> String {
        let remaining = user.wordsRemaining
        if remaining <= 0 {
            let inviteSuffix = ReferralProgram.isEnabled ? " or invite a friend for more words" : ""
            return "You've used all \(user.effectiveWordLimit.formatted()) free words. Upgrade to Pro for unlimited transcriptions\(inviteSuffix)."
        } else if remaining < 200 {
            let inviteSuffix = ReferralProgram.isEnabled ? " or invite a friend for more words" : ""
            return "Only \(remaining) words left. Upgrade for unlimited access\(inviteSuffix)."
        } else {
            return "Upgrade to Pro for unlimited transcriptions and included API access."
        }
    }

    // MARK: - Unified Transcription Check

    /// Check if user can transcribe (works for both authenticated and anonymous users)
    public func checkCanTranscribe() -> (canTranscribe: Bool, reason: String?) {
        DebugLog.info("checkCanTranscribe: isAuthenticated=\(authManager.isAuthenticated), isLoading=\(authManager.isLoading), hasUser=\(authManager.currentUser != nil)", context: "SubscriptionManager")
        if hasStoreEntitlement {
            DebugLog.info("checkCanTranscribe: allowing, store entitlement is active", context: "SubscriptionManager")
            return (true, nil)
        }

        if authManager.isLoading {
            DebugLog.info("checkCanTranscribe: allowing while auth state is loading", context: "SubscriptionManager")
            return (true, nil)
        }

        if authManager.isAuthenticated {
            guard authManager.currentUser != nil else {
                // Profile fetch failed (e.g. backend outage). Never block dictation on a
                // missing profile — fall back to local tracking like an anonymous user.
                let result = checkLocalWordLimit()
                DebugLog.warning("checkCanTranscribe: authenticated but profile unavailable, falling back to local tracking (canTranscribe=\(result.canTranscribe))", context: "SubscriptionManager")
                return result
            }

            // Use server-side tracking for authenticated users
            let result = authManager.checkCanTranscribe()
            DebugLog.info("checkCanTranscribe (auth): canTranscribe=\(result.canTranscribe), reason=\(result.reason ?? "nil")", context: "SubscriptionManager")
            return result
        } else {
            // Use local tracking for anonymous users
            let result = checkLocalWordLimit()
            DebugLog.info("checkCanTranscribe (local): canTranscribe=\(result.canTranscribe), localWordCount=\(localWordCount), limit=\(UsageLimits.freeTrialWordLimit)", context: "SubscriptionManager")
            return result
        }
    }

    /// Records words after transcription and reports whether the destination acknowledged it.
    /// This operation is not idempotent; durable callers must claim it before invoking this method.
    @discardableResult
    public func recordWords(_ count: Int) async -> Bool {
        if authManager.isAuthenticated {
            guard authManager.currentUser != nil else {
                // Profile unavailable — keep counting locally so usage isn't lost.
                addLocalWords(count)
                return true
            }

            do {
                _ = try await authManager.updateWordCount(wordsToAdd: count)
                await MainActor.run {
                    self.usageVersion += 1
                }
                return true
            } catch {
                DebugLog.warning(
                    "Word usage was not acknowledged: \(error.localizedDescription)",
                    context: "SubscriptionManager"
                )
                return false
            }
        } else {
            addLocalWords(count)
            return true
        }
    }

    public func wordCount(for text: String) -> Int {
        text.split { character in
            !(character.isLetter || character.isNumber)
        }.count
    }

    // MARK: - Local Word Limit Methods

    private func checkLocalWordLimit() -> (canTranscribe: Bool, reason: String?) {
        if localWordCount >= UsageLimits.freeTrialWordLimit {
            return (false, "You've dictated 5,000 words. Unlimited is $8.49/month or $84.99/year.")
        }
        return (true, nil)
    }

    public func addLocalWords(_ count: Int) {
        localWordCount += count
        usageVersion += 1
        DebugLog.info("Local trial word count updated: \(localWordCount)/\(UsageLimits.freeTrialWordLimit)", context: "SubscriptionManager")
    }
}

public enum ReferralProgram {
    /// Hides the invite surface in every app. Bonus words already granted are
    /// unaffected — they live on the profile and still count toward the word
    /// limit, so nobody loses what they earned while the feature was live.
    public static let isEnabled = false

    public static let bonusWordsPerReferral = 2000

    public static func inviteURL(for code: String) -> URL? {
        if let base = SecretsLoader.getValue(for: "REFERRAL_URL"), !base.isEmpty {
            return referralURL(base: base, code: code)
        }

        if let authWebURL = SecretsLoader.getValue(for: "AUTH_WEB_URL"), !authWebURL.isEmpty {
            return referralURL(base: authWebURL, code: code)
        }

        return URL(string: "https://aidictation.app/referral?code=\(code)")
    }

    public static func inviteText(code: String) -> String {
        guard let url = inviteURL(for: code) else {
            return "Try AI Dictation with my invite code: \(code)"
        }

        return "Try AI Dictation with my invite link. We both get \(bonusWordsPerReferral.formatted()) extra words: \(url.absoluteString)"
    }

    private static func referralURL(base: String, code: String) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "ref" || $0.name == "referral_code" }
        queryItems.append(URLQueryItem(name: "ref", value: code))
        components.queryItems = queryItems
        return components.url
    }
}
