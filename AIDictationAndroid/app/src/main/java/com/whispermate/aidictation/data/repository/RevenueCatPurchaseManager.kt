package com.whispermate.aidictation.data.repository

import android.app.Activity
import android.content.Context
import com.revenuecat.purchases.CacheFetchPolicy
import com.revenuecat.purchases.CustomerInfo
import com.revenuecat.purchases.LogLevel
import com.revenuecat.purchases.Offerings
import com.revenuecat.purchases.Package
import com.revenuecat.purchases.PurchaseParams
import com.revenuecat.purchases.Purchases
import com.revenuecat.purchases.PurchasesConfiguration
import com.revenuecat.purchases.PurchasesTransactionException
import com.revenuecat.purchases.awaitCustomerInfo
import com.revenuecat.purchases.awaitOfferings
import com.revenuecat.purchases.awaitLogIn
import com.revenuecat.purchases.awaitLogOut
import com.revenuecat.purchases.awaitPurchase
import com.revenuecat.purchases.awaitRestore
import com.revenuecat.purchases.getOfferingsWith
import com.revenuecat.purchases.interfaces.UpdatedCustomerInfoListener
import com.whispermate.aidictation.BuildConfig
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

sealed interface RevenueCatEntitlement {
    data class Active(val subscriptionStatus: String) : RevenueCatEntitlement
    data object Inactive : RevenueCatEntitlement
}

data class ConfirmedRevenueCatEntitlement(
    val appUserID: String,
    val authGeneration: Long,
    val entitlement: RevenueCatEntitlement
)

