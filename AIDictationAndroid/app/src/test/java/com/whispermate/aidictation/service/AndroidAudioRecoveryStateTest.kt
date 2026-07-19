package com.whispermate.aidictation.service

import com.whispermate.aidictation.data.preferences.ApiProvider
import com.whispermate.aidictation.data.remote.TranscriptionClient
import com.whispermate.aidictation.data.remote.CapturedTranscriptionCleanupContext
import com.whispermate.aidictation.data.remote.CleanupReplacement
import com.whispermate.aidictation.data.repository.TranscriptionAttemptConfiguration
import com.whispermate.aidictation.data.repository.finalizedAudioMarkerFile
import com.whispermate.aidictation.data.repository.readFinalizedAudioMarker
import com.whispermate.aidictation.data.repository.writeFinalizedAudioMarker
import com.whispermate.aidictation.domain.model.AudioAttemptLease
import com.whispermate.aidictation.domain.model.AudioProcessingStatus
import com.whispermate.aidictation.domain.model.AudioSourceIntegrity
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deterministic fake store/recorder/clock coverage for the Android durable attempt contract. */
class AndroidAudioRecoveryStateTest {
    private data class Row(
        val id: String,
        var attemptId: String,
        var generation: Long,
        var status: AudioProcessingStatus,
        var source: String,
        var integrity: AudioSourceIntegrity,
        var checkpoint: String = "",
        var completedLeaves: Int = 0,
        var recognitionComplete: Boolean = false,
        var error: String? = null
    )

    private class FakeClock(var now: Long = 1_000) {
        fun advance(ms: Long) { now += ms }
    }

    private class FakeStore {
        val rows = linkedMapOf<String, Row>()
        var failNextWrite = false
        var clearGeneration = 0L

        @Synchronized
        fun begin(id: String, attempt: String, source: String): Row {
            writeGate()
            return Row(
                id, attempt, 1, AudioProcessingStatus.CAPTURING, source,
                AudioSourceIntegrity.PARTIAL
            ).also { rows[id] = it }
        }

        @Synchronized
        fun finalize(row: Row, finalSource: String): Boolean {
            writeGate()
            val current = rows[row.id] ?: return false
            if (!matches(current, row) || current.status != AudioProcessingStatus.CAPTURING) return false
            current.status = AudioProcessingStatus.PROCESSING
            current.source = finalSource
            current.integrity = AudioSourceIntegrity.COMPLETE
            return true
        }

        @Synchronized
        fun checkpoint(row: Row, text: String, leaves: Int): Boolean {
            writeGate()
            val current = rows[row.id] ?: return false
            if (!matches(current, row) || !current.status.isActive) return false
            current.checkpoint = text
            current.completedLeaves = leaves
            return true
        }

        @Synchronized
        fun markRecognitionComplete(row: Row, text: String, leaves: Int): Boolean {
            val saved = checkpoint(row, text, leaves)
            if (saved) rows.getValue(row.id).recognitionComplete = true
            return saved
        }

        @Synchronized
        fun finish(row: Row, status: AudioProcessingStatus, error: String? = null): Boolean {
            writeGate()
            val current = rows[row.id] ?: return false
            if (!matches(current, row) || !current.status.isActive) return false
            current.status = status
            current.error = error
            return true
        }

        @Synchronized
        fun claimRetry(id: String): Row? {
            writeGate()
            val current = rows[id] ?: return null
            if (!current.status.isRetryable || current.integrity != AudioSourceIntegrity.COMPLETE) return null
            current.generation += 1
            current.attemptId = UUID.randomUUID().toString()
            current.status = AudioProcessingStatus.RETRYING
            current.recognitionComplete = false
            current.error = null
            return current.copy()
        }

        @Synchronized
        fun delete(id: String): Boolean {
            writeGate()
            val current = rows[id] ?: return true
            if (current.status.isActive) return false
            current.generation += 1
            current.status = AudioProcessingStatus.DELETED
            current.attemptId = ""
            return true
        }

        @Synchronized
        fun clear(): Boolean {
            writeGate()
            if (rows.values.any { it.status.isActive }) return false
            clearGeneration += 1
            rows.values.filter { it.status != AudioProcessingStatus.DELETED }.forEach {
                it.generation += 1
                it.attemptId = ""
                it.status = AudioProcessingStatus.DELETED
            }
            return true
        }

        @Synchronized
        fun normalizeAfterDeath() {
            rows.values.filter { it.status.isActive }.forEach {
                if (it.status == AudioProcessingStatus.CAPTURING ||
                    it.status == AudioProcessingStatus.FINALIZING
                ) {
                    it.integrity = AudioSourceIntegrity.UNFINALIZED
                }
                it.status = if (it.recognitionComplete) {
                    AudioProcessingStatus.SUCCESS
                } else {
                    AudioProcessingStatus.FAILED
                }
                it.error = if (it.recognitionComplete) null else "Interrupted; audio retained"
                it.attemptId = ""
            }
        }

