package com.whispermate.aidictation.telemetry

import android.app.Application
import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.whispermate.aidictation.data.local.AppDatabase
import com.whispermate.aidictation.data.local.entity.InstallationAnalyticsEventEntity
import com.whispermate.aidictation.domain.model.AuthState
import com.whispermate.aidictation.domain.model.UserProfile
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class InstallationAnalyticsTest {
    @Test
    fun restoredAccountOpensAppWithoutCountingAnotherSignIn() = runBlocking {
        val context: Context = ApplicationProvider.getApplicationContext()
        val userId = UUID.randomUUID().toString()
        val anonymousId = UUID.randomUUID().toString()
        context.getSharedPreferences("installation_analytics", Context.MODE_PRIVATE)
            .edit().clear().putString("last_user_id", userId)
            .putString("anonymous_id", anonymousId).commit()
        val database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries().build()
        val server = MockWebServer()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val session = FakeSession()
        session.current.value = AuthState(
            user = UserProfile(userId, "user@example.com", 0, "free"),
            isLoading = false
        )
        server.enqueue(MockResponse().setResponseCode(201))
        server.start()
        try {
            val analytics = InstallationAnalytics(
                context, database.installationAnalyticsDao(), session,
                server.url("/api/installation-event").toString(), OkHttpClient(), scope
            )
            analytics.start()
            assertEquals(0, database.installationAnalyticsDao().observePendingCount().first())
            assertNull(server.takeRequest(300, TimeUnit.MILLISECONDS))
            analytics.appOpened()
            val request = server.takeRequest(5, TimeUnit.SECONDS)
            assertNotNull(request)
            val event = JSONObject(request!!.body.readUtf8())
            assertEquals("app_opened", event.getString("event_name"))
            assertEquals(userId, event.getString("user_id"))
            assertEquals(anonymousId, event.getString("anonymous_id"))
            assertNull(server.takeRequest(500, TimeUnit.MILLISECONDS))
        } finally {
            scope.cancel()
            database.close()
            server.shutdown()
        }
    }

    @Test
    fun unresolvedAuthUsesAnIsolatedAnonymousIdAndStaleSignInIsIgnored() = runBlocking {
        val context: Context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("installation_analytics", Context.MODE_PRIVATE)
            .edit().clear().commit()
        val database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries().build()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val session = FakeSession()
        try {
            val analytics = InstallationAnalytics(
                context, database.installationAnalyticsDao(), session, null, OkHttpClient(), scope
            )
            val priorUserId = UUID.randomUUID().toString()
            session.current.value = AuthState(
                user = UserProfile(priorUserId, "user@example.com", 0, "free"),
                isLoading = false
            )
            val prior = analytics.identitySnapshot()!!
            session.current.value = AuthState(isLoading = true)
            val unresolved = analytics.identitySnapshot()!!
            assertEquals(prior.installationId, unresolved.installationId)
            assertNull(unresolved.userId)
            assertNotEquals(prior.anonymousId, unresolved.anonymousId)
            assertEquals(unresolved.anonymousId, analytics.identitySnapshot()!!.anonymousId)

            session.current.value = AuthState(isLoading = false)
            val signedOut = analytics.identitySnapshot()!!
            assertNotEquals(prior.anonymousId, signedOut.anonymousId)
            assertNotEquals(unresolved.anonymousId, signedOut.anonymousId)
            analytics.recordSignInIfCurrent(priorUserId, prior)
            assertEquals(0, database.installationAnalyticsDao().observePendingCount().first())

            val nextUserId = UUID.randomUUID().toString()
            session.current.value = AuthState(
                user = UserProfile(nextUserId, "next@example.com", 0, "free"),
                isLoading = false
            )
            val next = analytics.identitySnapshot()!!
            assertNotEquals(prior.anonymousId, next.anonymousId)
            assertNotEquals(unresolved.anonymousId, next.anonymousId)
            analytics.recordSignInIfCurrent(priorUserId, prior)
            assertEquals(0, database.installationAnalyticsDao().observePendingCount().first())
        } finally {
            scope.cancel()
            database.close()
        }
    }

    @Test
    fun forbiddenEventIsDroppedInsteadOfRetried() = runBlocking {
        val context: Context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("installation_analytics", Context.MODE_PRIVATE)
            .edit().clear().commit()
        val database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries().build()
        val server = MockWebServer()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val session = FakeSession()
        val eventId = UUID.randomUUID().toString()
        server.enqueue(MockResponse().setResponseCode(403))
        server.enqueue(MockResponse().setResponseCode(201))
        server.enqueue(MockResponse().setResponseCode(201))
        server.start()
        try {
            database.installationAnalyticsDao().insert(
                InstallationAnalyticsEventEntity(
                    eventId, UUID.randomUUID().toString(), UUID.randomUUID().toString(),
                    "app_opened", 0, null, System.currentTimeMillis()
                )
            )
            val analytics = InstallationAnalytics(
                context, database.installationAnalyticsDao(), session,
                server.url("/api/installation-event").toString(), OkHttpClient(), scope
            )
            analytics.start()
            val request = server.takeRequest(5, TimeUnit.SECONDS)
            assertNotNull(request)
            assertEquals(eventId, JSONObject(request!!.body.readUtf8()).getString("event_id"))
            withTimeout(5_000) {
                while (database.installationAnalyticsDao().getById(eventId) != null) delay(20)
            }
        } finally {
            scope.cancel()
            database.close()
            server.shutdown()
        }
    }

    @Test
    fun formerAccountEventsExpireAfterThirtyDays() = runBlocking {
        val context: Context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("installation_analytics", Context.MODE_PRIVATE)
            .edit().clear().commit()
        val database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries().build()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val oldEventId = UUID.randomUUID().toString()
        val recentEventId = UUID.randomUUID().toString()
        try {
            val dao = database.installationAnalyticsDao()
            val installationId = UUID.randomUUID().toString()
            val anonymousId = UUID.randomUUID().toString()
            val formerUserId = UUID.randomUUID().toString()
            dao.insert(InstallationAnalyticsEventEntity(
                oldEventId, installationId, anonymousId, "transcription_completed", 3,
                formerUserId, System.currentTimeMillis() - TimeUnit.DAYS.toMillis(31)
            ))
            dao.insert(InstallationAnalyticsEventEntity(
                recentEventId, installationId, anonymousId, "transcription_completed", 3,
                formerUserId, System.currentTimeMillis()
            ))
            val analytics = InstallationAnalytics(
                context, dao, FakeSession(), null, OkHttpClient(), scope
            )
            analytics.start()
            withTimeout(5_000) {
                while (dao.getById(oldEventId) != null) delay(20)
            }
            assertNotNull(dao.getById(recentEventId))
        } finally {
            scope.cancel()
            database.close()
        }
    }

    @Test
    fun anonymousLaunchAndVerifiedSignInKeepOneInstallationAndRotateOnSignOut() = runBlocking {
        val context: Context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("installation_analytics", Context.MODE_PRIVATE)
            .edit().clear().commit()
        val database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries().build()
        val server = MockWebServer()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val session = FakeSession()
        server.enqueue(MockResponse().setResponseCode(201).setBody("{\"accepted\":true}"))
        server.enqueue(MockResponse().setResponseCode(201).setBody("{\"accepted\":true}"))
        server.start()
        try {
            val analytics = InstallationAnalytics(
                context,
                database.installationAnalyticsDao(),
                session,
                server.url("/api/installation-event").toString(),
                OkHttpClient(),
                scope
            )
            analytics.start()
            analytics.appOpened()

            val anonymousRequest = server.takeRequest(5, TimeUnit.SECONDS)
            assertNotNull(anonymousRequest)
            val anonymous = JSONObject(anonymousRequest!!.body.readUtf8())
            assertEquals("app_opened", anonymous.getString("event_name"))
            assertEquals("android", anonymous.getString("platform"))
            assertFalse(anonymous.has("user_id"))
            assertNull(anonymousRequest.getHeader("Authorization"))
            val installationId = anonymous.getString("installation_id")
            val anonymousId = anonymous.getString("anonymous_id")
            UUID.fromString(installationId)
            UUID.fromString(anonymousId)

            val userId = UUID.randomUUID().toString()
            session.current.value = AuthState(
                user = UserProfile(userId, "user@example.com", 0, "free"),
                isLoading = false
            )
            val signedInRequest = server.takeRequest(5, TimeUnit.SECONDS)
            assertNotNull(signedInRequest)
            val signedIn = JSONObject(signedInRequest!!.body.readUtf8())
            assertEquals("signed_in", signedIn.getString("event_name"))
            assertEquals(userId, signedIn.getString("user_id"))
            assertEquals(installationId, signedIn.getString("installation_id"))
            assertEquals(anonymousId, signedIn.getString("anonymous_id"))
            assertEquals("Bearer test-token", signedInRequest.getHeader("Authorization"))

            session.current.value = AuthState(isLoading = false)
            val afterSignOut = analytics.identitySnapshot()
            assertNotNull(afterSignOut)
            assertEquals(installationId, afterSignOut?.installationId)
            assertNotEquals(anonymousId, afterSignOut?.anonymousId)
            assertNull(afterSignOut?.userId)
        } finally {
            scope.cancel()
            database.close()
            server.shutdown()
        }
    }

    private class FakeSession : InstallationAnalyticsSession {
        val current = MutableStateFlow(AuthState(isLoading = false))
        override val state = current
        override fun accessToken(expectedUserId: String): String? =
            if (current.value.user?.userId == expectedUserId) "test-token" else null
        override suspend fun refresh() = Unit
    }
}
