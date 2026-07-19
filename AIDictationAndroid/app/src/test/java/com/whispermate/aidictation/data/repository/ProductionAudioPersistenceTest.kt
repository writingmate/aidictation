package com.whispermate.aidictation.data.repository

import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.whispermate.aidictation.R
import com.whispermate.aidictation.data.local.AppDatabase
import com.whispermate.aidictation.data.local.ManagedAudioTemporaryFiles
import com.whispermate.aidictation.data.local.dao.RecordingDao
import com.whispermate.aidictation.data.local.entity.RecordingEntity
import com.whispermate.aidictation.data.local.entity.UsageClaimEntity
import com.whispermate.aidictation.domain.model.AudioAttemptLease
import com.whispermate.aidictation.domain.model.AudioProcessingStatus
import com.whispermate.aidictation.domain.model.audioUsageClaimId
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.xmlpull.v1.XmlPullParser

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class ProductionAudioPersistenceTest {
    private lateinit var context: Context
    private lateinit var database: AppDatabase
    private lateinit var dao: RecordingDao
    private lateinit var repository: RecordingRepository
    private lateinit var managedAudioDirectory: java.io.File

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        managedAudioDirectory = java.io.File(context.filesDir, "audio/recordings")
        ManagedAudioTemporaryFiles.retireAndSweepAll(managedAudioDirectory)
        database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        dao = database.recordingDao()
        repository = RecordingRepository(dao, context)
    }

    @After
    fun tearDown() {
        database.close()
        ManagedAudioTemporaryFiles.retireAndSweepAll(managedAudioDirectory)
    }

    @Test
    fun terminalSuccessQueuesOneProductionRoomClaimAndConcurrentClaimersDispatchAtMostOnce() =
        runBlocking {
            val row = activeRow(id = "usage", generation = 4, usageEligible = true)
            dao.insertRecording(row)
            val lease = row.lease()
            val pendingSignal = async(Dispatchers.IO) {
                repository.pendingUsageClaimCount.first { it > 0 }
            }

            assertTrue(
                repository.finishAttempt(
                    lease = lease,
                    status = AudioProcessingStatus.SUCCESS,
                    transcription = "one two three",
                    rawTranscription = "one two three"
                )
            )

            val claimId = audioUsageClaimId(row.id, row.generation)
            val pending = dao.getUsageClaimById(claimId)
            assertNotNull(pending)
            assertEquals(3, pending!!.wordCount)
            assertEquals(UsageClaimEntity.PENDING, pending.state)
            assertEquals(1, pendingSignal.await())

            val claims = listOf(
                async(Dispatchers.IO) { repository.claimUsage(claimId, now = 2_000L) },
                async(Dispatchers.IO) { repository.claimUsage(claimId, now = 2_001L) }
            ).awaitAll().filterNotNull()

            assertEquals(1, claims.size)
            assertEquals(UsageClaimEntity.CLAIMED, dao.getUsageClaimById(claimId)?.state)
            assertNull(repository.claimUsage(claimId, now = 2_002L))
            assertEquals(0, repository.pendingUsageClaimCount.first { it == 0 })
        }

    @Test
    fun staleTerminalWriteCannotCreateAUsageClaim() = runBlocking {
        val row = activeRow(id = "stale", generation = 9, usageEligible = true)
        dao.insertRecording(row)

        assertFalse(
            repository.finishAttempt(
                lease = row.lease().copy(generation = 8),
                status = AudioProcessingStatus.SUCCESS,
                transcription = "must not count",
                rawTranscription = "must not count"
            )
        )
        assertNull(dao.getUsageClaimById(audioUsageClaimId(row.id, 8)))
        assertEquals(AudioProcessingStatus.PROCESSING.persistedValue, dao.getRecordingById(row.id)?.status)
    }

    @Test
    fun nonBillableTerminalSuccessNeverQueuesAUsageClaim() = runBlocking {
        val row = activeRow(id = "non-billable", generation = 2, usageEligible = false)
        dao.insertRecording(row)

        assertTrue(
            repository.finishAttempt(
                lease = row.lease(),
                status = AudioProcessingStatus.SUCCESS,
                transcription = "saved without billing",
                rawTranscription = "saved without billing"
            )
        )

        assertEquals(AudioProcessingStatus.SUCCESS.persistedValue, dao.getRecordingById(row.id)?.status)
        assertNull(dao.getUsageClaimById(audioUsageClaimId(row.id, row.generation)))
        assertEquals(0, repository.pendingUsageClaimCount.first())
    }

    @Test
    fun startupRecoveryAtomicallyPromotesCompleteRawTextAndQueuesItsClaim() = runBlocking {
        val row = activeRow(
            id = "raw-complete",
            generation = 3,
            usageEligible = true,
            rawText = "durable raw words",
            recognitionComplete = true
        )
        dao.insertRecording(row)

        repository.normalizeAbandonedAttempts(now = 4_000L)

        val recovered = dao.getRecordingById(row.id)
        assertEquals(AudioProcessingStatus.SUCCESS.persistedValue, recovered?.status)
        assertEquals("durable raw words", recovered?.transcription)
        val claim = dao.getUsageClaimById(audioUsageClaimId(row.id, row.generation))
        assertEquals(3, claim?.wordCount)
        assertEquals(UsageClaimEntity.PENDING, claim?.state)
    }

    @Test
    fun startupDeleteAndClearSweepOwnedAudioWorkspacesAndFenceLateCreation() = runBlocking {
        val orphanSource = managedSource("orphan")
        val orphanWorkspace = ManagedAudioTemporaryFiles.openWorkspace(orphanSource)
        orphanWorkspace.createTemporaryFile("orphan_chunk_", ".m4a").writeBytes(byteArrayOf(1, 2, 3))

        repository.normalizeAbandonedAttempts(now = 5_000L)

        assertFalse(ManagedAudioTemporaryFiles.temporaryRoot(managedAudioDirectory).exists())
        assertThrows(IOException::class.java) {
            orphanWorkspace.createTemporaryFile("late_chunk_", ".m4a")
        }

        val deleteSource = managedSource("delete").apply { writeBytes(byteArrayOf(4, 5, 6)) }
        val deleteRow = terminalRow("delete", deleteSource)
        dao.insertRecording(deleteRow)
        val deleteWorkspace = ManagedAudioTemporaryFiles.openWorkspace(deleteSource)
        deleteWorkspace.createTemporaryFile("delete_left_", ".m4a").writeBytes(byteArrayOf(7))

        assertTrue(repository.deleteRecording(deleteRow.toDomain()))
        assertFalse(deleteSource.exists())
        assertFalse(ManagedAudioTemporaryFiles.recordingDirectory(deleteSource).exists())
        assertEquals(AudioProcessingStatus.DELETED.persistedValue, dao.getRecordingById("delete")?.status)
        assertNull(dao.getRecordingById("delete")?.audioFilePath)

        val clearSource = managedSource("clear").apply { writeBytes(byteArrayOf(8, 9)) }
        dao.insertRecording(terminalRow("clear", clearSource))
        ManagedAudioTemporaryFiles.openWorkspace(clearSource)
            .createTemporaryFile("clear_right_", ".m4a")
            .writeBytes(byteArrayOf(10))

        assertTrue(repository.clearAllRecordings())
        assertFalse(clearSource.exists())
        assertFalse(ManagedAudioTemporaryFiles.temporaryRoot(managedAudioDirectory).exists())
        assertEquals(AudioProcessingStatus.DELETED.persistedValue, dao.getRecordingById("clear")?.status)
    }

    @Test
    fun ownedAudioWorkspaceNeverFollowsSymlinksOutsideManagedStorage() {
        val outside = java.io.File(
            context.cacheDir,
            "audio-workspace-outside-${UUID.randomUUID()}"
        ).apply { assertTrue(mkdirs()) }
        val temporaryRoot = ManagedAudioTemporaryFiles.temporaryRoot(managedAudioDirectory)

        try {
            managedAudioDirectory.mkdirs()
            val sourceThroughLinkedRoot = managedSource("linked-root")
            val outsideRecording = java.io.File(outside, sourceThroughLinkedRoot.name)
                .apply { assertTrue(mkdirs()) }
            val rootSentinel = java.io.File(outsideRecording, "keep.txt")
                .apply { writeText("keep") }
            java.nio.file.Files.createSymbolicLink(
                temporaryRoot.toPath(),
                outside.toPath().toAbsolutePath()
            )

            assertTrue(ManagedAudioTemporaryFiles.retireAndSweepForSource(sourceThroughLinkedRoot))
            assertTrue("per-recording sweep traversed a linked temporary root", rootSentinel.exists())
            assertFalse(
                java.nio.file.Files.exists(
                    temporaryRoot.toPath(),
                    java.nio.file.LinkOption.NOFOLLOW_LINKS
                )
            )

            assertTrue(temporaryRoot.mkdir())
            val source = managedSource("symlink")
            val workspace = ManagedAudioTemporaryFiles.openWorkspace(source)
            val recordingDirectory = ManagedAudioTemporaryFiles.recordingDirectory(source)
            val outsideWorkspace = java.io.File(outside, workspace.directory.name)
                .apply { assertTrue(mkdirs()) }
            val workspaceSentinel = java.io.File(outsideWorkspace, "keep.txt")
                .apply { writeText("keep") }
            java.nio.file.Files.createSymbolicLink(
                recordingDirectory.toPath(),
                outside.toPath().toAbsolutePath()
            )

            assertThrows(IOException::class.java) {
                workspace.createTemporaryFile("blocked_chunk_", ".m4a")
            }
            assertTrue("workspace creation traversed an outside symlink", workspaceSentinel.exists())
            assertTrue(workspace.retire())
            assertTrue("workspace retirement traversed an outside symlink", workspaceSentinel.exists())
            assertFalse(
                "workspace retirement left the owned intermediate link behind",
                java.nio.file.Files.exists(
                    recordingDirectory.toPath(),
                    java.nio.file.LinkOption.NOFOLLOW_LINKS
                )
            )

            assertTrue(temporaryRoot.mkdir())
            val danglingSource = managedSource("dangling")
            val danglingWorkspace = ManagedAudioTemporaryFiles.openWorkspace(danglingSource)
            val danglingRecordingDirectory =
                ManagedAudioTemporaryFiles.recordingDirectory(danglingSource)
            java.nio.file.Files.createSymbolicLink(
                danglingRecordingDirectory.toPath(),
                java.io.File(outside, "missing-target").toPath().toAbsolutePath()
            )
            assertTrue(danglingWorkspace.retire())
            assertFalse(
                "workspace retirement falsely kept a dangling owned link",
                java.nio.file.Files.exists(
                    danglingRecordingDirectory.toPath(),
                    java.nio.file.LinkOption.NOFOLLOW_LINKS
                )
            )
        } finally {
            ManagedAudioTemporaryFiles.retireAndSweepAll(managedAudioDirectory)
            outside.deleteRecursively()
        }
    }

    @Test
    fun productionClearRefusesActiveRowsWithoutDeletingTheirSource() = runBlocking {
        repository.normalizeAbandonedAttempts(now = 6_000L)
        val source = managedSource("active").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        dao.insertRecording(activeRow(id = "active", sourcePath = source.absolutePath))
        val workspace = ManagedAudioTemporaryFiles.openWorkspace(source)
        val chunk = workspace.createTemporaryFile("active_chunk_", ".m4a")
            .apply { writeBytes(byteArrayOf(4)) }

        assertFalse(repository.clearAllRecordings())
        assertTrue(source.exists())
        assertTrue(chunk.exists())
        assertEquals(AudioProcessingStatus.PROCESSING.persistedValue, dao.getRecordingById("active")?.status)
    }

    @Test
    fun mergedManifestDisablesBackupAndRulesExcludeAudioAndDatabases() {
        assertEquals(0, context.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP)
        assertTrue(resourceExcludes(R.xml.backup_rules, "file", "audio/"))
        assertTrue(resourceExcludes(R.xml.backup_rules, "database", "."))
        assertTrue(resourceExcludes(R.xml.data_extraction_rules, "file", "audio/"))
        assertTrue(resourceExcludes(R.xml.data_extraction_rules, "database", "."))
    }

    private fun activeRow(
        id: String,
        generation: Long = 1,
        usageEligible: Boolean = false,
        sourcePath: String = managedSource(id).absolutePath,
        rawText: String = "",
        recognitionComplete: Boolean = false
    ) = RecordingEntity(
        id = id,
        timestamp = 1_000L,
        transcription = "",
        durationMs = 1_000L,
        audioFilePath = sourcePath,
        status = AudioProcessingStatus.PROCESSING.persistedValue,
        rawTranscription = rawText,
        checkpointText = rawText,
        completedLeafCount = if (rawText.isBlank()) 0 else 1,
        recognitionComplete = recognitionComplete,
        attemptId = "attempt-$generation",
        generation = generation,
        sourceIntegrity = "complete",
        updatedAt = 1_000L,
        usageEligible = usageEligible
    )

    private fun terminalRow(id: String, source: java.io.File) = RecordingEntity(
        id = id,
        timestamp = 1_000L,
        transcription = "saved",
        durationMs = 1_000L,
        audioFilePath = source.absolutePath,
        status = AudioProcessingStatus.FAILED.persistedValue,
        rawTranscription = "saved",
        checkpointText = "saved",
        completedLeafCount = 1,
        recognitionComplete = true,
        attemptId = "attempt",
        generation = 1,
        sourceIntegrity = "complete",
        updatedAt = 1_000L,
        usageEligible = true
    )

    private fun RecordingEntity.lease() = AudioAttemptLease(
        recordingId = id,
        attemptId = checkNotNull(attemptId),
        generation = generation,
        sourcePath = checkNotNull(audioFilePath),
        status = AudioProcessingStatus.PROCESSING
    )

    private fun managedSource(id: String) = java.io.File(
        managedAudioDirectory.apply { mkdirs() },
        "$id-${UUID.randomUUID()}.m4a"
    )

    private fun resourceExcludes(resourceId: Int, domain: String, path: String): Boolean {
        val parser = context.resources.getXml(resourceId)
        return try {
            while (parser.eventType != XmlPullParser.END_DOCUMENT) {
                if (parser.eventType == XmlPullParser.START_TAG && parser.name == "exclude" &&
                    parser.getAttributeValue(null, "domain") == domain &&
                    parser.getAttributeValue(null, "path") == path
                ) {
                    return true
                }
                parser.next()
            }
            false
        } finally {
            parser.close()
        }
    }
}
