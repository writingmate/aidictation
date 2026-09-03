package com.whispermate.aidictation.data.repository

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.util.Log
import android.widget.Toast
import androidx.core.net.toUri
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.whispermate.aidictation.R
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.domain.model.AuthState
import com.whispermate.aidictation.domain.model.UsageClaimDestination
import com.whispermate.aidictation.domain.model.UserProfile
import dagger.hilt.android.qualifiers.ApplicationContext
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

@Singleton
class AuthRepository @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private object SecureKeys {
        const val ACCESS_TOKEN = "access_token"
        const val REFRESH_TOKEN = "refresh_token"
        const val CACHED_PROFILE = "cached_profile"
    }

    /** Thrown when the backend actively rejects the session, as opposed to a
     *  network blip or a server-side error. Only the former should sign anyone
     *  out; treating both alike logged paying users out over a dropped Wi-Fi
     *  connection and left them staring at the signed-out gate. */
    private class SessionRejectedException(message: String) : Exception(message)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val jsonMediaType = "application/json".toMediaType()
    private val okHttpClient = OkHttpClient()

    private val securePrefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "auth_session",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    private val _authState = MutableStateFlow(AuthState(isLoading = true))
    val authState: StateFlow<AuthState> = _authState.asStateFlow()

    init {
        scope.launch {
            refreshUser()
        }
    }

    fun isAuthConfigured(): Boolean {
        return BuildConfig.SUPABASE_URL.isNotBlank() &&
            BuildConfig.SUPABASE_ANON_KEY.isNotBlank() &&
            BuildConfig.AUTH_WEB_URL.isNotBlank()
    }

    fun isPurchaseConfigured(): Boolean {
        return preferredPaymentLink().isNotBlank()
    }

    /** Native Google sign-in needs the auth API plus the Google web client ID. */
    fun isGoogleSignInConfigured(): Boolean {
        return BuildConfig.GOOGLE_WEB_CLIENT_ID.isNotBlank() &&
            BuildConfig.SUPABASE_URL.isNotBlank() &&
            BuildConfig.SUPABASE_ANON_KEY.isNotBlank()
    }

    /**
     * Signs in with a Google account through Android's Credential Manager, then trades
     * the Google ID token for an app session at the auth API (Supabase's
     * `grant_type=id_token` contract). The raw nonce goes to the auth API and its SHA-256
     * to Google, which is what the API verifies against the token's nonce claim.
     *
     * [activityContext] must be an Activity: the account picker is shown from it.
     * Returns true when a session was established, false when the user dismissed the
     * picker; failures are surfaced through [authState] and a toast.
     */
    suspend fun signInWithGoogle(activityContext: Context): Boolean {
        if (!isGoogleSignInConfigured()) {
            reportGoogleFailure(activityContext, context.getString(R.string.account_google_not_configured))
            return false
        }

        val rawNonce = ByteArray(32).also { SecureRandom().nextBytes(it) }.toHex()
        val hashedNonce = MessageDigest.getInstance("SHA-256")
            .digest(rawNonce.toByteArray(Charsets.UTF_8))
            .toHex()
        val request = GetCredentialRequest.Builder()
            .addCredentialOption(
                GetGoogleIdOption.Builder()
                    .setServerClientId(BuildConfig.GOOGLE_WEB_CLIENT_ID)
                    .setFilterByAuthorizedAccounts(false)
                    .setAutoSelectEnabled(false)
                    .setNonce(hashedNonce)
                    .build()
            )
            .build()

        val credential = try {
            CredentialManager.create(activityContext).getCredential(activityContext, request).credential
        } catch (error: GetCredentialCancellationException) {
            return false
        } catch (error: NoCredentialException) {
            reportGoogleFailure(activityContext, context.getString(R.string.account_google_no_account))
            return false
        } catch (error: GetCredentialException) {
            Log.w(TAG, "Google credential request failed", error)
            reportGoogleFailure(activityContext, context.getString(R.string.account_google_failed))
            return false
        }

        val idToken = (credential as? CustomCredential)
            ?.takeIf { it.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL }
            ?.let { runCatching { GoogleIdTokenCredential.createFrom(it.data).idToken }.getOrNull() }
        if (idToken.isNullOrBlank()) {
            reportGoogleFailure(activityContext, context.getString(R.string.account_google_failed))
            return false
        }

        // Do not expose the previous user while the secure token is being replaced.
        val previousState = _authState.value
        _authState.value = AuthState(isLoading = true)
        val session = exchangeGoogleIdToken(idToken, rawNonce)
        val tokens = session.getOrElse { error ->
            Log.w(TAG, "Google ID token exchange failed", error)
            _authState.value = previousState
            reportGoogleFailure(
                activityContext,
                error.message ?: context.getString(R.string.account_google_failed)
            )
            return false
        }
        storeTokens(tokens.first, tokens.second)
        refreshUser()
        return _authState.value.user != null
    }

    private suspend fun exchangeGoogleIdToken(idToken: String, rawNonce: String): Result<Pair<String, String?>> =
        withContext(Dispatchers.IO) {
            runCatching {
                val body = JSONObject()
                    .put("provider", "google")
                    .put("id_token", idToken)
                    .put("nonce", rawNonce)
                    .toString()
                    .toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/auth/v1/token?grant_type=id_token")
                    .addHeader("apikey", BuildConfig.SUPABASE_ANON_KEY)
                    .post(body)
                    .build()
                okHttpClient.newCall(request).execute().use { response ->
                    val text = response.body?.string().orEmpty()
                    if (!response.isSuccessful) {
                        throw sessionFailure(
                            runCatching { JSONObject(text) }.getOrNull()
                                ?.let { it.optString("error_description").ifBlank { it.optString("msg") } }
                                ?.ifBlank { null }
                                ?: context.getString(R.string.account_google_failed),
                            response.code
                        )
                    }
                    val json = JSONObject(text)
                    json.getString("access_token") to json.optString("refresh_token").ifBlank { null }
                }
            }
        }

    private fun reportGoogleFailure(activityContext: Context, message: String) {
        _authState.value = _authState.value.copy(error = message)
        Toast.makeText(activityContext, message, Toast.LENGTH_LONG).show()
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    fun openLogin(context: Context) {
        if (!isAuthConfigured()) {
            _authState.value = _authState.value.copy(error = "Auth is not configured")
            Toast.makeText(context, "Auth is not configured", Toast.LENGTH_SHORT).show()
            return
        }

        val redirectTo = "aidictation://auth-callback"
        val encodedRedirect = URLEncoder.encode(redirectTo, Charsets.UTF_8.name())
        val separator = if (BuildConfig.AUTH_WEB_URL.contains("?")) "&" else "?"
        val authUrl = "${BuildConfig.AUTH_WEB_URL}${separator}redirect_to=$encodedRedirect"
        openExternally(context, authUrl, "Could not open the sign-in page")
    }

    /// Sign-in and checkout both hand off to a browser, and a device without one
    /// — no browser installed, or the default disabled — made startActivity throw
    /// ActivityNotFoundException straight out of a tap handler, taking the app
    /// down. Tell the user instead.
    private fun openExternally(context: Context, url: String, failureMessage: String) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri()).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            })
        } catch (error: ActivityNotFoundException) {
            _authState.value = _authState.value.copy(error = failureMessage)
            Toast.makeText(context, failureMessage, Toast.LENGTH_LONG).show()
        }
    }

    fun openUpgrade(context: Context) {
        // Signing in comes first and needs no payment link. Checking the link
        // before the session made the "Sign in to upgrade" entry point dead for
        // signed-out users whenever no production Stripe link was configured.
        val user = _authState.value.user
        if (user == null) {
            openLogin(context)
            return
        }

        val link = preferredPaymentLink()
        if (link.isBlank()) {
            _authState.value = _authState.value.copy(error = "Purchase link is not configured")
            Toast.makeText(context, "Purchase link is not configured", Toast.LENGTH_SHORT).show()
            return
        }

        val separator = if (link.contains("?")) "&" else "?"
        val encodedEmail = URLEncoder.encode(user.email, Charsets.UTF_8.name())
        openExternally(
            context,
            "$link${separator}prefilled_email=$encodedEmail",
            "Could not open the checkout page",
        )
    }

    suspend fun handleAuthCallback(uri: Uri) {
        if (uri.scheme != "aidictation" || uri.host != "auth-callback") return

        val accessToken = uri.authParam("access_token")
        val refreshToken = uri.authParam("refresh_token")
        if (accessToken.isNullOrBlank()) {
            _authState.value = _authState.value.copy(error = "Authentication callback did not include a session")
            return
        }

        // Do not expose the previous user while the secure token is being replaced.
        _authState.value = AuthState(isLoading = true)
        storeTokens(accessToken, refreshToken)
        refreshUser()
    }

    suspend fun refreshUser() = withContext(Dispatchers.IO) {
        if (!isAuthConfigured()) {
            _authState.value = AuthState(isLoading = false)
            return@withContext
        }

        val accessToken = securePrefs.getString(SecureKeys.ACCESS_TOKEN, null)
        val refreshToken = securePrefs.getString(SecureKeys.REFRESH_TOKEN, null)
        if (accessToken.isNullOrBlank()) {
            _authState.value = AuthState(isLoading = false)
            return@withContext
        }

        _authState.value = _authState.value.copy(isLoading = true, error = null)
        var rejected = false
        val activeToken = fetchProfile(accessToken).fold(
            onSuccess = {
                cacheProfile(it)
                _authState.value = AuthState(user = it, isLoading = false)
                return@withContext
            },
            onFailure = { fetchError ->
                Log.w(TAG, "Initial profile fetch failed", fetchError)
                if (refreshToken.isNullOrBlank()) {
                    null
                } else {
                    refreshSession(refreshToken).fold(
                        onSuccess = { token -> token },
                        onFailure = { error ->
                            Log.w(TAG, "Session refresh failed", error)
                            rejected = error is SessionRejectedException
                            null
                        }
                    )
                }
            }
        )

        if (activeToken == null) {
            // Only a rejected session means the user is really signed out. Clearing
            // tokens on a network failure logged paying users out of a working
            // session, and the signed-out state reads as "no subscription".
            if (rejected || refreshToken.isNullOrBlank()) {
                clearTokens()
                _authState.value = AuthState(isLoading = false)
                return@withContext
            }
            // Keep the tokens — the failure was not a rejection — but only report a
            // signed-in state when there is actually a profile to show. Emitting a
            // null user with no error stranded the UI in a state that is neither
            // signed in nor signed out, so a sign-in appeared to do nothing at all.
            val cached = cachedProfile()
            Log.w(TAG, "Keeping session after a non-rejecting refresh failure; cached profile: ${cached != null}")
            _authState.value = AuthState(
                user = cached,
                isLoading = false,
                error = if (cached == null) "Could not reach your account. Please try again." else null
            )
            return@withContext
        }

        fetchProfile(activeToken).fold(
            onSuccess = {
                cacheProfile(it)
                _authState.value = AuthState(user = it, isLoading = false)
            },
            onFailure = { error ->
                Log.w(TAG, "Failed to fetch profile", error)
                // A failed fetch means the entitlement is unknown, not absent. Keep
                // the last known profile so lifetime access survives an outage.
                val cached = cachedProfile()
                _authState.value = AuthState(
                    user = cached,
                    isLoading = false,
                    error = if (cached == null) error.message else null
                )
            }
        )
    }

    suspend fun signOut() = withContext(Dispatchers.IO) {
        securePrefs.edit().remove(SecureKeys.CACHED_PROFILE).apply()
        clearTokens()
        _authState.value = AuthState(isLoading = false)
    }

    internal fun currentUsageDestination(): String? {
        val state = _authState.value
        if (state.isLoading) return null
        val user = state.user ?: return UsageClaimDestination.LOCAL
        return UsageClaimDestination.account(user.userId)
    }

    suspend fun updateWordCount(
        wordsToAdd: Int,
        expectedUserId: String
    ): UserProfile? = withContext(Dispatchers.IO) {
        if (wordsToAdd <= 0) return@withContext _authState.value.user
        val user = _authState.value.user
            ?.takeIf { it.userId == expectedUserId }
            ?: return@withContext null
        val token = securePrefs.getString(SecureKeys.ACCESS_TOKEN, null) ?: return@withContext user
        val updatedCount = user.monthlyWordCount + wordsToAdd
        val body = JSONObject()
            .put("monthly_word_count", updatedCount)
            .put("updated_at", Instant.now().toString())
            .toString()
            .toRequestBody(jsonMediaType)

        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/rest/v1/profiles?user_id=eq.$expectedUserId&select=*")
            .addSupabaseHeaders(token)
            .addHeader("Prefer", "return=representation")
            .patch(body)
            .build()

        runCatching {
            okHttpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) error("Profile update failed: ${response.code}")
                val responseBody = response.body?.string().orEmpty()
                val updated = parseProfileArray(responseBody, user.email).firstOrNull()
                    ?: user.copy(monthlyWordCount = updatedCount)
                if (_authState.value.user?.userId == expectedUserId) {
                    _authState.value = _authState.value.copy(user = updated)
                }
                updated
            }
        }.getOrElse { error ->
            Log.w(TAG, "Failed to update word count", error)
            user
        }
    }

    private fun fetchProfile(accessToken: String): Result<UserProfile> = runCatching {
        val authUser = fetchAuthUser(accessToken)
        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/rest/v1/profiles?select=*&user_id=eq.${authUser.first}")
            .addSupabaseHeaders(accessToken)
            .get()
            .build()

        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw sessionFailure("Profile fetch failed", response.code)
            val profiles = parseProfileArray(response.body?.string().orEmpty(), authUser.second)
            // An empty result is "we could not see a profile", which is not the same
            // as "this account has nothing". Prefer the last known profile over
            // inventing a free one.
            val profile = profiles.firstOrNull()
            if (profile != null) {
                // The profile row only carries a subscription once something has
                // synced it. Entitlement can also come from a redeemed code or a
                // Stripe purchase, which check-subscription resolves (and writes
                // back). Without asking, a lifetime owner reads as free here.
                return@use fetchSubscriptionStatus(accessToken)
                    ?.let { profile.copy(subscriptionStatus = it) }
                    ?: profile
            }
            cachedProfile() ?: UserProfile(
                userId = authUser.first,
                email = authUser.second,
                monthlyWordCount = 0,
                subscriptionStatus = "free"
            )
        }
    }

    // The auth backend answers an invalid or already-used refresh token with 400
    // ({"error_code":"invalid_credentials"}), not 401. Treating 400 as transient
    // kept a dead session alive: no re-login prompt, no error, nothing on screen.
    /** Resolves entitlement that the profile row may not reflect yet. Failures are
     *  swallowed: an unreachable check means unknown, and the stored profile value
     *  is a better answer than downgrading someone to free. */
    private fun fetchSubscriptionStatus(accessToken: String): String? = runCatching {
        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/functions/v1/check-subscription")
            .addSupabaseHeaders(accessToken)
            .post("{}".toRequestBody(jsonMediaType))
            .build()
        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return@runCatching null
            val json = JSONObject(response.body?.string().orEmpty())
            if (json.has("error")) return@runCatching null
            json.optNullableString("subscription_status")
        }
    }.onFailure { Log.w(TAG, "Subscription check failed", it) }.getOrNull()

    private fun sessionFailure(message: String, code: Int): Exception =
        if (code == 400 || code == 401 || code == 403) {
            SessionRejectedException("$message: $code")
        } else {
            IllegalStateException("$message: $code")
        }

    private fun cacheProfile(profile: UserProfile) {
        runCatching {
            val json = JSONObject()
                .put("user_id", profile.userId)
                .put("email", profile.email)
                .put("monthly_word_count", profile.monthlyWordCount)
                .put("subscription_status", profile.subscriptionStatus)
                .put("referral_code", profile.referralCode)
                .put("referred_by_user_id", profile.referredByUserId)
                .put("referral_bonus_words", profile.referralBonusWords)
            securePrefs.edit().putString(SecureKeys.CACHED_PROFILE, json.toString()).apply()
        }.onFailure { Log.w(TAG, "Failed to cache profile", it) }
    }

    private fun cachedProfile(): UserProfile? {
        val stored = securePrefs.getString(SecureKeys.CACHED_PROFILE, null) ?: return null
        return runCatching { parseProfile(stored, "") }.getOrNull()
    }

    private fun fetchAuthUser(accessToken: String): Pair<String, String> {
        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/auth/v1/user")
            .addSupabaseHeaders(accessToken)
            .get()
            .build()

        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw sessionFailure("Auth user fetch failed", response.code)
            val json = JSONObject(response.body?.string().orEmpty())
            return json.getString("id") to json.optString("email")
        }
    }

    private fun refreshSession(refreshToken: String): Result<String> = runCatching {
        val body = JSONObject()
            .put("refresh_token", refreshToken)
            .toString()
            .toRequestBody(jsonMediaType)
        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/auth/v1/token?grant_type=refresh_token")
            .addHeader("apikey", BuildConfig.SUPABASE_ANON_KEY)
            .addHeader("Content-Type", "application/json")
            .post(body)
            .build()

        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw sessionFailure("Session refresh failed", response.code)
            val json = JSONObject(response.body?.string().orEmpty())
            val accessToken = json.getString("access_token")
            storeTokens(accessToken, json.optString("refresh_token", refreshToken))
            accessToken
        }
    }

    private fun parseProfileArray(json: String, fallbackEmail: String): List<UserProfile> {
        val array = JSONArray(json.ifBlank { "[]" })
        return (0 until array.length()).map { index ->
            parseProfile(array.getJSONObject(index), fallbackEmail)
        }
    }

    private fun parseProfile(json: String, fallbackEmail: String): UserProfile {
        return parseProfile(JSONObject(json.ifBlank { "{}" }), fallbackEmail)
    }

    private fun parseProfile(item: JSONObject, fallbackEmail: String): UserProfile {
        return UserProfile(
            userId = item.optString("user_id"),
            email = item.optString("email", fallbackEmail),
            monthlyWordCount = item.optInt("monthly_word_count", 0),
            subscriptionStatus = item.optString("subscription_status", "free"),
            stripeCustomerId = item.optNullableString("stripe_customer_id"),
            stripeSubscriptionId = item.optNullableString("stripe_subscription_id"),
            wordCountResetAt = null,
            referralCode = item.optNullableString("referral_code"),
            referredByUserId = item.optNullableString("referred_by_user_id"),
            referralBonusWords = item.optInt("referral_bonus_words", 0)
        )
    }

    private fun storeTokens(accessToken: String, refreshToken: String?) {
        securePrefs.edit()
            .putString(SecureKeys.ACCESS_TOKEN, accessToken)
            .apply {
                if (!refreshToken.isNullOrBlank()) {
                    putString(SecureKeys.REFRESH_TOKEN, refreshToken)
                }
            }
            .apply()
    }

    private fun clearTokens() {
        securePrefs.edit()
            .remove(SecureKeys.ACCESS_TOKEN)
            .remove(SecureKeys.REFRESH_TOKEN)
            .apply()
    }

    private fun preferredPaymentLink(): String {
        return BuildConfig.STRIPE_PAYMENT_LINK_MONTHLY.ifBlank {
            BuildConfig.STRIPE_PAYMENT_LINK
        }.ifBlank {
            BuildConfig.STRIPE_PAYMENT_LINK_ANNUAL
        }.ifBlank {
            BuildConfig.STRIPE_PAYMENT_LINK_LIFETIME
        }
    }

    private fun Request.Builder.addSupabaseHeaders(accessToken: String): Request.Builder {
        return addHeader("apikey", BuildConfig.SUPABASE_ANON_KEY)
            .addHeader("Authorization", "Bearer $accessToken")
            .addHeader("Content-Type", "application/json")
    }

    private fun Uri.authParam(name: String): String? {
        getQueryParameter(name)?.let { return it }
        val fragment = fragment ?: return null
        return fragment.split("&")
            .mapNotNull { part ->
                val pieces = part.split("=", limit = 2)
                if (pieces.size == 2) pieces[0] to Uri.decode(pieces[1]) else null
            }
            .firstOrNull { it.first == name }
            ?.second
    }

    private fun JSONObject.optNullableString(name: String): String? {
        if (!has(name) || isNull(name)) return null
        return optString(name).takeIf { it.isNotBlank() }
    }

    private companion object {
        const val TAG = "AuthRepository"
    }
}
