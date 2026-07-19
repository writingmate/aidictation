package com.whispermate.aidictation.data.repository

import android.content.Context
import com.whispermate.aidictation.data.local.ManagedAudioTemporaryFiles
import com.whispermate.aidictation.data.local.dao.RecordingDao
import com.whispermate.aidictation.data.local.entity.RecordingEntity
import com.whispermate.aidictation.data.local.entity.UsageClaimEntity
import com.whispermate.aidictation.domain.model.AudioAttemptLease
import com.whispermate.aidictation.domain.model.AudioProcessingStatus
import com.whispermate.aidictation.domain.model.AudioSourceIntegrity
import com.whispermate.aidictation.domain.model.Recording
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withTimeout
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

private const val FINALIZED_AUDIO_MARKER_VERSION = "1"

internal data class FinalizedAudioMarker(
    val recordingId: String,
    val attemptId: String,
    val generation: Long,
    val durationMs: Long,
    val sourceLength: Long
)

internal fun finalizedAudioMarkerFile(source: File): File =
    File(source.parentFile, "${source.name}.finalized")

internal fun writeFinalizedAudioMarker(
    lease: AudioAttemptLease,
    source: File,
    durationMs: Long
) {
    require(source.isFile && source.length() > 0L) { "The finalized audio is empty" }
    require(durationMs > 0L) { "The finalized audio has no duration" }
    val marker = finalizedAudioMarkerFile(source)
    val temporary = File(marker.parentFile, "${marker.name}.${lease.attemptId}.tmp")
    val payload = listOf(
        FINALIZED_AUDIO_MARKER_VERSION,
        lease.recordingId,
        lease.attemptId,
        lease.generation.toString(),
        durationMs.toString(),
        source.length().toString()
    ).joinToString("\n")
    try {
        FileOutputStream(temporary, false).use { output ->
            output.write(payload.toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        if (marker.exists() && !marker.delete()) {
            throw IOException("The previous finalized-audio marker could not be replaced")
        }
        if (!temporary.renameTo(marker)) {
            throw IOException("The finalized-audio marker could not be committed")
        }
    } finally {
        if (temporary.exists()) temporary.delete()
    }
}

internal fun readFinalizedAudioMarker(source: File): FinalizedAudioMarker? {
    val marker = finalizedAudioMarkerFile(source)
    val fields = runCatching { marker.readLines(Charsets.UTF_8) }.getOrNull() ?: return null
    if (fields.size != 6 || fields[0] != FINALIZED_AUDIO_MARKER_VERSION) return null
    val parsed = FinalizedAudioMarker(
        recordingId = fields[1],
        attemptId = fields[2],
        generation = fields[3].toLongOrNull() ?: return null,
        durationMs = fields[4].toLongOrNull() ?: return null,
        sourceLength = fields[5].toLongOrNull() ?: return null
    )
    return parsed.takeIf {
        it.durationMs > 0L && it.sourceLength > 0L && source.isFile && source.length() == it.sourceLength
    }
}

@Singleton
class RecordingRepository @Inject constructor(
    private val recordingDao: RecordingDao,
    @ApplicationContext private val context: Context
) {
    companion object {
        private const val RECOVERY_OPERATION_TIMEOUT_MS = 5_000L
    }

    private val startupRecoveryComplete = CompletableDeferred<Unit>()
    private val recoveryOperationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val managedAudioDirectory = File(context.filesDir, "audio/recordings")

    val recordings: Flow<List<Recording>> = flow {
        startupRecoveryComplete.await()
        emitAll(
            recordingDao.getAllRecordings()
                .map { entities -> entities.map { it.toDomain() } }
        )
    }

    val pendingUsageClaimCount: Flow<Int> = recordingDao.observePendingUsageClaimCount()

    suspend fun beginCapture(
        recordingId: String,
        attemptId: String,
        partialSourcePath: String,
        usageEligible: Boolean,
        now: Long = System.currentTimeMillis()
    ): AudioAttemptLease {
        val row = Recording(
            id = recordingId,
            timestamp = now,
            audioFilePath = partialSourcePath,
            status = AudioProcessingStatus.CAPTURING,
            attemptId = attemptId,
            generation = 1,
            sourceIntegrity = AudioSourceIntegrity.PARTIAL,
            updatedAt = now,
            usageEligible = usageEligible
        )
        recordingDao.insertRecording(RecordingEntity.fromDomain(row))
        return AudioAttemptLease(recordingId, attemptId, 1, partialSourcePath, AudioProcessingStatus.CAPTURING)
    }

    suspend fun markFinalizing(lease: AudioAttemptLease, now: Long = System.currentTimeMillis()): Boolean =
        recordingDao.advanceCapture(
            id = lease.recordingId,
            attemptId = lease.attemptId,
            generation = lease.generation,
            expectedStatus = AudioProcessingStatus.CAPTURING.persistedValue,
            nextStatus = AudioProcessingStatus.FINALIZING.persistedValue,
            audioFilePath = lease.sourcePath,
            durationMs = null,
            sourceIntegrity = AudioSourceIntegrity.UNFINALIZED.persistedValue,
            errorMessage = null,
            updatedAt = now
        ) == 1

    suspend fun acceptFinalizedSource(
        lease: AudioAttemptLease,
        finalSourcePath: String,
        durationMs: Long,
        now: Long = System.currentTimeMillis()
    ): AudioAttemptLease? {
        val updated = recordingDao.advanceCapture(
            id = lease.recordingId,
            attemptId = lease.attemptId,
            generation = lease.generation,
            expectedStatus = AudioProcessingStatus.FINALIZING.persistedValue,
            nextStatus = AudioProcessingStatus.PROCESSING.persistedValue,
            audioFilePath = finalSourcePath,
            durationMs = durationMs,
            sourceIntegrity = AudioSourceIntegrity.COMPLETE.persistedValue,
            errorMessage = null,
            updatedAt = now
        )
        return if (updated == 1) {
            AudioAttemptLease(
                lease.recordingId,
                lease.attemptId,
                lease.generation,
                finalSourcePath,
                AudioProcessingStatus.PROCESSING
            )
        } else {
            null
        }
    }

    suspend fun claimRetry(
        recordingId: String,
        usageEligible: Boolean,
        now: Long = System.currentTimeMillis()
    ): AudioAttemptLease? {
        val current = recordingDao.getRecordingById(recordingId) ?: return null
        val source = current.audioFilePath ?: return null
        if (current.sourceIntegrity != AudioSourceIntegrity.COMPLETE.persistedValue || !File(source).isFile) return null
        val attemptId = UUID.randomUUID().toString()
        val updated = recordingDao.claimRetry(
            id = recordingId,
            expectedGeneration = current.generation,
            attemptId = attemptId,
            nextStatus = AudioProcessingStatus.RETRYING.persistedValue,
            usageEligible = usageEligible,
            updatedAt = now
        )
        return if (updated == 1) {
            AudioAttemptLease(recordingId, attemptId, current.generation + 1, source, AudioProcessingStatus.RETRYING)
        } else {
            null
        }
    }

    suspend fun checkpoint(
        lease: AudioAttemptLease,
        mergedText: String,
        completedLeafCount: Int,
        now: Long = System.currentTimeMillis()
    ): Boolean = recordingDao.checkpoint(
        id = lease.recordingId,
        attemptId = lease.attemptId,
        generation = lease.generation,
        checkpointText = mergedText,
        completedLeafCount = completedLeafCount,
        updatedAt = now
    ) == 1

    suspend fun markRecognitionComplete(
        lease: AudioAttemptLease,
        rawText: String,
        completedLeafCount: Int,
        now: Long = System.currentTimeMillis()
    ): Boolean = recordingDao.markRecognitionComplete(
        id = lease.recordingId,
        attemptId = lease.attemptId,
        generation = lease.generation,
        rawText = rawText,
        completedLeafCount = completedLeafCount,
        updatedAt = now
    ) == 1

    suspend fun finishAttempt(
        lease: AudioAttemptLease,
        status: AudioProcessingStatus,
        transcription: String = "",
        rawTranscription: String = "",
        checkpointText: String = rawTranscription,
        completedLeafCount: Int = 0,
        errorMessage: String? = null,
        now: Long = System.currentTimeMillis()
    ): Boolean = recordingDao.finishAttempt(
        id = lease.recordingId,
        attemptId = lease.attemptId,
        generation = lease.generation,
        status = status.persistedValue,
        transcription = transcription,
        rawTranscription = rawTranscription,
        checkpointText = checkpointText,
        completedLeafCount = completedLeafCount,
        errorMessage = errorMessage,
        updatedAt = now
    ) == 1

    suspend fun finishRecognitionPreservingProgress(
        lease: AudioAttemptLease,
        status: AudioProcessingStatus,
        errorMessage: String?,
        now: Long = System.currentTimeMillis()
    ): Boolean = recordingDao.finishRecognitionPreservingProgress(
        id = lease.recordingId,
        attemptId = lease.attemptId,
        generation = lease.generation,
        status = status.persistedValue,
        errorMessage = errorMessage,
        updatedAt = now
    ) == 1

    suspend fun normalizeAbandonedAttempts(now: Long = System.currentTimeMillis()): Int {
        var lastFailure: Throwable? = null
        repeat(3) { attempt ->
            try {
                withRecoveryOperationDeadline {
                    if (!ManagedAudioTemporaryFiles.retireAndSweepAll(managedAudioDirectory)) {
                        throw IOException("Temporary audio cleanup did not finish")
                    }
                }
                retryTombstonedSourceCleanup(now)
                recoverFinalizedSources(now)
                val normalized = withRecoveryOperationDeadline {
                    recordingDao.normalizeAbandonedAttempts(
                        message = "A previous attempt was interrupted. Your audio is still available to retry.",
                        updatedAt = now
                    )
                }
                startupRecoveryComplete.complete(Unit)
                return normalized
            } catch (error: CancellationException) {
                startupRecoveryComplete.completeExceptionally(error)
                throw error
            } catch (error: Throwable) {
                lastFailure = error
                if (attempt < 2) delay(250L * (attempt + 1))
            }
        }
        val failure = checkNotNull(lastFailure)
        startupRecoveryComplete.completeExceptionally(failure)
        throw failure
    }

    suspend fun awaitStartupRecovery() {
        startupRecoveryComplete.await()
    }

    /** Returns false while this recording has an active owner. Accepted deletion wins before file IO. */
    suspend fun deleteRecording(recording: Recording): Boolean {
        val current = recordingDao.getRecordingById(recording.id) ?: return true
        if (recordingDao.tombstoneExact(
                recording.id,
                current.generation,
                System.currentTimeMillis()
            ) != 1
        ) return false
        val sourcePath = current.audioFilePath ?: return true
        val source = File(sourcePath)
        val temporaryRemoved = ManagedAudioTemporaryFiles.retireAndSweepForSource(source)
        val sourceRemoved = removeManagedSource(source)
        val removed = temporaryRemoved && sourceRemoved
        if (removed) {
            runCatching {
                recordingDao.clearDeletedSourcePath(
                    current.id,
                    current.generation + 1,
                    System.currentTimeMillis()
                )
            }
        }
        return removed
    }

    /** Clear is all-or-nothing with respect to active ownership; inactive rows are tombstoned first. */
    suspend fun clearAllRecordings(): Boolean {
        val inactive = try {
            recordingDao.claimAllInactiveForClear(System.currentTimeMillis())
        } catch (_: RecordingDao.ActiveRecordingConflictException) {
            return false
        }
        var allRemoved = ManagedAudioTemporaryFiles.retireAndSweepAll(managedAudioDirectory)
        inactive.forEach { row ->
            val sourcePath = row.audioFilePath ?: return@forEach
            val source = File(sourcePath)
            val temporaryRemoved = ManagedAudioTemporaryFiles.retireAndSweepForSource(source)
            val sourceRemoved = removeManagedSource(source)
            val removed = temporaryRemoved && sourceRemoved
            allRemoved = allRemoved && removed
            if (removed) {
                runCatching {
                    recordingDao.clearDeletedSourcePath(
                        row.id,
                        row.generation + 1,
                        System.currentTimeMillis()
                    )
                }
            }
        }
        return allRemoved
    }

    suspend fun getRecordingById(id: String): Recording? {
        return recordingDao.getRecordingById(id)?.toDomain()
    }

    suspend fun claimUsage(
        id: String,
        now: Long = System.currentTimeMillis()
    ): UsageClaimEntity? = recordingDao.claimUsage(id, now)

    suspend fun claimNextUsage(
        now: Long = System.currentTimeMillis()
    ): UsageClaimEntity? = recordingDao.claimNextUsage(now)

    suspend fun recoverFinalizedSource(
        lease: AudioAttemptLease,
        source: File,
        now: Long = System.currentTimeMillis()
    ): Boolean {
        if (source.absolutePath != lease.sourcePath) return false
        val marker = readFinalizedAudioMarker(source) ?: return false
        if (marker.recordingId != lease.recordingId || marker.attemptId != lease.attemptId ||
            marker.generation != lease.generation
        ) {
            return false
        }
        val promoted = recordingDao.promoteRecoveredFinalizedSource(
            id = lease.recordingId,
            attemptId = lease.attemptId,
            generation = lease.generation,
            durationMs = marker.durationMs,
            updatedAt = now
        ) == 1
        if (promoted) finalizedAudioMarkerFile(source).delete()
        return promoted
    }

    private suspend fun recoverFinalizedSources(now: Long) {
        withRecoveryOperationDeadline { recordingDao.getFinalizationRecoveryCandidates() }
            .asSequence()
            .forEach { row ->
                val attemptId = row.attemptId ?: return@forEach
                val sourcePath = row.audioFilePath ?: return@forEach
                val source = File(sourcePath)
                val lease = AudioAttemptLease(
                    recordingId = row.id,
                    attemptId = attemptId,
                    generation = row.generation,
                    sourcePath = sourcePath,
                    status = AudioProcessingStatus.FINALIZING
                )
                withRecoveryOperationDeadline { recoverFinalizedSource(lease, source, now) }
            }
    }

    private suspend fun retryTombstonedSourceCleanup(now: Long) {
        withRecoveryOperationDeadline { recordingDao.getDeletedRecordingsWithSources() }
            .forEach { row ->
                val sourcePath = row.audioFilePath ?: return@forEach
                val source = File(sourcePath)
                val removed = withRecoveryOperationDeadline {
                    val temporaryRemoved = ManagedAudioTemporaryFiles.retireAndSweepForSource(source)
                    val sourceRemoved = removeManagedSource(source)
                    temporaryRemoved && sourceRemoved
                }
                if (!removed) return@forEach
                withRecoveryOperationDeadline {
                    recordingDao.clearDeletedSourcePath(row.id, row.generation, now)
                }
            }
    }

    private fun removeManagedSource(source: File): Boolean {
        fun removeIfPresent(file: File): Boolean = runCatching {
            !file.exists() || file.delete() || !file.exists()
        }.getOrDefault(false)

        val markerRemoved = removeIfPresent(finalizedAudioMarkerFile(source))
        val sourceRemoved = removeIfPresent(source)
        return markerRemoved && sourceRemoved
    }

    private suspend fun <T> withRecoveryOperationDeadline(block: suspend () -> T): T {
        val operation = recoveryOperationScope.async { runCatching { block() } }
        return try {
            withTimeout(RECOVERY_OPERATION_TIMEOUT_MS) { operation.await() }.getOrThrow()
        } catch (error: TimeoutCancellationException) {
            throw IOException("Audio recovery storage timed out", error)
        }
    }
}
