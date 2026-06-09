package com.whispermate.aidictation.ui.screens.settings

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
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
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.R
import com.whispermate.aidictation.data.preferences.OverlayBubblePreferences
import com.whispermate.aidictation.domain.model.Recording
import com.whispermate.aidictation.domain.model.UsageStatus
import com.whispermate.aidictation.service.OverlayDictationAccessibilityService
import com.whispermate.aidictation.ui.screens.main.OnDeviceModelUiState
import com.whispermate.aidictation.ui.views.OverlayMicButtonView

@Composable
fun SettingsScreen(
    recordings: List<Recording>,
    onClearHistory: () -> Unit,
    onNavigateToPostProcessingSettings: (Int) -> Unit,
    onNavigateToLanguageSettings: () -> Unit,
    onDeviceTranscriptionEnabled: Boolean = false,
    onDeviceModelState: OnDeviceModelUiState = OnDeviceModelUiState(),
    onOnDeviceTranscriptionToggled: (Boolean) -> Unit = {},
    autoStopOnSilenceEnabled: Boolean = false,
    onAutoStopOnSilenceToggled: (Boolean) -> Unit = {},
    usageStatus: UsageStatus,
    onSignIn: () -> Unit,
    onSignOut: () -> Unit,
    onUpgrade: () -> Unit,
    onShareInvite: () -> Unit,
    onRedeemInvite: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var showClearHistoryDialog by remember { mutableStateOf(false) }
    var showAccessibilityDisclosureDialog by remember { mutableStateOf(false) }
    var overlayBubbleSuppressed by remember { mutableStateOf(OverlayBubblePreferences.isSuppressed(context)) }
    var selectedBubbleColor by remember { mutableIntStateOf(OverlayBubblePreferences.getBubbleColor(context)) }
    var referralCodeInput by remember { mutableStateOf("") }
    var showTranscriptionModeScreen by remember { mutableStateOf(false) }
    var hasMicPermission by remember { mutableStateOf(hasMicrophonePermission(context)) }
    var hasOverlayPermission by remember { mutableStateOf(isOverlayAccessibilityEnabled(context)) }

    DisposableEffect(lifecycleOwner, context) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                hasMicPermission = hasMicrophonePermission(context)
                hasOverlayPermission = isOverlayAccessibilityEnabled(context)
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
            referralCodeInput = referralCodeInput,
            onReferralCodeChange = { referralCodeInput = it },
            onShareInvite = onShareInvite,
            onRedeemInvite = {
                onRedeemInvite(referralCodeInput)
                referralCodeInput = ""
            },
            onSignIn = onSignIn,
            onSignOut = onSignOut,
            onUpgrade = onUpgrade
        )

        Spacer(modifier = Modifier.height(24.dp))

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
                onClick = {
                    if (hasOverlayPermission) {
                        openAccessibilitySettings(context)
                    } else {
                        showAccessibilityDisclosureDialog = true
                    }
                },
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

            if (overlayBubbleSuppressed) {
                HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

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
                    },
                    iconTint = MaterialTheme.colorScheme.primary,
                    titleColor = MaterialTheme.colorScheme.primary
                )
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        SectionHeader(stringResource(R.string.settings_appearance))
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surface
            )
        ) {
            BubbleColorSelector(
                selectedColor = selectedBubbleColor,
                onColorSelected = { color ->
                    selectedBubbleColor = color
                    OverlayBubblePreferences.setBubbleColor(context, color)
                }
            )
            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))
            OverlayPreviewCard(selectedColor = selectedBubbleColor)
        }

        Spacer(modifier = Modifier.height(24.dp))

        SectionHeader(stringResource(R.string.settings_transcription))
        Card(
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

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

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

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

            SettingsItem(
                icon = Icons.Default.AutoAwesome,
                title = stringResource(R.string.transcription_tone_style),
                onClick = { onNavigateToPostProcessingSettings(1) },
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

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

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

    if (showAccessibilityDisclosureDialog) {
        AlertDialog(
            onDismissRequest = { showAccessibilityDisclosureDialog = false },
            title = { Text(stringResource(R.string.onboarding_accessibility_disclosure_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.onboarding_accessibility_disclosure_intro))
                    Text(stringResource(R.string.onboarding_accessibility_disclosure_use))
                    Text(stringResource(R.string.onboarding_accessibility_disclosure_data))
                    Text(stringResource(R.string.onboarding_accessibility_disclosure_cloud))
                    Text(stringResource(R.string.onboarding_accessibility_disclosure_settings))
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showAccessibilityDisclosureDialog = false
                        openAccessibilitySettings(context)
                    }
                ) {
                    Text(stringResource(R.string.onboarding_accessibility_disclosure_accept))
                }
            },
            dismissButton = {
                TextButton(onClick = { showAccessibilityDisclosureDialog = false }) {
                    Text(stringResource(R.string.onboarding_accessibility_disclosure_decline))
                }
            }
        )
    }
}

