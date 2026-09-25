package com.whispermate.aidictation.telemetry

import android.content.Context
import android.util.Log
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.local.dao.InstallationAnalyticsDao
import com.whispermate.aidictation.data.local.entity.InstallationAnalyticsEventEntity
import com.whispermate.aidictation.data.repository.AuthRepository
import com.whispermate.aidictation.domain.model.AuthState
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

data class InstallationAnalyticsIdentity(
    val installationId: String,
    val anonymousId: String,
    val userId: String?
)

internal interface InstallationAnalyticsSession {
    val state: StateFlow<AuthState>
    fun accessToken(expectedUserId: String): String?
    suspend fun refresh()
}

private class RepositoryInstallationAnalyticsSession(
    private val repository: AuthRepository
) : InstallationAnalyticsSession {
    override val state: StateFlow<AuthState> = repository.authState
    override fun accessToken(expectedUserId: String): String? =
        repository.analyticsAccessToken(expectedUserId)
    override suspend fun refresh() = repository.refreshUser()
}

@Singleton
class InstallationAnalytics internal constructor(
    @ApplicationContext context: Context,
    private val events: InstallationAnalyticsDao,
    private val session: InstallationAnalyticsSession,
    private val endpoint: String?,
    private val client: OkHttpClient,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
) {
    @Inject
    constructor(
        @ApplicationContext context: Context,
        events: InstallationAnalyticsDao,
        authRepository: AuthRepository
    ) : this(
        context,
        events,
        RepositoryInstallationAnalyticsSession(authRepository),
        BuildConfig.SUPABASE_URL.trimEnd('/')
            .takeIf { it.startsWith("https://") }
            ?.plus("/api/installation-event"),
        OkHttpClient.Builder().callTimeout(8, TimeUnit.SECONDS).build()
    )

    private val preferences = context.getSharedPreferences("installation_analytics", Context.MODE_PRIVATE)
    private val identityLock = Any()
    private val flushMutex = Mutex()
    private var started = false
    private var lastOpenAt = 0L
    private var observedUserId: String? = null
    private var authResolved = false
    @Volatile private var pendingOpen = false
    private var retryScheduled = false

    fun start() {
        synchronized(identityLock) {
            if (started) return
            started = true
        }
        scope.launch {
            session.state.collect { state ->
                if (state.isLoading) return@collect
                val userId = validId(state.user?.userId)
                if (!authResolved || userId != observedUserId) {
                    val signInUserId = userId?.takeIf {
                        authResolved || storedId("last_user_id") != it
                    }
                    authResolved = true
                    observedUserId = userId
                    val identity = identitySnapshot()
                    if (pendingOpen) appOpened()
                    if (signInUserId != null && identity != null) {
                        recordSignInIfCurrent(signInUserId, identity)
                    }
                }
                flush()
            }
        }
        scope.launch {
            events.observePendingCount().collect { pending ->
                if (pending > 0) flush()
            }
        }
    }

    fun appOpened() {
        if (session.state.value.isLoading) {
            synchronized(identityLock) { pendingOpen = true }
            return
        }
        val now = System.currentTimeMillis()
        synchronized(identityLock) {
            if (now - lastOpenAt < 3_000L) return
            lastOpenAt = now
            pendingOpen = false
        }
        scope.launch {
            identitySnapshot()?.let { identity ->
                enqueue("app_opened", UUID.randomUUID().toString(), 0, identity)
            }
        }
    }

    suspend fun identitySnapshot(): InstallationAnalyticsIdentity? = withContext(Dispatchers.IO) {
        synchronized(identityLock) {
            val currentState = session.state.value
            val userId = if (currentState.isLoading) null else validId(currentState.user?.userId)
            val previousUserId = preferences.getString("last_user_id", null)
            val installationId = storedId("installation_id") ?: UUID.randomUUID().toString()
            var anonymousId = storedId("anonymous_id") ?: UUID.randomUUID().toString()
            val editor = preferences.edit().putString("installation_id", installationId)
            if (currentState.isLoading) {
                anonymousId = storedId("unresolved_anonymous_id") ?: UUID.randomUUID().toString()
                editor.putString("unresolved_anonymous_id", anonymousId)
            } else {
                editor.remove("unresolved_anonymous_id")
            }
            if (!currentState.isLoading && previousUserId != userId) {
                if (previousUserId != null) anonymousId = UUID.randomUUID().toString()
                if (userId == null) editor.remove("last_user_id")
                else editor.putString("last_user_id", userId)
            }
            if (!currentState.isLoading) editor.putString("anonymous_id", anonymousId)
            if (!editor.commit()) {
                Log.w("InstallationAnalytics", "Could not persist installation identity")
                return@synchronized null
            }
            InstallationAnalyticsIdentity(installationId, anonymousId, userId)
        }
    }

    private fun storedId(key: String): String? = validId(preferences.getString(key, null))

    private fun validId(value: String?): String? =
        value?.let { runCatching { UUID.fromString(it).toString() }.getOrNull() }

    internal suspend fun recordSignInIfCurrent(
        userId: String,
        identity: InstallationAnalyticsIdentity
    ) {
        val state = session.state.value
        if (!state.isLoading && identity.userId == userId &&
            validId(state.user?.userId) == userId
        ) {
            enqueue("signed_in", UUID.randomUUID().toString(), 0, identity)
        }
    }

    private suspend fun enqueue(
        name: String,
        eventId: String,
        words: Int,
        identity: InstallationAnalyticsIdentity
    ) {
        events.insert(
            InstallationAnalyticsEventEntity(
                eventId = eventId,
                installationId = identity.installationId,
                anonymousId = identity.anonymousId,
                eventName = name,
                wordCount = words,
                userId = identity.userId,
                createdAt = System.currentTimeMillis()
            )
        )
        flush()
    }

    private suspend fun flush() = flushMutex.withLock {
        events.deleteOlderThan(System.currentTimeMillis() - EVENT_RETENTION_MILLIS)
        val endpoint = endpoint ?: return@withLock
        while (true) {
            val state = session.state.value
            val currentUserId = if (state.isLoading) null else validId(state.user?.userId)
            val event = events.nextDeliverable(currentUserId) ?: break
            val token = if (event.userId == null) null
                else session.accessToken(event.userId)
            if (event.userId != null && token == null) {
                scheduleRetry()
                break
            }
            val body = JSONObject()
                .put("event_id", event.eventId)
                .put("installation_id", event.installationId)
                .put("anonymous_id", event.anonymousId)
                .put("platform", "android")
                .put("event_name", event.eventName)
                .put("word_count", event.wordCount)
                .apply { event.userId?.let { put("user_id", it) } }
                .toString()
            val request = Request.Builder()
                .url(endpoint)
                .post(body.toRequestBody("application/json".toMediaType()))
                .apply { token?.let { addHeader("Authorization", "Bearer $it") } }
                .build()
            val code = try {
                client.newCall(request).execute().use { it.code }
            } catch (error: Exception) {
                scheduleRetry()
                break
            }
            when {
                code in 200..299 -> events.delete(event.eventId)
                code in 400..499 && code !in listOf(401, 429) -> {
                    Log.w("InstallationAnalytics", "Dropping invalid event after HTTP $code")
                    events.delete(event.eventId)
                }
                else -> {
                    if (code == 401) scope.launch { session.refresh() }
                    scheduleRetry()
                    break
                }
            }
        }
    }

    private fun scheduleRetry() {
        synchronized(identityLock) {
            if (retryScheduled) return
            retryScheduled = true
        }
        scope.launch {
            delay(60_000)
            synchronized(identityLock) { retryScheduled = false }
            flush()
        }
    }

    private companion object {
        const val EVENT_RETENTION_MILLIS = 30L * 24 * 60 * 60 * 1_000
    }
}
