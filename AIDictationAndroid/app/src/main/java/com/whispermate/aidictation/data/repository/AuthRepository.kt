package com.whispermate.aidictation.data.repository

import android.content.Context
import android.app.Activity
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.SystemClock
import android.util.Log
import android.util.Base64
import android.widget.Toast
import androidx.core.net.toUri
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.domain.model.AuthState
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
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

private data class RefreshedSession(
    val accessToken: String,
    val refreshToken: String?
)

private data class SubscriptionReconciliation(
    val subscribed: Boolean,
    val subscriptionStatus: String
)

private data class AuthSessionSnapshot(
    val generation: Long,
    val user: UserProfile,
    val accessToken: String
)

@Singleton
class AuthRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val revenueCat: RevenueCatPurchaseManager
) {
    private object SecureKeys {
        const val ACCESS_TOKEN = "access_token"
        const val REFRESH_TOKEN = "refresh_token"
        const val PENDING_AUTH_STATE = "pending_auth_state"
        const val PENDING_AUTH_STATE_CREATED_AT = "pending_auth_state_created_at"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val authStateMutex = Mutex()
    private val revenueCatRefreshMutex = Mutex()
    private val jsonMediaType = "application/json".toMediaType()
    private val okHttpClient = OkHttpClient()
    @Volatile
    private var lastRevenueCatRefreshUserID: String? = null

    @Volatile
    private var lastRevenueCatRefreshAtMs = 0L

    @Volatile
    private var authGeneration = 0L

    @Volatile
    private var reconciledRevenueCatGeneration: Long? = null

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
            revenueCat.entitlementUpdates.collect(::applyRevenueCatUpdate)
        }
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
        return revenueCat.isConfigured
    }

    fun openLogin(context: Context) {
        if (!isAuthConfigured()) {
            _authState.value = _authState.value.copy(error = "Auth is not configured")
            Toast.makeText(context, "Auth is not configured", Toast.LENGTH_SHORT).show()
            return
        }

        val authState = createPendingAuthState()
        val redirectTo = Uri.Builder()
            .scheme("https")
            .authority(AUTH_CALLBACK_HOST)
            .path(AUTH_CALLBACK_PATH)
            .appendQueryParameter("state", authState)
            .build()
            .toString()
        val encodedRedirect = URLEncoder.encode(redirectTo, Charsets.UTF_8.name())
        val separator = if (BuildConfig.AUTH_WEB_URL.contains("?")) "&" else "?"
        val authUrl = "${BuildConfig.AUTH_WEB_URL}${separator}redirect_to=$encodedRedirect" +
            "&as_web_authentication_session=1"
        context.startActivity(Intent(Intent.ACTION_VIEW, authUrl.toUri()).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        })
    }

    fun loadMonthlyPrice(
        onError: () -> Unit,
        onSuccess: (String) -> Unit
    ) {
        revenueCat.loadMonthlyPrice(
            onError = { error ->
                Log.w("AuthRepository", "Unable to load purchase options", IllegalStateException(error))
                onError()
            },
            onSuccess = onSuccess
        )
    }

    fun openUpgrade(
        activity: Activity,
        onError: () -> Unit,
        onCancelled: () -> Unit,
        onSuccess: () -> Unit
    ) {
        val generation = authGeneration
        val user = _authState.value.user
        if (user == null || !isAuthGenerationCurrent(generation)) {
            openLogin(activity)
            onCancelled()
            return
        }
        revenueCat.purchaseMonthly(
            activity = activity,
            expectedUserID = user.userId,
            authGeneration = generation,
            onError = { error ->
                Log.w("AuthRepository", "Purchase failed", IllegalStateException(error))
                if (isAuthGenerationCurrent(generation)) onError() else onCancelled()
            },
            onCancelled = onCancelled,
            onEntitlement = { entitlement ->
                if (!isAuthGenerationCurrent(generation)) {
                    onCancelled()
                } else {
                    queueRevenueCatEntitlement(user.userId, entitlement, generation)
                    if (entitlement is RevenueCatEntitlement.Active) onSuccess() else onError()
                }
            },
            identityIsCurrent = { isAuthGenerationCurrent(generation) }
        )
    }

    fun restorePurchases(
        onError: () -> Unit,
        onNotFound: () -> Unit,
        onSuccess: () -> Unit
    ) {
        val generation = authGeneration
        val user = _authState.value.user
        if (user == null || !isAuthGenerationCurrent(generation)) {
            openLogin(context)
            onNotFound()
            return
        }
        revenueCat.restore(
            expectedUserID = user.userId,
            authGeneration = generation,
            onError = { error ->
                Log.w("AuthRepository", "Restore failed", IllegalStateException(error))
                onError()
            },
            onEntitlement = { entitlement ->
                if (!isAuthGenerationCurrent(generation)) {
                    onError()
                } else {
                    queueRevenueCatEntitlement(user.userId, entitlement, generation)
                    if (entitlement is RevenueCatEntitlement.Active) onSuccess() else onNotFound()
                }
            },
            identityIsCurrent = { isAuthGenerationCurrent(generation) }
        )
    }

    fun handleAuthCallback(uri: Uri) {
        scope.launch { handleAuthCallbackInRepositoryScope(uri) }
    }

    private suspend fun handleAuthCallbackInRepositoryScope(uri: Uri) {
        if (!isExpectedAuthCallback(uri)) return

        val callbackState = uri.getQueryParameter("state")
        if (!consumePendingAuthState(callbackState)) {
            authStateMutex.withLock {
                _authState.value = _authState.value.copy(
                    isLoading = false,
                    error = "This sign-in link is invalid or expired. Start sign-in again."
                )
            }
            return
        }

        val accessToken = uri.authParam("access_token")
        val refreshToken = uri.authParam("refresh_token")
        if (accessToken.isNullOrBlank()) {
            authStateMutex.withLock {
                _authState.value = _authState.value.copy(
                    error = "Authentication callback did not include a session"
                )
            }
            return
        }

        val generation = beginAuthTransition(
            accessToken = accessToken,
            refreshToken = refreshToken,
            replaceTokens = true
        )
        refreshUserForGeneration(generation)
    }

    suspend fun refreshUser() = withContext(Dispatchers.IO) {
        val generation = beginAuthTransition()
        refreshUserForGeneration(generation)
    }

    private suspend fun refreshUserForGeneration(generation: Long) {
        if (!isAuthConfigured()) {
            setAuthStateIfCurrent(generation, AuthState(isLoading = false))
            return
        }

        val tokens = authStateMutex.withLock {
            if (authGeneration != generation) return
            securePrefs.getString(SecureKeys.ACCESS_TOKEN, null) to
                securePrefs.getString(SecureKeys.REFRESH_TOKEN, null)
        }
        val accessToken = tokens.first
        val refreshToken = tokens.second
        if (accessToken.isNullOrBlank()) {
            setAuthStateIfCurrent(generation, AuthState(isLoading = false))
            return
        }

        val initialProfile = fetchProfile(accessToken)
        if (initialProfile.isSuccess) {
            publishAuthenticatedProfile(
                user = initialProfile.getOrThrow(),
                accessToken = accessToken,
                generation = generation
            )
            return
        }

        val refreshedSession = if (refreshToken.isNullOrBlank()) {
            null
        } else {
            refreshSession(refreshToken).getOrNull()
        }

        if (refreshedSession == null) {
            clearSessionIfCurrent(generation)
            return
        }

        authStateMutex.withLock {
            if (authGeneration != generation) return
            storeTokens(refreshedSession.accessToken, refreshedSession.refreshToken)
        }

        fetchProfile(refreshedSession.accessToken).fold(
            onSuccess = { user ->
                publishAuthenticatedProfile(user, refreshedSession.accessToken, generation)
            },
            onFailure = { error ->
                Log.w(TAG, "Failed to fetch profile", error)
                setAuthStateIfCurrent(
                    generation,
                    AuthState(isLoading = false, error = error.message)
                )
            }
        )
    }

    suspend fun refreshRevenueCatEntitlement(force: Boolean = false): Result<Unit> =
        withContext(Dispatchers.IO) {
            revenueCatRefreshMutex.withLock {
                val snapshot = currentAuthSessionSnapshot()
                    ?: return@withLock Result.success(Unit)
                val now = SystemClock.elapsedRealtime()
                val wasRecentlyChecked = lastRevenueCatRefreshUserID.equals(
                    snapshot.user.userId,
                    ignoreCase = true
                ) && now - lastRevenueCatRefreshAtMs < REVENUECAT_REFRESH_INTERVAL_MS
                if (!force && wasRecentlyChecked) return@withLock Result.success(Unit)

                clearReconciliationAuthority(snapshot)
                val backendResult = reconcileSubscription(snapshot.accessToken)
                if (!isAuthGenerationCurrent(snapshot.generation)) {
                    return@withLock Result.failure(staleAuthOperation())
                }
                val revenueCatResult = revenueCat.refresh(
                    userID = snapshot.user.userId,
                    authGeneration = snapshot.generation,
                    identityIsCurrent = { isAuthGenerationCurrent(snapshot.generation) }
                )
                if (!isAuthGenerationCurrent(snapshot.generation)) {
                    return@withLock Result.failure(staleAuthOperation())
                }

                applyReconciliationResult(snapshot, backendResult, revenueCatResult)
                val failure = backendResult.exceptionOrNull() ?: revenueCatResult.exceptionOrNull()
                if (failure != null) {
                    Log.w(TAG, "Unable to refresh purchase access", failure)
                    return@withLock Result.failure(failure)
                }

                lastRevenueCatRefreshUserID = snapshot.user.userId
                lastRevenueCatRefreshAtMs = SystemClock.elapsedRealtime()
                Result.success(Unit)
            }
        }

    suspend fun signOut() = withContext(NonCancellable + Dispatchers.IO) {
        val result = revenueCat.signOut {
            authStateMutex.withLock {
                authGeneration += 1
                reconciledRevenueCatGeneration = null
                clearTokens()
                _authState.value = AuthState(isLoading = false)
                true
            }
        }
        result.onFailure { error -> Log.w(TAG, "Unable to sign out of purchases", error) }
        lastRevenueCatRefreshUserID = null
        lastRevenueCatRefreshAtMs = 0L
    }

    suspend fun updateWordCount(wordsToAdd: Int): UserProfile? = withContext(Dispatchers.IO) {
        if (wordsToAdd <= 0) return@withContext _authState.value.user
        val snapshot = currentAuthSessionSnapshot() ?: return@withContext null
        val user = snapshot.user
        val updatedCount = user.monthlyWordCount + wordsToAdd
        val body = JSONObject()
            .put("monthly_word_count", updatedCount)
            .put("updated_at", Instant.now().toString())
            .toString()
            .toRequestBody(jsonMediaType)

        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/rest/v1/profiles?user_id=eq.${user.userId}&select=*")
            .addSupabaseHeaders(snapshot.accessToken)
            .addHeader("Prefer", "return=representation")
            .patch(body)
            .build()

        runCatching {
            okHttpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) error("Profile update failed: ${response.code}")
                val responseBody = response.body?.string().orEmpty()
                val serverProfile = parseProfileArray(responseBody, user.email).firstOrNull()
                    ?: user.copy(monthlyWordCount = updatedCount)
                authStateMutex.withLock {
                    val state = _authState.value
                    if (
                        authGeneration == snapshot.generation &&
                        state.user?.userId.equals(user.userId, ignoreCase = true)
                    ) {
                        val updated = overlayCachedRevenueCatEntitlement(serverProfile)
                        _authState.value = state.copy(user = updated)
                        updated
                    } else {
                        state.user
                    }
                }
            }
        }.getOrElse { error ->
            Log.w(TAG, "Failed to update word count", error)
            user
        }
    }

    suspend fun ensureReferralCode(): Result<UserProfile> = withContext(Dispatchers.IO) {
        val snapshot = currentAuthSessionSnapshot()
            ?: return@withContext Result.failure(Exception("Sign in to create an invite link."))

        callProfileRpc("ensure_referral_code", JSONObject(), snapshot)
    }

    suspend fun redeemReferralCode(code: String): Result<UserProfile> = withContext(Dispatchers.IO) {
        val snapshot = currentAuthSessionSnapshot()
            ?: return@withContext Result.failure(Exception("Sign in to apply an invite code."))
        val cleanedCode = code.trim()
        if (cleanedCode.isBlank()) {
            return@withContext Result.failure(Exception("Enter an invite code."))
        }

        callProfileRpc("redeem_referral_code", JSONObject().put("code", cleanedCode), snapshot)
    }

    private suspend fun callProfileRpc(
        functionName: String,
        payload: JSONObject,
        snapshot: AuthSessionSnapshot
    ): Result<UserProfile> = runCatching {
        val request = Request.Builder()
            .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/rest/v1/rpc/$functionName")
            .addSupabaseHeaders(snapshot.accessToken)
            .post(payload.toString().toRequestBody(jsonMediaType))
            .build()

        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Request failed: ${response.code}")
            val serverProfile = parseProfile(
                response.body?.string().orEmpty(),
                snapshot.user.email
            )
            authStateMutex.withLock {
                val state = _authState.value
                check(
                    authGeneration == snapshot.generation &&
                        state.user?.userId.equals(snapshot.user.userId, ignoreCase = true)
                ) {
                    "The signed-in account changed before the profile update completed."
                }
                val updated = overlayCachedRevenueCatEntitlement(serverProfile)
                _authState.value = state.copy(user = updated)
                updated
            }
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

    private fun reconcileSubscription(accessToken: String): Result<SubscriptionReconciliation> =
        runCatching {
            val request = Request.Builder()
                .url("${BuildConfig.SUPABASE_URL.trimEnd('/')}/functions/v1/check-subscription")
                .addSupabaseHeaders(accessToken)
                .post("{}".toRequestBody(jsonMediaType))
                .build()

            okHttpClient.newCall(request).execute().use { response ->
                val responseBody = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    error("Access reconciliation failed: ${response.code}")
                }
                val json = JSONObject(responseBody.ifBlank { "{}" })
                if (json.has("error")) error("Access reconciliation was not completed")
                val subscribed = json.opt("subscribed") as? Boolean
                    ?: error("Access reconciliation returned an invalid subscription state")
                val status = (json.opt("subscription_status") as? String)
                    ?.trim()
                    ?.lowercase()
                    ?.takeIf { it in setOf("free", "pro", "lifetime") }
                    ?: error("Access reconciliation returned an invalid access level")
                if (subscribed != (status != "free")) {
                    error("Access reconciliation returned inconsistent subscription data")
                }
                SubscriptionReconciliation(
                    subscribed = subscribed,
                    subscriptionStatus = status
                )
            }
        }

    private fun refreshSession(refreshToken: String): Result<RefreshedSession> = runCatching {
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
            RefreshedSession(
                accessToken = json.getString("access_token"),
                refreshToken = json.optString("refresh_token", refreshToken)
            )
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

    private fun storeTokens(
        accessToken: String,
        refreshToken: String?,
        clearMissingRefreshToken: Boolean = false
    ) {
        securePrefs.edit()
            .putString(SecureKeys.ACCESS_TOKEN, accessToken)
            .apply {
                if (!refreshToken.isNullOrBlank()) {
                    putString(SecureKeys.REFRESH_TOKEN, refreshToken)
                } else if (clearMissingRefreshToken) {
                    remove(SecureKeys.REFRESH_TOKEN)
                }
            }
            .apply()
    }

    private fun clearTokens() {
        securePrefs.edit()
            .remove(SecureKeys.ACCESS_TOKEN)
            .remove(SecureKeys.REFRESH_TOKEN)
            .remove(SecureKeys.PENDING_AUTH_STATE)
            .remove(SecureKeys.PENDING_AUTH_STATE_CREATED_AT)
            .apply()
    }

    private fun createPendingAuthState(): String {
        val bytes = ByteArray(AUTH_STATE_BYTES)
        SecureRandom().nextBytes(bytes)
        val state = Base64.encodeToString(
            bytes,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        )
        securePrefs.edit()
            .putString(SecureKeys.PENDING_AUTH_STATE, state)
            .putLong(SecureKeys.PENDING_AUTH_STATE_CREATED_AT, System.currentTimeMillis())
            .apply()
        return state
    }

    private suspend fun consumePendingAuthState(receivedState: String?): Boolean {
        if (receivedState.isNullOrBlank()) return false
        return authStateMutex.withLock {
            val expectedState = securePrefs.getString(SecureKeys.PENDING_AUTH_STATE, null)
                ?: return@withLock false
            val createdAt = securePrefs.getLong(SecureKeys.PENDING_AUTH_STATE_CREATED_AT, 0L)
            val now = System.currentTimeMillis()
            val isFresh = createdAt > 0L &&
                createdAt <= now + AUTH_STATE_CLOCK_SKEW_MS &&
                now - createdAt <= AUTH_STATE_TTL_MS
            val matches = MessageDigest.isEqual(
                expectedState.toByteArray(Charsets.UTF_8),
                receivedState.toByteArray(Charsets.UTF_8)
            )
            if (!isFresh || !matches) return@withLock false
            securePrefs.edit()
                .remove(SecureKeys.PENDING_AUTH_STATE)
                .remove(SecureKeys.PENDING_AUTH_STATE_CREATED_AT)
                .apply()
            true
        }
    }

    private fun isExpectedAuthCallback(uri: Uri): Boolean {
        return uri.scheme.equals("https", ignoreCase = true) &&
            uri.host.equals(AUTH_CALLBACK_HOST, ignoreCase = true) &&
            uri.path == AUTH_CALLBACK_PATH
    }

    private suspend fun beginAuthTransition(
        accessToken: String? = null,
        refreshToken: String? = null,
        replaceTokens: Boolean = false
    ): Long = revenueCat.serializeAuthTransition {
        authStateMutex.withLock {
            authGeneration += 1
            reconciledRevenueCatGeneration = null
            if (replaceTokens && !accessToken.isNullOrBlank()) {
                storeTokens(
                    accessToken,
                    refreshToken,
                    clearMissingRefreshToken = true
                )
            }
            _authState.value = AuthState(isLoading = true)
            authGeneration
        }
    }

    private suspend fun setAuthStateIfCurrent(generation: Long, state: AuthState): Boolean {
        return authStateMutex.withLock {
            if (authGeneration != generation) return@withLock false
            _authState.value = state
            true
        }
    }

    private suspend fun clearSessionIfCurrent(generation: Long) {
        val result = revenueCat.signOut {
            authStateMutex.withLock {
                if (authGeneration != generation) return@withLock false
                authGeneration += 1
                clearTokens()
                reconciledRevenueCatGeneration = null
                _authState.value = AuthState(isLoading = false)
                true
            }
        }
        result.onFailure { error -> Log.w(TAG, "Unable to clear the expired purchase session", error) }
        lastRevenueCatRefreshUserID = null
        lastRevenueCatRefreshAtMs = 0L
    }

    private suspend fun currentAuthSessionSnapshot(): AuthSessionSnapshot? {
        return authStateMutex.withLock {
            val user = _authState.value.user ?: return@withLock null
            val accessToken = securePrefs.getString(SecureKeys.ACCESS_TOKEN, null)
                ?.takeIf { it.isNotBlank() } ?: return@withLock null
            AuthSessionSnapshot(authGeneration, user, accessToken)
        }
    }

    private suspend fun clearReconciliationAuthority(snapshot: AuthSessionSnapshot) {
        authStateMutex.withLock {
            if (authGeneration != snapshot.generation) return@withLock
            if (!_authState.value.user?.userId.equals(snapshot.user.userId, ignoreCase = true)) {
                return@withLock
            }
            reconciledRevenueCatGeneration = null
        }
    }

    private fun isAuthGenerationCurrent(generation: Long): Boolean {
        return authGeneration == generation
    }

    private fun staleAuthOperation(): IllegalStateException {
        return IllegalStateException("The signed-in account changed while access was refreshing.")
    }

    private suspend fun publishAuthenticatedProfile(
        user: UserProfile,
        accessToken: String,
        generation: Long
    ) {
        if (!isAuthGenerationCurrent(generation)) return
        val backendResult = reconcileSubscription(accessToken)
        if (!isAuthGenerationCurrent(generation)) return
        val revenueCatResult = revenueCat.identify(
            userID = user.userId,
            email = user.email,
            authGeneration = generation,
            identityIsCurrent = { isAuthGenerationCurrent(generation) }
        )
        if (!isAuthGenerationCurrent(generation)) return

        backendResult.exceptionOrNull()?.let { error ->
            Log.w(TAG, "Unable to reconcile purchase access", error)
        }
        revenueCatResult.exceptionOrNull()?.let { error ->
            Log.w(TAG, "Unable to confirm purchase access", error)
        }
        applyReconciliationResult(
            snapshot = AuthSessionSnapshot(generation, user, accessToken),
            backendResult = backendResult,
            revenueCatResult = revenueCatResult
        )
    }

    private suspend fun applyReconciliationResult(
        snapshot: AuthSessionSnapshot,
        backendResult: Result<SubscriptionReconciliation>,
        revenueCatResult: Result<RevenueCatEntitlement>
    ) {
        authStateMutex.withLock {
            if (authGeneration != snapshot.generation) return@withLock
            val currentUser = _authState.value.user
                ?.takeIf { it.userId.equals(snapshot.user.userId, ignoreCase = true) }
                ?: snapshot.user
            val resolvedUser = resolveReconciledUser(currentUser, backendResult, revenueCatResult)
            val fullyReconciled = backendResult.isSuccess && revenueCatResult.isSuccess
            if (fullyReconciled) {
                reconciledRevenueCatGeneration = snapshot.generation
            } else {
                reconciledRevenueCatGeneration = null
            }
            _authState.value = AuthState(user = resolvedUser, isLoading = false)
        }
    }

    private fun resolveReconciledUser(
        user: UserProfile,
        backendResult: Result<SubscriptionReconciliation>,
        revenueCatResult: Result<RevenueCatEntitlement>
    ): UserProfile {
        val backend = backendResult.getOrNull()
        val entitlement = revenueCatResult.getOrNull()
        if (backend != null && entitlement != null) {
            return applyConfirmedEntitlement(
                user = user,
                entitlement = entitlement,
                authoritativeInactive = true
            )
        }
        if (backend?.subscribed == true) {
            return user.copy(subscriptionStatus = normalizedPaidStatus(backend.subscriptionStatus))
        }
        if (entitlement is RevenueCatEntitlement.Active) {
            return applyConfirmedEntitlement(
                user = user,
                entitlement = entitlement,
                authoritativeInactive = false
            )
        }
        return overlayCachedRevenueCatEntitlement(user, authoritativeInactive = false)
    }

    private suspend fun applyRevenueCatUpdate(update: ConfirmedRevenueCatEntitlement) {
        applyRevenueCatEntitlementNow(
            expectedUserID = update.appUserID,
            entitlement = update.entitlement,
            expectedGeneration = update.authGeneration
        )
    }

    private fun queueRevenueCatEntitlement(
        expectedUserID: String,
        entitlement: RevenueCatEntitlement,
        expectedGeneration: Long
    ) {
        scope.launch {
            applyRevenueCatEntitlementNow(expectedUserID, entitlement, expectedGeneration)
        }
    }

    private suspend fun applyRevenueCatEntitlementNow(
        expectedUserID: String,
        entitlement: RevenueCatEntitlement,
        expectedGeneration: Long
    ) {
        authStateMutex.withLock {
            if (authGeneration != expectedGeneration) return@withLock
            val state = _authState.value
            val user = state.user ?: return@withLock
            if (!user.userId.equals(expectedUserID, ignoreCase = true)) return@withLock
            val isAuthoritative = reconciledRevenueCatGeneration == expectedGeneration
            _authState.value = state.copy(
                user = applyConfirmedEntitlement(
                    user = user,
                    entitlement = entitlement,
                    authoritativeInactive = isAuthoritative
                ),
                error = null
            )
        }
    }

    private fun overlayCachedRevenueCatEntitlement(
        user: UserProfile,
        authoritativeInactive: Boolean? = null
    ): UserProfile {
        val entitlement = revenueCat.cachedEntitlement(user.userId) ?: return user
        val isAuthoritative = authoritativeInactive
            ?: (reconciledRevenueCatGeneration == authGeneration)
        return applyConfirmedEntitlement(
            user = user,
            entitlement = entitlement,
            authoritativeInactive = isAuthoritative
        )
    }

    private fun applyConfirmedEntitlement(
        user: UserProfile,
        entitlement: RevenueCatEntitlement,
        authoritativeInactive: Boolean
    ): UserProfile {
        return when (entitlement) {
            is RevenueCatEntitlement.Active -> user.copy(
                subscriptionStatus = entitlement.subscriptionStatus
            )
            RevenueCatEntitlement.Inactive -> {
                if (authoritativeInactive) user.copy(subscriptionStatus = "free") else user
            }
        }
    }

    private fun normalizedPaidStatus(status: String): String {
        return when (status.lowercase()) {
            "lifetime", "appsumo" -> "lifetime"
            else -> "pro"
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
        const val REVENUECAT_REFRESH_INTERVAL_MS = 5 * 60 * 1_000L
        const val AUTH_CALLBACK_HOST = "aidictation.com"
        const val AUTH_CALLBACK_PATH = "/auth/android-callback"
        const val AUTH_STATE_BYTES = 32
        const val AUTH_STATE_TTL_MS = 10 * 60 * 1_000L
        const val AUTH_STATE_CLOCK_SKEW_MS = 30 * 1_000L
    }
}