@Composable
private fun AccountSettingsSection(
    usageStatus: UsageStatus,
    referralCodeInput: String,
    onReferralCodeChange: (String) -> Unit,
    onShareInvite: () -> Unit,
    onRedeemInvite: () -> Unit,
    onSignIn: () -> Unit,
    onSignOut: () -> Unit,
    onUpgrade: () -> Unit
) {
    val showsIdentityRow = usageStatus.isAuthenticated || usageStatus.isPro

    SectionHeader(stringResource(R.string.settings_account))
    Card(
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
        } else if (usageStatus.isPro) {
            SettingsItem(
                icon = Icons.Default.AccountCircle,
                title = stringResource(R.string.account_sign_in),
                onClick = onSignIn,
                iconTint = MaterialTheme.colorScheme.primary,
                titleColor = MaterialTheme.colorScheme.primary
            )
        }

        if (showsIdentityRow) {
            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))
        }

        UsageSummary(usageStatus = usageStatus)

        HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

        if (!usageStatus.isPro) {
            SettingsItem(
                icon = Icons.Default.AutoAwesome,
                title = if (usageStatus.isAuthenticated) {
                    stringResource(R.string.account_upgrade)
                } else {
                    stringResource(R.string.account_sign_in_or_upgrade)
                },
                onClick = onUpgrade,
                iconTint = MaterialTheme.colorScheme.primary,
                titleColor = MaterialTheme.colorScheme.primary
            )

            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))
        }

        ReferralInviteItem(
            usageStatus = usageStatus,
            referralCodeInput = referralCodeInput,
            onReferralCodeChange = onReferralCodeChange,
            onShareInvite = onShareInvite,
            onRedeemInvite = onRedeemInvite
        )

        if (usageStatus.isAuthenticated) {
            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))
            SettingsItem(
                icon = Icons.AutoMirrored.Filled.Logout,
                title = stringResource(R.string.account_sign_out),
                onClick = onSignOut
            )
        }
    }
}

@Composable
private fun BubbleColorSelector(
    selectedColor: Int,
    onColorSelected: (Int) -> Unit
) {
    val context = LocalContext.current
    val options = listOf(
        BubbleColorOption(
            color = OverlayBubblePreferences.SYSTEM_COLOR,
            resolvedColor = OverlayBubblePreferences.getResolvedSystemColor(context),
            label = stringResource(R.string.settings_bubble_color_system)
        ),
        BubbleColorOption(
            color = OverlayBubblePreferences.DEFAULT_COLOR,
            resolvedColor = OverlayBubblePreferences.DEFAULT_COLOR,
            label = stringResource(R.string.settings_bubble_color_default)
        ),
        BubbleColorOption(
            color = 0xFFE11D48.toInt(),
            resolvedColor = 0xFFE11D48.toInt(),
            label = stringResource(R.string.settings_bubble_color_red)
        ),
        BubbleColorOption(
            color = 0xFF7C3AED.toInt(),
            resolvedColor = 0xFF7C3AED.toInt(),
            label = stringResource(R.string.settings_bubble_color_purple)
        ),
        BubbleColorOption(
            color = 0xFF2563EB.toInt(),
            resolvedColor = 0xFF2563EB.toInt(),
            label = stringResource(R.string.settings_bubble_color_blue)
        ),
        BubbleColorOption(
            color = 0xFF0D9488.toInt(),
            resolvedColor = 0xFF0D9488.toInt(),
            label = stringResource(R.string.settings_bubble_color_teal)
        ),
        BubbleColorOption(
            color = OverlayBubblePreferences.BLACK_COLOR,
            resolvedColor = OverlayBubblePreferences.BLACK_COLOR,
            label = stringResource(R.string.settings_bubble_color_black)
        )
    )

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text(
            text = stringResource(R.string.settings_bubble_color),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface
        )

        options.chunked(4).forEach { rowOptions ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                rowOptions.forEach { option ->
                    BubbleColorSwatchOption(
                        option = option,
                        selected = option.color == selectedColor,
                        onClick = { onColorSelected(option.color) }
                    )
                }
                repeat(4 - rowOptions.size) {
                    Spacer(modifier = Modifier.width(62.dp))
                }
            }
        }
    }
}

private data class BubbleColorOption(
    val color: Int,
    val resolvedColor: Int,
    val label: String
)

