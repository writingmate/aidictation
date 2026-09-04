package com.whispermate.aidictation.ui.permissions

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.FindInPage
import androidx.compose.material.icons.filled.KeyboardVoice
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PrivacyTip
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.whispermate.aidictation.R

/**
 * The three permission rows shared by onboarding and Settings: Microphone and Text field
 * access (required), Display over other apps (recommended). A missing permission shows a
 * tonal Allow button; a granted one a neutral "On" chip.
 */
@Composable
fun PermissionRows(
    state: PermissionsState,
    onAllowMicrophone: () -> Unit,
    onAllowAccessibility: () -> Unit,
    onAllowOverlay: () -> Unit,
    modifier: Modifier = Modifier,
    showMicrophone: Boolean = true,
    showOverlayRows: Boolean = true
) {
    Column(modifier = modifier) {
        if (showMicrophone) {
            PermissionRow(
                icon = Icons.Default.Mic,
                title = stringResource(R.string.permission_microphone_title),
                body = stringResource(R.string.permission_microphone_body),
                granted = state.microphone,
                recommended = false,
                onAllow = onAllowMicrophone
            )
        }
        if (showMicrophone && showOverlayRows) {
            HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))
        }
        if (!showOverlayRows) return@Column
        PermissionRow(
            icon = Icons.Default.EditNote,
            title = stringResource(R.string.permission_accessibility_title),
            body = stringResource(R.string.permission_accessibility_body),
            granted = state.accessibility,
            recommended = false,
            onAllow = onAllowAccessibility
        )
        HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))
        PermissionRow(
            icon = Icons.Default.Layers,
            title = stringResource(R.string.permission_overlay_title),
            body = stringResource(R.string.permission_overlay_body),
            granted = state.overlay,
            recommended = true,
            onAllow = onAllowOverlay
        )
    }
}

@Composable
private fun PermissionRow(
    icon: ImageVector,
    title: String,
    body: String,
    granted: Boolean,
    recommended: Boolean,
    onAllow: () -> Unit
) {
    val colors = MaterialTheme.colorScheme
    // Neutral tiles in both states: the row's status is carried by the chip or button.
    val accent = colors.onSurface

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, top = 14.dp, end = 12.dp, bottom = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(accent.copy(alpha = 0.06f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(22.dp),
                tint = accent
            )
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                color = colors.onSurface
            )
            Text(
                text = body,
                style = MaterialTheme.typography.bodyMedium,
                color = colors.onSurfaceVariant
            )
            // The chip on the right already says "On", so the tag is only for missing ones.
            if (!granted) {
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = if (recommended) {
                        stringResource(R.string.permission_tag_recommended)
                    } else {
                        stringResource(R.string.permission_tag_required)
                    }.uppercase(),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (recommended) colors.primary else colors.onSurfaceVariant
                )
            }
        }
        Spacer(modifier = Modifier.width(12.dp))
        if (granted) {
            GrantedChip()
        } else {
            FilledTonalButton(onClick = onAllow) {
                Text(stringResource(R.string.permission_allow))
            }
        }
    }
}

@Composable
private fun GrantedChip() {
    val colors = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(18.dp))
            .background(colors.secondaryContainer)
            .padding(start = 8.dp, top = 8.dp, end = 12.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = Icons.Default.Check,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = colors.onSecondaryContainer
        )
        Spacer(modifier = Modifier.width(6.dp))
        Text(
            text = stringResource(R.string.permission_tag_on),
            style = MaterialTheme.typography.labelLarge,
            color = colors.onSecondaryContainer
        )
    }
}

/**
 * Prominent disclosure shown before sending the user to Android's accessibility settings,
 * as Google Play requires. [onAgree] should open those settings.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccessibilityDisclosureSheet(
    onAgree: () -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val colors = MaterialTheme.colorScheme

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(start = 24.dp, end = 24.dp, bottom = 24.dp)
        ) {
            Text(
                text = stringResource(R.string.onboarding_accessibility_disclosure_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                color = colors.onSurface
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.onboarding_accessibility_disclosure_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(12.dp))
            DisclosureVisualCard(
                icon = Icons.Default.FindInPage,
                title = stringResource(R.string.onboarding_accessibility_visual_find_title),
                body = stringResource(R.string.onboarding_accessibility_visual_find_body)
            )
            Spacer(modifier = Modifier.height(6.dp))
            DisclosureVisualCard(
                icon = Icons.Default.KeyboardVoice,
                title = stringResource(R.string.onboarding_accessibility_visual_insert_title),
                body = stringResource(R.string.onboarding_accessibility_visual_insert_body)
            )
            Spacer(modifier = Modifier.height(6.dp))
            DisclosureVisualCard(
                icon = Icons.Default.PrivacyTip,
                title = stringResource(R.string.onboarding_accessibility_visual_private_title),
                body = stringResource(R.string.onboarding_accessibility_visual_private_body)
            )
            Spacer(modifier = Modifier.height(6.dp))
            DisclosureVisualCard(
                icon = Icons.Default.CloudDone,
                title = stringResource(R.string.onboarding_accessibility_visual_processing_title),
                body = stringResource(R.string.onboarding_accessibility_visual_processing_body)
            )
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = stringResource(R.string.onboarding_accessibility_disclosure_use),
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.onboarding_accessibility_disclosure_data),
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.onboarding_accessibility_disclosure_cloud),
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.onboarding_accessibility_disclosure_settings),
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(20.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .weight(1f)
                        .height(48.dp)
                ) {
                    Text(stringResource(R.string.onboarding_accessibility_disclosure_decline))
                }
                Button(
                    onClick = onAgree,
                    modifier = Modifier
                        .weight(1f)
                        .height(48.dp)
                ) {
                    Text(stringResource(R.string.onboarding_accessibility_disclosure_accept))
                }
            }
        }
    }
}

@Composable
private fun DisclosureVisualCard(
    icon: ImageVector,
    title: String,
    body: String
) {
    val colors = MaterialTheme.colorScheme

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.small)
            .background(colors.background)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(colors.onSurface.copy(alpha = 0.06f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(21.dp),
                tint = colors.onSurface
            )
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.Bold,
                color = colors.onSurface
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = body,
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant
            )
        }
    }
}

/** Returns a function that shows the runtime microphone prompt; [onResult] gets the outcome. */
@Composable
fun rememberMicrophonePermissionLauncher(onResult: (Boolean) -> Unit): () -> Unit {
    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
        onResult = onResult
    )
    return { launcher.launch(Manifest.permission.RECORD_AUDIO) }
}
