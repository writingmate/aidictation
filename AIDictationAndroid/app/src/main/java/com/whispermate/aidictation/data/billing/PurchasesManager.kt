package com.whispermate.aidictation.data.billing

import android.app.Activity
import android.content.Context
import android.util.Log
import com.revenuecat.purchases.CustomerInfo
import com.revenuecat.purchases.Offering
import com.revenuecat.purchases.Offerings
import com.revenuecat.purchases.Package
import com.revenuecat.purchases.PurchaseParams
import com.revenuecat.purchases.Purchases
import com.revenuecat.purchases.PurchasesConfiguration
import com.revenuecat.purchases.PurchasesErrorCode
import com.revenuecat.purchases.PurchasesTransactionException
import com.revenuecat.purchases.awaitCustomerInfo
import com.revenuecat.purchases.awaitLogIn
import com.revenuecat.purchases.awaitLogOut
import com.revenuecat.purchases.awaitOfferings
import com.revenuecat.purchases.awaitPurchase
import com.revenuecat.purchases.awaitRestore
import com.revenuecat.purchases.interfaces.UpdatedCustomerInfoListener
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.repository.AuthRepository
import com.whispermate.aidictation.domain.model.PaymentPlan
import com.whispermate.aidictation.domain.model.SubscriptionTier
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * How an in-app purchase attempt ended. Unconfirmed means the connection dropped before
 * the result was known: the store may have taken the payment, and the entitlement then
 * arrives on its own once the device is back online.
 */
enum class PurchaseOutcome { Purchased, Cancelled, Unconfirmed, Failed }

/**
 * Manages in-app purchases through RevenueCat: the Pro entitlement, the plans on offer
 * with their store prices, buying and restoring.
 *
 * It is inert when no usable RevenueCat key is built in; the app then keeps its browser
 * checkout.
 */
@Singleton
class PurchasesManager @Inject constructor(
    @ApplicationContext private val context: Context,
    private val authRepository: AuthRepository
) {
    // MARK: - Published Properties

    private val _storeTier = MutableStateFlow(SubscriptionTier.Free)
    private val _planPrices = MutableStateFlow<Map<PaymentPlan, String>>(emptyMap())

    /** Whether this build can sell in the app at all. */
    val isConfigured: Boolean = apiKey.isNotBlank()

    /** Pro while the store account or signed-in user holds the `pro` entitlement, else Free. */
    val storeTier: StateFlow<SubscriptionTier> = _storeTier.asStateFlow()

    /** Store-formatted price per plan, for the plans the current offering contains. */
    val planPrices: StateFlow<Map<PaymentPlan, String>> = _planPrices.asStateFlow()

    // MARK: - Private Properties

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var offerings: Offerings? = null

    // MARK: - Initialization

    init {
        if (isConfigured) start()
    }

    // MARK: - Public API

    /**
     * Starts the store purchase sheet for [plan] from [activity] and waits for it to end.
     */
    suspend fun purchase(activity: Activity, plan: PaymentPlan): PurchaseOutcome {
        if (!isConfigured) return PurchaseOutcome.Failed
        return try {
            val current = (offerings ?: Purchases.sharedInstance.awaitOfferings().also(::onOfferings)).current
            val storePackage = current?.packageFor(plan) ?: return PurchaseOutcome.Failed
            val result = Purchases.sharedInstance.awaitPurchase(
                PurchaseParams.Builder(activity, storePackage).build()
            )
            onCustomerInfo(result.customerInfo)
            // Pick up the plan the backend recorded for this account, if it has by now.
            scope.launch { authRepository.refreshUser() }
            PurchaseOutcome.Purchased
        } catch (e: PurchasesTransactionException) {
            Log.w(TAG, "Purchase did not complete: ${e.message}")
            when {
                e.userCancelled -> PurchaseOutcome.Cancelled
                e.code == PurchasesErrorCode.NetworkError -> PurchaseOutcome.Unconfirmed
                else -> PurchaseOutcome.Failed
            }
        } catch (e: Exception) {
            Log.w(TAG, "Purchase failed", e)
            PurchaseOutcome.Failed
        }
    }

    /** Re-reads the store account's purchases. Returns whether Pro is active afterwards. */
    suspend fun restore(): Boolean {
        if (!isConfigured) return false
        return try {
            onCustomerInfo(Purchases.sharedInstance.awaitRestore())
            _storeTier.value.isPaid
        } catch (e: Exception) {
            Log.w(TAG, "Restore failed", e)
            false
        }
    }

    /**
     * Re-reads the entitlement after a RevenueCat screen (paywall, Customer Center) closes,
     * where a purchase, a cancellation or a refund may have happened.
     */
    fun refresh() {
        if (!isConfigured) return
        scope.launch {
            runCatching { onCustomerInfo(Purchases.sharedInstance.awaitCustomerInfo()) }
                .onFailure { Log.w(TAG, "Could not refresh the entitlement", it) }
            authRepository.refreshUser()
        }
    }

    // MARK: - Private Methods

    private fun start() {
        Purchases.configure(PurchasesConfiguration.Builder(context, apiKey).build())
        Purchases.sharedInstance.updatedCustomerInfoListener =
            UpdatedCustomerInfoListener { info -> onCustomerInfo(info) }

        scope.launch {
            runCatching { onOfferings(Purchases.sharedInstance.awaitOfferings()) }
                .onFailure { Log.w(TAG, "Could not load offerings", it) }
        }
        // The purchase follows the account: the signed-in user id is the RevenueCat user id,
        // so the backend can match a purchase to a profile and other devices can see it.
        scope.launch {
            authRepository.authState
                .filter { !it.isLoading }
                .map { it.user?.userId }
                .distinctUntilChanged()
                .collect { userId -> syncIdentity(userId) }
        }
    }

    private suspend fun syncIdentity(userId: String?) {
        runCatching {
            val purchases = Purchases.sharedInstance
            when {
                userId != null -> onCustomerInfo(purchases.awaitLogIn(userId).customerInfo)
                !purchases.isAnonymous -> onCustomerInfo(purchases.awaitLogOut())
            }
        }.onFailure { Log.w(TAG, "Could not sync the purchase identity", it) }
    }

    private fun onCustomerInfo(info: CustomerInfo) {
        val active = info.entitlements[PRO_ENTITLEMENT]?.isActive == true
        _storeTier.value = if (active) SubscriptionTier.Pro else SubscriptionTier.Free
    }

    private fun onOfferings(loaded: Offerings) {
        offerings = loaded
        val current = loaded.current
        _planPrices.value = buildMap {
            PaymentPlan.entries.forEach { plan ->
                current?.packageFor(plan)?.let { put(plan, it.product.price.formatted) }
            }
        }
    }

    private fun Offering.packageFor(plan: PaymentPlan): Package? = packageForPlan(
        plan = plan,
        standardSlot = when (plan) {
            PaymentPlan.Monthly -> monthly
            PaymentPlan.Annual -> annual
        },
        packages = availablePackages,
        productIdOf = { it.product.id }
    )

    private companion object {
        const val TAG = "PurchasesManager"

        val apiKey: String = usableRevenueCatKey(BuildConfig.REVENUECAT_API_KEY, BuildConfig.DEBUG)
    }
}
