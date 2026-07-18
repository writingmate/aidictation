package com.whispermate.aidictation.data.repository

import com.revenuecat.purchases.models.Period

internal fun <T> selectMonthlyPackage(
    configuredMonthlyPackage: T?,
    availablePackages: List<T>,
    periodOf: (T) -> Period?
): T? {
    fun isExactMonthlyPackage(packageOption: T): Boolean {
        val period = periodOf(packageOption)
        return period?.unit == Period.Unit.MONTH && period.value == 1
    }

    return configuredMonthlyPackage?.takeIf(::isExactMonthlyPackage)
        ?: availablePackages.firstOrNull(::isExactMonthlyPackage)
}

internal fun activeSubscriptionStatus(
    isActive: Boolean,
    hasExpirationDate: Boolean
): String? {
    if (!isActive) return null
    return if (hasExpirationDate) "pro" else "lifetime"
}