        private fun matches(current: Row, lease: Row): Boolean =
            current.attemptId == lease.attemptId && current.generation == lease.generation

        private fun writeGate() {
            if (failNextWrite) {
                failNextWrite = false
                throw IOException("storage failure")
            }
        }
    }

    private class FakeRecorder(
        private val startFailure: Boolean = false,
        private val writeFailure: Boolean = false,
        private val finalizationTimeout: Boolean = false
    ) {
        var starts = 0
        var stops = 0
        var releases = 0
        fun start() {
            starts += 1
            if (startFailure) throw IOException("microphone start")
        }

        fun stop() {
            stops += 1
            if (writeFailure) throw IOException("capture write")
            if (finalizationTimeout) throw IOException("finalization deadline")
        }

        fun release() {
            releases += 1
        }
    }

    private class Harness(
        val store: FakeStore,
        val recorder: FakeRecorder,
        val clock: FakeClock
    ) {
        var idle = true
        var recognitions = 0
        lateinit var lease: Row

        fun start(id: String = "recording") {
            idle = false
            lease = store.begin(id, "attempt-${clock.now}", "$id.partial.m4a")
            try {
                recorder.start()
            } catch (error: Throwable) {
                recorder.release()
                store.finish(lease, AudioProcessingStatus.FAILED, error.message)
                idle = true
                throw error
            }
        }

        fun finalize(): Boolean {
            return try {
                recorder.stop()
                store.finalize(lease, "${lease.id}.m4a")
            } catch (error: Throwable) {
                recorder.release()
                store.finish(lease, AudioProcessingStatus.FAILED, error.message)
                idle = true
                false
            }
        }

        fun recognize(raw: String = "raw", cleanup: (String) -> String = { it }): Boolean {
            recognitions += 1
            val checkpointSaved = try {
                store.checkpoint(lease, raw, 1)
            } catch (error: Throwable) {
                store.finish(lease, AudioProcessingStatus.FAILED, error.message)
                idle = true
                return false
            }
            if (!checkpointSaved) {
                idle = true
                return false
            }
            if (!store.markRecognitionComplete(lease, raw, 1)) {
                idle = true
                return false
            }
            val final = runCatching { cleanup(raw) }.getOrNull().orEmpty().ifBlank { raw }
            val saved = store.finish(lease, AudioProcessingStatus.SUCCESS)
            idle = true
            return saved && final.isNotBlank()
        }
    }

    @Test
    fun captureWriteFailureAndStalledFinalizationNeverStartRecognitionAndReturnIdle() {
        listOf(
            FakeRecorder(writeFailure = true),
            FakeRecorder(finalizationTimeout = true)
        ).forEach { recorder ->
            val harness = Harness(FakeStore(), recorder, FakeClock())
            harness.start()
            assertFalse(harness.finalize())
            assertTrue(harness.idle)
            assertEquals(0, harness.recognitions)
            assertEquals(1, recorder.releases)
            assertEquals(AudioProcessingStatus.FAILED, harness.store.rows.getValue("recording").status)
            assertTrue(harness.store.rows.getValue("recording").source.endsWith("partial.m4a"))
        }
    }

    @Test
    fun maximumLengthCaptureStillEntersBoundedFinalization() {
        val clock = FakeClock()
        val store = FakeStore()
        val recorder = FakeRecorder()
        val harness = Harness(store, recorder, clock)
        harness.start()
        clock.advance(30 * 60 * 1000L)

        assertTrue(harness.finalize())
        assertEquals(1, recorder.stops)
        assertEquals(AudioProcessingStatus.PROCESSING, store.rows.getValue("recording").status)
        assertEquals(AudioSourceIntegrity.COMPLETE, store.rows.getValue("recording").integrity)
    }

    @Test
    fun initialJournalStorageFailurePreventsNativeRecorderStart() {
        val store = FakeStore().apply { failNextWrite = true }
        val recorder = FakeRecorder()
        val harness = Harness(store, recorder, FakeClock())
        runCatching { harness.start() }
        assertEquals(0, recorder.starts)
        assertTrue(store.rows.isEmpty())
    }

