package com.whispermate.aidictation.data.local.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "usage_claims",
    indices = [
        Index(value = ["state"]),
        Index(value = ["recordingId"])
    ]
)
data class UsageClaimEntity(
    @PrimaryKey val id: String,
    val recordingId: String,
    val generation: Long,
    val wordCount: Int,
    val state: String = PENDING,
    val createdAt: Long,
    val claimedAt: Long? = null
) {
    companion object {
        const val PENDING = "pending"
        const val CLAIMED = "claimed"
    }
}
