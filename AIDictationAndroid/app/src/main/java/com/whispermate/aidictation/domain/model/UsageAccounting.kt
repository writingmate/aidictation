package com.whispermate.aidictation.domain.model

object UsageClaimDestination {
    const val LOCAL = "local"
    const val UNATTRIBUTED = "unattributed"
    private const val ACCOUNT_PREFIX = "account:"

    fun account(userId: String): String? =
        userId.trim().takeIf { it.isNotEmpty() }?.let { "$ACCOUNT_PREFIX$it" }

    fun accountId(destination: String): String? =
        destination.takeIf { it.startsWith(ACCOUNT_PREFIX) }
            ?.removePrefix(ACCOUNT_PREFIX)
            ?.takeIf { it.isNotEmpty() }
}

fun countUsageWords(text: String): Int = text.trim()
    .split(Regex("\\s+"))
    .count { token -> token.any { it.isLetterOrDigit() } }

fun audioUsageClaimId(recordingId: String, generation: Long): String =
    "audio:$recordingId:$generation"
