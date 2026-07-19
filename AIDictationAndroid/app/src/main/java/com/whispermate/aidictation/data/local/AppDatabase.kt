package com.whispermate.aidictation.data.local

import androidx.room.Database
import androidx.room.RoomDatabase
import com.whispermate.aidictation.data.local.dao.RecordingDao
import com.whispermate.aidictation.data.local.entity.RecordingEntity

@Database(
    entities = [RecordingEntity::class],
    version = 2,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun recordingDao(): RecordingDao
}
