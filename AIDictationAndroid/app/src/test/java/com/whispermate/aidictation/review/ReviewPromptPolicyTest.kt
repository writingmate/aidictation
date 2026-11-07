package com.whispermate.aidictation.review

import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReviewPromptPolicyTest {
    private val zone = ZoneOffset.UTC
    private val day = 24L * 60 * 60 * 1000

    @Test
    fun asksOnlyAfterRepeatedSuccessAcrossDaysWhileTheAppIsIdle() {
        val start = 1_700_000_000_000L
        var record = ReviewPromptRecord()
        record = note(record, "first", start)
        record = note(record, "second", start + 60_000)
        record = note(record, "third", start + day)
        record = note(record, "fourth", start + day + 60_000)
        record = note(record, "fifth", start + (3 * day))

        val readyAt = start + ReviewPromptPolicy.minimumAgeSinceFirstSuccessMillis
        assertTrue(ReviewPromptPolicy.shouldRequestReview(record, readyAt, hostIsAtRest = true))
        assertFalse(ReviewPromptPolicy.shouldRequestReview(record, readyAt, hostIsAtRest = false))
        assertFalse(
            ReviewPromptPolicy.shouldRequestReview(
                record,
                readyAt - 1,
                hostIsAtRest = true,
            )
        )
    }

    @Test
    fun blankOrFailedDictationDoesNotCountAsAHappyMoment() {
        val start = 1_700_000_000_000L
        val ready = qualified(start)
        val blank = ReviewPromptPolicy.notingDictation(ready, "   ", start + (4 * day), zone)
        assertFalse(blank.lastOutcomeSucceeded)
        assertEquals(ready.successfulDictations, blank.successfulDictations)
        assertFalse(ReviewPromptPolicy.shouldRequestReview(blank, start + (4 * day), true))

        val failed = ReviewPromptPolicy.notingFailure(ready)
        assertFalse(ReviewPromptPolicy.shouldRequestReview(failed, start + (4 * day), true))
    }

    @Test
    fun recentOverlayDictationAndPriorPromptsHoldTheAsk() {
        val start = 1_700_000_000_000L
        val deferred = ReviewPromptPolicy.notingDictation(
            qualified(start),
            "from the floating mic",
            start + (4 * day),
            zone,
            deferPrompt = true,
        )
        val duringReturn = start + (4 * day) + 1_000
        assertFalse(ReviewPromptPolicy.shouldRequestReview(deferred, duringReturn, true))
        assertTrue(
            ReviewPromptPolicy.shouldRequestReview(
                deferred,
                duringReturn + ReviewPromptPolicy.returnSuppressionMillis,
                true,
            )
        )

        val prompted = ReviewPromptPolicy.notingPromptAttempt(deferred, duringReturn)
        assertFalse(
            ReviewPromptPolicy.shouldRequestReview(
                prompted,
                duringReturn + ReviewPromptPolicy.cooldownMillis - 1,
                true,
            )
        )
        assertTrue(
            ReviewPromptPolicy.shouldRequestReview(
                prompted,
                duringReturn + ReviewPromptPolicy.cooldownMillis,
                true,
            )
        )

        val exhausted = prompted.copy(promptAttempts = ReviewPromptPolicy.maximumPromptAttempts)
        assertFalse(
            ReviewPromptPolicy.shouldRequestReview(
                exhausted,
                duringReturn + ReviewPromptPolicy.cooldownMillis,
                true,
            )
        )
    }

    private fun qualified(start: Long): ReviewPromptRecord {
        var record = ReviewPromptRecord()
        record = note(record, "one", start)
        record = note(record, "two", start + day)
        record = note(record, "three", start + (2 * day))
        record = note(record, "four", start + (2 * day) + 1_000)
        record = note(record, "five", start + (3 * day))
        return record
    }

    private fun note(record: ReviewPromptRecord, text: String, at: Long): ReviewPromptRecord {
        return ReviewPromptPolicy.notingDictation(record, text, at, zone)
    }
}
