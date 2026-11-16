package com.whispermate.aidictation.ui.screens.settings

import com.whispermate.aidictation.domain.model.UsageStatus

/** A row of the Settings Account card, in the order the card shows them. */
internal enum class AccountAction { Upgrade, RestorePurchases, ManagePurchase, SignIn, SignOut }

/**
 * The Account rows for [usageStatus].
 *
 * With Pro sold in the app ([sellsInApp]) a purchase needs no account, so a signed-out user
 * can upgrade and restore; with the browser checkout, upgrading needs an account first.
 */
internal fun accountActions(
    usageStatus: UsageStatus,
    sellsInApp: Boolean,
    canSignIn: Boolean
): List<AccountAction> = buildList {
    if (!usageStatus.isPro) {
        if (usageStatus.isAuthenticated || sellsInApp) add(AccountAction.Upgrade)
        if (sellsInApp) add(AccountAction.RestorePurchases)
    }
    if (sellsInApp && usageStatus.hasStorePurchase) add(AccountAction.ManagePurchase)
    if (usageStatus.isAuthenticated) {
        add(AccountAction.SignOut)
    } else if (canSignIn) {
        add(AccountAction.SignIn)
    }
}