@Composable
private fun BubbleColorSwatchOption(
    option: BubbleColorOption,
    selected: Boolean,
    onClick: () -> Unit
) {
    Column(
        modifier = Modifier.width(62.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        BubbleColorSwatch(
            color = option.resolvedColor,
            selected = selected,
            onClick = onClick
        )
        Text(
            text = option.label,
            style = MaterialTheme.typography.labelSmall,
            color = if (selected) {
                MaterialTheme.colorScheme.onSurface
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun BubbleColorSwatch(
    color: Int,
    selected: Boolean,
    onClick: () -> Unit
) {
    val shape = CircleShape
    val composeColor = Color(color)
    val borderColor = if (selected) {
        if (color == OverlayBubblePreferences.BLACK_COLOR) {
            MaterialTheme.colorScheme.primary
        } else {
            Color.Black.copy(alpha = 0.74f)
        }
    } else {
        MaterialTheme.colorScheme.outlineVariant
    }

    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(shape)
            .background(composeColor)
            .border(
                BorderStroke(if (selected) 3.dp else 1.dp, borderColor),
                shape
            )
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        if (selected) {
            Box(
                modifier = Modifier
                    .size(18.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.94f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Check,
                    contentDescription = null,
                    tint = composeColor,
                    modifier = Modifier.size(13.dp)
                )
            }
        }
    }
}

@Composable
private fun OverlayPreviewCard(selectedColor: Int) {
    var previewStateIndex by remember { mutableIntStateOf(0) }
    val previewStates = remember {
        listOf(
            OverlayMicButtonView.State.Idle,
            OverlayMicButtonView.State.Recording,
            OverlayMicButtonView.State.Processing
        )
    }
    val previewState = previewStates[previewStateIndex]
    val previewWidth = if (previewState == OverlayMicButtonView.State.Idle) 55.dp else 250.dp
    val resolvedColor = when (selectedColor) {
        OverlayBubblePreferences.SYSTEM_COLOR -> OverlayBubblePreferences.getResolvedSystemColor(LocalContext.current)
        else -> selectedColor
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(
            text = "Overlay preview",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = "Tap the control to switch states.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(74.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f))
                .clickable {
                    previewStateIndex = (previewStateIndex + 1) % previewStates.size
                },
            contentAlignment = Alignment.CenterEnd
        ) {
            AndroidView(
                modifier = Modifier
                    .width(previewWidth)
                    .height(55.dp)
                    .padding(end = 10.dp),
                factory = { context ->
                    OverlayMicButtonView(context).apply {
                        setColors(resolvedColor, resolvedColor)
                        setState(previewState)
                        setAudioLevel(0.72f)
                        setFrequencyBands(floatArrayOf(0.34f, 0.9f, 0.52f, 0.86f, 0.42f))
                        setOnClickCallback {
                            previewStateIndex = (previewStateIndex + 1) % previewStates.size
                        }
                    }
                },
                update = { view ->
                    view.setColors(resolvedColor, resolvedColor)
                    view.setState(previewState)
                    view.setAudioLevel(if (previewState == OverlayMicButtonView.State.Recording) 0.72f else 0f)
                    view.setFrequencyBands(floatArrayOf(0.34f, 0.9f, 0.52f, 0.86f, 0.42f))
                }
            )
        }
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
private fun ReferralInviteItem(
    usageStatus: UsageStatus,
    referralCodeInput: String,
    onReferralCodeChange: (String) -> Unit,
    onShareInvite: () -> Unit,
    onRedeemInvite: () -> Unit
) {
    Column(
        modifier = Modifier.padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Default.AccountCircle,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.size(24.dp)
            )
            Spacer(modifier = Modifier.width(16.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.referral_title),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = if (usageStatus.referralBonusWords > 0) {
                        stringResource(R.string.referral_earned, usageStatus.referralBonusWords)
                    } else {
                        stringResource(R.string.referral_description)
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        if (usageStatus.isAuthenticated) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(
                    onClick = onShareInvite,
                    modifier = Modifier.weight(1f)
                ) {
                    Text(stringResource(R.string.referral_share))
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = referralCodeInput,
                    onValueChange = onReferralCodeChange,
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    label = { Text(stringResource(R.string.referral_code_hint)) }
                )
                Button(
                    onClick = onRedeemInvite,
                    enabled = referralCodeInput.isNotBlank()
                ) {
                    Text(stringResource(R.string.referral_apply))
                }
            }
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
                if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
                else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
            )
            .border(
                BorderStroke(
                    width = if (selected) 2.dp else 1.dp,
                    color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant
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
                        MaterialTheme.colorScheme.primary
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

private fun hasMicrophonePermission(context: Context): Boolean {
    return ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.RECORD_AUDIO
    ) == PackageManager.PERMISSION_GRANTED
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
