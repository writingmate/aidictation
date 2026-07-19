package com.whispermate.aidictation.domain.model

/** Durable lifecycle for one recording. Capture/finalize are journal-only pre-recognition states. */
enum class AudioProcessingStatus(val persistedValue: String) {
    CAPTURING("capturing"),
    FINALIZING("finalizing"),
    PROCESSING("processing"),
    RETRYING("retrying"),
    SUCCESS("success"),
    FAILED("failed"),
    CANCELLED("cancelled"),
    DELETED("deleted");

    val isActive: Boolean
        get() = this == CAPTURING || this == FINALIZING || this == PROCESSING || this == RETRYING

    val isRetryable: Boolean
        get() = this == SUCCESS || this == FAILED || this == CANCELLED

    companion object {
        fun fromPersisted(value: String): AudioProcessingStatus =
            entries.firstOrNull { it.persistedValue == value } ?: FAILED
    }
}

enum class AudioSourceIntegrity(val persistedValue: String) {
    PARTIAL("partial"),
    UNFINALIZED("unfinalized"),
    COMPLETE("complete"),
    KNOWN_INCOMPLETE("known_incomplete");

    companion object {
        fun fromPersisted(value: String): AudioSourceIntegrity =
            entries.firstOrNull { it.persistedValue == value } ?: KNOWN_INCOMPLETE
    }
}

data class AudioAttemptLease(
    val recordingId: String,
    val attemptId: String,
    val generation: Long,
    val sourcePath: String,
    val status: AudioProcessingStatus
)
