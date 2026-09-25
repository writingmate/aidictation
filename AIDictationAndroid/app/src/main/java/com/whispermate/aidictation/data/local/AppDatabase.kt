package com.whispermate.aidictation.data.local

import androidx.room.Database
import androidx.room.RoomDatabase
import com.whispermate.aidictation.data.local.dao.RecordingDao
import com.whispermate.aidictation.data.local.dao.InstallationAnalyticsDao
import com.whispermate.aidictation.data.local.entity.RecordingEntity
import com.whispermate.aidictation.data.local.entity.UsageClaimEntity
import com.whispermate.aidictation.data.local.entity.InstallationAnalyticsEventEntity

@Database(
    entities = [RecordingEntity::class, UsageClaimEntity::class, InstallationAnalyticsEventEntity::class],
    version = 5,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun recordingDao(): RecordingDao
    abstract fun installationAnalyticsDao(): InstallationAnalyticsDao
}
