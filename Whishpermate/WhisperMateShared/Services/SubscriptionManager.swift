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
        static let localWordCountResetAt = "localWordCountResetAt"
    }

    // MARK: - Published Properties

    @Published public var showUpgradeModal: Bool = false
    @Published public var showSignupModal: Bool = false

    // MARK: - Private Properties

    private let authManager = AuthManager.shared

    // MARK: - Local Word Tracking (for anonymous users)

    public var localWordCount: Int {
        get { AppDefaults.shared.integer(forKey: Keys.localWordCount) }
        set { AppDefaults.shared.set(newValue, forKey: Keys.localWordCount) }
    }

    public var localWordCountResetAt: Date? {
        get { AppDefaults.shared.object(forKey: Keys.localWordCountResetAt) as? Date }
        set { AppDefaults.shared.set(newValue, forKey: Keys.localWordCountResetAt) }
    }

    // MARK: - Initialization

    private init() {
        // Check and reset local count if needed on init
        checkAndResetLocalIfNeeded()
    }

    // MARK: - Subscription

    public func openUpgrade() {
        guard let stripePaymentLink = SecretsLoader.getValue(for: "STRIPE_PAYMENT_LINK") else {
            print("Missing Stripe payment link configuration")
            return
        }

        if let user = authManager.currentUser {
            if user.subscriptionTier == .pro || user.stripeSubscriptionId != nil {
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
            let isPro = user.subscriptionTier == .pro
            let limit = user.subscriptionTier.wordLimit
            let used = user.totalWordsUsed
            let percentage = isPro ? 0.0 : user.usagePercentage
            return (used, limit, percentage, isPro)
        } else {
            // Anonymous user - use local tracking
            checkAndResetLocalIfNeeded()
            let limit = UsageLimits.freeMonthlyWordLimit
            let used = localWordCount
            let percentage = Double(used) / Double(limit)
            return (used, limit, percentage, false)
        }
    }

    public func shouldShowUpgradePrompt(for wordCount: Int) -> Bool {
        guard let user = authManager.currentUser else {
            return false
        }

        // Don't show for pro users
        if user.subscriptionTier == .pro {
            return false
        }

        // Show if they're approaching limit (90%) or over
        let newTotal = user.totalWordsUsed + wordCount
        let limit = user.subscriptionTier.wordLimit
        let percentage = Double(newTotal) / Double(limit)

        return percentage >= 0.9
    }

    public func getUpgradeMessage(for user: User) -> String {
        let remaining = user.wordsRemaining
        if remaining <= 0 {
            return "You've used all \(UsageLimits.freeMonthlyWordLimit.formatted()) free words. Upgrade to Pro for unlimited transcriptions!"
        } else if remaining < 200 {
            return "Only \(remaining) words left in your free trial. Upgrade now for unlimited access!"
        } else {
            return "Upgrade to Pro for unlimited transcriptions and included API access."
        }
    }

    // MARK: - Unified Transcription Check

    /// Check if user can transcribe (works for both authenticated and anonymous users)
    public func checkCanTranscribe() -> (canTranscribe: Bool, reason: String?) {
        DebugLog.info("checkCanTranscribe: isAuthenticated=\(authManager.isAuthenticated)", context: "SubscriptionManager")
        if authManager.isAuthenticated {
            // Use server-side tracking for authenticated users
            let result = authManager.checkCanTranscribe()
            DebugLog.info("checkCanTranscribe (auth): canTranscribe=\(result.canTranscribe), reason=\(result.reason ?? "nil")", context: "SubscriptionManager")
            return result
        } else {
            // Use local tracking for anonymous users
            let result = checkLocalWordLimit()
            DebugLog.info("checkCanTranscribe (local): canTranscribe=\(result.canTranscribe), localWordCount=\(localWordCount), limit=\(UsageLimits.freeMonthlyWordLimit)", context: "SubscriptionManager")
            return result
        }
    }

    /// Record words after transcription (works for both authenticated and anonymous users)
    public func recordWords(_ count: Int) async {
        if authManager.isAuthenticated {
            _ = try? await authManager.updateWordCount(wordsToAdd: count)
        } else {
            addLocalWords(count)
        }
    }

    // MARK: - Local Word Limit Methods

    private func checkLocalWordLimit() -> (canTranscribe: Bool, reason: String?) {
        // Check if reset needed (monthly)
        checkAndResetLocalIfNeeded()

        if localWordCount >= UsageLimits.freeMonthlyWordLimit {
            return (false, "You've reached your free limit. Create an account to continue.")
        }
        return (true, nil)
    }

    public func addLocalWords(_ count: Int) {
        if localWordCountResetAt == nil {
            localWordCountResetAt = nextMonthStart()
        }
        localWordCount += count
        DebugLog.info("Local word count updated: \(localWordCount)/\(UsageLimits.freeMonthlyWordLimit)", context: "SubscriptionManager")
    }

    private func checkAndResetLocalIfNeeded() {
        if let resetAt = localWordCountResetAt, Date() >= resetAt {
            DebugLog.info("Resetting local word count (was \(localWordCount))", context: "SubscriptionManager")
            localWordCount = 0
            localWordCountResetAt = nextMonthStart()
        }
    }

    private func nextMonthStart() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let startOfMonth = calendar.date(from: components)!
        return calendar.date(byAdding: .month, value: 1, to: startOfMonth)!
    }
}
