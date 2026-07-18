package com.whispermate.aidictation.data.repository

import com.revenuecat.purchases.models.Period
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class RevenueCatPurchasePolicyTest {
    @Test
    fun `uses the configured monthly package before inspecting fallback packages`() {
        val configured = TestPackage("configured", period(1, Period.Unit.MONTH, "P1M"))
        val fallback = TestPackage("fallback", period(1, Period.Unit.MONTH, "P1M"))

        val selected = selectMonthlyPackage(
            configuredMonthlyPackage = configured,
            availablePackages = listOf(fallback),
            periodOf = TestPackage::period
        )

        assertSame(configured, selected)
    }

    @Test
    fun `falls back safely when the configured monthly package is yearly`() {
        val misconfigured = TestPackage("misconfigured", period(1, Period.Unit.YEAR, "P1Y"))
        val fallback = TestPackage("fallback", period(1, Period.Unit.MONTH, "P1M"))

        val selected = selectMonthlyPackage(
            configuredMonthlyPackage = misconfigured,
            availablePackages = listOf(misconfigured, fallback),
            periodOf = TestPackage::period
        )

        assertSame(fallback, selected)
    }

    @Test
    fun `rejects a misconfigured monthly package when no exact fallback exists`() {
        val misconfigured = TestPackage("misconfigured", period(1, Period.Unit.YEAR, "P1Y"))

        val selected = selectMonthlyPackage(
            configuredMonthlyPackage = misconfigured,
            availablePackages = listOf(
                misconfigured,
                TestPackage("two-months", period(2, Period.Unit.MONTH, "P2M"))
            ),
            periodOf = TestPackage::period
        )

        assertNull(selected)
    }

    @Test
    fun `falls back to the first package with an exact one month period`() {
        val exactMonthly = TestPackage("one-month", period(1, Period.Unit.MONTH, "P1M"))
        val anotherMonthly = TestPackage("another-month", period(1, Period.Unit.MONTH, "P1M"))
        val available = listOf(
            TestPackage("no-period", null),
            TestPackage("thirty-days", period(30, Period.Unit.DAY, "P30D")),
            TestPackage("four-weeks", period(4, Period.Unit.WEEK, "P4W")),
            TestPackage("two-months", period(2, Period.Unit.MONTH, "P2M")),
            exactMonthly,
            anotherMonthly
        )

        val selected = selectMonthlyPackage(
            configuredMonthlyPackage = null,
            availablePackages = available,
            periodOf = TestPackage::period
        )

        assertSame(exactMonthly, selected)
    }

    @Test
    fun `does not select an approximate or multi-month package`() {
        val available = listOf(
            TestPackage("thirty-days", period(30, Period.Unit.DAY, "P30D")),
            TestPackage("four-weeks", period(4, Period.Unit.WEEK, "P4W")),
            TestPackage("two-months", period(2, Period.Unit.MONTH, "P2M"))
        )

        val selected = selectMonthlyPackage(
            configuredMonthlyPackage = null,
            availablePackages = available,
            periodOf = TestPackage::period
        )

        assertNull(selected)
    }

    @Test
    fun `maps an active expiring entitlement to pro`() {
        assertEquals(
            "pro",
            activeSubscriptionStatus(isActive = true, hasExpirationDate = true)
        )
    }

    @Test
    fun `maps an active non-expiring entitlement to lifetime`() {
        assertEquals(
            "lifetime",
            activeSubscriptionStatus(isActive = true, hasExpirationDate = false)
        )
    }

    @Test
    fun `does not grant access for an inactive entitlement`() {
        assertNull(
            activeSubscriptionStatus(isActive = false, hasExpirationDate = false)
        )
        assertNull(
            activeSubscriptionStatus(isActive = false, hasExpirationDate = true)
        )
    }

    private fun period(value: Int, unit: Period.Unit, iso8601: String): Period {
        return Period(value, unit, iso8601)
    }

    private data class TestPackage(
        val name: String,
        val period: Period?
    )
}
