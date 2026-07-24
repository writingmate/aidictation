package com.whispermate.aidictation.data.local

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

object AppDatabaseMigrations {
    val MIGRATION_1_2 = object : Migration(1, 2) {
        override fun migrate(database: SupportSQLiteDatabase) {
            database.execSQL("ALTER TABLE recordings ADD COLUMN status TEXT NOT NULL DEFAULT 'success'")
            database.execSQL("ALTER TABLE recordings ADD COLUMN rawTranscription TEXT NOT NULL DEFAULT ''")
            database.execSQL("ALTER TABLE recordings ADD COLUMN checkpointText TEXT NOT NULL DEFAULT ''")
            database.execSQL("ALTER TABLE recordings ADD COLUMN completedLeafCount INTEGER NOT NULL DEFAULT 0")
            database.execSQL("ALTER TABLE recordings ADD COLUMN recognitionComplete INTEGER NOT NULL DEFAULT 0")
            database.execSQL("ALTER TABLE recordings ADD COLUMN attemptId TEXT")
            database.execSQL("ALTER TABLE recordings ADD COLUMN generation INTEGER NOT NULL DEFAULT 0")
            database.execSQL("ALTER TABLE recordings ADD COLUMN errorMessage TEXT")
            database.execSQL("ALTER TABLE recordings ADD COLUMN sourceIntegrity TEXT NOT NULL DEFAULT 'complete'")
            database.execSQL("ALTER TABLE recordings ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0")
            database.execSQL(
                """
                UPDATE recordings
                SET rawTranscription = transcription,
                    checkpointText = transcription,
                    updatedAt = timestamp
                """.trimIndent()
            )
        }
    }

    val MIGRATION_2_3 = object : Migration(2, 3) {
        override fun migrate(database: SupportSQLiteDatabase) {
            database.execSQL(
                "ALTER TABLE recordings ADD COLUMN usageEligible INTEGER NOT NULL DEFAULT 0"
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
                "CREATE INDEX IF NOT EXISTS index_usage_claims_recordingId ON usage_claims(recordingId)"
            )
        }
    }

    val MIGRATION_3_4 = object : Migration(3, 4) {
        override fun migrate(database: SupportSQLiteDatabase) {
            database.execSQL(
                """
                ALTER TABLE recordings
                ADD COLUMN usageDestination TEXT NOT NULL DEFAULT 'unattributed'
                """.trimIndent()
            )
            database.execSQL(
                """
                ALTER TABLE usage_claims
                ADD COLUMN usageDestination TEXT NOT NULL DEFAULT 'unattributed'
                """.trimIndent()
            )
            // Version 3 did not persist an account or local destination. Keep every claim for
            // auditability, but fence pending legacy rows from ever charging a later account.
            database.execSQL(
                """
                UPDATE usage_claims
                SET state = 'unattributed'
                WHERE state = 'pending'
                """.trimIndent()
            )
            database.execSQL(
                """
                CREATE INDEX IF NOT EXISTS index_usage_claims_state_usageDestination
                ON usage_claims(state, usageDestination)
                """.trimIndent()
            )
        }
    }

    val ALL: Array<Migration> = arrayOf(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4)
}
