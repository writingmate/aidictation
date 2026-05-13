package com.whispermate.aidictation.ui.screens.settings

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
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
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.R
import com.whispermate.aidictation.domain.model.Recording
import com.whispermate.aidictation.domain.model.UsageStatus
import com.whispermate.aidictation.service.OverlayDictationAccessibilityService
import com.whispermate.aidictation.ui.screens.main.OnDeviceModelUiState

@Composable
fun SettingsScreen(
    recordings: List<Recording>,
    onClearHistory: () -> Unit,
    onNavigateToPostProcessingSettings: () -> Unit,
    onNavigateToLanguageSettings: () -> Unit,
    multilingualEnabled: Boolean = true,
    onMultilingualToggled: (Boolean) -> Unit = {},
    postProcessingEnabled: Boolean = true,
    onPostProcessingToggled: (Boolean) -> Unit = {},
    onDeviceTranscriptionEnabled: Boolean = false,
    onDeviceModelState: OnDeviceModelUiState = OnDeviceModelUiState(),
    onOnDeviceTranscriptionToggled: (Boolean) -> Unit = {},
    autoStopOnSilenceEnabled: Boolean = false,
    onAutoStopOnSilenceToggled: (Boolean) -> Unit = {},
    usageStatus: UsageStatus,
    onSignIn: () -> Unit,
    onSignOut: () -> Unit,
    onUpgrade: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    var showClearHistoryDialog by remember { mutableStateOf(false) }
    var overlayBubbleSuppressed by remember { mutableStateOf(isOverlayBubbleSuppressed(context)) }
    var volumeShortcutEnabled by remember { mutableStateOf(isVolumeShortcutEnabled(context)) }

    val hasMicPermission = ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.RECORD_AUDIO
    ) == PackageManager.PERMISSION_GRANTED

    val hasOverlayPermission = isOverlayAccessibilityEnabled(context)

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        SectionHeader(stringResource(R.string.settings_permissions))
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surface
            )
        ) {
            SettingsItem(
                icon = Icons.Default.Mic,
                title = stringResource(R.string.settings_microphone),
                trailingContent = {
                    StatusIcon(isEnabled = hasMicPermission)
                }
            )

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

            SettingsItem(
                icon = Icons.Default.Security,
                title = stringResource(R.string.settings_overlay_access),
                onClick = { openAccessibilitySettings(context) },
                trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        StatusIcon(isEnabled = hasOverlayPermission)
                        Spacer(modifier = Modifier.width(8.dp))
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            )

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

            SettingsItem(
                icon = Icons.Default.Mic,
                title = stringResource(R.string.settings_volume_button_shortcut),
                enabled = hasOverlayPermission,
                trailingContent = {
                    Switch(
                        checked = volumeShortcutEnabled,
                        enabled = hasOverlayPermission,
                        onCheckedChange = { enabled ->
                            setVolumeShortcutEnabled(context, enabled)
                            volumeShortcutEnabled = enabled
                        }
                    )
                }
            )

            if (overlayBubbleSuppressed) {
                HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

                SettingsItem(
                    icon = Icons.Default.Mic,
                    title = stringResource(R.string.settings_show_overlay_bubble),
                    onClick = {
                        restoreOverlayBubble(context)
                        overlayBubbleSuppressed = false
                        Toast.makeText(
                            context,
                            R.string.overlay_restored,
                            Toast.LENGTH_SHORT
                        ).show()
                    },
                    iconTint = MaterialTheme.colorScheme.primary,
                    titleColor = MaterialTheme.colorScheme.primary
                )
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        SectionHeader(stringResource(R.string.settings_account))
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surface
            )
        ) {
            UsageSummary(usageStatus = usageStatus)

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

            if (usageStatus.isAuthenticated) {
                AccountIdentityItem(
                    email = usageStatus.email ?: stringResource(R.string.account_signed_in),
                    tierName = usageStatus.tierName
                )

                if (!usageStatus.isPro) {
                    HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))
                    SettingsItem(
                        icon = Icons.Default.Star,
                        title = stringResource(R.string.account_upgrade),
                        onClick = onUpgrade,
                        iconTint = MaterialTheme.colorScheme.primary,
                        titleColor = MaterialTheme.colorScheme.primary
                    )
                }

                HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))
                SettingsItem(
                    icon = Icons.AutoMirrored.Filled.Logout,
                    title = stringResource(R.string.account_sign_out),
                    onClick = onSignOut
                )
            } else {
                SettingsItem(
                    icon = Icons.Default.AccountCircle,
                    title = stringResource(R.string.account_sign_in),
                    onClick = onSignIn,
                    iconTint = MaterialTheme.colorScheme.primary,
                    titleColor = MaterialTheme.colorScheme.primary
                )

                HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))
                SettingsItem(
                    icon = Icons.Default.Star,
                    title = stringResource(R.string.account_upgrade),
                    onClick = onUpgrade,
                    iconTint = MaterialTheme.colorScheme.primary,
                    titleColor = MaterialTheme.colorScheme.primary
                )
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        SectionHeader(stringResource(R.string.settings_transcription))
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surface
            )
        ) {
            OnDeviceTranscriptionItem(
                enabled = onDeviceTranscriptionEnabled,
                state = onDeviceModelState,
                onToggle = onOnDeviceTranscriptionToggled
            )

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

            SettingsItem(
                icon = Icons.Default.Mic,
                title = stringResource(R.string.settings_auto_stop_on_silence),
                trailingContent = {
                    Switch(
                        checked = autoStopOnSilenceEnabled,
                        onCheckedChange = onAutoStopOnSilenceToggled
                    )
                }
            )

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

            SettingsItem(
                icon = Icons.Default.Translate,
                title = stringResource(R.string.settings_multilingual_mode),
                trailingContent = {
                    Switch(
                        checked = multilingualEnabled,
                        onCheckedChange = onMultilingualToggled
                    )
                }
            )

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

            SettingsItem(
                icon = Icons.Default.Language,
                title = stringResource(R.string.settings_languages),
                onClick = onNavigateToLanguageSettings,
                enabled = multilingualEnabled,
                trailingContent = {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = if (multilingualEnabled) MaterialTheme.colorScheme.onSurfaceVariant
                               else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                    )
                }
            )

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

            SettingsItem(
                icon = Icons.Default.AutoAwesome,
                title = stringResource(R.string.settings_post_processing),
                trailingContent = {
                    Switch(
                        checked = postProcessingEnabled,
                        onCheckedChange = onPostProcessingToggled
                    )
                }
            )

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

            SettingsItem(
                icon = Icons.Default.Settings,
                title = stringResource(R.string.settings_post_processing_settings),
                onClick = onNavigateToPostProcessingSettings,
                enabled = postProcessingEnabled,
                trailingContent = {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = if (postProcessingEnabled) MaterialTheme.colorScheme.onSurfaceVariant
                               else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                    )
                }
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        SectionHeader(stringResource(R.string.settings_about))
        Card(
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
}

