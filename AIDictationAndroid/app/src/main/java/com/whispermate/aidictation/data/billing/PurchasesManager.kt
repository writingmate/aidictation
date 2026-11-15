package com.whispermate.aidictation.data.billing

import android.app.Activity
import android.content.Context
import android.util.Log
import com.revenuecat.purchases.CustomerInfo
import com.revenuecat.purchases.Offerings
import com.revenuecat.purchases.PurchaseParams
import com.revenuecat.purchases.Purchases
import com.revenuecat.purchases.PurchasesConfiguration
import com.revenuecat.purchases.PurchasesTransactionException
import com.revenuecat.purchases.awaitLogIn
import com.revenuecat.purchases.awaitLogOut
import com.revenuecat.purchases.awaitOfferings
import com.revenuecat.purchases.awaitPurchase
import com.revenuecat.purchases.awaitRestore
import com.revenuecat.purchases.interfaces.UpdatedCustomerInfoListener
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.repository.AuthRepository
import com.whispermate.aidictation.domain.model.PaymentPlan
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

/** How an in-app purchase attempt ended. */
enum class PurchaseOutcome { Purchased, Cancelled, Failed }

/**
 * Manages in-app purchases through RevenueCat (Google Play Billing underneath): the Pro
 * entitlement, the plans on offer with their store prices, buying and restoring.
 *
 * It is inert when no RevenueCat key is built in; the app then keeps its browser checkout.
 */
@Singleton
class PurchasesManager @Inject constructor(
    @ApplicationContext private val context: Context,
    private val authRepository: AuthRepository
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _hasProEntitlement = MutableStateFlow(false)
    private val _planPrices = MutableStateFlow<Map<PaymentPlan, String>>(emptyMap())
    private var offerings: Offerings? = null

    /** Whether this build can sell in the app at all. */
    val isConfigured: Boolean = BuildConfig.REVENUECAT_API_KEY.isNotBlank()

    /** Whether the store account or signed-in user holds an active Pro entitlement. */
    val hasProEntitlement: StateFlow<Boolean> = _hasProEntitlement.asStateFlow()

    /** Store-formatted price per plan, for the plans the current offering contains. */
    val planPrices: StateFlow<Map<PaymentPlan, String>> = _planPrices.asStateFlow()

    init {
        if (isConfigured) start()
    }

    /**
     * Starts the Play purchase sheet for [plan] from [activity] and waits for it to end.
     */
    suspend fun purchase(activity: Activity, plan: PaymentPlan): PurchaseOutcome {
        if (!isConfigured) return PurchaseOutcome.Failed
        return try {
            val current = (offerings ?: Purchases.sharedInstance.awaitOfferings().also(::onOfferings)).current
            val storePackage = when (plan) {
                PaymentPlan.Monthly -> current?.monthly
                PaymentPlan.Annual -> current?.annual
            } ?: return PurchaseOutcome.Failed
            val result = Purchases.sharedInstance.awaitPurchase(
                PurchaseParams.Builder(activity, storePackage).build()
            )
            onCustomerInfo(result.customerInfo)
            // Pick up the plan the backend recorded for this account, if it has by now.
            scope.launch { authRepository.refreshUser() }
            PurchaseOutcome.Purchased
        } catch (e: PurchasesTransactionException) {
            if (e.userCancelled) {
                PurchaseOutcome.Cancelled
            } else {
                Log.w(TAG, "Purchase failed: ${e.message}")
                PurchaseOutcome.Failed
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
            _hasProEntitlement.value
        } catch (e: Exception) {
            Log.w(TAG, "Restore failed", e)
            false
        }
    }

    private fun start() {
        Purchases.configure(
            PurchasesConfiguration.Builder(context, BuildConfig.REVENUECAT_API_KEY).build()
        )
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
        _hasProEntitlement.value = info.entitlements[PRO_ENTITLEMENT]?.isActive == true
    }

    private fun onOfferings(loaded: Offerings) {
        offerings = loaded
        val current = loaded.current
        _planPrices.value = buildMap {
            current?.monthly?.let { put(PaymentPlan.Monthly, it.product.price.formatted) }
            current?.annual?.let { put(PaymentPlan.Annual, it.product.price.formatted) }
        }
    }

    private companion object {
        const val TAG = "PurchasesManager"

        /** The RevenueCat entitlement that unlocks unlimited dictation. */
        const val PRO_ENTITLEMENT = "pro"
    }
}
