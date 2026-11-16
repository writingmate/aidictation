package com.whispermate.aidictation.data.billing

import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.domain.model.PaymentPlan
import com.whispermate.aidictation.domain.model.SubscriptionTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BillingPlansTest {
    @Test
    fun testStoreKeyIsDroppedOutsideDebuggableBuilds() {
        assertEquals("", usableRevenueCatKey("test_abc123", debuggable = false))
        assertEquals("", usableRevenueCatKey("  test_abc123 ", debuggable = false))
        assertEquals("test_abc123", usableRevenueCatKey("test_abc123", debuggable = true))
    }

    @Test
    fun storeKeyIsKeptInEveryBuild() {
        assertEquals("goog_abc123", usableRevenueCatKey("goog_abc123", debuggable = false))
        assertEquals("goog_abc123", usableRevenueCatKey(" goog_abc123\n", debuggable = true))
        assertEquals("", usableRevenueCatKey("", debuggable = true))
    }

    /** Holds for the variant under test: `testReleaseUnitTest` checks the release BuildConfig. */
    @Test
    fun thisBuildHasNoTestStoreKeyUnlessDebuggable() {
        if (!BuildConfig.DEBUG) {
            assertFalse(BuildConfig.REVENUECAT_API_KEY.startsWith("test_"))
        }
    }

    @Test
    fun plansMapToTheDashboardProducts() {
        assertEquals("monthly", PaymentPlan.Monthly.storeProductId)
        assertEquals("yearly", PaymentPlan.Annual.storeProductId)
        assertEquals("lifetime", PaymentPlan.Lifetime.storeProductId)
    }

    @Test
    fun productIdsMatchWithOrWithoutAPlayBasePlan() {
        assertTrue(isProductForPlan("yearly", PaymentPlan.Annual))
        assertTrue(isProductForPlan("yearly:annual-base", PaymentPlan.Annual))
        assertTrue(isProductForPlan("Lifetime", PaymentPlan.Lifetime))
        assertFalse(isProductForPlan("monthly", PaymentPlan.Annual))
        assertFalse(isProductForPlan("yearly_promo", PaymentPlan.Annual))
    }

    @Test
    fun standardSlotWinsOverAProductIdMatch() {
        val packages = listOf("monthly", "yearly", "lifetime")
        assertEquals(
            "slot",
            packageForPlan(PaymentPlan.Lifetime, standardSlot = "slot", packages = packages) { it }
        )
    }

    @Test
    fun customPackagesAreFoundByProductId() {
        val packages = listOf("monthly:base", "yearly:base", "lifetime")
        assertEquals("monthly:base", packageForPlan(PaymentPlan.Monthly, null, packages) { it })
        assertEquals("yearly:base", packageForPlan(PaymentPlan.Annual, null, packages) { it })
        assertEquals("lifetime", packageForPlan(PaymentPlan.Lifetime, null, packages) { it })
    }

    @Test
    fun aPlanTheOfferingLacksHasNoPackage() {
        assertNull(packageForPlan(PaymentPlan.Lifetime, null, listOf("monthly", "yearly")) { it })
    }

    @Test
    fun aSubscriptionEntitlementIsPro() {
        assertEquals(SubscriptionTier.Pro, storeTier(isActive = true, productId = "monthly", hasExpiry = true))
        assertEquals(SubscriptionTier.Pro, storeTier(isActive = true, productId = "yearly:base", hasExpiry = true))
    }

    @Test
    fun aOneTimePurchaseIsLifetime() {
        assertEquals(SubscriptionTier.Lifetime, storeTier(isActive = true, productId = "lifetime", hasExpiry = false))
        // An entitlement with no end date is a one-time purchase whatever the product is called.
        assertEquals(SubscriptionTier.Lifetime, storeTier(isActive = true, productId = "founder", hasExpiry = false))
        assertEquals(SubscriptionTier.Lifetime, storeTier(isActive = true, productId = "lifetime", hasExpiry = true))
    }

    @Test
    fun anInactiveEntitlementIsFree() {
        assertEquals(SubscriptionTier.Free, storeTier(isActive = false, productId = "lifetime", hasExpiry = false))
        assertEquals(SubscriptionTier.Free, storeTier(isActive = false, productId = null, hasExpiry = false))
    }
}
