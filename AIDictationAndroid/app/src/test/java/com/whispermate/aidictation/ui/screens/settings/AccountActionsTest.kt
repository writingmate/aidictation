package com.whispermate.aidictation.ui.screens.settings

import com.whispermate.aidictation.domain.model.UsageStatus
import com.whispermate.aidictation.ui.screens.settings.AccountAction.ManagePurchase
import com.whispermate.aidictation.ui.screens.settings.AccountAction.RestorePurchases
import com.whispermate.aidictation.ui.screens.settings.AccountAction.SignIn
import com.whispermate.aidictation.ui.screens.settings.AccountAction.SignOut
import com.whispermate.aidictation.ui.screens.settings.AccountAction.Upgrade
import org.junit.Assert.assertEquals
import org.junit.Test

class AccountActionsTest {
    private fun status(
        signedIn: Boolean,
        pro: Boolean,
        storePurchase: Boolean = false
    ) = UsageStatus(
        used = 0,
        limit = 5_000,
        isPro = pro,
        isAuthenticated = signedIn,
        hasStorePurchase = storePurchase
    )

    @Test
    fun signedOutTrialUserCanBuyRestoreAndSignInWhenSoldInApp() {
        assertEquals(
            listOf(Upgrade, RestorePurchases, SignIn),
            accountActions(status(signedIn = false, pro = false), sellsInApp = true, canSignIn = true)
        )
    }

    @Test
    fun signedOutTrialUserCanStillBuyWithoutGoogleSignIn() {
        assertEquals(
            listOf(Upgrade, RestorePurchases),
            accountActions(status(signedIn = false, pro = false), sellsInApp = true, canSignIn = false)
        )
    }

    @Test
    fun signedOutUserWithBrowserCheckoutSignsInFirst() {
        assertEquals(
            listOf(SignIn),
            accountActions(status(signedIn = false, pro = false), sellsInApp = false, canSignIn = true)
        )
    }

    @Test
    fun signedOutBuyerManagesThePurchaseAndCanSignIn() {
        assertEquals(
            listOf(ManagePurchase, SignIn),
            accountActions(
                status(signedIn = false, pro = true, storePurchase = true),
                sellsInApp = true,
                canSignIn = true
            )
        )
    }

    @Test
    fun signedInFreeUserUpgradesAndRestoresWhenSoldInApp() {
        assertEquals(
            listOf(Upgrade, RestorePurchases, SignOut),
            accountActions(status(signedIn = true, pro = false), sellsInApp = true, canSignIn = true)
        )
    }

    @Test
    fun signedInFreeUserWithBrowserCheckoutUpgradesOnly() {
        assertEquals(
            listOf(Upgrade, SignOut),
            accountActions(status(signedIn = true, pro = false), sellsInApp = false, canSignIn = true)
        )
    }

    @Test
    fun signedInStoreSubscriberManagesThePurchase() {
        assertEquals(
            listOf(ManagePurchase, SignOut),
            accountActions(
                status(signedIn = true, pro = true, storePurchase = true),
                sellsInApp = true,
                canSignIn = true
            )
        )
    }

    @Test
    fun signedInProFromTheAccountHasNothingToBuyOrManage() {
        assertEquals(
            listOf(SignOut),
            accountActions(status(signedIn = true, pro = true), sellsInApp = true, canSignIn = true)
        )
        assertEquals(
            listOf(SignOut),
            accountActions(status(signedIn = true, pro = true), sellsInApp = false, canSignIn = true)
        )
    }
}
