package com.whispermate.aidictation.data.repository

import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import org.json.JSONException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A signed-in account is only signed out when the backend rejects the credential
 * itself. Every other failure has to leave the stored session alone, because the
 * user cannot recover a session the app has already deleted.
 */
class AuthSessionPolicyTest {

    @Test
    fun `rejects the stored credential when the backend returns unauthorized`() {
        assertTrue(
            AuthSessionPolicy.rejectsStoredCredential(
                AuthHttpException(401, "Profile fetch failed: 401")
            )
        )
    }

    @Test
    fun `rejects the stored credential when the backend returns forbidden`() {
        assertTrue(
            AuthSessionPolicy.rejectsStoredCredential(
                AuthHttpException(403, "Profile fetch failed: 403")
            )
        )
    }

    @Test
    fun `keeps the session when the backend fails`() {
        for (status in listOf(500, 502, 503, 504)) {
            assertFalse(
                "status $status must not sign the account out",
                AuthSessionPolicy.rejectsStoredCredential(
                    AuthHttpException(status, "Profile fetch failed: $status")
                )
            )
        }
    }

    @Test
    fun `keeps the session when the device cannot reach the backend`() {
        val transportFailures = listOf(
            UnknownHostException("aidictation.com"),
            SocketTimeoutException("timeout"),
            IOException("unexpected end of stream")
        )
        for (failure in transportFailures) {
            assertFalse(
                "${failure::class.simpleName} must not sign the account out",
                AuthSessionPolicy.rejectsStoredCredential(failure)
            )
        }
    }

    @Test
    fun `keeps the session when the response cannot be parsed`() {
        assertFalse(AuthSessionPolicy.rejectsStoredCredential(JSONException("no value for id")))
    }

    @Test
    fun `keeps the session for a missing failure`() {
        assertFalse(AuthSessionPolicy.rejectsStoredCredential(null))
    }

    @Test
    fun `keeps the session for other rejected statuses that are not about the credential`() {
        for (status in listOf(400, 404, 409, 429)) {
            assertFalse(
                "status $status must not sign the account out",
                AuthSessionPolicy.rejectsStoredCredential(
                    AuthHttpException(status, "Profile fetch failed: $status")
                )
            )
        }
    }
}
