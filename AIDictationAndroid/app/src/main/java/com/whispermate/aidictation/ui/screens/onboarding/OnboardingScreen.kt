package com.whispermate.aidictation.ui.screens.onboarding

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.FindInPage
import androidx.compose.material.icons.filled.KeyboardVoice
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PrivacyTip
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.whispermate.aidictation.R
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.preferences.OverlayBubblePreferences
import com.whispermate.aidictation.domain.model.WhisperLanguage
import com.whispermate.aidictation.domain.model.WhisperLanguages
import com.whispermate.aidictation.service.OverlayDictationAccessibilityService
import com.whispermate.aidictation.ui.views.OverlayMicButtonView

private val OnboardingSupportedLanguageCodes = listOf(
    // Mirrors the macOS app's Language enum. Empty selection means auto-detect.
    "en",
    "ru",
    "es",
    "fr",
    "de",
    "it",
    "pt",
    "pl",
    "tr",
    "nl",
    "ja",
    "ko",
    "zh",
    "ar",
    "hi",
    "uk",
    "cs",
    "sv",
    "fi"
)

private data class OnboardingColors(
    val primary: Color,
    val onPrimary: Color,
    val background: Color,
    val surface: Color,
    val surfaceVariant: Color,
    val onSurface: Color,
    val onSurfaceVariant: Color,
    val outline: Color
)

@Composable
private fun onboardingColors() = OnboardingColors(
    primary = MaterialTheme.colorScheme.primary,
    onPrimary = Color.White,
    background = MaterialTheme.colorScheme.background,
    surface = MaterialTheme.colorScheme.surface,
    surfaceVariant = MaterialTheme.colorScheme.surfaceVariant,
    onSurface = MaterialTheme.colorScheme.onSurface,
    onSurfaceVariant = MaterialTheme.colorScheme.onSurfaceVariant,
    outline = MaterialTheme.colorScheme.outlineVariant
)

@Composable
private fun OnboardingHeroIcon(
    icon: ImageVector,
    modifier: Modifier = Modifier
) {
    val colors = onboardingColors()

    Box(
        modifier = modifier
            .size(72.dp)
            .clip(CircleShape)
            .background(colors.primary.copy(alpha = 0.10f)),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(36.dp),
            tint = colors.primary
        )
    }
}

@Composable
private fun OnboardingSmallIcon(
    icon: ImageVector,
    modifier: Modifier = Modifier
) {
    val colors = onboardingColors()

    Box(
        modifier = modifier
            .size(32.dp)
            .clip(CircleShape)
            .background(colors.primary.copy(alpha = 0.10f)),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = colors.primary
        )
    }
}

private enum class OnboardingStep {
    Welcome,
    Color,
    Languages,
    Microphone,
    ButtonDemo,
    AccessibilityDisclosure,
    Overlay,
    OnDeviceTranscription,
    VolumeShortcut
}

