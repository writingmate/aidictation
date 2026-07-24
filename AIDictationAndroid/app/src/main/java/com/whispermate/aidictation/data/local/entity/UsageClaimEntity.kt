package com.whispermate.aidictation.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.whispermate.aidictation.domain.model.UsageClaimDestination

@Entity(
    tableName = "usage_claims",
    indices = [
        Index(value = ["state"]),
        Index(value = ["recordingId"]),
        Index(value = ["state", "usageDestination"])
    ]
)
data class UsageClaimEntity(
    @PrimaryKey val id: String,
    val recordingId: String,
    val generation: Long,
    val wordCount: Int,
    val state: String = PENDING,
    val createdAt: Long,
    val claimedAt: Long? = null,
    @ColumnInfo(defaultValue = "'unattributed'")
    val usageDestination: String = UsageClaimDestination.UNATTRIBUTED
) {
    companion object {
        const val PENDING = "pending"
        const val CLAIMED = "claimed"
        const val UNATTRIBUTED = "unattributed"
    }
}
