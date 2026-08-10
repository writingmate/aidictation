package com.whispermate.aidictation.data.repository

import java.io.IOException

/** Carries the response status so a rejected credential can be told apart from an unreachable backend. */
class AuthHttpException(val statusCode: Int, message: String) : IOException(message)

/**
 * Decides whether a failed account request means the stored session is gone.
 *
 * Only a status the backend uses to reject the credential itself invalidates a
 * session. Treating every failure as a rejection let one unreachable network or
 * one server error delete a good session: the account dropped back to the
 * signed-out screen with nothing explaining why, and retrying could not recover
 * it because the tokens were already deleted.
 */
object AuthSessionPolicy {

    // MARK: - Private Properties

    private val credentialRejectionStatuses = setOf(401, 403)

    // MARK: - Public API

    fun rejectsStoredCredential(error: Throwable?): Boolean =
        error is AuthHttpException && error.statusCode in credentialRejectionStatuses
}
