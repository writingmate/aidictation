package com.whispermate.aidictation.ui.screens.onboarding

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.whispermate.aidictation.R
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.service.OverlayDictationAccessibilityService

@Composable
fun OnboardingScreen(
    onComplete: () -> Unit,
    onSaveContextRules: (List<Boolean>) -> Unit = {}
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    var currentStep by remember { mutableIntStateOf(0) }
    var hasMicPermission by remember { mutableStateOf(hasMicrophonePermission(context)) }
    var isOverlayServiceEnabled by remember { mutableStateOf(isOverlayAccessibilityEnabled(context)) }
    var testInputText by remember { mutableStateOf("") }
    val hasTestedDictation = testInputText.isNotBlank()

    val contextRulesEnabled = remember {
        AppPreferences.defaultContextRules.map { false }.toMutableStateList()
    }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                hasMicPermission = hasMicrophonePermission(context)
                isOverlayServiceEnabled = isOverlayAccessibilityEnabled(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasMicPermission = granted
        if (granted) {
            currentStep = 2
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 16.dp),
            horizontalArrangement = Arrangement.Center
        ) {
            repeat(3) { index ->
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(
                            if (index <= currentStep) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.outlineVariant
                        )
                )
                if (index < 2) {
                    Spacer(modifier = Modifier.width(8.dp))
                }
            }
        }

        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            AnimatedContent(
                targetState = currentStep,
                transitionSpec = { fadeIn() togetherWith fadeOut() },
                label = "onboarding_step"
            ) { step ->
                when (step) {
                    0 -> WelcomeStep()
                    1 -> MicrophonePermissionStep(hasPermission = hasMicPermission)
                    2 -> OverlaySetupStep(
                        isEnabled = isOverlayServiceEnabled,
                        testInputText = testInputText,
                        onTestInputChanged = { testInputText = it },
                        onOpenSettings = { openAccessibilitySettings(context) }
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Button(
            onClick = {
                when (currentStep) {
                    0 -> currentStep = 1
                    1 -> {
                        if (hasMicPermission) {
                            currentStep = 2
                        } else {
                            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                        }
                    }
                    2 -> {
                        if (!isOverlayServiceEnabled) {
                            openAccessibilitySettings(context)
                        } else if (hasTestedDictation) {
                            onSaveContextRules(contextRulesEnabled.toList())
                            onComplete()
                        }
                    }
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(56.dp),
            enabled = currentStep != 2 || !isOverlayServiceEnabled || hasTestedDictation,
            colors = ButtonDefaults.buttonColors(
                containerColor = MaterialTheme.colorScheme.primary
            )
        ) {
            Text(
                text = when (currentStep) {
                    0 -> stringResource(R.string.onboarding_continue)
                    1 -> if (hasMicPermission) {
                        stringResource(R.string.onboarding_continue)
                    } else {
                        stringResource(R.string.onboarding_mic_enable)
                    }
                    2 -> when {
                        !isOverlayServiceEnabled -> stringResource(R.string.onboarding_open_settings)
                        hasTestedDictation -> stringResource(R.string.onboarding_get_started)
                        else -> stringResource(R.string.onboarding_try_dictation)
                    }
                    else -> ""
                },
                style = MaterialTheme.typography.titleMedium
            )
        }
    }
}

@Composable
private fun WelcomeStep() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Default.Mic,
                contentDescription = null,
                modifier = Modifier.size(36.dp),
                tint = MaterialTheme.colorScheme.primary
            )
        }

        Spacer(modifier = Modifier.height(20.dp))

        Text(
            text = stringResource(R.string.onboarding_welcome_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(6.dp))

        Text(
            text = stringResource(R.string.onboarding_welcome_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(32.dp))

        FeatureItem(
            icon = Icons.Default.Translate,
            text = stringResource(R.string.onboarding_feature_1)
        )
        Spacer(modifier = Modifier.height(12.dp))
        FeatureItem(
            icon = Icons.Default.Speed,
            text = stringResource(R.string.onboarding_feature_2)
        )
        Spacer(modifier = Modifier.height(12.dp))
        FeatureItem(
            icon = Icons.Default.Security,
            text = stringResource(R.string.onboarding_feature_3)
        )
    }
}

@Composable
private fun MicrophonePermissionStep(hasPermission: Boolean) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(
                    if (hasPermission) MaterialTheme.colorScheme.primaryContainer
                    else MaterialTheme.colorScheme.secondaryContainer
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = if (hasPermission) Icons.Default.Check else Icons.Default.Mic,
                contentDescription = null,
                modifier = Modifier.size(36.dp),
                tint = if (hasPermission) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.secondary
            )
        }

        Spacer(modifier = Modifier.height(20.dp))

        Text(
            text = stringResource(R.string.onboarding_mic_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(6.dp))

        Text(
            text = stringResource(R.string.onboarding_mic_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun ContextRulesStep(
    enabledStates: List<Boolean>,
    onToggle: (Int, Boolean) -> Unit
) {
    val defaultRules = AppPreferences.defaultContextRules

    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Default.Tune,
                contentDescription = null,
                modifier = Modifier.size(36.dp),
                tint = MaterialTheme.colorScheme.primary
            )
        }

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = "Speech Cleanup",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(4.dp))

        Text(
            text = "Choose which cleanup rules to apply to your dictation",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(16.dp))

        defaultRules.forEachIndexed { index, rule ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onToggle(index, !enabledStates[index]) }
                    .background(
                        MaterialTheme.colorScheme.surfaceVariant,
                        shape = MaterialTheme.shapes.small
                    )
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(
                    checked = enabledStates[index],
                    onCheckedChange = { onToggle(index, it) },
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = rule.name,
                        style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.Medium
                    )
                    Text(
                        text = rule.instructions,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            Spacer(modifier = Modifier.height(4.dp))
        }
    }
}

