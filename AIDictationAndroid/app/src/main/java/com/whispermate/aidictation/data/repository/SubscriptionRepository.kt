package com.whispermate.aidictation.data.repository

import android.content.Context
import android.content.Intent
import android.util.Log
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.domain.model.FREE_MONTHLY_WORD_LIMIT
import com.whispermate.aidictation.domain.model.REFERRAL_BONUS_WORDS
import com.whispermate.aidictation.domain.model.UsageClaimDestination
import com.whispermate.aidictation.domain.model.UsageStatus
import com.whispermate.aidictation.domain.model.countUsageWords
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

@Singleton
class SubscriptionRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val appPreferences: AppPreferences,
    private val authRepository: AuthRepository,
    private val recordingRepository: RecordingRepository
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val usageDispatchMutex = Mutex()

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
            runCatching {
                authRepository.authState.first { !it.isLoading }
                recordingRepository.awaitStartupRecovery()
                combine(
                    recordingRepository.pendingUsageClaimCount,
                    authRepository.authState
                ) { pendingCount, _ ->
                    pendingCount to authRepository.currentUsageDestination()
                }.collect { (pendingCount, usageDestination) ->
                    if (pendingCount > 0 && usageDestination != null) {
                        drainPendingUsageClaims(usageDestination)
                    }
                }
            }.onFailure { error ->
                Log.e("SubscriptionRepository", "Pending usage monitoring stopped", error)
            }
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
        val count = countUsageWords(text)
        if (count <= 0) return
        authRepository.authState.first { !it.isLoading }
        val usageDestination = authRepository.currentUsageDestination() ?: return

        usageDispatchMutex.withLock {
            dispatchWordsOnce(count, usageDestination)
        }
    }

    /**
     * The Room claim is consumed before the current non-idempotent sink is invoked. A crash or an
     * ambiguous network failure after this point is intentionally never retried, so undercount is
     * possible but the same successful transcription cannot be charged twice by this device.
     */
    fun recordUsageClaim(claimId: String?) {
        if (claimId == null) return
        scope.launch {
            authRepository.authState.first { !it.isLoading }
            val usageDestination = authRepository.currentUsageDestination() ?: return@launch
            dispatchPersistedUsageClaim(claimId, usageDestination)
        }
    }

    private suspend fun dispatchPersistedUsageClaim(
        claimId: String,
        usageDestination: String
    ) {
        usageDispatchMutex.withLock {
            if (authRepository.currentUsageDestination() != usageDestination) return@withLock
            val claim = recordingRepository.claimUsage(
                claimId,
                usageDestination
            ) ?: return@withLock
            runCatching { dispatchWordsOnce(claim.wordCount, claim.usageDestination) }
                .onFailure { error ->
                    Log.e("SubscriptionRepository", "Claimed usage could not be dispatched", error)
                }
        }
    }

    private suspend fun drainPendingUsageClaims(usageDestination: String) {
        usageDispatchMutex.withLock {
            while (authRepository.currentUsageDestination() == usageDestination) {
                val claim = recordingRepository.claimNextUsage(usageDestination) ?: break
                runCatching { dispatchWordsOnce(claim.wordCount, claim.usageDestination) }
                    .onFailure { error ->
                        Log.e("SubscriptionRepository", "Claimed usage could not be dispatched", error)
                    }
            }
        }
    }

    private suspend fun dispatchWordsOnce(count: Int, usageDestination: String) {
        when (usageDestination) {
            UsageClaimDestination.LOCAL -> appPreferences.addLocalWords(count)
            else -> {
                val expectedUserId = UsageClaimDestination.accountId(usageDestination)
                    ?: error("Usage claim has no dispatchable destination")
                authRepository.updateWordCount(count, expectedUserId)
            }
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

}
