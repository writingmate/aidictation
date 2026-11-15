package com.whispermate.aidictation.data.repository

import android.app.Activity
import android.content.Context
import android.widget.Toast
import com.whispermate.aidictation.R
import com.whispermate.aidictation.data.billing.PurchaseOutcome
import com.whispermate.aidictation.data.billing.PurchasesManager
import com.whispermate.aidictation.domain.model.SubscriptionTier
import kotlinx.coroutines.withContext
import com.whispermate.aidictation.domain.model.PaymentPlan
import android.content.Intent
import android.util.Log
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.domain.model.FREE_TRIAL_WORD_LIMIT
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
    private val recordingRepository: RecordingRepository,
    private val purchasesManager: PurchasesManager
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val usageDispatchMutex = Mutex()

    val usageStatus: StateFlow<UsageStatus> = combine(
        appPreferences.localUsage,
        authRepository.authState,
        purchasesManager.hasProEntitlement
    ) { localUsage, authState, hasProEntitlement ->
        val user = authState.user
        if (user == null) {
            UsageStatus(
                used = localUsage.wordCount,
                limit = FREE_TRIAL_WORD_LIMIT,
                // A Play purchase made without an account still unlocks this device.
                isPro = hasProEntitlement,
                isAuthenticated = false,
                tierName = (if (hasProEntitlement) SubscriptionTier.Pro else SubscriptionTier.Free).displayName
            )
        } else {
            // The account's plan (web checkout, lifetime codes) or an in-app purchase.
            val tier = user.subscriptionTier.takeIf { it.isPaid }
                ?: if (hasProEntitlement) SubscriptionTier.Pro else SubscriptionTier.Free
            UsageStatus(
                used = user.monthlyWordCount,
                limit = user.effectiveWordLimit,
                isPro = tier.isPaid,
                isAuthenticated = true,
                email = user.email,
                avatarUrl = authState.avatarUrl,
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
            limit = FREE_TRIAL_WORD_LIMIT,
            isPro = false,
            isAuthenticated = false
        )
    )

    init {
        scope.launch {
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
        if (purchasesManager.hasProEntitlement.value) return Result.success(Unit)
        val user = authRepository.authState.value.user
        if (user != null) {
            if (user.subscriptionTier.isPaid || !user.hasReachedLimit) return Result.success(Unit)
            return Result.failure(Exception("You've used all ${user.effectiveWordLimit} trial words. Unlimited is \$8.49/month or \$84.99/year."))
        }

        return if (appPreferences.hasReachedLocalFreeLimit()) {
            Result.failure(Exception("You've dictated 5,000 words. Unlimited is \$8.49/month or \$84.99/year."))
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

    fun isGoogleSignInConfigured(): Boolean = authRepository.isGoogleSignInConfigured()

    /** [activityContext] must be an Activity; see [AuthRepository.signInWithGoogle]. */
    suspend fun signInWithGoogle(activityContext: Context): Boolean =
        authRepository.signInWithGoogle(activityContext)

    /** Store-formatted prices for the plans sold in the app; empty with browser checkout. */
    val planPrices: StateFlow<Map<PaymentPlan, String>> = purchasesManager.planPrices

    /** Whether Pro is bought inside the app (Google Play) rather than in the browser. */
    val sellsInApp: Boolean
        get() = purchasesManager.isConfigured

    /**
     * Starts an upgrade to [plan]. With in-app purchases configured and an [activity] to
     * show the Play sheet from, the purchase happens in the app; otherwise checkout opens
     * in the browser.
     */
    fun openUpgrade(plan: PaymentPlan? = null, activity: Activity? = null) {
        if (!purchasesManager.isConfigured || activity == null) {
            authRepository.openUpgrade(context, plan)
            return
        }
        scope.launch {
            val outcome = withContext(Dispatchers.Main) {
                purchasesManager.purchase(activity, plan ?: PaymentPlan.Annual)
            }
            if (outcome == PurchaseOutcome.Failed) showToast(R.string.purchase_failed)
        }
    }

    /** Re-reads the Play account's purchases, for a new phone or a reinstall. */
    fun restorePurchases() {
        scope.launch {
            val restored = purchasesManager.restore()
            showToast(if (restored) R.string.purchase_restored else R.string.purchase_nothing_to_restore)
        }
    }

    fun hasPaymentLinks(): Boolean = purchasesManager.isConfigured || authRepository.hasPaymentLinks()

    private suspend fun showToast(messageRes: Int) = withContext(Dispatchers.Main) {
        Toast.makeText(context, messageRes, Toast.LENGTH_LONG).show()
    }

    suspend fun signOut() {
        authRepository.signOut()
    }


}
