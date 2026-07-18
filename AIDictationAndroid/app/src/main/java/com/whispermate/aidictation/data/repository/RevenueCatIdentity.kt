package com.whispermate.aidictation.data.repository

import java.util.UUID

private val SUPABASE_UUID = Regex(
    "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

internal fun normalizeSupabaseUserID(userID: String): Result<String> {
    val candidate = userID.trim()
    if (!SUPABASE_UUID.matches(candidate)) {
        return Result.failure(
            IllegalArgumentException("The account identifier is not a Supabase UUID.")
        )
    }
    return runCatching { UUID.fromString(candidate).toString() }
}
