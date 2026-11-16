package com.whispermate.aidictation.data.repository

import com.whispermate.aidictation.domain.model.SubscriptionTier
import com.whispermate.aidictation.domain.model.WordLimitReachedException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SubscriptionPlanRulesTest {
    @Test
    fun storePurchaseUnlocksAnAccountWithNoPlan() {
        assertEquals(SubscriptionTier.Pro, effectiveTier(SubscriptionTier.Free, SubscriptionTier.Pro))
        assertEquals(SubscriptionTier.Lifetime, effectiveTier(SubscriptionTier.Free, SubscriptionTier.Lifetime))
        assertEquals(SubscriptionTier.Free, effectiveTier(SubscriptionTier.Free, SubscriptionTier.Free))
    }

    @Test
    fun accountPlanStandsWithoutAStorePurchase() {
        assertEquals(SubscriptionTier.Pro, effectiveTier(SubscriptionTier.Pro, SubscriptionTier.Free))
        assertEquals(SubscriptionTier.Lifetime, effectiveTier(SubscriptionTier.Lifetime, SubscriptionTier.Free))
    }

    @Test
    fun lifetimeOutranksASubscriptionFromEitherSide() {
        assertEquals(SubscriptionTier.Lifetime, effectiveTier(SubscriptionTier.Pro, SubscriptionTier.Lifetime))
        assertEquals(SubscriptionTier.Lifetime, effectiveTier(SubscriptionTier.Lifetime, SubscriptionTier.Pro))
    }

    @Test
    fun paywallAnswersOnlyAWordLimitBlockWhenSoldInApp() {
        val limit = WordLimitReachedException("limit")
        assertTrue(shouldOfferPaywall(limit, sellsInApp = true))
        assertFalse(shouldOfferPaywall(limit, sellsInApp = false))
        assertFalse(shouldOfferPaywall(IllegalStateException("Access check timed out."), sellsInApp = true))
    }
}