    @Test
    fun stalledPersistenceDeadlineFailsInsteadOfHoldingActiveState() = runBlocking {
        val operationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val lateReconciled = CompletableDeferred<Unit>()
        try {
            val failure = runCatching {
                withAudioPersistenceDeadline(
                    operationScope = operationScope,
                    timeoutMillis = 10L,
                    onLateCompletion = { result, _ ->
                        if (result.getOrNull() == "lease") lateReconciled.complete(Unit)
                    }
                ) {
                    delay(50L)
                    "lease"
                }
            }.exceptionOrNull()

            assertTrue(failure is IOException)
            withTimeout(1_000L) { lateReconciled.await() }
        } finally {
            operationScope.cancel()
        }
    }

    @Test
    fun checkpointStorageFailureStopsBeforeTerminalSuccess() {
        val store = FakeStore()
        val harness = Harness(store, FakeRecorder(), FakeClock())
        harness.start()
        assertTrue(harness.finalize())
        store.failNextWrite = true
        assertFalse(harness.recognize())
        assertTrue(harness.idle)
        assertEquals(AudioProcessingStatus.FAILED, store.rows.getValue("recording").status)
        assertEquals("", store.rows.getValue("recording").checkpoint)
    }

    @Test
    fun processDeathNormalizesActiveAttemptAndRetryUsesSameRecordingId() {
        val store = FakeStore()
        val harness = Harness(store, FakeRecorder(), FakeClock())
        harness.start("stable-id")
        assertTrue(harness.finalize())
        store.checkpoint(harness.lease, "first", 1)
        store.normalizeAfterDeath()
        val interrupted = store.rows.getValue("stable-id")
        assertEquals(AudioProcessingStatus.FAILED, interrupted.status)
        assertEquals("first", interrupted.checkpoint)
        val retry = store.claimRetry("stable-id")
        assertNotNull(retry)
        assertEquals("stable-id", retry!!.id)
        assertEquals(1, store.rows.size)
        assertTrue(store.finish(retry, AudioProcessingStatus.SUCCESS))
        assertEquals(AudioProcessingStatus.SUCCESS, store.rows.getValue("stable-id").status)
    }

    @Test
    fun processDeathAfterRawRecognitionDuringCleanupKeepsCompleteRawAsSuccess() {
        val store = FakeStore()
        val harness = Harness(store, FakeRecorder(), FakeClock())
        harness.start("raw-complete")
        assertTrue(harness.finalize())
        assertTrue(store.markRecognitionComplete(harness.lease, "complete raw transcript", 1))

        store.normalizeAfterDeath()

        val recovered = store.rows.getValue("raw-complete")
        assertEquals(AudioProcessingStatus.SUCCESS, recovered.status)
        assertEquals("complete raw transcript", recovered.checkpoint)
        assertTrue(recovered.recognitionComplete)
        assertEquals(null, recovered.error)
    }

    @Test
    fun finalizedMarkerRequiresExactLeaseAndUnchangedSource() {
        val source = kotlin.io.path.createTempFile("android-audio-recovery", ".m4a").toFile()
        val lease = AudioAttemptLease(
            recordingId = "stable-id",
            attemptId = "attempt-id",
            generation = 4,
            sourcePath = source.absolutePath,
            status = AudioProcessingStatus.FINALIZING
        )
        try {
            source.writeBytes(byteArrayOf(1, 2, 3, 4))
            writeFinalizedAudioMarker(lease, source, durationMs = 1_250L)

            val marker = readFinalizedAudioMarker(source)
            assertNotNull(marker)
            assertEquals(lease.recordingId, marker!!.recordingId)
            assertEquals(lease.attemptId, marker.attemptId)
            assertEquals(lease.generation, marker.generation)
            assertEquals(1_250L, marker.durationMs)

            source.appendBytes(byteArrayOf(5))
            assertEquals(null, readFinalizedAudioMarker(source))
        } finally {
            finalizedAudioMarkerFile(source).delete()
            source.delete()
        }
    }

    @Test
    fun twoSimultaneousRetriesHaveExactlyOneOwner() = runBlocking {
        val store = FakeStore()
        store.rows["same"] = Row(
            "same", "old", 3, AudioProcessingStatus.FAILED, "same.m4a",
            AudioSourceIntegrity.COMPLETE
        )
        val claims = listOf(
            async(Dispatchers.Default) { store.claimRetry("same") },
            async(Dispatchers.Default) { store.claimRetry("same") }
        ).awaitAll().filterNotNull()
        assertEquals(1, claims.size)
        assertEquals(4, claims.single().generation)
        assertEquals(1, store.rows.size)
    }