@Singleton
class RevenueCatPurchaseManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val identityMutex = Mutex()
    private var listenerInstalled = false

    private val _entitlementUpdates = MutableSharedFlow<ConfirmedRevenueCatEntitlement>(
        replay = 1,
        extraBufferCapacity = 1,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val entitlementUpdates: SharedFlow<ConfirmedRevenueCatEntitlement> =
        _entitlementUpdates.asSharedFlow()

    @Volatile
    private var lastConfirmedEntitlement: ConfirmedRevenueCatEntitlement? = null

    @Volatile
    private var activeAuthGeneration: Long? = null

    val isConfigured: Boolean
        get() = BuildConfig.REVENUECAT_GOOGLE_API_KEY.trim().let { key ->
            key.startsWith("goog_") &&
                key.length > "goog_".length &&
                BuildConfig.REVENUECAT_ENTITLEMENT_ID.isNotBlank()
        }

    @Synchronized
    fun configure() {
        if (!isConfigured) return
        if (!Purchases.isConfigured) {
            if (BuildConfig.DEBUG) Purchases.logLevel = LogLevel.DEBUG
            Purchases.configure(
                PurchasesConfiguration.Builder(
                    context,
                    BuildConfig.REVENUECAT_GOOGLE_API_KEY.trim()
                ).build()
            )
        }
        if (!listenerInstalled) {
            Purchases.sharedInstance.updatedCustomerInfoListener =
                UpdatedCustomerInfoListener(::recordCurrentCustomerInfo)
            listenerInstalled = true
        }
    }

    suspend fun identify(
        userID: String,
        email: String,
        authGeneration: Long,
        identityIsCurrent: () -> Boolean = { true }
    ): Result<RevenueCatEntitlement> {
        configure()
        if (!isConfigured || !Purchases.isConfigured) {
            return Result.failure(IllegalStateException("Checkout isn't available right now. Please try again later."))
        }
        val normalizedUserID = normalizeSupabaseUserID(userID).getOrElse {
            return Result.failure(it)
        }

        return resultOf {
            identityMutex.withLock {
                requireIdentityCurrent(identityIsCurrent)
                val purchases = Purchases.sharedInstance
                val customerInfo = withTimeout(IDENTITY_TIMEOUT_MS) {
                    if (purchases.appUserID != normalizedUserID) {
                        purchases.awaitLogIn(normalizedUserID).customerInfo
                    } else {
                        purchases.invalidateCustomerInfoCache()
                        purchases.awaitCustomerInfo(CacheFetchPolicy.FETCH_CURRENT)
                    }
                }
                requireCurrentUser(purchases, normalizedUserID)
                activeAuthGeneration = authGeneration
                purchases.setEmail(email)
                recordConfirmedEntitlement(normalizedUserID, authGeneration, customerInfo)
            }
        }
    }

    fun purchaseMonthly(
        activity: Activity,
        expectedUserID: String,
        onError: (String) -> Unit,
        onCancelled: () -> Unit,
        onEntitlement: (RevenueCatEntitlement) -> Unit,
        authGeneration: Long,
        identityIsCurrent: () -> Boolean = { true }
    ) {
        configure()
        if (!isConfigured) {
            onError("Checkout isn't available right now. Please try again later.")
            return
        }
        val normalizedUserID = normalizeSupabaseUserID(expectedUserID).getOrElse {
            onError("Your account could not be verified for this purchase.")
            return
        }

        scope.launch {
            try {
                val entitlement = identityMutex.withLock {
                    requireIdentityCurrent(identityIsCurrent)
                    val purchases = Purchases.sharedInstance
                    ensurePurchaseIdentityLocked(purchases, normalizedUserID, authGeneration)
                    val offerings = purchases.awaitOfferings()
                    requireCurrentUser(purchases, normalizedUserID)
                    val packageToPurchase = monthlyPackage(offerings)
                        ?: throw IllegalStateException("The monthly plan is not available right now.")
                    val result = purchases.awaitPurchase(
                        PurchaseParams.Builder(activity, packageToPurchase).build()
                    )
                    requireCurrentUser(purchases, normalizedUserID)
                    recordConfirmedEntitlement(
                        normalizedUserID,
                        authGeneration,
                        result.customerInfo
                    )
                }
                onEntitlement(entitlement)
            } catch (error: PurchasesTransactionException) {
                if (error.userCancelled) onCancelled() else onError(error.message.orEmpty())
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                onError(error.message ?: "Your purchase could not be completed.")
            }
        }
    }

    fun loadMonthlyPrice(
        onError: (String) -> Unit,
        onSuccess: (String) -> Unit
    ) {
        configure()
        if (!isConfigured) {
            onError("Checkout isn't available right now. Please try again later.")
            return
        }

        Purchases.sharedInstance.getOfferingsWith(
            onError = { onError(it.message) },
            onSuccess = { offerings ->
                val monthlyPackage = monthlyPackage(offerings)
                if (monthlyPackage == null) {
                    onError("The monthly plan is not available right now.")
                    return@getOfferingsWith
                }
                onSuccess(monthlyPackage.product.price.formatted)
            }
        )
    }

    suspend fun signOut(onIdentityLocked: suspend () -> Boolean = { true }): Result<Unit> {
        return withContext(NonCancellable) {
            try {
                identityMutex.withLock {
                    val shouldSignOut = onIdentityLocked()
                    if (shouldSignOut) {
                        activeAuthGeneration = null
                        lastConfirmedEntitlement = null
                        if (isConfigured && Purchases.isConfigured) {
                            Purchases.sharedInstance.awaitLogOut()
                        }
                    }
                    Unit
                }
                Result.success(Unit)
            } catch (error: Throwable) {
                Result.failure(error)
            }
        }
    }

    fun restore(
        expectedUserID: String,
        onError: (String) -> Unit,
        onEntitlement: (RevenueCatEntitlement) -> Unit,
        authGeneration: Long,
        identityIsCurrent: () -> Boolean = { true }
    ) {
        configure()
        if (!isConfigured) {
            onError("Checkout isn't available right now. Please try again later.")
            return
        }
        val normalizedUserID = normalizeSupabaseUserID(expectedUserID).getOrElse {
            onError("Your account could not be verified before restoring purchases.")
            return
        }
        scope.launch {
            try {
                val entitlement = identityMutex.withLock {
                    requireIdentityCurrent(identityIsCurrent)
                    val purchases = Purchases.sharedInstance
                    ensurePurchaseIdentityLocked(purchases, normalizedUserID, authGeneration)
                    val customerInfo = purchases.awaitRestore()
                    requireCurrentUser(purchases, normalizedUserID)
                    recordConfirmedEntitlement(normalizedUserID, authGeneration, customerInfo)
                }
                onEntitlement(entitlement)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                onError(error.message ?: "Your purchases could not be restored.")
            }
        }
    }

    suspend fun refresh(
        userID: String,
        authGeneration: Long,
        identityIsCurrent: () -> Boolean = { true }
    ): Result<RevenueCatEntitlement> {
        configure()
        if (!isConfigured || !Purchases.isConfigured) {
            return Result.failure(IllegalStateException("Checkout isn't available right now. Please try again later."))
        }
        val normalizedUserID = normalizeSupabaseUserID(userID).getOrElse {
            return Result.failure(it)
        }

        return resultOf {
            identityMutex.withLock {
                requireIdentityCurrent(identityIsCurrent)
                val purchases = Purchases.sharedInstance
                val customerInfo = withTimeout(IDENTITY_TIMEOUT_MS) {
                    if (purchases.appUserID != normalizedUserID) {
                        purchases.awaitLogIn(normalizedUserID).customerInfo
                    } else {
                        purchases.invalidateCustomerInfoCache()
                        purchases.awaitCustomerInfo(CacheFetchPolicy.FETCH_CURRENT)
                    }
                }
                requireCurrentUser(purchases, normalizedUserID)
                activeAuthGeneration = authGeneration
                recordConfirmedEntitlement(normalizedUserID, authGeneration, customerInfo)
            }
        }
    }

    fun cachedEntitlement(userID: String): RevenueCatEntitlement? {
        val normalizedUserID = normalizeSupabaseUserID(userID).getOrNull() ?: return null
        val confirmed = lastConfirmedEntitlement?.takeIf { it.appUserID == normalizedUserID }
            ?: return null
        return confirmed.entitlement
    }

    suspend fun <T> serializeAuthTransition(block: suspend () -> T): T {
        return identityMutex.withLock {
            activeAuthGeneration = null
            block()
        }
    }

    private suspend fun ensurePurchaseIdentityLocked(
        purchases: Purchases,
        userID: String,
        authGeneration: Long
    ) {
        if (purchases.appUserID != userID) {
            val customerInfo = withTimeout(IDENTITY_TIMEOUT_MS) {
                purchases.awaitLogIn(userID).customerInfo
            }
            requireCurrentUser(purchases, userID)
            activeAuthGeneration = authGeneration
            recordConfirmedEntitlement(userID, authGeneration, customerInfo)
        } else {
            requireCurrentUser(purchases, userID)
            activeAuthGeneration = authGeneration
        }
    }

    private fun recordCurrentCustomerInfo(customerInfo: CustomerInfo) {
        if (!Purchases.isConfigured) return
        val callbackUserID = normalizeSupabaseUserID(Purchases.sharedInstance.appUserID).getOrNull()
            ?: return
        val callbackGeneration = activeAuthGeneration ?: return
        scope.launch {
            try {
                identityMutex.withLock {
                    val purchases = Purchases.sharedInstance
                    if (activeAuthGeneration != callbackGeneration) return@withLock
                    requireCurrentUser(purchases, callbackUserID)
                    val currentCustomerInfo = withTimeout(IDENTITY_TIMEOUT_MS) {
                        purchases.awaitCustomerInfo(CacheFetchPolicy.CACHED_OR_FETCHED)
                    }
                    if (activeAuthGeneration != callbackGeneration) return@withLock
                    requireCurrentUser(purchases, callbackUserID)
                    if (currentCustomerInfo == customerInfo) {
                        recordConfirmedEntitlement(
                            callbackUserID,
                            callbackGeneration,
                            currentCustomerInfo
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // A foreground refresh will retry without replacing confirmed access.
            }
        }
    }

    private fun recordConfirmedEntitlement(
        userID: String,
        authGeneration: Long,
        customerInfo: CustomerInfo
    ): RevenueCatEntitlement {
        val entitlement = entitlementState(customerInfo)
        val confirmed = ConfirmedRevenueCatEntitlement(userID, authGeneration, entitlement)
        lastConfirmedEntitlement = confirmed
        _entitlementUpdates.tryEmit(confirmed)
        return entitlement
    }

    private fun entitlementState(customerInfo: CustomerInfo): RevenueCatEntitlement {
        val entitlement = customerInfo.entitlements[BuildConfig.REVENUECAT_ENTITLEMENT_ID]
            ?: return RevenueCatEntitlement.Inactive
        val status = activeSubscriptionStatus(
            isActive = entitlement.isActive,
            hasExpirationDate = entitlement.expirationDate != null
        ) ?: return RevenueCatEntitlement.Inactive
        return RevenueCatEntitlement.Active(status)
    }

    private fun monthlyPackage(offerings: Offerings): Package? {
        val current = offerings.current ?: return null
        return selectMonthlyPackage(
            configuredMonthlyPackage = current.monthly,
            availablePackages = current.availablePackages
        ) { packageOption ->
            packageOption.product.period
        }
    }

    private fun requireCurrentUser(purchases: Purchases, expectedUserID: String) {
        check(purchases.appUserID == expectedUserID) {
            "RevenueCat is not identified as the current Supabase user."
        }
    }

    private fun requireIdentityCurrent(identityIsCurrent: () -> Boolean) {
        check(identityIsCurrent()) {
            "The signed-in account changed before the purchase operation started."
        }
    }

    private suspend fun <T> resultOf(block: suspend () -> T): Result<T> {
        return try {
            Result.success(block())
        } catch (error: TimeoutCancellationException) {
            Result.failure(IllegalStateException("RevenueCat did not respond in time.", error))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            Result.failure(error)
        }
    }

    private companion object {
        const val IDENTITY_TIMEOUT_MS = 10_000L
    }
}
