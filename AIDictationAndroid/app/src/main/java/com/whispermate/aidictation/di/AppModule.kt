package com.whispermate.aidictation.di

import android.content.Context
import androidx.room.Room
import com.squareup.moshi.Moshi
import com.whispermate.aidictation.data.local.AppDatabase
import com.whispermate.aidictation.data.local.AppDatabaseMigrations
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
        ).addMigrations(*AppDatabaseMigrations.ALL).build()

    @Provides
    @Singleton
    fun provideRecordingDao(database: AppDatabase): RecordingDao = database.recordingDao()
}
