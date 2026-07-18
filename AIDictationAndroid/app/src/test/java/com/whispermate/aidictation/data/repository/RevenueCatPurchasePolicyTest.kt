package com.whispermate.aidictation.data.repository

import com.revenuecat.purchases.PackageType
import com.revenuecat.purchases.ProductType
import com.revenuecat.purchases.models.Period
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class RevenueCatPurchasePolicyTest {
    @Test
    fun `selects the sole package matching the exact monthly contract`() {
        val exactMonthly = monthlyPackage("exact-monthly")

        val selected = selectPackage(listOf(exactMonthly))

        assertSame(exactMonthly, selected)
    }

    @Test
    fun `rejects a yearly package mapped as monthly`() {
        val misconfigured = monthlyPackage(
            name = "misconfigured",
            period = period(1, Period.Unit.YEAR, "P1Y")
        )

        val selected = selectPackage(listOf(misconfigured))

        assertNull(selected)
    }

    @Test
    fun `selects the exact monthly package after rejecting malformed packages`() {
        val exactMonthly = monthlyPackage("one-month")
        val available = listOf(
            monthlyPackage("no-period", period = null),
            monthlyPackage("thirty-days", period(30, Period.Unit.DAY, "P30D")),
            monthlyPackage("four-weeks", period(4, Period.Unit.WEEK, "P4W")),
            monthlyPackage("two-months", period(2, Period.Unit.MONTH, "P2M")),
            monthlyPackage("wrong-identifier", identifier = "custom_monthly"),
            monthlyPackage("wrong-package-type", packageType = PackageType.CUSTOM),
            monthlyPackage("wrong-product-type", productType = ProductType.INAPP),
            exactMonthly
        )

        val selected = selectPackage(available)

        assertSame(exactMonthly, selected)
    }

    @Test
    fun `does not select an approximate or multi-month package`() {
        val available = listOf(
            monthlyPackage("thirty-days", period(30, Period.Unit.DAY, "P30D")),
            monthlyPackage("four-weeks", period(4, Period.Unit.WEEK, "P4W")),
            monthlyPackage("two-months", period(2, Period.Unit.MONTH, "P2M"))
        )

        val selected = selectPackage(available)

        assertNull(selected)
    }

    @Test
    fun `rejects a one month package with the wrong RevenueCat identifier`() {
        val selected = selectPackage(
            listOf(
                monthlyPackage(
                    name = "wrong-identifier",
                    identifier = "custom_monthly"
                )
            )
        )

        assertNull(selected)
    }

    @Test
    fun `rejects a one month package with the wrong RevenueCat package type`() {
        val selected = selectPackage(
            listOf(
                monthlyPackage(
                    name = "wrong-package-type",
                    packageType = PackageType.CUSTOM
                )
            )
        )

        assertNull(selected)
    }

    @Test
    fun `rejects a one month in-app product`() {
        val selected = selectPackage(
            listOf(
                monthlyPackage(
                    name = "in-app",
                    productType = ProductType.INAPP
                )
            )
        )

        assertNull(selected)
    }

    @Test
    fun `rejects a one month period without the exact P1M representation`() {
        val selected = selectPackage(
            listOf(
                monthlyPackage(
                    name = "noncanonical-period",
                    period = period(1, Period.Unit.MONTH, "P30D")
                )
            )
        )

        assertNull(selected)
    }

    @Test
    fun `rejects an ambiguous offering with more than one exact monthly package`() {
        val selected = selectPackage(
            listOf(monthlyPackage("first"), monthlyPackage("second"))
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

    private fun monthlyPackage(
        name: String,
        period: Period? = period(1, Period.Unit.MONTH, "P1M"),
        identifier: String = REVENUECAT_MONTHLY_PACKAGE_IDENTIFIER,
        packageType: PackageType = PackageType.MONTHLY,
        productType: ProductType = ProductType.SUBS
    ) = TestPackage(name, identifier, packageType, productType, period)

    private fun selectPackage(availablePackages: List<TestPackage>) = selectMonthlyPackage(
        availablePackages = availablePackages,
        identifierOf = TestPackage::identifier,
        packageTypeOf = TestPackage::packageType,
        productTypeOf = TestPackage::productType,
        periodOf = TestPackage::period
    )

    private data class TestPackage(
        val name: String,
        val identifier: String,
        val packageType: PackageType,
        val productType: ProductType,
        val period: Period?
    )
}
