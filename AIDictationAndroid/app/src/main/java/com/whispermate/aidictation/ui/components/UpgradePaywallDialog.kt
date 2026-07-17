package com.whispermate.aidictation.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.whispermate.aidictation.R
import com.whispermate.aidictation.ui.screens.main.PaywallMessage
import com.whispermate.aidictation.ui.screens.main.PaywallOperation

@Composable
fun UpgradePaywallDialog(
    isAuthenticated: Boolean,
    monthlyPrice: String?,
    operation: PaywallOperation,
    message: PaywallMessage,
    onDismiss: () -> Unit,
    onContinue: () -> Unit,
    onRetryPlan: () -> Unit,
    onRestorePurchases: () -> Unit
) {
    val title = stringResource(R.string.paywall_title)
    val isBusy = operation == PaywallOperation.LoadingPlan ||
        operation == PaywallOperation.Purchasing ||
        operation == PaywallOperation.Restoring
    val canDismiss = operation != PaywallOperation.Purchasing &&
        operation != PaywallOperation.Restoring
    val isComplete = operation == PaywallOperation.Complete

    Dialog(
        onDismissRequest = { if (canDismiss) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(16.dp),
            contentAlignment = Alignment.Center
        ) {
            Surface(
                modifier = Modifier
                    .widthIn(max = 520.dp)
                    .fillMaxWidth()
                    .heightIn(max = 680.dp)
                    .semantics { paneTitle = title },
                shape = MaterialTheme.shapes.extraLarge,
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 6.dp
            ) {
                Column(
                    modifier = Modifier
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 24.dp, vertical = 20.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.Top
                    ) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.primaryContainer,
                            contentColor = MaterialTheme.colorScheme.onPrimaryContainer
                        ) {
                            Icon(
                                imageVector = Icons.Default.AutoAwesome,
                                contentDescription = null,
                                modifier = Modifier.padding(10.dp)
                            )
                        }
                        Spacer(modifier = Modifier.weight(1f))
                        IconButton(
                            onClick = onDismiss,
                            enabled = canDismiss,
                            modifier = Modifier.size(48.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Close,
                                contentDescription = stringResource(R.string.paywall_close)
                            )
                        }
                    }

                    Text(
                        text = stringResource(R.string.paywall_pro_label),
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(top = 12.dp)
                    )
                    Text(
                        text = title,
                        style = MaterialTheme.typography.headlineSmall,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier
                            .padding(top = 4.dp)
                            .semantics { heading() }
                    )
                    Text(
                        text = stringResource(R.string.paywall_message),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 8.dp)
                    )

                    Column(
                        modifier = Modifier.padding(top = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                        PaywallBenefit(
                            title = stringResource(R.string.paywall_benefit_unlimited),
                            detail = stringResource(R.string.paywall_benefit_unlimited_detail)
                        )
                        PaywallBenefit(
                            title = stringResource(R.string.paywall_benefit_devices),
                            detail = stringResource(R.string.paywall_benefit_devices_detail)
                        )
                        PaywallBenefit(
                            title = stringResource(R.string.paywall_benefit_control),
                            detail = stringResource(R.string.paywall_benefit_control_detail)
                        )
                    }

                    if (isAuthenticated) {
                        PlanCard(
                            monthlyPrice = monthlyPrice,
                            isLoading = operation == PaywallOperation.LoadingPlan,
                            modifier = Modifier.padding(top = 20.dp)
                        )
                    } else {
                        Text(
                            text = stringResource(R.string.paywall_sign_in_detail),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 20.dp)
                        )
                    }

                    PaywallStatus(message = message)

                    Spacer(modifier = Modifier.height(20.dp))

                    Button(
                        onClick = {
                            when {
                                isComplete -> onDismiss()
                                !isAuthenticated -> onContinue()
                                monthlyPrice == null -> onRetryPlan()
                                else -> onContinue()
                            }
                        },
                        enabled = !isBusy,
                        colors = ButtonDefaults.buttonColors(
                            contentColor = accessibleContentColor(MaterialTheme.colorScheme.primary)
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp)
                    ) {
                        if (operation == PaywallOperation.LoadingPlan ||
                            operation == PaywallOperation.Purchasing
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                color = LocalContentColor.current,
                                strokeWidth = 2.dp
                            )
                            Spacer(modifier = Modifier.size(10.dp))
                        }
                        Text(
                            text = when {
                                isComplete -> stringResource(R.string.paywall_done)
                                !isAuthenticated -> stringResource(R.string.paywall_sign_in_confirm)
                                operation == PaywallOperation.LoadingPlan -> stringResource(R.string.paywall_loading_plan)
                                operation == PaywallOperation.Purchasing -> stringResource(R.string.paywall_purchasing)
                                monthlyPrice == null -> stringResource(R.string.paywall_try_again)
                                else -> stringResource(R.string.paywall_confirm_with_price, monthlyPrice)
                            }
                        )
                    }

                    if (isAuthenticated && !isComplete) {
                        TextButton(
                            onClick = onRestorePurchases,
                            enabled = !isBusy,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                        ) {
                            if (operation == PaywallOperation.Restoring) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(18.dp),
                                    color = LocalContentColor.current,
                                    strokeWidth = 2.dp
                                )
                                Spacer(modifier = Modifier.size(10.dp))
                            }
                            Text(
                                if (operation == PaywallOperation.Restoring) {
                                    stringResource(R.string.paywall_restoring)
                                } else {
                                    stringResource(R.string.account_restore_purchases)
                                }
                            )
                        }
                    }

                    if (!isComplete) {
                        TextButton(
                            onClick = onDismiss,
                            enabled = canDismiss,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                        ) {
                            Text(stringResource(R.string.paywall_not_now))
                        }
                    }
                }
            }
        }
    }
}

