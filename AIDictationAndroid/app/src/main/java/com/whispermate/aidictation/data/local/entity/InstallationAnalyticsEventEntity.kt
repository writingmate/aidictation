package com.whispermate.aidictation.data.local.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "installation_analytics_events",
    indices = [Index(value = ["createdAt"]), Index(value = ["userId", "createdAt"])]
)
data class InstallationAnalyticsEventEntity(
    @PrimaryKey val eventId: String,
    val installationId: String,
    val anonymousId: String,
    val eventName: String,
    val wordCount: Int,
    val userId: String?,
    val createdAt: Long
)
