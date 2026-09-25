package com.whispermate.aidictation.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.whispermate.aidictation.data.local.entity.InstallationAnalyticsEventEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface InstallationAnalyticsDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(event: InstallationAnalyticsEventEntity): Long

    @Query("SELECT COUNT(*) FROM installation_analytics_events")
    fun observePendingCount(): Flow<Int>

    @Query(
        """
        SELECT * FROM installation_analytics_events
        WHERE userId IS NULL OR userId = :currentUserId
        ORDER BY createdAt, eventId
        LIMIT 1
        """
    )
    suspend fun nextDeliverable(currentUserId: String?): InstallationAnalyticsEventEntity?

    @Query("DELETE FROM installation_analytics_events WHERE eventId = :eventId")
    suspend fun delete(eventId: String): Int

    @Query("SELECT * FROM installation_analytics_events WHERE eventId = :eventId")
    suspend fun getById(eventId: String): InstallationAnalyticsEventEntity?
}
