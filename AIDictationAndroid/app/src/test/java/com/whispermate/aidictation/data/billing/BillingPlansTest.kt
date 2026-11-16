package com.whispermate.aidictation.data.billing

import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.domain.model.PaymentPlan
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
    }

    @Test
    fun productIdsMatchWithOrWithoutAPlayBasePlan() {
        assertTrue(isProductForPlan("yearly", PaymentPlan.Annual))
        assertTrue(isProductForPlan("yearly:annual-base", PaymentPlan.Annual))
        assertTrue(isProductForPlan("Monthly", PaymentPlan.Monthly))
        assertFalse(isProductForPlan("monthly", PaymentPlan.Annual))
        assertFalse(isProductForPlan("yearly_promo", PaymentPlan.Annual))
    }

    @Test
    fun standardSlotWinsOverAProductIdMatch() {
        val packages = listOf("monthly", "yearly")
        assertEquals(
            "slot",
            packageForPlan(PaymentPlan.Annual, standardSlot = "slot", packages = packages) { it }
        )
    }

    @Test
    fun customPackagesAreFoundByProductId() {
        val packages = listOf("lifetime", "monthly:base", "yearly:base")
        assertEquals("monthly:base", packageForPlan(PaymentPlan.Monthly, null, packages) { it })
        assertEquals("yearly:base", packageForPlan(PaymentPlan.Annual, null, packages) { it })
    }

    @Test
    fun aPlanTheOfferingLacksHasNoPackage() {
        assertNull(packageForPlan(PaymentPlan.Annual, null, listOf("monthly", "lifetime")) { it })
    }

    @Test
    fun aKeyWithNothingToSellKeepsTheBrowserCheckout() {
        assertFalse(canSellInApp(configured = true, purchasablePlans = emptySet()))
    }

    @Test
    fun aKeyWithAPurchasablePlanSellsInApp() {
        assertTrue(canSellInApp(configured = true, purchasablePlans = setOf(PaymentPlan.Monthly)))
        assertTrue(canSellInApp(configured = true, purchasablePlans = PaymentPlan.entries.toSet()))
    }

    @Test
    fun noKeyNeverSellsInApp() {
        assertFalse(canSellInApp(configured = false, purchasablePlans = emptySet()))
        assertFalse(canSellInApp(configured = false, purchasablePlans = setOf(PaymentPlan.Annual)))
    }
}
