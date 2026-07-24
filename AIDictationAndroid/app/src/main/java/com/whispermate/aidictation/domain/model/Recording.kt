package com.whispermate.aidictation.domain.model

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID

data class Recording(
    val id: String = UUID.randomUUID().toString(),
    val timestamp: Long = System.currentTimeMillis(),
    val transcription: String = "",
    val durationMs: Long? = null,
    val audioFilePath: String? = null,
    val status: AudioProcessingStatus = AudioProcessingStatus.SUCCESS,
    val rawTranscription: String = "",
    val checkpointText: String = "",
    val completedLeafCount: Int = 0,
    val recognitionComplete: Boolean = false,
    val attemptId: String? = null,
    val generation: Long = 0,
    val errorMessage: String? = null,
    val sourceIntegrity: AudioSourceIntegrity = AudioSourceIntegrity.COMPLETE,
    val updatedAt: Long = timestamp,
    val usageEligible: Boolean = false,
    val usageDestination: String = UsageClaimDestination.UNATTRIBUTED,
    val retrySourceAvailable: Boolean = true
) {
    val isProcessing: Boolean get() = status.isActive
    val availableText: String get() = transcription.ifBlank { checkpointText }
    val canRetry: Boolean
        get() = status.isRetryable &&
            sourceIntegrity == AudioSourceIntegrity.COMPLETE &&
            retrySourceAvailable &&
            !audioFilePath.isNullOrBlank()

    val formattedDate: String
        get() {
            val instant = Instant.ofEpochMilli(timestamp)
            val formatter = DateTimeFormatter.ofPattern("MMM d, yyyy 'at' h:mm a")
                .withZone(ZoneId.systemDefault())
            return formatter.format(instant)
        }

    val formattedDuration: String?
        get() = durationMs?.let { ms ->
            val seconds = ms / 1000
            val minutes = seconds / 60
            val remainingSeconds = seconds % 60
            "${minutes}:${remainingSeconds.toString().padStart(2, '0')}"
        }
}
