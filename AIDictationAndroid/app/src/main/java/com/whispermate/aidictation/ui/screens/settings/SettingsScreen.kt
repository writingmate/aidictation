package com.whispermate.aidictation.ui.screens.settings

import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.R
import com.whispermate.aidictation.ui.components.SettingsRowGap
import com.whispermate.aidictation.data.preferences.OverlayBubblePreferences
import com.whispermate.aidictation.domain.model.Recording
import com.whispermate.aidictation.domain.model.UsageStatus
import com.whispermate.aidictation.ui.permissions.AccessibilityDisclosureSheet
import com.whispermate.aidictation.ui.permissions.OverlayPermissions
import com.whispermate.aidictation.ui.permissions.PermissionRows
import com.whispermate.aidictation.ui.permissions.rememberMicrophonePermissionLauncher
import com.whispermate.aidictation.ui.screens.main.OnDeviceModelUiState

@Composable
fun SettingsScreen(
    recordings: List<Recording>,
    onClearHistory: () -> Unit,
    onNavigateToPostProcessingSettings: (Int) -> Unit,
    onNavigateToLanguageSettings: () -> Unit,
    onDeviceTranscriptionEnabled: Boolean = false,
    onDeviceModelState: OnDeviceModelUiState = OnDeviceModelUiState(),
    onOnDeviceTranscriptionToggled: (Boolean) -> Unit = {},
    usageStatus: UsageStatus,
    onSignOut: () -> Unit,
    onUpgrade: () -> Unit,
    onSignInWithGoogle: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var showClearHistoryDialog by remember { mutableStateOf(false) }
    var showAccessibilityDisclosureDialog by remember { mutableStateOf(false) }
    var overlayBubbleSuppressed by remember { mutableStateOf(OverlayBubblePreferences.isSuppressed(context)) }
    var showTranscriptionModeScreen by remember { mutableStateOf(false) }
    var permissions by remember { mutableStateOf(OverlayPermissions.read(context)) }
    val requestMicrophone = rememberMicrophonePermissionLauncher { granted ->
        permissions = permissions.copy(microphone = granted)
    }

    DisposableEffect(lifecycleOwner, context) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permissions = OverlayPermissions.read(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    if (showTranscriptionModeScreen) {
        TranscriptionModeSettingsScreen(
            enabled = onDeviceTranscriptionEnabled,
            state = onDeviceModelState,
            onBack = { showTranscriptionModeScreen = false },
            onModeSelected = onOnDeviceTranscriptionToggled,
            modifier = modifier
        )
        return
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        AccountSettingsSection(
            usageStatus = usageStatus,
            onSignInWithGoogle = onSignInWithGoogle,
            onSignOut = onSignOut,
            onUpgrade = onUpgrade
        )

        Spacer(modifier = Modifier.height(24.dp))

        SectionHeader(stringResource(R.string.settings_permissions))
        Card(
            shape = MaterialTheme.shapes.large,
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surface
            )
        ) {
            PermissionRows(
                state = permissions,
                onAllowMicrophone = requestMicrophone,
                onAllowAccessibility = { showAccessibilityDisclosureDialog = true },
                onAllowOverlay = { OverlayPermissions.openDisplayOverAppsSettings(context) }
            )

            if (overlayBubbleSuppressed) {
                SettingsRowGap()

                SettingsItem(
                    icon = Icons.Default.Mic,
                    title = stringResource(R.string.settings_show_overlay_bubble),
                    onClick = {
                        OverlayBubblePreferences.restore(context)
                        overlayBubbleSuppressed = false
                        Toast.makeText(
                            context,
                            R.string.overlay_restored,
                            Toast.LENGTH_SHORT
                        ).show()
                    }
                )
            }
        }


        Spacer(modifier = Modifier.height(24.dp))

        SectionHeader(stringResource(R.string.settings_transcription))
        Card(
            shape = MaterialTheme.shapes.large,
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surface
            )
        ) {
            TranscriptionModeSettingsItem(
                enabled = onDeviceTranscriptionEnabled,
                state = onDeviceModelState,
                onClick = { showTranscriptionModeScreen = true }
            )

            SettingsRowGap()

            SettingsItem(
                icon = Icons.Default.Language,
                title = stringResource(R.string.settings_languages),
                onClick = onNavigateToLanguageSettings,
                trailingContent = {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            )

            SettingsRowGap()

            SettingsItem(
                icon = Icons.Default.Settings,
                title = stringResource(R.string.transcription_dictionary),
                onClick = { onNavigateToPostProcessingSettings(0) },
                enabled = !onDeviceTranscriptionEnabled,
                trailingContent = {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = if (!onDeviceTranscriptionEnabled) MaterialTheme.colorScheme.onSurfaceVariant
                               else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                    )
                }
            )

            SettingsRowGap()

            SettingsItem(
                icon = Icons.Default.Translate,
                title = stringResource(R.string.transcription_shortcuts),
                onClick = { onNavigateToPostProcessingSettings(2) },
                enabled = !onDeviceTranscriptionEnabled,
                trailingContent = {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = if (!onDeviceTranscriptionEnabled) MaterialTheme.colorScheme.onSurfaceVariant
                               else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                    )
                }
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        SectionHeader(stringResource(R.string.settings_about))
        Card(
            shape = MaterialTheme.shapes.large,
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surface
            )
        ) {
            SettingsItem(
                icon = Icons.Default.Info,
                title = stringResource(R.string.settings_version),
                trailingContent = {
                    Text(
                        text = BuildConfig.VERSION_NAME,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        SectionHeader(stringResource(R.string.settings_data))
        Card(
            shape = MaterialTheme.shapes.large,
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surface
            )
        ) {
            SettingsItem(
                icon = Icons.Default.Delete,
                title = stringResource(R.string.settings_clear_history),
                onClick = { showClearHistoryDialog = true },
                enabled = recordings.isNotEmpty(),
                iconTint = MaterialTheme.colorScheme.error,
                titleColor = MaterialTheme.colorScheme.error
            )
        }
    }

    if (showClearHistoryDialog) {
        AlertDialog(
            onDismissRequest = { showClearHistoryDialog = false },
            title = { Text(stringResource(R.string.settings_clear_history)) },
            text = { Text("This will delete all ${recordings.size} recordings. This cannot be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        onClearHistory()
                        showClearHistoryDialog = false
                    }
                ) {
                    Text(
                        stringResource(R.string.delete),
                        color = MaterialTheme.colorScheme.error
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { showClearHistoryDialog = false }) {
                    Text(stringResource(R.string.cancel))
                }
            }
        )
    }

    if (showAccessibilityDisclosureDialog) {
        AccessibilityDisclosureSheet(
            onAgree = {
                showAccessibilityDisclosureDialog = false
                OverlayPermissions.openAccessibilitySettings(context)
            },
            onDismiss = { showAccessibilityDisclosureDialog = false }
        )
    }
}

@Composable
private fun AccountSettingsSection(
    usageStatus: UsageStatus,
    onSignInWithGoogle: (() -> Unit)?,
    onSignOut: () -> Unit,
    onUpgrade: () -> Unit
) {
    SectionHeader(stringResource(R.string.settings_account))
    Card(
        shape = MaterialTheme.shapes.large,
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        )
    ) {
        if (usageStatus.isAuthenticated) {
            AccountIdentityItem(
                email = usageStatus.email ?: stringResource(R.string.account_signed_in),
                tierName = usageStatus.tierName
            )
            SettingsRowGap()
        }

        UsageSummary(usageStatus = usageStatus)

        // Google is the only way in. Upgrading needs an account, so an anonymous user
        // sees the Google button where a signed-in free user sees Upgrade. The button
        // is the card's last element and carries its own outline, so no rule around it.
        if (!usageStatus.isAuthenticated) {
            if (onSignInWithGoogle != null) {
                GoogleSignInButton(
                    onClick = onSignInWithGoogle,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 16.dp)
                )
            }
        } else if (!usageStatus.isPro) {
            SettingsRowGap()
            SettingsItem(
                icon = Icons.Default.AutoAwesome,
                title = stringResource(R.string.account_upgrade),
                onClick = onUpgrade,
                iconTint = MaterialTheme.colorScheme.primary,
                titleColor = MaterialTheme.colorScheme.primary
            )

            SettingsRowGap()
        }

        if (usageStatus.isAuthenticated) {
            if (usageStatus.isPro) SettingsRowGap()
            SettingsItem(
                icon = Icons.AutoMirrored.Filled.Logout,
                title = stringResource(R.string.account_sign_out),
                onClick = onSignOut
            )
        }
    }
}

