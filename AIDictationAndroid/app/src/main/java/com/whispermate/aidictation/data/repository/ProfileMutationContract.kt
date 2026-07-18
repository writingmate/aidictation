package com.whispermate.aidictation.data.repository

import kotlinx.coroutines.sync.Mutex

internal class ProfileMutationGate {
    private val mutex = Mutex()

    suspend fun <T> run(operation: suspend () -> T): T {
        mutex.lock()
        return try {
            operation()
        } finally {
            mutex.unlock()
        }
    }
}

internal data class ProfileMutationRpc(
    val functionName: String,
    val parameters: Map<String, Any>
)

internal fun incrementWordCountMutation(
    expectedUserID: String,
    wordsToAdd: Int
) = ProfileMutationRpc(
    functionName = "increment_monthly_word_count_for_session",
    parameters = mapOf(
        "expected_user_id" to expectedUserID,
        "words_to_add" to wordsToAdd
    )
)

internal fun ensureReferralCodeMutation(expectedUserID: String) = ProfileMutationRpc(
    functionName = "ensure_referral_code_for_session",
    parameters = mapOf("expected_user_id" to expectedUserID)
)

internal fun redeemReferralCodeMutation(
    expectedUserID: String,
    code: String
) = ProfileMutationRpc(
    functionName = "redeem_referral_code_for_session",
    parameters = mapOf(
        "code" to code,
        "expected_user_id" to expectedUserID
    )
)

internal fun profileMutationResultMatchesExpectedUser(
    expectedUserID: String,
    resultUserID: String
): Boolean = expectedUserID.equals(resultUserID, ignoreCase = true)

internal fun profileMutationSnapshotMatchesActiveIdentity(
    expectedUserID: String,
    expectedGeneration: Long,
    currentGeneration: Long,
    currentUserID: String?
): Boolean = expectedGeneration == currentGeneration &&
    currentUserID?.equals(expectedUserID, ignoreCase = true) == true