private fun accessibleContentColor(background: Color): Color {
    return if (background.luminance() > 0.179f) Color.Black else Color.White
}

@Composable
private fun PaywallBenefit(title: String, detail: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top
    ) {
        Icon(
            imageVector = Icons.Default.CheckCircle,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .padding(top = 2.dp)
                .size(20.dp)
        )
        Column {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp)
            )
        }
    }
}

@Composable
private fun PlanCard(
    monthlyPrice: String?,
    isLoading: Boolean,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surfaceVariant
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.paywall_monthly_plan),
                    style = MaterialTheme.typography.titleSmall
                )
                Text(
                    text = stringResource(R.string.paywall_renewal_terms),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 3.dp)
                )
            }
            if (isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp
                )
            } else {
                Text(
                    text = monthlyPrice?.let {
                        stringResource(R.string.paywall_price_per_month, it)
                    } ?: stringResource(R.string.paywall_price_unavailable),
                    style = MaterialTheme.typography.titleMedium,
                    color = if (monthlyPrice == null) {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    }
                )
            }
        }
    }
}

@Composable
private fun PaywallStatus(message: PaywallMessage) {
    if (message == PaywallMessage.None) return

    val isError = message == PaywallMessage.PlanUnavailable ||
        message == PaywallMessage.PurchaseFailed ||
        message == PaywallMessage.RestoreFailed
    val text = when (message) {
        PaywallMessage.None -> ""
        PaywallMessage.PlanUnavailable -> stringResource(R.string.paywall_plan_unavailable)
        PaywallMessage.PurchaseFailed -> stringResource(R.string.paywall_purchase_failed)
        PaywallMessage.PurchaseComplete -> stringResource(R.string.paywall_purchase_complete)
        PaywallMessage.RestoreFailed -> stringResource(R.string.paywall_restore_failed)
        PaywallMessage.NothingToRestore -> stringResource(R.string.paywall_nothing_to_restore)
        PaywallMessage.RestoreComplete -> stringResource(R.string.paywall_restore_complete)
    }

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 16.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        shape = MaterialTheme.shapes.medium,
        color = if (isError) {
            MaterialTheme.colorScheme.errorContainer
        } else {
            MaterialTheme.colorScheme.primaryContainer
        },
        contentColor = if (isError) {
            MaterialTheme.colorScheme.onErrorContainer
        } else {
            MaterialTheme.colorScheme.onPrimaryContainer
        }
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(12.dp)
        )
    }
}
