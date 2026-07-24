package com.whispermate.aidictation.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
import com.whispermate.aidictation.domain.model.Recording
import com.whispermate.aidictation.domain.model.UsageClaimDestination

@Entity(tableName = "recordings")
data class RecordingEntity(
    @PrimaryKey
    val id: String,
    val timestamp: Long,
    val transcription: String,
    val durationMs: Long?,
    val audioFilePath: String?,
    @ColumnInfo(defaultValue = "'success'") val status: String = "success",
    @ColumnInfo(defaultValue = "''") val rawTranscription: String = "",
    @ColumnInfo(defaultValue = "''") val checkpointText: String = "",
    @ColumnInfo(defaultValue = "0") val completedLeafCount: Int = 0,
    @ColumnInfo(defaultValue = "0") val recognitionComplete: Boolean = false,
    val attemptId: String? = null,
    @ColumnInfo(defaultValue = "0") val generation: Long = 0,
    val errorMessage: String? = null,
    @ColumnInfo(defaultValue = "'complete'") val sourceIntegrity: String = "complete",
    @ColumnInfo(defaultValue = "0") val updatedAt: Long = timestamp,
    @ColumnInfo(defaultValue = "0") val usageEligible: Boolean = false,
    @ColumnInfo(defaultValue = "'unattributed'")
    val usageDestination: String = UsageClaimDestination.UNATTRIBUTED
) {
    fun toDomain(): Recording = Recording(
        id = id,
        timestamp = timestamp,
        transcription = transcription,
        durationMs = durationMs,
        audioFilePath = audioFilePath,
        status = com.whispermate.aidictation.domain.model.AudioProcessingStatus.fromPersisted(status),
        rawTranscription = rawTranscription,
        checkpointText = checkpointText,
        completedLeafCount = completedLeafCount,
        recognitionComplete = recognitionComplete,
        attemptId = attemptId,
        generation = generation,
        errorMessage = errorMessage,
        sourceIntegrity = com.whispermate.aidictation.domain.model.AudioSourceIntegrity.fromPersisted(sourceIntegrity),
        updatedAt = updatedAt,
        usageEligible = usageEligible,
        usageDestination = usageDestination
    )

    companion object {
        fun fromDomain(recording: Recording): RecordingEntity = RecordingEntity(
            id = recording.id,
            timestamp = recording.timestamp,
            transcription = recording.transcription,
            durationMs = recording.durationMs,
            audioFilePath = recording.audioFilePath,
            status = recording.status.persistedValue,
            rawTranscription = recording.rawTranscription,
            checkpointText = recording.checkpointText,
            completedLeafCount = recording.completedLeafCount,
            recognitionComplete = recording.recognitionComplete,
            attemptId = recording.attemptId,
            generation = recording.generation,
            errorMessage = recording.errorMessage,
            sourceIntegrity = recording.sourceIntegrity.persistedValue,
            updatedAt = recording.updatedAt,
            usageEligible = recording.usageEligible,
            usageDestination = recording.usageDestination
        )
    }
}
