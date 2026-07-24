package com.whispermate.aidictation.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import com.whispermate.aidictation.data.local.entity.RecordingEntity
import com.whispermate.aidictation.data.local.entity.UsageClaimEntity
import com.whispermate.aidictation.domain.model.UsageClaimDestination
import com.whispermate.aidictation.domain.model.audioUsageClaimId
import com.whispermate.aidictation.domain.model.countUsageWords
import kotlinx.coroutines.flow.Flow

@Dao
interface RecordingDao {
    class ActiveRecordingConflictException : IllegalStateException()
    @Query("SELECT * FROM recordings WHERE status != 'deleted' AND status != 'capturing' AND status != 'finalizing' ORDER BY timestamp DESC LIMIT 100")
    fun getAllRecordings(): Flow<List<RecordingEntity>>

    @Query("SELECT * FROM recordings WHERE id = :id")
    suspend fun getRecordingById(id: String): RecordingEntity?

    @Query("SELECT * FROM recordings WHERE status IN ('capturing', 'finalizing', 'processing', 'retrying')")
    suspend fun getActiveRecordings(): List<RecordingEntity>

    @Query(
        """
        SELECT * FROM recordings
        WHERE status IN ('finalizing', 'failed', 'cancelled')
          AND sourceIntegrity = 'unfinalized'
        """
    )
    suspend fun getFinalizationRecoveryCandidates(): List<RecordingEntity>

    @Query("SELECT * FROM recordings WHERE status NOT IN ('capturing', 'finalizing', 'processing', 'retrying', 'deleted')")
    suspend fun getInactiveRecordings(): List<RecordingEntity>

    @Query("SELECT * FROM recordings WHERE status = 'deleted' AND audioFilePath IS NOT NULL")
    suspend fun getDeletedRecordingsWithSources(): List<RecordingEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertRecording(recording: RecordingEntity)

    @Query(
        """
        UPDATE recordings SET
            status = :nextStatus,
            attemptId = :attemptId,
            generation = generation + 1,
            recognitionComplete = 0,
            usageEligible = :usageEligible,
            usageDestination = :usageDestination,
            errorMessage = NULL,
            updatedAt = :updatedAt
        WHERE id = :id
          AND generation = :expectedGeneration
          AND status IN ('success', 'failed', 'cancelled')
          AND sourceIntegrity = 'complete'
        """
    )
    suspend fun claimRetry(
        id: String,
        expectedGeneration: Long,
        attemptId: String,
        nextStatus: String,
        usageEligible: Boolean,
        usageDestination: String,
        updatedAt: Long
    ): Int

    @Query(
        """
        UPDATE recordings SET
            status = :nextStatus,
            audioFilePath = :audioFilePath,
            durationMs = :durationMs,
            sourceIntegrity = :sourceIntegrity,
            errorMessage = :errorMessage,
            updatedAt = :updatedAt
        WHERE id = :id AND attemptId = :attemptId AND generation = :generation
          AND status = :expectedStatus
        """
    )
    suspend fun advanceCapture(
        id: String,
        attemptId: String,
        generation: Long,
        expectedStatus: String,
        nextStatus: String,
        audioFilePath: String?,
        durationMs: Long?,
        sourceIntegrity: String,
        errorMessage: String?,
        updatedAt: Long
    ): Int

    @Query(
        """
        UPDATE recordings SET
            status = CASE WHEN status = 'finalizing' THEN 'processing' ELSE status END,
            durationMs = :durationMs,
            sourceIntegrity = 'complete',
            errorMessage = NULL,
            updatedAt = :updatedAt
        WHERE id = :id AND attemptId = :attemptId AND generation = :generation
          AND status IN ('finalizing', 'failed', 'cancelled')
          AND sourceIntegrity = 'unfinalized'
        """
    )
    suspend fun promoteRecoveredFinalizedSource(
        id: String,
        attemptId: String,
        generation: Long,
        durationMs: Long,
        updatedAt: Long
    ): Int

    @Query(
        """
        UPDATE recordings SET
            checkpointText = :checkpointText,
            rawTranscription = :checkpointText,
            completedLeafCount = :completedLeafCount,
            updatedAt = :updatedAt
        WHERE id = :id AND attemptId = :attemptId AND generation = :generation
          AND status IN ('processing', 'retrying')
        """
    )
    suspend fun checkpoint(
        id: String,
        attemptId: String,
        generation: Long,
        checkpointText: String,
        completedLeafCount: Int,
        updatedAt: Long
    ): Int

    @Query(
        """
        UPDATE recordings SET
            rawTranscription = :rawText,
            checkpointText = :rawText,
            completedLeafCount = :completedLeafCount,
            recognitionComplete = 1,
            updatedAt = :updatedAt
        WHERE id = :id AND attemptId = :attemptId AND generation = :generation
          AND status IN ('processing', 'retrying')
        """
    )
    suspend fun markRecognitionComplete(
        id: String,
        attemptId: String,
        generation: Long,
        rawText: String,
        completedLeafCount: Int,
        updatedAt: Long
    ): Int