/**
 * Google's sign-in button per its branding guidelines: outlined, the untinted "G" mark,
 * "Continue with Google". Material outlined emphasis, so it sits below the accent-filled
 * primary actions.
 */
@Composable
private fun GoogleSignInButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(24.dp),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = MaterialTheme.colorScheme.onSurface
        )
    ) {
        Icon(
            painter = painterResource(R.drawable.ic_google_g),
            contentDescription = null,
            tint = Color.Unspecified,
            modifier = Modifier.size(20.dp)
        )
        Spacer(modifier = Modifier.width(12.dp))
        Text(
            text = stringResource(R.string.account_continue_with_google),
            fontWeight = FontWeight.Medium
        )
    }
}

@Composable
private fun AccountIdentityItem(
    email: String,
    tierName: String
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = Icons.Default.AccountCircle,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.size(24.dp)
        )
        Spacer(modifier = Modifier.width(16.dp))
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Text(
                text = email,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
                // An address is one unbreakable token; wrapping it mid-string
                // reads as broken, so keep it on a single ellipsised line.
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = tierName,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun UsageSummary(usageStatus: UsageStatus) {
    Column(
        modifier = Modifier.padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text(
            text = if (usageStatus.isPro) {
                stringResource(R.string.account_usage_unlimited)
            } else {
                stringResource(R.string.account_usage_words, usageStatus.used, usageStatus.limit)
            },
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface
        )

        Text(
            text = if (usageStatus.isAuthenticated) {
                stringResource(R.string.account_authenticated_hint)
            } else {
                stringResource(R.string.account_anonymous_hint)
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        if (!usageStatus.isPro) {
            LinearProgressIndicator(
                progress = { usageStatus.percentage.coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
private fun TranscriptionModeSettingsItem(
    enabled: Boolean,
    state: OnDeviceModelUiState,
    onClick: () -> Unit
) {
    val status = transcriptionModeStatus(enabled, state)

    SettingsItem(
        icon = Icons.Default.Mic,
        title = stringResource(R.string.settings_on_device_transcription),
        onClick = onClick,
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = status,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(modifier = Modifier.width(8.dp))
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    )
}

@Composable
private fun TranscriptionModeSettingsScreen(
    enabled: Boolean,
    state: OnDeviceModelUiState,
    onBack: () -> Unit,
    onModeSelected: (Boolean) -> Unit,
    modifier: Modifier = Modifier
) {
    val progress = state.downloadProgress?.coerceIn(0f, 1f)

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onBack),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurface
                )
            }
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = stringResource(R.string.settings_on_device_transcription),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
        }

        Text(
            text = stringResource(R.string.onboarding_on_device_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        TranscriptionModeChoiceCard(
            title = stringResource(R.string.onboarding_transcription_cloud_title),
            body = stringResource(R.string.onboarding_transcription_cloud_body),
            accuracyStars = 5,
            speedStars = 5,
            selected = !enabled && !state.isDownloading,
            onClick = { onModeSelected(false) }
        )

        TranscriptionModeChoiceCard(
            title = stringResource(R.string.onboarding_transcription_offline_title),
            body = when {
                state.isDownloading -> transcriptionModeStatus(enabled = true, state = state)
                state.isInstalled -> stringResource(R.string.settings_on_device_ready)
                else -> stringResource(R.string.onboarding_transcription_offline_body)
            },
            accuracyStars = 3,
            speedStars = 4,
            selected = enabled || state.isDownloading,
            onClick = { onModeSelected(true) }
        )

        if (state.isDownloading) {
            LinearProgressIndicator(
                progress = { progress ?: 0f },
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
private fun TranscriptionModeChoiceCard(
    title: String,
    body: String,
    accuracyStars: Int,
    speedStars: Int,
    selected: Boolean,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(
                if (selected) MaterialTheme.colorScheme.primaryContainer
                else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
            )
            .border(
                BorderStroke(
                    width = if (selected) 2.dp else 1.dp,
                    color = if (selected) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.outlineVariant
                ),
                RoundedCornerShape(12.dp)
            )
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(CircleShape)
                .border(
                    width = 2.dp,
                    color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            if (selected) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary)
                )
            }
        }

        Spacer(modifier = Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = body,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(10.dp))
            SettingsRatingRow(
                label = stringResource(R.string.onboarding_transcription_accuracy),
                stars = accuracyStars
            )
            Spacer(modifier = Modifier.height(4.dp))
            SettingsRatingRow(
                label = stringResource(R.string.onboarding_transcription_speed),
                stars = speedStars
            )
        }
    }
}

@Composable
private fun SettingsRatingRow(
    label: String,
    stars: Int
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f)
        )
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            repeat(5) { index ->
                Icon(
                    imageVector = Icons.Default.Star,
                    contentDescription = null,
                    modifier = Modifier.size(13.dp),
                    tint = if (index < stars.coerceIn(0, 5)) {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    } else {
                        MaterialTheme.colorScheme.outlineVariant
                    }
                )
            }
        }
    }
}

