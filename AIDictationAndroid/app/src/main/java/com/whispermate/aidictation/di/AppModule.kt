package com.whispermate.aidictation.di

import android.content.Context
import androidx.room.Room
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.squareup.moshi.Moshi
import com.whispermate.aidictation.data.local.AppDatabase
import com.whispermate.aidictation.data.local.dao.RecordingDao
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    private val MIGRATION_1_2 = object : Migration(1, 2) {
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
            database.execSQL("UPDATE recordings SET rawTranscription = transcription, checkpointText = transcription, updatedAt = timestamp")
        }
    }

    private val MIGRATION_2_3 = object : Migration(2, 3) {
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

    @Provides
    @Singleton
    fun provideMoshi(): Moshi = Moshi.Builder().build()

    @Provides
    @Singleton
    fun provideAppDatabase(@ApplicationContext context: Context): AppDatabase =
        Room.databaseBuilder(
            context,
            AppDatabase::class.java,
            "aidictation_db"
        ).addMigrations(MIGRATION_1_2, MIGRATION_2_3).build()

    @Provides
    @Singleton
    fun provideRecordingDao(database: AppDatabase): RecordingDao = database.recordingDao()
}
