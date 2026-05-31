package com.whispermate.aidictation.domain.model

const val FREE_MONTHLY_WORD_LIMIT = 2_000
const val REFERRAL_BONUS_WORDS = 2_000

enum class SubscriptionTier {
    Free,
    Pro,
    Lifetime;

    val isPaid: Boolean
        get() = this == Pro || this == Lifetime

    val wordLimit: Int
        get() = if (isPaid) Int.MAX_VALUE else FREE_MONTHLY_WORD_LIMIT

    val displayName: String
        get() = when (this) {
            Free -> "Free"
            Pro -> "Pro"
            Lifetime -> "Lifetime"
        }

    companion object {
        fun fromStatus(status: String?): SubscriptionTier = when (status?.lowercase()) {
            "pro" -> Pro
            "lifetime" -> Lifetime
            else -> Free
        }
    }
}

data class UserProfile(
    val userId: String,
    val email: String,
    val monthlyWordCount: Int,
    val subscriptionStatus: String,
    val stripeCustomerId: String? = null,
    val stripeSubscriptionId: String? = null,
    val wordCountResetAt: Long? = null,
    val referralCode: String? = null,
    val referredByUserId: String? = null,
    val referralBonusWords: Int = 0
) {
    val subscriptionTier: SubscriptionTier
        get() = SubscriptionTier.fromStatus(subscriptionStatus)

    val effectiveWordLimit: Int
        get() = if (subscriptionTier.isPaid) Int.MAX_VALUE else FREE_MONTHLY_WORD_LIMIT + referralBonusWords.coerceAtLeast(0)

    val hasReachedLimit: Boolean
        get() = !subscriptionTier.isPaid && monthlyWordCount >= effectiveWordLimit

    val wordsRemaining: Int
        get() = if (subscriptionTier.isPaid) Int.MAX_VALUE else (effectiveWordLimit - monthlyWordCount).coerceAtLeast(0)
}

data class AuthState(
    val user: UserProfile? = null,
    val isLoading: Boolean = false,
    val error: String? = null
) {
    val isAuthenticated: Boolean
        get() = user != null
}

data class UsageStatus(
    val used: Int,
    val limit: Int,
    val isPro: Boolean,
    val isAuthenticated: Boolean,
    val email: String? = null,
    val tierName: String = SubscriptionTier.Free.displayName,
    val referralCode: String? = null,
    val referralBonusWords: Int = 0
) {
    val remaining: Int
        get() = if (isPro) Int.MAX_VALUE else (limit - used).coerceAtLeast(0)

    val percentage: Float
        get() = if (isPro || limit <= 0) 0f else used.toFloat() / limit.toFloat()
}