@Composable
private fun transcriptionModeStatus(
    enabled: Boolean,
    state: OnDeviceModelUiState
): String {
    val progress = state.downloadProgress?.coerceIn(0f, 1f)
    return when {
        state.isDownloading && progress != null -> {
            stringResource(R.string.settings_on_device_downloading, (progress * 100).toInt())
        }
        state.isDownloading -> stringResource(R.string.settings_on_device_downloading_unknown)
        enabled -> stringResource(R.string.settings_on_device_local)
        state.isInstalled -> stringResource(R.string.settings_on_device_ready)
        else -> stringResource(R.string.settings_on_device_cloud)
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(bottom = 8.dp, start = 4.dp)
    )
}

@Composable
private fun SettingsItem(
    icon: ImageVector,
    title: String,
    onClick: (() -> Unit)? = null,
    enabled: Boolean = true,
    iconTint: Color = MaterialTheme.colorScheme.onSurface,
    titleColor: Color = MaterialTheme.colorScheme.onSurface,
    trailingContent: @Composable () -> Unit = {}
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (onClick != null && enabled) {
                    Modifier.clickable(onClick = onClick)
                } else {
                    Modifier
                }
            )
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Row(
            modifier = Modifier.weight(1f),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (enabled) iconTint else iconTint.copy(alpha = 0.38f),
                modifier = Modifier.size(24.dp)
            )
            Spacer(modifier = Modifier.width(16.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = if (enabled) titleColor else titleColor.copy(alpha = 0.38f),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
        Spacer(modifier = Modifier.width(12.dp))
        trailingContent()
    }
}
