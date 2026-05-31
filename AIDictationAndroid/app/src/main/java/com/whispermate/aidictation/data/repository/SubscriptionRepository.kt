package com.whispermate.aidictation.data.repository

import android.content.Context
import android.content.Intent
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.domain.model.FREE_MONTHLY_WORD_LIMIT
import com.whispermate.aidictation.domain.model.REFERRAL_BONUS_WORDS
import com.whispermate.aidictation.domain.model.UsageStatus
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@Singleton
class SubscriptionRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val appPreferences: AppPreferences,
    private val authRepository: AuthRepository
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    val usageStatus: StateFlow<UsageStatus> = combine(
        appPreferences.localUsage,
        authRepository.authState
    ) { localUsage, authState ->
        val user = authState.user
        if (user == null) {
            UsageStatus(
                used = localUsage.wordCount,
                limit = FREE_MONTHLY_WORD_LIMIT,
                isPro = false,
                isAuthenticated = false
            )
        } else {
            val tier = user.subscriptionTier
            UsageStatus(
                used = user.monthlyWordCount,
                limit = user.effectiveWordLimit,
                isPro = tier.isPaid,
                isAuthenticated = true,
                email = user.email,
                tierName = tier.displayName,
                referralCode = user.referralCode,
                referralBonusWords = user.referralBonusWords
            )
        }
    }.stateIn(
        scope = scope,
        started = SharingStarted.Eagerly,
        initialValue = UsageStatus(
            used = 0,
            limit = FREE_MONTHLY_WORD_LIMIT,
            isPro = false,
            isAuthenticated = false
        )
    )

    init {
        scope.launch {
            appPreferences.checkAndResetLocalUsageIfNeeded()
        }
    }

    suspend fun checkCanTranscribe(): Result<Unit> {
        val user = authRepository.authState.value.user
        if (user != null) {
            if (user.subscriptionTier.isPaid || !user.hasReachedLimit) return Result.success(Unit)
            return Result.failure(Exception("You've used all ${user.effectiveWordLimit} free words. Upgrade or invite a friend to keep dictating."))
        }

        return if (appPreferences.hasReachedLocalFreeLimit()) {
            Result.failure(Exception("You've used all 2,000 free words this month. Sign in to unlock more words or upgrade."))
        } else {
            Result.success(Unit)
        }
    }

    suspend fun recordWords(text: String) {
        val count = countWords(text)
        if (count <= 0) return

        if (authRepository.authState.value.user != null) {
            authRepository.updateWordCount(count)
        } else {
            appPreferences.addLocalWords(count)
        }
    }

    fun openLogin() {
        authRepository.openLogin(context)
    }

    fun openUpgrade() {
        authRepository.openUpgrade(context)
    }

    suspend fun signOut() {
        authRepository.signOut()
    }

    suspend fun shareReferralInvite(): Result<Unit> {
        val user = authRepository.authState.value.user
        if (user == null) {
            openLogin()
            return Result.success(Unit)
        }

        return authRepository.ensureReferralCode().map { updated ->
            val code = updated.referralCode ?: error("Your invite link is not ready yet.")
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, referralInviteText(code))
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val chooser = Intent.createChooser(shareIntent, "Share invite").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(chooser)
        }
    }

    suspend fun redeemReferralCode(code: String): Result<Unit> {
        if (authRepository.authState.value.user == null) {
            openLogin()
            return Result.success(Unit)
        }

        return authRepository.redeemReferralCode(code).map { }
    }

    private fun referralInviteText(code: String): String {
        val baseUrl = BuildConfig.AUTH_WEB_URL.ifBlank { "https://aidictation.app" }
        val separator = if (baseUrl.contains("?")) "&" else "?"
        val inviteUrl = "$baseUrl${separator}ref=$code"
        return "Try AI Dictation with my invite link. We both get ${REFERRAL_BONUS_WORDS} extra words: $inviteUrl"
    }

    private fun countWords(text: String): Int {
        return text.trim()
            .split(Regex("\\s+"))
            .count { token -> token.any { it.isLetterOrDigit() } }
    }
}
