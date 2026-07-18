package com.whispermate.aidictation.data.repository

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RevenueCatIdentityTest {
    @Test
    fun `normalizes a Supabase user ID before identifying the purchaser`() {
        val result = normalizeSupabaseUserID(
            " 550E8400-E29B-41D4-A716-446655440000 "
        )

        assertEquals(
            "550e8400-e29b-41d4-a716-446655440000",
            result.getOrThrow()
        )
    }

    @Test
    fun `rejects a RevenueCat anonymous user ID`() {
        val result = normalizeSupabaseUserID("\$RCAnonymousID:87a53f66d9be4a8d")

        assertTrue(result.isFailure)
    }

    @Test
    fun `rejects an identifier without the Supabase UUID shape`() {
        val result = normalizeSupabaseUserID("550e8400e29b41d4a716446655440000")

        assertTrue(result.isFailure)
    }

    @Test
    fun `rejects an empty account identifier`() {
        val result = normalizeSupabaseUserID("   ")

        assertTrue(result.isFailure)
    }
}