@Composable
fun OnboardingScreen(
    onComplete: () -> Unit,
    onSaveContextRules: (List<Boolean>) -> Unit = {},
    selectedLanguageCodes: List<String> = emptyList(),
    onToggleLanguage: (String) -> Unit = {},
    onDeviceTranscriptionEnabled: Boolean = false,
    onDeviceModelState: OnboardingOnDeviceModelState = OnboardingOnDeviceModelState(),
    onSetOnDeviceTranscriptionEnabled: (Boolean) -> Unit = {}
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    var currentStep by remember { mutableIntStateOf(0) }
    var hasMicPermission by remember { mutableStateOf(hasMicrophonePermission(context)) }
    var isOverlayServiceEnabled by remember { mutableStateOf(isOverlayAccessibilityEnabled(context)) }
    var volumeShortcutEnabled by remember { mutableStateOf(isVolumeShortcutEnabled(context)) }
    var hasAcceptedAccessibilityDisclosure by remember { mutableStateOf(false) }
    var selectedBubbleColor by remember { mutableIntStateOf(OverlayBubblePreferences.getBubbleColor(context)) }
    val colors = onboardingColors()

    OnboardingSystemBars()

    val onboardingSteps = remember {
        buildList {
            add(OnboardingStep.Welcome)
            add(OnboardingStep.Color)
            add(OnboardingStep.Languages)
            add(OnboardingStep.Microphone)
            add(OnboardingStep.ButtonDemo)
            add(OnboardingStep.AccessibilityDisclosure)
            add(OnboardingStep.Overlay)
            add(OnboardingStep.OnDeviceTranscription)
            add(OnboardingStep.VolumeShortcut)
        }
    }
    val currentOnboardingStep = onboardingSteps[currentStep.coerceAtMost(onboardingSteps.lastIndex)]

    val contextRulesEnabled = remember {
        AppPreferences.defaultContextRules.map { false }.toMutableStateList()
    }

    LaunchedEffect(onboardingSteps.size) {
        if (currentStep > onboardingSteps.lastIndex) {
            currentStep = onboardingSteps.lastIndex
        }
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
            currentStep = (currentStep + 1).coerceAtMost(onboardingSteps.lastIndex)
        }
    }

    fun goToNextStep() {
        currentStep = (currentStep + 1).coerceAtMost(onboardingSteps.lastIndex)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 20.dp, bottom = 16.dp),
            horizontalArrangement = Arrangement.Center
        ) {
            repeat(onboardingSteps.size) { index ->
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(
                            if (index <= currentStep) colors.primary
                            else MaterialTheme.colorScheme.outlineVariant
                        )
                )
                if (index < onboardingSteps.lastIndex) {
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
                targetState = currentOnboardingStep,
                transitionSpec = { fadeIn() togetherWith fadeOut() },
                label = "onboarding_step"
            ) { step ->
                when (step) {
                    OnboardingStep.Welcome -> WelcomeStep()
                    OnboardingStep.Color -> BubbleColorStep(
                        selectedColor = selectedBubbleColor,
                        onColorSelected = { color ->
                            selectedBubbleColor = color
                            OverlayBubblePreferences.setBubbleColor(context, color)
                        }
                    )
                    OnboardingStep.Languages -> LanguageSelectionStep(
                        selectedLanguageCodes = selectedLanguageCodes,
                        onToggleLanguage = onToggleLanguage
                    )
                    OnboardingStep.Microphone -> MicrophonePermissionStep(hasPermission = hasMicPermission)
                    OnboardingStep.ButtonDemo -> ButtonDemoStep(selectedColor = selectedBubbleColor)
                    OnboardingStep.AccessibilityDisclosure -> AccessibilityDisclosureStep(
                        hasAccepted = hasAcceptedAccessibilityDisclosure,
                        onAcceptedChanged = { hasAcceptedAccessibilityDisclosure = it }
                    )
                    OnboardingStep.Overlay -> OverlaySetupStep(
                        isEnabled = isOverlayServiceEnabled,
                        onOpenSettings = { openAccessibilitySettings(context) }
                    )
                    OnboardingStep.OnDeviceTranscription -> OnDeviceTranscriptionStep(
                        enabled = onDeviceTranscriptionEnabled,
                        state = onDeviceModelState,
                        onEnabledChanged = onSetOnDeviceTranscriptionEnabled
                    )
                    OnboardingStep.VolumeShortcut -> VolumeShortcutStep(
                        isEnabled = volumeShortcutEnabled,
                        onEnabledChanged = { volumeShortcutEnabled = it }
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Button(
            onClick = {
                when (currentOnboardingStep) {
                    OnboardingStep.Welcome -> goToNextStep()
                    OnboardingStep.Color -> goToNextStep()
                    OnboardingStep.Languages -> goToNextStep()
                    OnboardingStep.Microphone -> {
                        if (hasMicPermission) {
                            goToNextStep()
                        } else {
                            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                        }
                    }
                    OnboardingStep.ButtonDemo -> goToNextStep()
                    OnboardingStep.AccessibilityDisclosure -> goToNextStep()
                    OnboardingStep.Overlay -> {
                        if (!isOverlayServiceEnabled) {
                            openAccessibilitySettings(context)
                        } else {
                            goToNextStep()
                        }
                    }
                    OnboardingStep.OnDeviceTranscription -> goToNextStep()
                    OnboardingStep.VolumeShortcut -> {
                        setVolumeShortcutEnabled(context, volumeShortcutEnabled)
                        onSaveContextRules(contextRulesEnabled.toList())
                        onComplete()
                    }
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(56.dp),
            enabled = when (currentOnboardingStep) {
                OnboardingStep.AccessibilityDisclosure -> hasAcceptedAccessibilityDisclosure
                OnboardingStep.OnDeviceTranscription -> !onDeviceModelState.isDownloading
                else -> true
            },
            colors = ButtonDefaults.buttonColors(
                containerColor = colors.primary,
                contentColor = colors.onPrimary
            )
        ) {
            Text(
                text = when (currentOnboardingStep) {
                    OnboardingStep.Welcome -> stringResource(R.string.onboarding_continue)
                    OnboardingStep.Color -> stringResource(R.string.onboarding_continue)
                    OnboardingStep.Languages -> stringResource(R.string.onboarding_continue)
                    OnboardingStep.Microphone -> if (hasMicPermission) {
                        stringResource(R.string.onboarding_continue)
                    } else {
                        stringResource(R.string.onboarding_mic_enable)
                    }
                    OnboardingStep.AccessibilityDisclosure -> {
                        stringResource(R.string.onboarding_accessibility_disclosure_continue)
                    }
                    OnboardingStep.ButtonDemo -> stringResource(R.string.onboarding_continue)
                    OnboardingStep.Overlay -> when {
                        !isOverlayServiceEnabled -> stringResource(R.string.onboarding_open_settings)
                        else -> stringResource(R.string.onboarding_continue)
                    }
                    OnboardingStep.OnDeviceTranscription -> stringResource(R.string.onboarding_continue)
                    OnboardingStep.VolumeShortcut -> stringResource(R.string.onboarding_get_started)
                },
                style = MaterialTheme.typography.titleMedium
            )
        }
    }
}

@Composable
private fun OnboardingSystemBars() {
    val context = LocalContext.current
    val view = LocalView.current
    val systemInDarkTheme = isSystemInDarkTheme()
    val useDarkSystemBarIcons = !systemInDarkTheme

    DisposableEffect(context, view, useDarkSystemBarIcons) {
        val window = context.findActivity()?.window
        if (window == null) {
            onDispose {}
        } else {
            val controller = WindowCompat.getInsetsController(window, view)

            controller.isAppearanceLightStatusBars = useDarkSystemBarIcons
            controller.isAppearanceLightNavigationBars = useDarkSystemBarIcons

            onDispose {
                controller.isAppearanceLightStatusBars = !systemInDarkTheme
                controller.isAppearanceLightNavigationBars = !systemInDarkTheme
            }
        }
    }
}

private data class OnboardingBubbleColorOption(
    val color: Int,
    val resolvedColor: Int,
    val label: String
)

@Composable
private fun BubbleColorStep(
    selectedColor: Int,
    onColorSelected: (Int) -> Unit
) {
    val colors = onboardingColors()

    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        OnboardingHeroIcon(icon = Icons.Default.Tune)

        Spacer(modifier = Modifier.height(20.dp))

        Text(
            text = stringResource(R.string.onboarding_color_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(6.dp))

        Text(
            text = stringResource(R.string.onboarding_color_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            color = colors.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(24.dp))

        OnboardingBubbleColorSelector(
            selectedColor = selectedColor,
            onColorSelected = onColorSelected
        )
    }
}

@Composable
private fun OnboardingBubbleColorSelector(
    selectedColor: Int,
    onColorSelected: (Int) -> Unit
) {
    val context = LocalContext.current
    val options = listOf(
        OnboardingBubbleColorOption(
            color = OverlayBubblePreferences.SYSTEM_COLOR,
            resolvedColor = OverlayBubblePreferences.getResolvedSystemColor(context),
            label = stringResource(R.string.settings_bubble_color_system)
        ),
        OnboardingBubbleColorOption(
            color = OverlayBubblePreferences.DEFAULT_COLOR,
            resolvedColor = OverlayBubblePreferences.DEFAULT_COLOR,
            label = stringResource(R.string.settings_bubble_color_default)
        ),
        OnboardingBubbleColorOption(
            color = 0xFFE11D48.toInt(),
            resolvedColor = 0xFFE11D48.toInt(),
            label = stringResource(R.string.settings_bubble_color_red)
        ),
        OnboardingBubbleColorOption(
            color = 0xFF7C3AED.toInt(),
            resolvedColor = 0xFF7C3AED.toInt(),
            label = stringResource(R.string.settings_bubble_color_purple)
        ),
        OnboardingBubbleColorOption(
            color = 0xFF2563EB.toInt(),
            resolvedColor = 0xFF2563EB.toInt(),
            label = stringResource(R.string.settings_bubble_color_blue)
        ),
        OnboardingBubbleColorOption(
            color = 0xFF0D9488.toInt(),
            resolvedColor = 0xFF0D9488.toInt(),
            label = stringResource(R.string.settings_bubble_color_teal)
        ),
        OnboardingBubbleColorOption(
            color = OverlayBubblePreferences.BLACK_COLOR,
            resolvedColor = OverlayBubblePreferences.BLACK_COLOR,
            label = stringResource(R.string.settings_bubble_color_black)
        )
    )

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        options.chunked(4).forEach { rowOptions ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                rowOptions.forEach { option ->
                    OnboardingBubbleColorSwatchOption(
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

@Composable
private fun OnboardingBubbleColorSwatchOption(
    option: OnboardingBubbleColorOption,
    selected: Boolean,
    onClick: () -> Unit
) {
    val colors = onboardingColors()

    Column(
        modifier = Modifier.width(62.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        OnboardingBubbleColorSwatch(
            color = option.resolvedColor,
            selected = selected,
            onClick = onClick
        )
        Text(
            text = option.label,
            style = MaterialTheme.typography.labelSmall,
            color = if (selected) colors.onSurface else colors.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun OnboardingBubbleColorSwatch(
    color: Int,
    selected: Boolean,
    onClick: () -> Unit
) {
    val colors = onboardingColors()
    val composeColor = Color(color)
    val borderColor = if (selected) {
        if (color == OverlayBubblePreferences.BLACK_COLOR) colors.primary else Color.Black.copy(alpha = 0.74f)
    } else {
        colors.outline
    }

    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(composeColor)
            .border(BorderStroke(if (selected) 3.dp else 1.dp, borderColor), CircleShape)
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
private fun ButtonDemoStep(selectedColor: Int) {
    val colors = onboardingColors()
    val context = LocalContext.current
    var demoStage by remember { mutableIntStateOf(0) }
    val previewState = when (demoStage) {
        2 -> OverlayMicButtonView.State.Recording
        3 -> OverlayMicButtonView.State.Processing
        else -> OverlayMicButtonView.State.Idle
    }
    val resolvedColor = when (selectedColor) {
        OverlayBubblePreferences.SYSTEM_COLOR -> OverlayBubblePreferences.getResolvedSystemColor(context)
        else -> selectedColor
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        OnboardingHeroIcon(icon = Icons.Default.KeyboardVoice)

        Spacer(modifier = Modifier.height(20.dp))

        Text(
            text = stringResource(R.string.onboarding_button_demo_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(6.dp))

        Text(
            text = stringResource(R.string.onboarding_button_demo_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            color = colors.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(28.dp))

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(176.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(colors.surfaceVariant.copy(alpha = 0.45f))
                .clickable { demoStage = (demoStage + 1) % 4 }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(colors.surface)
                    .padding(14.dp)
            ) {
                Text(
                    text = when (demoStage) {
                        0 -> stringResource(R.string.onboarding_button_demo_tap_area)
                        1 -> stringResource(R.string.onboarding_button_demo_mic_appears)
                        2 -> stringResource(R.string.onboarding_button_demo_speak)
                        else -> stringResource(R.string.onboarding_button_demo_result)
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = if (demoStage == 3) colors.onSurface else colors.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(32.dp))
            }

            if (demoStage >= 1) {
            AndroidView(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(16.dp)
                    .width(if (previewState == OverlayMicButtonView.State.Idle) 55.dp else 250.dp)
                    .height(55.dp),
                factory = { androidContext ->
                    OverlayMicButtonView(androidContext).apply {
                        setColors(resolvedColor, resolvedColor)
                        setState(previewState)
                        setAudioLevel(0.72f)
                        setFrequencyBands(floatArrayOf(0.34f, 0.9f, 0.52f, 0.86f, 0.42f))
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

        Spacer(modifier = Modifier.height(10.dp))

        Text(
            text = stringResource(R.string.onboarding_button_demo_hint),
            style = MaterialTheme.typography.labelSmall,
            color = colors.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun LanguageSelectionStep(
    selectedLanguageCodes: List<String>,
    onToggleLanguage: (String) -> Unit
) {
    val colors = onboardingColors()
    val selectedSet = selectedLanguageCodes.toSet()
    val supportedLanguageCodeSet = OnboardingSupportedLanguageCodes.toSet()
    val visibleLanguages = remember(selectedLanguageCodes) {
        val supportedLanguages = OnboardingSupportedLanguageCodes.mapNotNull { WhisperLanguages.getLanguage(it) }
        val selected = selectedLanguageCodes
            .mapNotNull { WhisperLanguages.getLanguage(it) }
            .filter { it.code in supportedLanguageCodeSet }
        (selected + supportedLanguages).distinctBy { it.code }
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        OnboardingHeroIcon(icon = Icons.Default.Language)

        Spacer(modifier = Modifier.height(20.dp))

        Text(
            text = stringResource(R.string.onboarding_languages_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(6.dp))

        Text(
            text = stringResource(R.string.onboarding_languages_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            color = colors.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(18.dp))

        visibleLanguages.forEach { language ->
            OnboardingLanguageRow(
                language = language,
                isSelected = language.code in selectedSet,
                onClick = { onToggleLanguage(language.code) }
            )
            Spacer(modifier = Modifier.height(8.dp))
        }

        Text(
            text = stringResource(R.string.onboarding_languages_change_later),
            style = MaterialTheme.typography.labelSmall,
            color = colors.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 4.dp)
        )
    }
}

@Composable
private fun OnboardingLanguageRow(
    language: WhisperLanguage,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    val colors = onboardingColors()
    val shape = MaterialTheme.shapes.small

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(if (isSelected) colors.primary.copy(alpha = 0.12f) else colors.surfaceVariant.copy(alpha = 0.45f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(if (isSelected) colors.primary.copy(alpha = 0.18f) else colors.surfaceVariant),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = language.code.uppercase(),
                style = MaterialTheme.typography.labelSmall,
                color = colors.primary,
                fontWeight = FontWeight.Bold
            )
        }

        Spacer(modifier = Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = language.englishName,
                style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.Bold,
                color = colors.onSurface
            )
            if (language.nativeName != language.englishName) {
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = language.nativeName,
                    style = MaterialTheme.typography.labelSmall,
                    color = colors.onSurfaceVariant
                )
            }
        }

        if (isSelected) {
            Spacer(modifier = Modifier.width(8.dp))
            Box(
                modifier = Modifier
                    .size(24.dp)
                    .clip(CircleShape)
                    .background(colors.primary),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Check,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = colors.onPrimary
                )
            }
        }
    }
}

@Composable
private fun AccessibilityDisclosureStep(
    hasAccepted: Boolean,
    onAcceptedChanged: (Boolean) -> Unit
) {
    val colors = onboardingColors()

    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        AccessibilityDisclosureHero()

        Spacer(modifier = Modifier.height(18.dp))

        Text(
            text = stringResource(R.string.onboarding_accessibility_disclosure_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            color = colors.onSurface,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(12.dp))

        Text(
            text = stringResource(R.string.onboarding_accessibility_disclosure_intro),
            style = MaterialTheme.typography.bodySmall,
            color = colors.onSurfaceVariant,
            textAlign = TextAlign.Center
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
            text = stringResource(R.string.onboarding_accessibility_next),
            style = MaterialTheme.typography.labelSmall,
            color = colors.primary,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(12.dp))

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(MaterialTheme.shapes.small)
                .clickable { onAcceptedChanged(!hasAccepted) }
                .background(
                    if (hasAccepted) colors.primary.copy(alpha = 0.10f)
                    else colors.surfaceVariant.copy(alpha = 0.55f)
                )
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Checkbox(
                checked = hasAccepted,
                onCheckedChange = onAcceptedChanged,
                colors = androidx.compose.material3.CheckboxDefaults.colors(
                    checkedColor = colors.primary,
                    uncheckedColor = colors.onSurfaceVariant,
                    checkmarkColor = colors.onPrimary
                )
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = stringResource(R.string.onboarding_accessibility_disclosure_consent),
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurface,
                modifier = Modifier.weight(1f)
            )
        }
    }
}

@Composable
private fun AccessibilityDisclosureHero() {
    val colors = onboardingColors()

    Box(
        modifier = Modifier.size(width = 176.dp, height = 92.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(22.dp))
                .background(colors.surfaceVariant.copy(alpha = 0.55f))
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.Center
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(0.68f)
                    .height(8.dp)
                    .clip(RoundedCornerShape(100.dp))
                    .background(colors.outline.copy(alpha = 0.7f))
            )
            Spacer(modifier = Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .width(3.dp)
                        .height(20.dp)
                        .clip(RoundedCornerShape(100.dp))
                        .background(colors.primary)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth(0.78f)
                        .height(8.dp)
                        .clip(RoundedCornerShape(100.dp))
                        .background(colors.primary.copy(alpha = 0.16f))
                )
            }
        }
        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .size(32.dp)
                .clip(CircleShape)
                .background(colors.surface),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Default.PrivacyTip,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = colors.onSurfaceVariant
            )
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .size(48.dp)
                .clip(CircleShape)
                .background(colors.primary),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Default.Mic,
                contentDescription = null,
                modifier = Modifier.size(24.dp),
                tint = colors.onPrimary
            )
        }
    }
}

@Composable
private fun DisclosureVisualCard(
    icon: ImageVector,
    title: String,
    body: String
) {
    val colors = onboardingColors()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.small)
            .background(colors.surfaceVariant.copy(alpha = 0.45f))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(colors.primary.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(21.dp),
                tint = colors.primary
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

@Composable
private fun OnDeviceTranscriptionStep(
    enabled: Boolean,
    state: OnboardingOnDeviceModelState,
    onEnabledChanged: (Boolean) -> Unit
) {
    val progress = state.downloadProgress?.coerceIn(0f, 1f)

    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        OnboardingHeroIcon(icon = if (enabled) Icons.Default.Check else Icons.Default.Mic)

        Spacer(modifier = Modifier.height(20.dp))

        Text(
            text = stringResource(R.string.onboarding_on_device_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(6.dp))

        Text(
            text = stringResource(R.string.onboarding_on_device_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(24.dp))

        TranscriptionModeChoice(
            title = stringResource(R.string.onboarding_transcription_cloud_title),
            body = stringResource(R.string.onboarding_transcription_cloud_body),
            selected = !enabled && !state.isDownloading,
            enabled = !state.isDownloading,
            onClick = { onEnabledChanged(false) }
        )

        Spacer(modifier = Modifier.height(10.dp))

        TranscriptionModeChoice(
            title = stringResource(R.string.onboarding_transcription_offline_title),
            body = if (state.isDownloading && progress != null) {
                stringResource(R.string.settings_on_device_downloading, (progress * 100).toInt())
            } else if (state.isDownloading) {
                stringResource(R.string.settings_on_device_downloading_unknown)
            } else {
                stringResource(R.string.onboarding_transcription_offline_body)
            },
            selected = enabled || state.isDownloading,
            enabled = !state.isDownloading,
            onClick = { onEnabledChanged(true) }
        )

        if (state.isDownloading) {
            Spacer(modifier = Modifier.height(12.dp))
            LinearProgressIndicator(
                progress = { progress ?: 0f },
                modifier = Modifier.fillMaxWidth()
            )
        }

        state.errorMessage?.let { error ->
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = error,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                textAlign = TextAlign.Center
            )
        }

        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = stringResource(R.string.onboarding_on_device_note),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun TranscriptionModeChoice(
    title: String,
    body: String,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit
) {
    val colors = onboardingColors()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) colors.primary.copy(alpha = 0.10f) else colors.surfaceVariant.copy(alpha = 0.55f))
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(CircleShape)
                .border(
                    width = 2.dp,
                    color = if (selected) colors.primary else MaterialTheme.colorScheme.outline,
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            if (selected) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(colors.primary)
                )
            }
        }

        Spacer(modifier = Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = colors.onSurface
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = body,
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun VolumeShortcutStep(
    isEnabled: Boolean,
    onEnabledChanged: (Boolean) -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        OnboardingHeroIcon(icon = Icons.Default.Mic)

        Spacer(modifier = Modifier.height(20.dp))

        Text(
            text = stringResource(R.string.onboarding_volume_shortcut_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(6.dp))

        Text(
            text = stringResource(R.string.onboarding_volume_shortcut_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(24.dp))

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .clickable { onEnabledChanged(!isEnabled) }
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.onboarding_volume_shortcut_toggle),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Medium
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = stringResource(R.string.onboarding_volume_shortcut_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(modifier = Modifier.width(12.dp))
            Switch(
                checked = isEnabled,
                onCheckedChange = onEnabledChanged
            )
        }
    }
}

@Composable
private fun WelcomeStep() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        OnboardingHeroIcon(icon = Icons.Default.Mic)

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
        OnboardingHeroIcon(icon = if (hasPermission) Icons.Default.Check else Icons.Default.Mic)

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
        OnboardingHeroIcon(icon = Icons.Default.Tune)

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
    onOpenSettings: () -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        OnboardingHeroIcon(icon = if (isEnabled) Icons.Default.Check else Icons.Default.Security)

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
            text = stringResource(R.string.onboarding_overlay_permission_step2),
            isCompleted = isEnabled,
            onClick = if (!isEnabled) onOpenSettings else null
        )

        if (!isEnabled) {
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = stringResource(R.string.onboarding_overlay_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
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
        OnboardingSmallIcon(icon = icon)
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
    val colors = onboardingColors()

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(
                if (isCompleted) colors.primary.copy(alpha = 0.16f)
                else colors.surfaceVariant,
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
                    if (isCompleted) colors.primary
                    else MaterialTheme.colorScheme.outline
                ),
            contentAlignment = Alignment.Center
        ) {
            if (isCompleted) {
                Icon(
                    imageVector = Icons.Default.Check,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = colors.onPrimary
                )
            } else {
                Text(
                    text = number,
                    style = MaterialTheme.typography.labelSmall,
                    color = colors.surface
                )
            }
        }
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            color = if (isCompleted) colors.primary else colors.onSurface,
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

    val expected = ComponentName(context, OverlayDictationAccessibilityService::class.java)
    return enabledServices.split(':').any { serviceId ->
        ComponentName.unflattenFromString(serviceId) == expected
    }
}

private const val SHORTCUT_PREFS = "dictation_shortcuts"
private const val VOLUME_SHORTCUT_ENABLED_KEY = "volume_shortcut_enabled"

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

private tailrec fun Context.findActivity(): Activity? {
    return when (this) {
        is Activity -> this
        is ContextWrapper -> baseContext.findActivity()
        else -> null
    }
}
