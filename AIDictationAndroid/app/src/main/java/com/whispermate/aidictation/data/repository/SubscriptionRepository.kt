package com.whispermate.aidictation.data.repository

import android.content.Context
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.domain.model.FREE_MONTHLY_WORD_LIMIT
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
                limit = tier.wordLimit,
                isPro = tier.isPaid,
                isAuthenticated = true,
                email = user.email,
                tierName = tier.displayName
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
            return Result.failure(Exception("You've used all 2,000 free words. Upgrade to keep dictating."))
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

    private fun countWords(text: String): Int {
        return text.trim()
            .split(Regex("\\s+"))
            .count { token -> token.any { it.isLetterOrDigit() } }
    }
}
