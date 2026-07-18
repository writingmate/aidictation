package com.whispermate.aidictation.data.repository

import com.revenuecat.purchases.PackageType
import com.revenuecat.purchases.ProductType
import com.revenuecat.purchases.models.Period

internal const val REVENUECAT_MONTHLY_PACKAGE_IDENTIFIER = "\$rc_monthly"
internal const val REVENUECAT_MONTHLY_PERIOD_ISO8601 = "P1M"

internal fun <T> selectMonthlyPackage(
    availablePackages: List<T>,
    identifierOf: (T) -> String,
    packageTypeOf: (T) -> PackageType,
    productTypeOf: (T) -> ProductType,
    periodOf: (T) -> Period?
): T? {
    fun isExactMonthlyPackage(packageOption: T): Boolean {
        val period = periodOf(packageOption)
        return identifierOf(packageOption) == REVENUECAT_MONTHLY_PACKAGE_IDENTIFIER &&
            packageTypeOf(packageOption) == PackageType.MONTHLY &&
            productTypeOf(packageOption) == ProductType.SUBS &&
            period?.unit == Period.Unit.MONTH &&
            period.value == 1 &&
            period.iso8601 == REVENUECAT_MONTHLY_PERIOD_ISO8601
    }

    return availablePackages.singleOrNull(::isExactMonthlyPackage)
}

internal fun activeSubscriptionStatus(
    isActive: Boolean,
    hasExpirationDate: Boolean
): String? {
    if (!isActive) return null
    return if (hasExpirationDate) "pro" else "lifetime"
}
