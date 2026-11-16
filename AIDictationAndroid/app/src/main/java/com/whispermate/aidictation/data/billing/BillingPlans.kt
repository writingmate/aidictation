package com.whispermate.aidictation.data.billing

import com.whispermate.aidictation.domain.model.PaymentPlan

/** The RevenueCat entitlement that unlocks unlimited dictation. */
const val PRO_ENTITLEMENT = "pro"

/** RevenueCat Test Store keys start with this; the SDK refuses to run with one in a release build. */
private const val TEST_STORE_KEY_PREFIX = "test_"

/** The store product behind each plan, as named in the RevenueCat dashboard. */
val PaymentPlan.storeProductId: String
    get() = when (this) {
        PaymentPlan.Monthly -> "monthly"
        PaymentPlan.Annual -> "yearly"
    }

/**
 * The RevenueCat key this build may use, or blank to keep the browser checkout. A Test Store
 * key only works in a debuggable build: in any other build the SDK crashes on purpose.
 */
fun usableRevenueCatKey(key: String, debuggable: Boolean): String {
    val trimmed = key.trim()
    return if (!debuggable && trimmed.startsWith(TEST_STORE_KEY_PREFIX)) "" else trimmed
}

/**
 * Whether a store product id is the product for [plan]. Google Play subscription ids arrive
 * as `product:base-plan`, so only the part before the colon is compared.
 */
fun isProductForPlan(productId: String, plan: PaymentPlan): Boolean =
    productId.substringBefore(':').equals(plan.storeProductId, ignoreCase = true)

/**
 * Picks the package for [plan]: the offering's standard slot when it is filled, else the
 * first package whose product id matches the plan's dashboard product.
 */
fun <T> packageForPlan(
    plan: PaymentPlan,
    standardSlot: T?,
    packages: List<T>,
    productIdOf: (T) -> String
): T? = standardSlot ?: packages.firstOrNull { isProductForPlan(productIdOf(it), plan) }

/**
 * Whether Pro can actually be bought in the app right now: a usable key is not enough, the
 * current offering must also hold at least one plan the store can sell. Until it does (no
 * store products yet, or offerings could not be loaded) the app keeps the browser checkout,
 * exactly as if no key were set, so there is always a way to buy.
 */
fun canSellInApp(configured: Boolean, purchasablePlans: Set<PaymentPlan>): Boolean =
    configured && purchasablePlans.isNotEmpty()
