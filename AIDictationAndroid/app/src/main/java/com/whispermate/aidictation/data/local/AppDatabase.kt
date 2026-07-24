package com.whispermate.aidictation.data.local

import androidx.room.Database
import androidx.room.RoomDatabase
import com.whispermate.aidictation.data.local.dao.RecordingDao
import com.whispermate.aidictation.data.local.entity.RecordingEntity
import com.whispermate.aidictation.data.local.entity.UsageClaimEntity

@Database(
    entities = [RecordingEntity::class, UsageClaimEntity::class],
    version = 4,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun recordingDao(): RecordingDao
}
