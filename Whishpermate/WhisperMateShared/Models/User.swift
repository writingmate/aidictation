//
//  User.swift
//  WhisperMate
//
//  Created by WhisperMate on 2025-01-24.
//

import Foundation

public struct User: Codable, Identifiable {
    public let id: UUID
    public let userId: UUID
    public let email: String
    public var monthlyWordCount: Int
    public var subscriptionStatus: String
    public let createdAt: Date?
    public var updatedAt: Date?
    public let stripeCustomerId: String?
    public let stripeSubscriptionId: String?
    public let wordCountResetAt: Date?
    public let referralCode: String?
    public let referredByUserId: UUID?
    public let referralBonusWords: Int?

    // Computed property for compatibility
    public var subscriptionTier: SubscriptionTier {
        switch subscriptionStatus {
        case "pro": return .pro
        case "lifetime": return .lifetime
        default: return .free
        }
    }

    // Compatibility property
    public var totalWordsUsed: Int {
        monthlyWordCount
    }

    public var wordsRemaining: Int {
        let limit = effectiveWordLimit
        if limit == Int.max {
            return Int.max // Unlimited
        }
        return max(0, limit - monthlyWordCount)
    }

    public var hasReachedLimit: Bool {
        effectiveWordLimit != Int.max && monthlyWordCount >= effectiveWordLimit
    }

    public var usagePercentage: Double {
        guard effectiveWordLimit != Int.max else {
            return 0.0
        }
        return Double(monthlyWordCount) / Double(effectiveWordLimit)
    }

    public var bonusWords: Int {
        max(0, referralBonusWords ?? 0)
    }

    public var effectiveWordLimit: Int {
        let baseLimit = subscriptionTier.wordLimit
        guard baseLimit != Int.max else { return Int.max }
        return baseLimit + bonusWords
    }

    /// Check if word count needs to be reset (new month has started)
    public var needsWordCountReset: Bool {
        // Paid users don't need reset
        guard !subscriptionTier.isPaid else { return false }
        // If reset date was never set, we need to set it (don't reset count, just init date)
        guard let resetAt = wordCountResetAt else { return false }
        // Check if reset date has passed
        return Date() >= resetAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case email
        case monthlyWordCount = "monthly_word_count"
        case subscriptionStatus = "subscription_status"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case stripeCustomerId = "stripe_customer_id"
        case stripeSubscriptionId = "stripe_subscription_id"
        case wordCountResetAt = "word_count_reset_at"
        case referralCode = "referral_code"
        case referredByUserId = "referred_by_user_id"
        case referralBonusWords = "referral_bonus_words"
    }
}

struct Subscription: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let stripeCustomerId: String?
    let stripeSubscriptionId: String?
    let status: String
    let currentPeriodEnd: Date?
    let createdAt: Date
    var updatedAt: Date

    var isActive: Bool {
        status == "active"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case stripeCustomerId = "stripe_customer_id"
        case stripeSubscriptionId = "stripe_subscription_id"
        case status
        case currentPeriodEnd = "current_period_end"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