@Composable
private fun OverlaySetupStep(
    isEnabled: Boolean,
    testInputText: String,
    onTestInputChanged: (String) -> Unit,
    onOpenSettings: () -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(
                    if (isEnabled) MaterialTheme.colorScheme.primaryContainer
                    else MaterialTheme.colorScheme.secondaryContainer
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = if (isEnabled) Icons.Default.Check else Icons.Default.Security,
                contentDescription = null,
                modifier = Modifier.size(36.dp),
                tint = if (isEnabled) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.secondary
            )
        }

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = stringResource(R.string.onboarding_overlay_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(4.dp))

        Text(
            text = stringResource(R.string.onboarding_overlay_subtitle),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(16.dp))

        SetupStepItem(
            number = "1",
            text = stringResource(R.string.onboarding_overlay_step1),
            isCompleted = isEnabled,
            onClick = if (!isEnabled) onOpenSettings else null
        )

        Spacer(modifier = Modifier.height(8.dp))

        SetupStepItem(
            number = "2",
            text = stringResource(R.string.onboarding_overlay_step2),
            isCompleted = isEnabled,
            onClick = if (!isEnabled) onOpenSettings else null
        )

        Spacer(modifier = Modifier.height(8.dp))

        SetupStepItem(
            number = "3",
            text = stringResource(R.string.onboarding_overlay_step3),
            isCompleted = testInputText.isNotBlank()
        )

        if (!isEnabled) {
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = stringResource(R.string.onboarding_overlay_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        } else {
            Spacer(modifier = Modifier.height(12.dp))
            OutlinedTextField(
                value = testInputText,
                onValueChange = onTestInputChanged,
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
                label = { Text(stringResource(R.string.onboarding_overlay_test_label)) },
                placeholder = { Text(stringResource(R.string.onboarding_overlay_test_placeholder)) }
            )
        }
    }
}

@Composable
private fun FeatureItem(icon: ImageVector, text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(0.85f)
    ) {
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = MaterialTheme.colorScheme.primary
            )
        }
        Spacer(modifier = Modifier.width(12.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium
        )
    }
}

@Composable
private fun SetupStepItem(
    number: String,
    text: String,
    isCompleted: Boolean = false,
    onClick: (() -> Unit)? = null
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(
                if (isCompleted) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.5f)
                else MaterialTheme.colorScheme.surfaceVariant,
                shape = MaterialTheme.shapes.small
            )
            .then(
                if (onClick != null) Modifier.clickable(onClick = onClick)
                else Modifier
            )
            .padding(12.dp)
    ) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(
                    if (isCompleted) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.outline
                ),
            contentAlignment = Alignment.Center
        ) {
            if (isCompleted) {
                Icon(
                    imageVector = Icons.Default.Check,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = MaterialTheme.colorScheme.onPrimary
                )
            } else {
                Text(
                    text = number,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.surface
                )
            }
        }
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            color = if (isCompleted) MaterialTheme.colorScheme.primary
            else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f)
        )
    }
}

private fun hasMicrophonePermission(context: Context): Boolean {
    return ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.RECORD_AUDIO
    ) == PackageManager.PERMISSION_GRANTED
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

    val className = OverlayDictationAccessibilityService::class.java.name
    val classNameWithoutPackage = className.removePrefix("${context.packageName}.")
    val fullServiceId = "${context.packageName}/$className"
    val shortServiceId = "${context.packageName}/.$classNameWithoutPackage"
    val shortSimpleServiceId = "${context.packageName}/.${OverlayDictationAccessibilityService::class.java.simpleName}"

    return enabledServices.split(':').any { serviceId ->
        serviceId.equals(fullServiceId, ignoreCase = true) ||
            serviceId.equals(shortServiceId, ignoreCase = true) ||
            serviceId.equals(shortSimpleServiceId, ignoreCase = true)
    }
}