    @Query(
        """
        UPDATE recordings SET
            status = :status,
            transcription = :transcription,
            rawTranscription = :rawTranscription,
            checkpointText = :checkpointText,
            completedLeafCount = :completedLeafCount,
            recognitionComplete = CASE WHEN :status = 'success' THEN 1 ELSE recognitionComplete END,
            errorMessage = :errorMessage,
            updatedAt = :updatedAt
        WHERE id = :id AND attemptId = :attemptId AND generation = :generation
          AND status IN ('capturing', 'finalizing', 'processing', 'retrying')
        """
    )
    suspend fun finishAttemptRow(
        id: String,
        attemptId: String,
        generation: Long,
        status: String,
        transcription: String,
        rawTranscription: String,
        checkpointText: String,
        completedLeafCount: Int,
        errorMessage: String?,
        updatedAt: Long
    ): Int

    @Transaction
    suspend fun finishAttempt(
        id: String,
        attemptId: String,
        generation: Long,
        status: String,
        transcription: String,
        rawTranscription: String,
        checkpointText: String,
        completedLeafCount: Int,
        errorMessage: String?,
        updatedAt: Long
    ): Int {
        val updated = finishAttemptRow(
            id = id,
            attemptId = attemptId,
            generation = generation,
            status = status,
            transcription = transcription,
            rawTranscription = rawTranscription,
            checkpointText = checkpointText,
            completedLeafCount = completedLeafCount,
            errorMessage = errorMessage,
            updatedAt = updatedAt
        )
        if (updated == 1 && status == "success") {
            queueUsageClaimIfEligible(id, generation, transcription, updatedAt)
        }
        return updated
    }

    @Query(
        """
        UPDATE recordings SET
            status = CASE WHEN recognitionComplete = 1 THEN 'success' ELSE :status END,
            transcription = CASE
                WHEN recognitionComplete = 1 THEN rawTranscription
                ELSE transcription
            END,
            errorMessage = CASE WHEN recognitionComplete = 1 THEN NULL ELSE :errorMessage END,
            updatedAt = :updatedAt
        WHERE id = :id AND attemptId = :attemptId AND generation = :generation
          AND status IN ('processing', 'retrying')
        """
    )
    suspend fun finishRecognitionPreservingProgressRow(
        id: String,
        attemptId: String,
        generation: Long,
        status: String,
        errorMessage: String?,
        updatedAt: Long
    ): Int

    @Transaction
    suspend fun finishRecognitionPreservingProgress(
        id: String,
        attemptId: String,
        generation: Long,
        status: String,
        errorMessage: String?,
        updatedAt: Long
    ): Int {
        val updated = finishRecognitionPreservingProgressRow(
            id = id,
            attemptId = attemptId,
            generation = generation,
            status = status,
            errorMessage = errorMessage,
            updatedAt = updatedAt
        )
        if (updated == 1) {
            val current = getRecordingById(id)
            if (current?.status == "success") {
                queueUsageClaimIfEligible(id, generation, current.transcription, updatedAt)
            }
        }
        return updated
    }

    @Query(
        """
        UPDATE recordings SET
            status = CASE WHEN recognitionComplete = 1 THEN 'success' ELSE 'failed' END,
            attemptId = NULL,
            transcription = CASE
                WHEN recognitionComplete = 1 THEN rawTranscription
                ELSE transcription
            END,
            errorMessage = CASE WHEN recognitionComplete = 1 THEN NULL ELSE :message END,
            sourceIntegrity = CASE
                WHEN status IN ('capturing', 'finalizing') THEN 'unfinalized'
                ELSE sourceIntegrity
            END,
            updatedAt = :updatedAt
        WHERE status IN ('capturing', 'finalizing', 'processing', 'retrying')
        """
    )
    suspend fun normalizeAbandonedAttemptRows(message: String, updatedAt: Long): Int

    @Transaction
    suspend fun normalizeAbandonedAttempts(message: String, updatedAt: Long): Int {
        val recognizedCandidates = getActiveRecordings().filter { it.recognitionComplete }
        val updated = normalizeAbandonedAttemptRows(message, updatedAt)
        recognizedCandidates.forEach { candidate ->
            val current = getRecordingById(candidate.id)
            if (current?.status == "success" && current.generation == candidate.generation) {
                queueUsageClaimIfEligible(
                    id = current.id,
                    generation = current.generation,
                    text = current.transcription,
                    createdAt = updatedAt
                )
            }
        }
        return updated
    }

    @Query(
        """
        UPDATE recordings SET
            status = 'deleted',
            generation = generation + 1,
            attemptId = NULL,
            transcription = '',
            rawTranscription = '',
            checkpointText = '',
            recognitionComplete = 0,
            errorMessage = NULL,
            updatedAt = :updatedAt
        WHERE id = :id AND status NOT IN ('capturing', 'finalizing', 'processing', 'retrying', 'deleted')
        """
    )
    suspend fun tombstone(id: String, updatedAt: Long): Int

