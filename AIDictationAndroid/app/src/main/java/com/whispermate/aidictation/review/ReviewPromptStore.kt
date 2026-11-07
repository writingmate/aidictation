package com.whispermate.aidictation.review

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import java.time.ZoneId
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ReviewPromptStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val lock = Any()
    private var launchInProgress = false

    @Volatile
    private var unavailableThisProcess = false

    fun recordSuccessfulDictation(
        text: String,
        deferPrompt: Boolean = false,
        atMillis: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ) {
        update { ReviewPromptPolicy.notingDictation(it, text, atMillis, zone, deferPrompt) }
    }

    fun recordFailedDictation() {
        update { ReviewPromptPolicy.notingFailure(it) }
    }

    fun tryBeginPrompt(atMillis: Long = System.currentTimeMillis()): Boolean {
        if (unavailableThisProcess) return false
        synchronized(lock) {
            if (launchInProgress) return false
            val record = loadLocked()
            if (!ReviewPromptPolicy.shouldRequestReview(record, atMillis, hostIsAtRest = true)) {
                return false
            }
            launchInProgress = true
            return true
        }
    }

    fun finishPrompt(launched: Boolean, atMillis: Long = System.currentTimeMillis()) {
        synchronized(lock) {
            launchInProgress = false
            if (launched) {
                saveLocked(ReviewPromptPolicy.notingPromptAttempt(loadLocked(), atMillis))
            } else {
                unavailableThisProcess = true
            }
        }
    }

    fun abandonPrompt() {
        synchronized(lock) {
            launchInProgress = false
        }
    }

    /**
     * The onboarding step always shows the ask. This only decides whether the
     * Play dialog may be presented again, and records that it was.
     */
    fun beginOnboardingPrompt(atMillis: Long = System.currentTimeMillis()): Boolean {
        synchronized(lock) {
            val record = loadLocked()
            if (record.promptAttempts >= ReviewPromptPolicy.maximumPromptAttempts) return false
            val lastPrompt = record.lastPromptAttemptAtMillis
            if (lastPrompt != null && atMillis - lastPrompt < ReviewPromptPolicy.cooldownMillis) {
                return false
            }
            saveLocked(ReviewPromptPolicy.notingPromptAttempt(record, atMillis))
            return true
        }
    }

    private fun update(transform: (ReviewPromptRecord) -> ReviewPromptRecord) {
        synchronized(lock) {
            saveLocked(transform(loadLocked()))
        }
    }

    private fun loadLocked(): ReviewPromptRecord {
        return ReviewPromptRecord(
            successfulDictations = preferences.getInt(KEY_SUCCESSES, 0),
            distinctUsageDays = preferences.getInt(KEY_DAYS, 0),
            lastUsageDay = preferences.getString(KEY_LAST_DAY, "") ?: "",
            firstSuccessAtMillis = preferences.optionalLong(KEY_FIRST_SUCCESS),
            promptAttempts = preferences.getInt(KEY_ATTEMPTS, 0),
            lastPromptAttemptAtMillis = preferences.optionalLong(KEY_LAST_ATTEMPT),
            suppressUntilMillis = preferences.optionalLong(KEY_SUPPRESS_UNTIL),
            lastOutcomeSucceeded = preferences.getBoolean(KEY_LAST_SUCCEEDED, false),
        )
    }

    private fun saveLocked(record: ReviewPromptRecord) {
        preferences.edit()
            .putInt(KEY_SUCCESSES, record.successfulDictations)
            .putInt(KEY_DAYS, record.distinctUsageDays)
            .putString(KEY_LAST_DAY, record.lastUsageDay)
            .putOptionalLong(KEY_FIRST_SUCCESS, record.firstSuccessAtMillis)
            .putInt(KEY_ATTEMPTS, record.promptAttempts)
            .putOptionalLong(KEY_LAST_ATTEMPT, record.lastPromptAttemptAtMillis)
            .putOptionalLong(KEY_SUPPRESS_UNTIL, record.suppressUntilMillis)
            .putBoolean(KEY_LAST_SUCCEEDED, record.lastOutcomeSucceeded)
            .apply()
    }

    private fun android.content.SharedPreferences.optionalLong(key: String): Long? {
        if (!contains(key)) return null
        return getLong(key, 0L)
    }

    private fun android.content.SharedPreferences.Editor.putOptionalLong(
        key: String,
        value: Long?,
    ): android.content.SharedPreferences.Editor {
        return if (value == null) remove(key) else putLong(key, value)
    }

    private companion object {
        const val PREFS_NAME = "review_prompt"
        const val KEY_SUCCESSES = "successful_dictations"
        const val KEY_DAYS = "distinct_usage_days"
        const val KEY_LAST_DAY = "last_usage_day"
        const val KEY_FIRST_SUCCESS = "first_success_at"
        const val KEY_ATTEMPTS = "prompt_attempts"
        const val KEY_LAST_ATTEMPT = "last_prompt_attempt_at"
        const val KEY_SUPPRESS_UNTIL = "suppress_until"
        const val KEY_LAST_SUCCEEDED = "last_outcome_succeeded"
    }
}
