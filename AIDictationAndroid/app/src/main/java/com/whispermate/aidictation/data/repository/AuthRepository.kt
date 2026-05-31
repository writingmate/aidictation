package com.whispermate.aidictation.data.repository

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.util.Log
import android.widget.Toast
import androidx.core.net.toUri
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.domain.model.AuthState
import com.whispermate.aidictation.domain.model.UserProfile
import dagger.hilt.android.qualifiers.ApplicationContext
import java.net.URLEncoder
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
    }

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
        context.startActivity(Intent(Intent.ACTION_VIEW, authUrl.toUri()).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        })
    }

    fun openUpgrade(context: Context) {
        val link = preferredPaymentLink()
        if (link.isBlank()) {
            _authState.value = _authState.value.copy(error = "Purchase link is not configured")
            Toast.makeText(context, "Purchase link is not configured", Toast.LENGTH_SHORT).show()
            return
        }

        val user = _authState.value.user
        if (user == null) {
            openLogin(context)
            return
        }

        val separator = if (link.contains("?")) "&" else "?"
        val encodedEmail = URLEncoder.encode(user.email, Charsets.UTF_8.name())
        context.startActivity(Intent(Intent.ACTION_VIEW, "$link${separator}prefilled_email=$encodedEmail".toUri()).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        })
    }

    suspend fun handleAuthCallback(uri: Uri) {
        if (uri.scheme != "aidictation" || uri.host != "auth-callback") return

        val accessToken = uri.authParam("access_token")
        val refreshToken = uri.authParam("refresh_token")
        if (accessToken.isNullOrBlank()) {
            _authState.value = _authState.value.copy(error = "Authentication callback did not include a session")
            return
        }

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
        val activeToken = fetchProfile(accessToken).fold(
            onSuccess = {
                _authState.value = AuthState(user = it, isLoading = false)
                return@withContext
            },
            onFailure = {
                if (refreshToken.isNullOrBlank()) null else refreshSession(refreshToken).getOrNull()
            }
        )

        if (activeToken == null) {
            clearTokens()
            _authState.value = AuthState(isLoading = false)
            return@withContext
        }

        fetchProfile(activeToken).fold(
            onSuccess = { _authState.value = AuthState(user = it, isLoading = false) },
            onFailure = { error ->
                Log.w(TAG, "Failed to fetch profile", error)
                _authState.value = AuthState(isLoading = false, error = error.message)
            }
        )
    }

    suspend fun signOut() = withContext(Dispatchers.IO) {
        clearTokens()
        _authState.value = AuthState(isLoading = false)
    }

    suspend fun updateWordCount(wordsToAdd: Int): UserProfile? = withContext(Dispatchers.IO) {
        if (wordsToAdd <= 0) return@withContext _authState.value.user
        val user = _authState.value.user ?: return@withContext null
        val token = securePrefs.getString(SecureKeys.ACCESS_TOKEN, null) ?: return@withContext user
        val updatedCount = user.monthlyWordCount + wordsToAdd
        val body = JSONObject()
            .put("monthly_word_count", updatedCount)
            .put("updated_at", Instant.now().toString())
            .toString()
            .toRequestBody(jsonMediaType)

        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/rest/v1/profiles?user_id=eq.${user.userId}&select=*")
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
                _authState.value = _authState.value.copy(user = updated)
                updated
            }
        }.getOrElse { error ->
            Log.w(TAG, "Failed to update word count", error)
            user
        }
    }

    suspend fun ensureReferralCode(): Result<UserProfile> = withContext(Dispatchers.IO) {
        val token = securePrefs.getString(SecureKeys.ACCESS_TOKEN, null)
            ?: return@withContext Result.failure(Exception("Sign in to create an invite link."))

        callProfileRpc("ensure_referral_code", JSONObject(), token)
    }

    suspend fun redeemReferralCode(code: String): Result<UserProfile> = withContext(Dispatchers.IO) {
        val token = securePrefs.getString(SecureKeys.ACCESS_TOKEN, null)
            ?: return@withContext Result.failure(Exception("Sign in to apply an invite code."))
        val cleanedCode = code.trim()
        if (cleanedCode.isBlank()) {
            return@withContext Result.failure(Exception("Enter an invite code."))
        }

        callProfileRpc("redeem_referral_code", JSONObject().put("code", cleanedCode), token)
    }

    private fun callProfileRpc(functionName: String, payload: JSONObject, accessToken: String): Result<UserProfile> = runCatching {
        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/rest/v1/rpc/$functionName")
            .addSupabaseHeaders(accessToken)
            .post(payload.toString().toRequestBody(jsonMediaType))
            .build()

        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Request failed: ${response.code}")
            val updated = parseProfile(response.body?.string().orEmpty(), _authState.value.user?.email.orEmpty())
            _authState.value = _authState.value.copy(user = updated)
            updated
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
            if (!response.isSuccessful) error("Profile fetch failed: ${response.code}")
            val profiles = parseProfileArray(response.body?.string().orEmpty(), authUser.second)
            profiles.firstOrNull() ?: UserProfile(
                userId = authUser.first,
                email = authUser.second,
                monthlyWordCount = 0,
                subscriptionStatus = "free"
            )
        }
    }

    private fun fetchAuthUser(accessToken: String): Pair<String, String> {
        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/auth/v1/user")
            .addSupabaseHeaders(accessToken)
            .get()
            .build()

        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Auth user fetch failed: ${response.code}")
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
            if (!response.isSuccessful) error("Session refresh failed: ${response.code}")
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