    @Query(
        """
        UPDATE recordings SET
            status = 'deleted',
            generation = generation + 1,
            attemptId = NULL,
            transcription = '',
            rawTranscription = '',
            checkpointText = '',
            recognitionComplete = 0,
            errorMessage = NULL,
            updatedAt = :updatedAt
        WHERE id = :id AND generation = :expectedGeneration
          AND status NOT IN ('capturing', 'finalizing', 'processing', 'retrying', 'deleted')
        """
    )
    suspend fun tombstoneExact(id: String, expectedGeneration: Long, updatedAt: Long): Int

    @Transaction
    suspend fun claimAllInactiveForClear(updatedAt: Long): List<RecordingEntity> {
        if (activeCount() != 0) throw ActiveRecordingConflictException()
        val candidates = getInactiveRecordings()
        candidates.forEach { row ->
            if (tombstoneExact(row.id, row.generation, updatedAt) != 1) {
                throw ActiveRecordingConflictException()
            }
        }
        return candidates
    }

    @Query(
        """
        UPDATE recordings SET
            status = 'deleted', generation = generation + 1, attemptId = NULL,
            transcription = '', rawTranscription = '', checkpointText = '', recognitionComplete = 0,
            errorMessage = NULL,
            updatedAt = :updatedAt
        WHERE status NOT IN ('capturing', 'finalizing', 'processing', 'retrying', 'deleted')
        """
    )
    suspend fun tombstoneAllInactive(updatedAt: Long): Int

    @Query(
        """
        UPDATE recordings SET
            audioFilePath = NULL,
            durationMs = NULL,
            sourceIntegrity = 'unfinalized',
            updatedAt = :updatedAt
        WHERE id = :id AND generation = :generation AND status = 'deleted'
        """
    )
    suspend fun clearDeletedSourcePath(id: String, generation: Long, updatedAt: Long): Int

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertUsageClaim(claim: UsageClaimEntity): Long

    @Query("SELECT * FROM usage_claims WHERE id = :id")
    suspend fun getUsageClaimById(id: String): UsageClaimEntity?

    @Query(
        """
        SELECT id FROM usage_claims
        WHERE state = 'pending' AND usageDestination = :usageDestination
        ORDER BY createdAt, id
        LIMIT 1
        """
    )
    suspend fun getNextPendingUsageClaimId(usageDestination: String): String?

    @Query("SELECT COUNT(*) FROM usage_claims WHERE state = 'pending'")
    fun observePendingUsageClaimCount(): Flow<Int>

    @Query(
        """
        UPDATE usage_claims SET state = 'claimed', claimedAt = :claimedAt
        WHERE id = :id AND state = 'pending' AND usageDestination = :usageDestination
        """
    )
    suspend fun markUsageClaimed(
        id: String,
        usageDestination: String,
        claimedAt: Long
    ): Int

    @Transaction
    suspend fun claimUsage(
        id: String,
        usageDestination: String,
        claimedAt: Long
    ): UsageClaimEntity? {
        if (markUsageClaimed(id, usageDestination, claimedAt) != 1) return null
        return getUsageClaimById(id)
    }

    @Transaction
    suspend fun claimNextUsage(
        usageDestination: String,
        claimedAt: Long
    ): UsageClaimEntity? {
        val id = getNextPendingUsageClaimId(usageDestination) ?: return null
        if (markUsageClaimed(id, usageDestination, claimedAt) != 1) return null
        return getUsageClaimById(id)
    }

    @Query("SELECT COUNT(*) FROM usage_claims WHERE state = :state")
    suspend fun getUsageClaimCount(state: String): Int

    @Query("SELECT COUNT(*) FROM recordings WHERE status IN ('capturing', 'finalizing', 'processing', 'retrying')")
    suspend fun activeCount(): Int

    @Query("SELECT COUNT(*) FROM recordings WHERE status != 'deleted'")
    suspend fun getRecordingCount(): Int

    private suspend fun queueUsageClaimIfEligible(
        id: String,
        generation: Long,
        text: String,
        createdAt: Long
    ) {
        val current = getRecordingById(id) ?: return
        if (!current.usageEligible || current.generation != generation || current.status != "success") return
        val wordCount = countUsageWords(text)
        if (wordCount <= 0) return
        insertUsageClaim(
            UsageClaimEntity(
                id = audioUsageClaimId(id, generation),
                recordingId = id,
                generation = generation,
                wordCount = wordCount,
                state = if (current.usageDestination == UsageClaimDestination.UNATTRIBUTED) {
                    UsageClaimEntity.UNATTRIBUTED
                } else {
                    UsageClaimEntity.PENDING
                },
                usageDestination = current.usageDestination,
                createdAt = createdAt
            )
        )
    }
}