private const val OVERLAY_BUBBLE_PREFS = "overlay_bubble"
private const val OVERLAY_BUBBLE_HIDDEN_KEY = "bubble_hidden"
private const val OVERLAY_BUBBLE_SNOOZE_UNTIL_MS_KEY = "bubble_snooze_until_ms"
private const val SHORTCUT_PREFS = "dictation_shortcuts"
private const val VOLUME_SHORTCUT_ENABLED_KEY = "volume_shortcut_enabled"

private fun isOverlayBubbleSuppressed(context: Context): Boolean {
    val prefs = context.getSharedPreferences(OVERLAY_BUBBLE_PREFS, Context.MODE_PRIVATE)
    if (prefs.getBoolean(OVERLAY_BUBBLE_HIDDEN_KEY, false)) return true

    val snoozeUntil = prefs.getLong(OVERLAY_BUBBLE_SNOOZE_UNTIL_MS_KEY, 0L)
    if (snoozeUntil <= 0L) return false
    if (System.currentTimeMillis() < snoozeUntil) return true

    prefs.edit().remove(OVERLAY_BUBBLE_SNOOZE_UNTIL_MS_KEY).apply()
    return false
}

private fun restoreOverlayBubble(context: Context) {
    context.getSharedPreferences(OVERLAY_BUBBLE_PREFS, Context.MODE_PRIVATE)
        .edit()
        .remove(OVERLAY_BUBBLE_HIDDEN_KEY)
        .remove(OVERLAY_BUBBLE_SNOOZE_UNTIL_MS_KEY)
        .apply()
}

private fun isVolumeShortcutEnabled(context: Context): Boolean {
    return context.getSharedPreferences(SHORTCUT_PREFS, Context.MODE_PRIVATE)
        .getBoolean(VOLUME_SHORTCUT_ENABLED_KEY, false)
}

private fun setVolumeShortcutEnabled(context: Context, enabled: Boolean) {
    context.getSharedPreferences(SHORTCUT_PREFS, Context.MODE_PRIVATE)
        .edit()
        .putBoolean(VOLUME_SHORTCUT_ENABLED_KEY, enabled)
        .apply()
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
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = tierName,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary
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
private fun OnDeviceTranscriptionItem(
    enabled: Boolean,
    state: OnDeviceModelUiState,
    onToggle: (Boolean) -> Unit
) {
    val progress = state.downloadProgress?.coerceIn(0f, 1f)
    val status = when {
        state.isDownloading && progress != null -> {
            stringResource(R.string.settings_on_device_downloading, (progress * 100).toInt())
        }
        state.isDownloading -> stringResource(R.string.settings_on_device_downloading_unknown)
        enabled -> stringResource(R.string.settings_on_device_local)
        state.isInstalled -> stringResource(R.string.settings_on_device_ready)
        else -> stringResource(R.string.settings_on_device_cloud)
    }

    Column {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    if (!state.isDownloading) {
                        Modifier.clickable { onToggle(!enabled) }
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
                    imageVector = Icons.Default.Mic,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.size(24.dp)
                )
                Spacer(modifier = Modifier.width(16.dp))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = stringResource(R.string.settings_on_device_transcription),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        text = status,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            Spacer(modifier = Modifier.width(12.dp))
            Switch(
                checked = enabled || state.isDownloading,
                enabled = !state.isDownloading,
                onCheckedChange = onToggle
            )
        }

        if (state.isDownloading) {
            LinearProgressIndicator(
                progress = { progress ?: 0f },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 56.dp, end = 16.dp, bottom = 16.dp)
            )
        }
    }
}

@Composable
private fun StatusIcon(isEnabled: Boolean) {
    Icon(
        imageVector = if (isEnabled) Icons.Default.Check else Icons.Default.Close,
        contentDescription = null,
        tint = if (isEnabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
        modifier = Modifier.size(20.dp)
    )
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
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

private fun openAccessibilitySettings(context: Context) {
    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK
    }
    context.startActivity(intent)
}

private fun isOverlayAccessibilityEnabled(context: Context): Boolean {
    val enabled = Settings.Secure.getInt(
        context.contentResolver,
        Settings.Secure.ACCESSIBILITY_ENABLED,
        0
    ) == 1

    if (!enabled) return false

    val enabledServices = Settings.Secure.getString(
        context.contentResolver,
        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
    ) ?: return false

    val expected = ComponentName(context, OverlayDictationAccessibilityService::class.java)
    return enabledServices.split(':').any { serviceId ->
        ComponentName.unflattenFromString(serviceId) == expected
    }
}
