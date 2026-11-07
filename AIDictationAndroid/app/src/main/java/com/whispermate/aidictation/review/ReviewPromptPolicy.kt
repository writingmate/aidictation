package com.whispermate.aidictation.review

import java.time.Instant
import java.time.ZoneId

/**
 * Decides when Android may ask Play for an in-app review.
 *
 * The Play dialog is quota-limited and must not be opened from a button, from
 * the floating mic, or while dictation is in progress. Settings opens the Play
 * listing directly. Thresholds match the iOS review policy.
 */
data class ReviewPromptRecord(
    val successfulDictations: Int = 0,
    val distinctUsageDays: Int = 0,
    val lastUsageDay: String = "",
    val firstSuccessAtMillis: Long? = null,
    val promptAttempts: Int = 0,
    val lastPromptAttemptAtMillis: Long? = null,
    val suppressUntilMillis: Long? = null,
    val lastOutcomeSucceeded: Boolean = false,
)

object ReviewPromptPolicy {
    const val minimumSuccessfulDictations = 5
    const val minimumDistinctUsageDays = 3
    const val minimumAgeSinceFirstSuccessMillis = 3L * 24 * 60 * 60 * 1000
    const val cooldownMillis = 120L * 24 * 60 * 60 * 1000
    const val maximumPromptAttempts = 3
    const val returnSuppressionMillis = 30_000L

    fun dayKey(millis: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        return Instant.ofEpochMilli(millis).atZone(zone).toLocalDate().toString()
    }

    fun notingDictation(
        record: ReviewPromptRecord,
        text: String,
        atMillis: Long,
        zone: ZoneId = ZoneId.systemDefault(),
        deferPrompt: Boolean = false,
    ): ReviewPromptRecord {
        if (text.isBlank()) return notingFailure(record)
        val day = dayKey(atMillis, zone)
        val distinctDays = if (day != record.lastUsageDay) {
            record.distinctUsageDays + 1
        } else {
            record.distinctUsageDays
        }
        val suppressUntil = if (deferPrompt) {
            val until = atMillis + returnSuppressionMillis
            maxOf(record.suppressUntilMillis ?: Long.MIN_VALUE, until).takeIf { it != Long.MIN_VALUE }
        } else {
            record.suppressUntilMillis
        }
        return record.copy(
            successfulDictations = record.successfulDictations + 1,
            distinctUsageDays = distinctDays,
            lastUsageDay = day,
            firstSuccessAtMillis = record.firstSuccessAtMillis ?: atMillis,
            suppressUntilMillis = suppressUntil,
            lastOutcomeSucceeded = true,
        )
    }

    fun notingFailure(record: ReviewPromptRecord): ReviewPromptRecord {
        return record.copy(lastOutcomeSucceeded = false)
    }

    fun notingPromptAttempt(record: ReviewPromptRecord, atMillis: Long): ReviewPromptRecord {
        return record.copy(
            promptAttempts = record.promptAttempts + 1,
            lastPromptAttemptAtMillis = atMillis,
        )
    }

    fun shouldRequestReview(
        record: ReviewPromptRecord,
        atMillis: Long,
        hostIsAtRest: Boolean,
    ): Boolean {
        if (!hostIsAtRest || !record.lastOutcomeSucceeded) return false
        if (record.successfulDictations < minimumSuccessfulDictations) return false
        if (record.distinctUsageDays < minimumDistinctUsageDays) return false
        val firstSuccessAt = record.firstSuccessAtMillis ?: return false
        if (atMillis - firstSuccessAt < minimumAgeSinceFirstSuccessMillis) return false
        if (record.promptAttempts >= maximumPromptAttempts) return false
        val lastPrompt = record.lastPromptAttemptAtMillis
        if (lastPrompt != null && atMillis - lastPrompt < cooldownMillis) return false
        val suppressUntil = record.suppressUntilMillis
        if (suppressUntil != null && atMillis < suppressUntil) return false
        return true
    }
}
