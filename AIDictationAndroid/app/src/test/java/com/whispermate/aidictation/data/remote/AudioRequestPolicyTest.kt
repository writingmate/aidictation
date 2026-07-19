package com.whispermate.aidictation.data.remote

import java.io.IOException
import java.util.ArrayDeque
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AudioRequestPolicyTest {
    private class ScriptedTransport(
        scripts: Map<String, List<Any>>
    ) : AudioLeafTransport<String> {
        private val scripts = scripts.mapValues { ArrayDeque(it.value) }
        val calls = mutableListOf<String>()

        override suspend fun recognize(leaf: String): String {
            calls += leaf
            val next = scripts.getValue(leaf).removeFirst()
            if (next is Throwable) throw next
            return next as String
        }
    }

    private class FakeDelay : RecoveryDelay {
        val delays = mutableListOf<Long>()
        override suspend fun wait(milliseconds: Long) {
            delays += milliseconds
        }
    }

    @Test
    fun permanent4xxAreAttemptedOnceIncludingConflict() = runBlocking {
        listOf(400, 401, 403, 404, 409, 422).forEach { status ->
            val transport = ScriptedTransport(mapOf("leaf" to listOf(AudioHttpException(status, "bad"), "wrong")))
            val error = failure {
                engine(transport).recognize(listOf("leaf")) { _, _ -> true }
            }
            assertTrue("status=$status", error is AudioHttpException)
            assertEquals(listOf("leaf"), transport.calls)
        }
    }

    @Test
    fun incompleteSuccessStatusesAreAttemptedOnce() = runBlocking {
        listOf(202, 206).forEach { status ->
            val transport = ScriptedTransport(
                mapOf("leaf" to listOf(AudioHttpException(status, "not complete"), "wrong"))
            )
            assertTrue(
                "status=$status",
                failure { engine(transport).recognize(listOf("leaf")) { _, _ -> true } } is AudioHttpException
            )
            assertEquals(listOf("leaf"), transport.calls)
        }
    }

    @Test
    fun retryableHttpAndTransportFailuresUseThreeTotalAttempts() = runBlocking {
        val failures = listOf<Throwable>(
            AudioHttpException(408, "timeout"),
            AudioHttpException(429, "slow", retryAfterMillis = 30_000),
            AudioHttpException(500, "server"),
            AudioHttpException(599, "server"),
            IOException("connect"),
            IOException("response body disconnected")
        )
        failures.forEach { initial ->
            val delay = FakeDelay()
            val transport = ScriptedTransport(mapOf("leaf" to listOf(initial, initial, "ok")))
            val text = engine(transport, delay = delay).recognize(listOf("leaf")) { _, _ -> true }
            assertEquals("ok", text)
            assertEquals(3, transport.calls.size)
            if (initial is AudioHttpException && initial.statusCode == 429) {
                assertEquals(listOf(10_000L, 10_000L), delay.delays)
            }
        }
    }

    @Test
    fun repeatedTimeoutStopsAfterThirdAttempt() = runBlocking {
        val timeout = IOException("request timeout")
        val transport = ScriptedTransport(mapOf("leaf" to listOf(timeout, timeout, timeout, "wrong")))
        assertTrue(failure { engine(transport).recognize(listOf("leaf")) { _, _ -> true } } is IOException)
        assertEquals(3, transport.calls.size)
    }

    @Test
    fun malformedAndEmptySuccessfulBodiesAreNeverRetried() = runBlocking {
        listOf<Throwable>(
            AudioMalformedResponseException("bad json"),
            AudioEmptyResponseException()
        ).forEach { error ->
            val transport = ScriptedTransport(mapOf("leaf" to listOf(error, "wrong")))
            assertSame(error, failure { engine(transport).recognize(listOf("leaf")) { _, _ -> true } })
            assertEquals(1, transport.calls.size)
        }
    }

    @Test
    fun cancellationIsNotRetried() = runBlocking {
        val transport = ScriptedTransport(
            mapOf("leaf" to listOf(CancellationException("cancelled"), "wrong"))
        )
        assertTrue(failure { engine(transport).recognize(listOf("leaf")) { _, _ -> true } } is CancellationException)
        assertEquals(1, transport.calls.size)
    }

    @Test
    fun nested413SplitsRejectedLeafOnlyAndNeverReplaysCheckpoint() = runBlocking {
        val transport = ScriptedTransport(
            mapOf(
                "root" to listOf(AudioHttpException(413, "large")),
                "left" to listOf("one"),
                "right" to listOf(AudioHttpException(413, "still large")),
                "right-left" to listOf("two"),
                "right-right" to listOf("three")
            )
        )
        val splits = mapOf(
            "root" to listOf("left", "right"),
            "right" to listOf("right-left", "right-right")
        )
        val checkpoints = mutableListOf<Pair<String, Int>>()
        val text = engine(
            transport,
            splitter = AudioLeafSplitter { leaf, _ -> splits[leaf] }
        ).recognize(listOf("root")) { merged, count ->
            checkpoints += merged to count
            true
        }

        assertEquals("one two three", text)
        assertEquals(listOf("root", "left", "right", "right-left", "right-right"), transport.calls)
        assertEquals(
            listOf("one" to 1, "one two" to 2, "one two three" to 3),
            checkpoints
        )
    }

    @Test
    fun threeChunksCheckpointInOrderAndCheckpointFailureStopsLaterLeaves() = runBlocking {
        val transport = ScriptedTransport(
            mapOf("a" to listOf("A"), "b" to listOf("B"), "c" to listOf("C"))
        )
        val error = failure {
            engine(transport).recognize(listOf("a", "b", "c")) { _, count -> count < 2 }
        }
        assertTrue(error is AudioCheckpointException)
        assertEquals(listOf("a", "b"), transport.calls)
    }

    @Test
    fun bulkChunkBoundariesAbsorbTinyTailWithoutOverlapOrLoss() {
        val durationUs = 1_000_000L
        val segmentDurationUs = 400_000L
        val ranges = mutableListOf<Pair<Long, Long>>()
        var startUs = 0L
        while (startUs < durationUs) {
            val endUs = TranscriptionClient.nextChunkEndUs(startUs, durationUs, segmentDurationUs)
            ranges += startUs to endUs
            startUs = endUs
        }

        assertEquals(listOf(0L to 400_000L, 400_000L to durationUs), ranges)
        assertEquals(durationUs, ranges.last().second)
        assertEquals(ranges.first().second, ranges.last().first)
    }

    @Test
    fun bounded413RefusesUnsplittableLeaf() = runBlocking {
        val transport = ScriptedTransport(mapOf("leaf" to listOf(AudioHttpException(413, "large"))))
        val error = failure {
            engine(transport, splitter = AudioLeafSplitter { _, _ -> null })
                .recognize(listOf("leaf")) { _, _ -> true }
        }
        assertTrue(error is AudioSplitException)
        assertEquals(1, transport.calls.size)
    }

    @Test
    fun cleanupTimeoutErrorAndEmptyOutputPreserveRaw() = runBlocking {
        val raw = "complete raw transcript"
        assertEquals(raw, preserveRawOnCleanupFailure(raw) { "" })
        assertEquals(raw, preserveRawOnCleanupFailure(raw) { throw IOException("cleanup offline") })
        assertEquals(raw, completedCleanupTextOrFallback(raw, "truncated prefix", "length"))
        assertEquals(raw, completedCleanupTextOrFallback(raw, "filtered prefix", "content_filter"))
        assertEquals(raw, completedCleanupTextOrFallback(raw, "unconfirmed output", null))
        assertEquals("cleaned", completedCleanupTextOrFallback(raw, "cleaned", "stop"))
        assertEquals(
            "'Tis the opening, and \"this exact quote\" is the final sentence.",
            completedCleanupTextOrFallback(
                raw,
                "'Tis the opening, and \"this exact quote\" is the final sentence.",
                "stop"
            )
        )
        assertEquals("cleaned", preserveRawOnCleanupFailure(raw) { "cleaned" })
    }

    @Test
    fun oneStageAndTwoStageRoutesUseTheExactSameGenericPrompt() {
        val genericPrompt = TranscriptionCleanupPrompt.systemPrompt(
            CapturedTranscriptionCleanupContext.EMPTY
        )
        val oneStage = AudioCleanupRoute(genericPrompt, oneStageRequested = true, initialLeafCount = 1)

        assertSame(genericPrompt, oneStage.serverPrompt(isInitialLeaf = true))
        assertEquals(null, oneStage.clientCleanupPrompt())

        oneStage.invalidateForSplit()
        assertEquals(null, oneStage.serverPrompt(isInitialLeaf = false))
        assertSame(genericPrompt, oneStage.clientCleanupPrompt())

        val twoStage = AudioCleanupRoute(genericPrompt, oneStageRequested = true, initialLeafCount = 3)
        assertEquals(null, twoStage.serverPrompt(isInitialLeaf = true))
        assertSame(genericPrompt, twoStage.clientCleanupPrompt())
    }

    private fun engine(
        transport: AudioLeafTransport<String>,
        splitter: AudioLeafSplitter<String> = AudioLeafSplitter { _, _ -> null },
        delay: RecoveryDelay = RecoveryDelay { }
    ) = SequentialAudioRecognitionEngine(transport, splitter, recoveryDelay = delay)

    private suspend fun failure(block: suspend () -> Unit): Throwable {
        try {
            block()
            fail("Expected failure")
        } catch (error: Throwable) {
            return error
        }
        throw AssertionError("unreachable")
    }
}
