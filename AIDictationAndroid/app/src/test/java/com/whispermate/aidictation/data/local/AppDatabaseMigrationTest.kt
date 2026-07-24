package com.whispermate.aidictation.data.local

import android.app.Application
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.whispermate.aidictation.data.local.entity.UsageClaimEntity
import com.whispermate.aidictation.domain.model.UsageClaimDestination
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class AppDatabaseMigrationTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val databases = mutableSetOf<String>()

    @After
    fun tearDown() {
        databases.forEach(context::deleteDatabase)
    }

    @Test
    fun roomRunsSchemaOneThroughTwoAndThreeWithoutLosingRecordingOrCheckpoint() =
        runBlocking {
            val databaseName = "migration-1-through-4.db"
            createSchemaOne(databaseName)

            val database = openCurrentRoomDatabase(databaseName)
            try {
                val recording = database.recordingDao().getRecordingById("legacy-recording")
                assertNotNull(recording)
                assertEquals("legacy transcript tail", recording?.transcription)
                assertEquals("legacy transcript tail", recording?.rawTranscription)
                assertEquals("legacy transcript tail", recording?.checkpointText)
                assertEquals(987_654L, recording?.updatedAt)
                assertEquals("success", recording?.status)
                assertFalse(recording?.usageEligible ?: true)
                assertEquals(
                    UsageClaimDestination.UNATTRIBUTED,
                    recording?.usageDestination
                )

                val localClaim = UsageClaimEntity(
                    id = "new-local-claim",
                    recordingId = "legacy-recording",
                    generation = 0,
                    wordCount = 3,
                    createdAt = 999_000L,
                    usageDestination = UsageClaimDestination.LOCAL
                )
                assertTrue(database.recordingDao().insertUsageClaim(localClaim) != -1L)
                assertEquals(localClaim, database.recordingDao().getUsageClaimById(localClaim.id))

                assertDestinationSchema(database)
            } finally {
                database.close()
            }
        }

    @Test
    fun roomPreservesSchemaThreeClaimsButLegacyPendingClaimFailsClosed() = runBlocking {
        val databaseName = "migration-3-through-4.db"
        createSchemaThree(databaseName)

        val database = openCurrentRoomDatabase(databaseName)
        try {
            val dao = database.recordingDao()
            val recording = dao.getRecordingById("checkpointed")
            assertEquals("first chunk second chunk", recording?.checkpointText)
            assertEquals(2, recording?.completedLeafCount)
            assertEquals(7L, recording?.generation)
            assertEquals(
                UsageClaimDestination.UNATTRIBUTED,
                recording?.usageDestination
            )

            val pending = dao.getUsageClaimById("legacy-pending")
            assertNotNull(pending)
            assertEquals(UsageClaimEntity.UNATTRIBUTED, pending?.state)
            assertEquals(8, pending?.wordCount)
            assertEquals(
                UsageClaimDestination.UNATTRIBUTED,
                pending?.usageDestination
            )
            assertNull(
                dao.claimUsage(
                    id = "legacy-pending",
                    usageDestination = UsageClaimDestination.LOCAL,
                    claimedAt = 20_000L
                )
            )
            assertNull(
                dao.claimUsage(
                    id = "legacy-pending",
                    usageDestination = checkNotNull(
                        UsageClaimDestination.account("different-user")
                    ),
                    claimedAt = 20_001L
                )
            )

            val claimed = dao.getUsageClaimById("legacy-claimed")
            assertEquals(UsageClaimEntity.CLAIMED, claimed?.state)
            assertEquals(12_345L, claimed?.claimedAt)
            assertEquals(
                UsageClaimDestination.UNATTRIBUTED,
                claimed?.usageDestination
            )

            assertDestinationSchema(database)
        } finally {
            database.close()
        }
    }

    private fun createSchemaOne(databaseName: String) {
        rawDatabase(databaseName).use { database ->
            database.execSQL(
                """
                CREATE TABLE IF NOT EXISTS recordings (
                    id TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    transcription TEXT NOT NULL,
                    durationMs INTEGER,
                    audioFilePath TEXT,
                    PRIMARY KEY(id)
                )
                """.trimIndent()
            )
            database.execSQL(
                """
                INSERT INTO recordings(
                    id, timestamp, transcription, durationMs, audioFilePath
                ) VALUES (?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf(
                    "legacy-recording",
                    987_654L,
                    "legacy transcript tail",
                    4_321L,
                    "/managed/legacy.m4a"
                )
            )
            database.version = 1
        }
    }

    private fun createSchemaThree(databaseName: String) {
        rawDatabase(databaseName).use { database ->
            database.execSQL(
                """
                CREATE TABLE IF NOT EXISTS recordings (
                    id TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    transcription TEXT NOT NULL,
                    durationMs INTEGER,
                    audioFilePath TEXT,
                    status TEXT NOT NULL DEFAULT 'success',
                    rawTranscription TEXT NOT NULL DEFAULT '',
                    checkpointText TEXT NOT NULL DEFAULT '',
                    completedLeafCount INTEGER NOT NULL DEFAULT 0,
                    recognitionComplete INTEGER NOT NULL DEFAULT 0,
                    attemptId TEXT,
                    generation INTEGER NOT NULL DEFAULT 0,
                    errorMessage TEXT,
                    sourceIntegrity TEXT NOT NULL DEFAULT 'complete',
                    updatedAt INTEGER NOT NULL DEFAULT 0,
                    usageEligible INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(id)
                )
                """.trimIndent()
            )
            database.execSQL(
                """
                CREATE TABLE IF NOT EXISTS usage_claims (
                    id TEXT NOT NULL,
                    recordingId TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    wordCount INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    createdAt INTEGER NOT NULL,
                    claimedAt INTEGER,
                    PRIMARY KEY(id)
                )
                """.trimIndent()
            )
            database.execSQL(
                "CREATE INDEX IF NOT EXISTS index_usage_claims_state ON usage_claims(state)"
            )
            database.execSQL(
                """
                CREATE INDEX IF NOT EXISTS index_usage_claims_recordingId
                ON usage_claims(recordingId)
                """.trimIndent()
            )
            database.execSQL(
                """
                INSERT INTO recordings(
                    id, timestamp, transcription, durationMs, audioFilePath, status,
                    rawTranscription, checkpointText, completedLeafCount,
                    recognitionComplete, attemptId, generation, errorMessage,
                    sourceIntegrity, updatedAt, usageEligible
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf(
                    "checkpointed",
                    1_000L,
                    "",
                    2_000L,
                    "/managed/checkpointed.m4a",
                    "failed",
                    "first chunk second chunk",
                    "first chunk second chunk",
                    2,
                    0,
                    null,
                    7L,
                    "interrupted",
                    "complete",
                    2_000L,
                    1
                )
            )
            database.execSQL(
                """
                INSERT INTO usage_claims(
                    id, recordingId, generation, wordCount, state, createdAt, claimedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf(
                    "legacy-pending",
                    "checkpointed",
                    7L,
                    8,
                    UsageClaimEntity.PENDING,
                    3_000L,
                    null
                )
            )
            database.execSQL(
                """
                INSERT INTO usage_claims(
                    id, recordingId, generation, wordCount, state, createdAt, claimedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf(
                    "legacy-claimed",
                    "checkpointed",
                    6L,
                    5,
                    UsageClaimEntity.CLAIMED,
                    2_500L,
                    12_345L
                )
            )
            database.version = 3
        }
    }

    private fun openCurrentRoomDatabase(databaseName: String): AppDatabase =
        Room.databaseBuilder(context, AppDatabase::class.java, databaseName)
            .addMigrations(*AppDatabaseMigrations.ALL)
            .allowMainThreadQueries()
            .build()
            .also { it.openHelper.writableDatabase }

    private fun rawDatabase(databaseName: String): SQLiteDatabase {
        databases += databaseName
        context.deleteDatabase(databaseName)
        return SQLiteDatabase.openOrCreateDatabase(
            context.getDatabasePath(databaseName),
            null
        )
    }

    private fun assertDestinationSchema(database: AppDatabase) {
        val sqlite = database.openHelper.readableDatabase
        val recordingColumn = sqlite.query("PRAGMA table_info(recordings)").use { cursor ->
            generateSequence { cursor.takeIf { it.moveToNext() } }
                .map {
                    ColumnDefinition(
                        name = it.getString(it.getColumnIndexOrThrow("name")),
                        type = it.getString(it.getColumnIndexOrThrow("type")),
                        notNull = it.getInt(it.getColumnIndexOrThrow("notnull")),
                        defaultValue = it.getString(it.getColumnIndexOrThrow("dflt_value"))
                    )
                }
                .first { it.name == "usageDestination" }
        }
        assertEquals("TEXT", recordingColumn.type)
        assertEquals(1, recordingColumn.notNull)
        assertEquals("'unattributed'", recordingColumn.defaultValue)

        val claimColumn = sqlite.query("PRAGMA table_info(usage_claims)").use { cursor ->
            generateSequence { cursor.takeIf { it.moveToNext() } }
                .map {
                    ColumnDefinition(
                        name = it.getString(it.getColumnIndexOrThrow("name")),
                        type = it.getString(it.getColumnIndexOrThrow("type")),
                        notNull = it.getInt(it.getColumnIndexOrThrow("notnull")),
                        defaultValue = it.getString(it.getColumnIndexOrThrow("dflt_value"))
                    )
                }
                .first { it.name == "usageDestination" }
        }
        assertEquals("TEXT", claimColumn.type)
        assertEquals(1, claimColumn.notNull)
        assertEquals("'unattributed'", claimColumn.defaultValue)

        val compositeIndexColumns = sqlite.query(
            "PRAGMA index_info(index_usage_claims_state_usageDestination)"
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(cursor.getString(cursor.getColumnIndexOrThrow("name")))
                }
            }
        }
        assertEquals(listOf("state", "usageDestination"), compositeIndexColumns)
    }

    private data class ColumnDefinition(
        val name: String,
        val type: String,
        val notNull: Int,
        val defaultValue: String?
    )
}
