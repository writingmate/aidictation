package com.whispermate.aidictation.domain.model

fun countUsageWords(text: String): Int = text.trim()
    .split(Regex("\\s+"))
    .count { token -> token.any { it.isLetterOrDigit() } }

fun audioUsageClaimId(recordingId: String, generation: Long): String =
    "audio:$recordingId:$generation"