    @Test
    fun deleteAndClearWinAgainstLateCallbacksWithGenerationFence() {
        val store = FakeStore()
        val terminal = Row(
            "one", "attempt", 2, AudioProcessingStatus.FAILED, "one.m4a",
            AudioSourceIntegrity.COMPLETE
        )
        store.rows[terminal.id] = terminal
        val stale = terminal.copy()
        assertTrue(store.delete("one"))
        assertFalse(store.checkpoint(stale, "late", 1))
        assertFalse(store.finish(stale, AudioProcessingStatus.SUCCESS))

        store.rows["two"] = Row(
            "two", "attempt", 1, AudioProcessingStatus.FAILED, "two.m4a",
            AudioSourceIntegrity.COMPLETE
        )
        val staleTwo = store.rows.getValue("two").copy()
        assertTrue(store.clear())
        assertEquals(1, store.clearGeneration)
        assertFalse(store.finish(staleTwo, AudioProcessingStatus.SUCCESS))
        assertTrue(store.rows.values.all { it.status == AudioProcessingStatus.DELETED })
    }

    @Test
    fun clearRefusesActiveWork() {
        val store = FakeStore()
        store.rows["active"] = Row(
            "active", "attempt", 1, AudioProcessingStatus.PROCESSING, "active.m4a",
            AudioSourceIntegrity.COMPLETE
        )
        assertFalse(store.clear())
        assertEquals(AudioProcessingStatus.PROCESSING, store.rows.getValue("active").status)
    }

    @Test
    fun retryClaimAndClearSerializeWithoutDeletingAnOwnedSource() {
        val retryWins = FakeStore().apply {
            rows["race"] = Row(
                "race", "old", 2, AudioProcessingStatus.FAILED, "race.m4a",
                AudioSourceIntegrity.COMPLETE
            )
        }
        val claimed = retryWins.claimRetry("race")
        assertNotNull(claimed)
        assertFalse(retryWins.clear())
        assertEquals(AudioProcessingStatus.RETRYING, retryWins.rows.getValue("race").status)
        assertEquals("race.m4a", retryWins.rows.getValue("race").source)

        val clearWins = FakeStore().apply {
            rows["race"] = Row(
                "race", "old", 2, AudioProcessingStatus.FAILED, "race.m4a",
                AudioSourceIntegrity.COMPLETE
            )
        }
        assertTrue(clearWins.clear())
        assertEquals(null, clearWins.claimRetry("race"))
        assertEquals(AudioProcessingStatus.DELETED, clearWins.rows.getValue("race").status)
    }

    @Test
    fun cleanupFailureAndEmptyOutputKeepCompleteRawText() {
        val store = FakeStore()
        val harness = Harness(store, FakeRecorder(), FakeClock())
        harness.start()
        assertTrue(harness.finalize())
        assertTrue(harness.recognize("complete raw") { throw IOException("cleanup") })
        assertEquals("complete raw", store.rows.getValue("recording").checkpoint)
        assertEquals(AudioProcessingStatus.SUCCESS, store.rows.getValue("recording").status)
    }

    @Test
    fun concurrentJobsRetainIndependentProviderSnapshots() = runBlocking {
        fun configuration(name: String, replacement: String) = TranscriptionAttemptConfiguration(
            provider = ApiProvider.WRITINGMATE,
            useLocalRecognition = false,
            cleanupEnabled = true,
            languageNames = listOf("English"),
            cleanupLanguageNames = listOf("English"),
            transcriptionPrompt = "Vocabulary: $name",
            postProcessingPrompt = "Keep $name",
            contextRules = "Rule $name",
            requestSnapshot = TranscriptionClient.RequestSnapshot(
                endpoint = "https://$name.example/transcribe",
                apiKey = "key-$name",
                model = "model-$name",
                cleanupEndpoint = "https://$name.example/cleanup",
                cleanupApiKey = "cleanup-key-$name",
                cleanupModel = "cleanup-model-$name"
            ),
            cleanupContext = CapturedTranscriptionCleanupContext(
                vocabulary = emptyList(),
                phrases = emptyList(),
                explicitReplacements = emptyList(),
                shortcutExpansions = listOf(CleanupReplacement("shortcut", replacement)),
                formattingInstructions = emptyList(),
                appContext = null,
                languageContext = listOf("English")
            )
        )
        val first = configuration("cloud-a", "first expansion")
        val second = configuration("cloud-b", "second expansion")
        val observed = listOf(
            async(Dispatchers.Default) {
                first.requestSnapshot.model to
                    first.cleanupContext.shortcutExpansions.single().replacement
            },
            async(Dispatchers.Default) {
                second.requestSnapshot.model to
                    second.cleanupContext.shortcutExpansions.single().replacement
            }
        ).awaitAll()
        assertEquals("model-cloud-a" to "first expansion", observed[0])
        assertEquals("model-cloud-b" to "second expansion", observed[1])
        assertNotEquals(observed[0], observed[1])
    }
}
