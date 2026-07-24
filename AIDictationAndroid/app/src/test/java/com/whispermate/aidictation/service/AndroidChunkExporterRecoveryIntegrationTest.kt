package com.whispermate.aidictation.service

import android.app.Application
import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.whispermate.aidictation.data.local.AppDatabase
import com.whispermate.aidictation.data.local.ManagedAudioSourceFiles
import com.whispermate.aidictation.data.local.ManagedAudioTemporaryFiles
import com.whispermate.aidictation.data.local.ManagedAudioTemporaryWorkspace
import com.whispermate.aidictation.data.local.entity.RecordingEntity
import com.whispermate.aidictation.data.preferences.ApiProvider
import com.whispermate.aidictation.data.remote.CapturedTranscriptionCleanupContext
import com.whispermate.aidictation.data.remote.TranscriptionClient
import com.whispermate.aidictation.data.repository.RecordingRepository
import com.whispermate.aidictation.data.repository.TranscriptionAttemptConfiguration
import com.whispermate.aidictation.domain.model.AudioProcessingStatus
import com.whispermate.aidictation.domain.model.AudioSourceIntegrity
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class AndroidChunkExporterRecoveryIntegrationTest {
    private lateinit var context: Context
    private lateinit var database: AppDatabase
    private lateinit var repository: RecordingRepository
    private lateinit var source: File

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        File(context.filesDir, "audio").deleteRecursively()
        database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        repository = RecordingRepository(database.recordingDao(), context)
        val paths = ManagedAudioSourceFiles(context)
        source = paths.sourceForRecording("stalled-export")
        paths.prepareCaptureSource("stalled-export", source.absolutePath)
        RandomAccessFile(source, "rw").use { file ->
            file.write(byteArrayOf(1, 2, 3, 4))
            file.setLength(3_600_001L)
            file.fd.sync()
        }
    }

    @After
    fun tearDown() {
        database.close()
        File(context.filesDir, "audio").deleteRecursively()
    }

    @Test
    fun stalledProductionExporterDeadlineReturnsIdleAndFencesLateWorkspaceMutation() =
        runBlocking {
            val checkpoint = "durable checkpoint before exporter"
            database.recordingDao().insertRecording(
                RecordingEntity(
                    id = "stalled-export",
                    timestamp = 1_000L,
                    transcription = "",
                    durationMs = 1_000L,
                    audioFilePath = source.absolutePath,
                    status = AudioProcessingStatus.FAILED.persistedValue,
                    rawTranscription = "",
                    checkpointText = checkpoint,
                    completedLeafCount = 1,
                    recognitionComplete = false,
                    attemptId = "previous-attempt",
                    generation = 1,
                    sourceIntegrity = AudioSourceIntegrity.COMPLETE.persistedValue,
                    updatedAt = 1_000L,
                    usageEligible = false
                )
            )
            repository.normalizeAbandonedAttempts(now = 2_000L)

            val exporterStarted = CountDownLatch(1)
            val releaseExporter = CountDownLatch(1)
            val lateExporterFinished = CountDownLatch(1)
            val operations = StalledExporterOperations(
                source = source,
                exporterStarted = exporterStarted,
                releaseExporter = releaseExporter,
                lateExporterFinished = lateExporterFinished
            )
            val coordinator = AndroidAudioProcessingCoordinator(
                context = context,
                recordingRepository = repository,
                transcriptionOperations = operations,
                audioDurationReader = { 1_000L },
                recognitionTimeoutMillis = { 500L }
            )

            val result = coordinator.retry(
                owner = AndroidAudioAttemptOwner.MAIN,
                workflowToken = 77L,
                recordingId = "stalled-export",
                additionalPrompt = null,
                contextRules = null
            )

            assertTrue(exporterStarted.await(2, TimeUnit.SECONDS))
            assertTrue(result.isFailure)
            assertEquals(AndroidAudioProcessingState.IDLE, coordinator.state.value)
            val timedOut = database.recordingDao().getRecordingById("stalled-export")
            assertEquals(AudioProcessingStatus.FAILED.persistedValue, timedOut?.status)
            assertEquals(source.absolutePath, timedOut?.audioFilePath)
            assertEquals(checkpoint, timedOut?.checkpointText)
            assertTrue(source.exists())
            assertEquals(3_600_001L, source.length())
            assertTrue(source.inputStream().use { it.read() } == 1)

            releaseExporter.countDown()
            assertTrue(lateExporterFinished.await(2, TimeUnit.SECONDS))
            delay(100L)

            assertFalse(operations.lateWorkspaceMutationSucceeded)
            assertTrue(source.exists())
            assertEquals(checkpoint, database.recordingDao()
                .getRecordingById("stalled-export")?.checkpointText)
            assertFalse(ManagedAudioTemporaryFiles.recordingDirectory(source).exists())
            assertEquals(AndroidAudioProcessingState.IDLE, coordinator.state.value)

            val freshRetry = coordinator.retry(
                owner = AndroidAudioAttemptOwner.MAIN,
                workflowToken = 78L,
                recordingId = "stalled-export",
                additionalPrompt = null,
                contextRules = null
            )
            assertTrue(freshRetry.isSuccess)
            assertEquals("fresh retry raw", freshRetry.getOrThrow().text)
            assertEquals(AndroidAudioProcessingState.IDLE, coordinator.state.value)
            val recovered = database.recordingDao().getRecordingById("stalled-export")
            assertEquals(3L, recovered?.generation)
            assertEquals(AudioProcessingStatus.SUCCESS.persistedValue, recovered?.status)
            assertEquals("fresh retry raw", recovered?.checkpointText)
            assertEquals(source.absolutePath, recovered?.audioFilePath)
            assertTrue(source.exists())
        }

    private class StalledExporterOperations(
        private val source: File,
        private val exporterStarted: CountDownLatch,
        private val releaseExporter: CountDownLatch,
        private val lateExporterFinished: CountDownLatch
    ) : AndroidTranscriptionOperations {
        private val firstAttempt = AtomicBoolean(true)

        @Volatile
        var lateWorkspaceMutationSucceeded: Boolean = false

        private val configuration = TranscriptionAttemptConfiguration(
            provider = ApiProvider.GROQ,
            useLocalRecognition = false,
            cleanupEnabled = true,
            languageNames = listOf("English"),
            cleanupLanguageNames = listOf("English"),
            transcriptionPrompt = null,
            postProcessingPrompt = null,
            contextRules = null,
            requestSnapshot = TranscriptionClient.RequestSnapshot(
                endpoint = "https://custom.example.test/transcribe",
                apiKey = "test-key",
                model = "test-model",
                cleanupEndpoint = "https://custom.example.test/cleanup",
                cleanupApiKey = "test-cleanup-key",
                cleanupModel = "test-cleanup-model"
            ),
            cleanupContext = CapturedTranscriptionCleanupContext.EMPTY
        )

        override suspend fun captureAttemptConfiguration(
            additionalPrompt: String?,
            contextRules: String?
        ): TranscriptionAttemptConfiguration = configuration

        override suspend fun transcribe(
            audioFile: File,
            configuration: TranscriptionAttemptConfiguration,
            checkpoint: suspend (mergedText: String, completedLeafCount: Int) -> Boolean,
            rawComplete: suspend (rawText: String) -> Boolean
        ): Result<String> {
            if (!firstAttempt.getAndSet(false)) {
                val raw = "fresh retry raw"
                if (!checkpoint(raw, 1) || !rawComplete(raw)) {
                    return Result.failure(IllegalStateException("The retry checkpoint was rejected"))
                }
                return Result.success(raw)
            }
            return TranscriptionClient.transcribeWithInitialChunkExporterForTest(
                audioFile = audioFile,
                requestSnapshot = configuration.requestSnapshot,
                chunkExportTimeoutMillis = 10_000L,
                initialChunkExporter = ::stallAndAttemptLateMutation
            )
        }

        override fun abandonLocalRecognition() = Unit

        private fun stallAndAttemptLateMutation(
            originalSource: File,
            workspace: ManagedAudioTemporaryWorkspace
        ): List<TranscriptionClient.AudioUploadChunk> {
            check(originalSource == source)
            exporterStarted.countDown()
            while (true) {
                try {
                    if (releaseExporter.await(10L, TimeUnit.MILLISECONDS)) break
                } catch (_: InterruptedException) {
                    // Simulate a native exporter that ignores coroutine cancellation.
                }
            }
            lateWorkspaceMutationSucceeded = runCatching {
                workspace.createTemporaryFile("late_export_", ".m4a")
                    .writeBytes(byteArrayOf(9, 9, 9))
                true
            }.getOrDefault(false)
            lateExporterFinished.countDown()
            return listOf(TranscriptionClient.AudioUploadChunk(originalSource, isTemporary = false))
        }
    }
}
