package com.whispermate.aidictation.ui.screens.main

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.whispermate.aidictation.R
import com.whispermate.aidictation.domain.model.Recording
import com.whispermate.aidictation.ui.components.CircularMicButton
import com.whispermate.aidictation.ui.components.KeepScreenOn
import com.whispermate.aidictation.ui.components.MicButtonState
import com.whispermate.aidictation.ui.components.UpgradePaywallDialog
import com.whispermate.aidictation.ui.screens.settings.SettingsScreen
import com.whispermate.aidictation.util.AudioRecorder
import java.io.File
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    onNavigateToPostProcessingSettings: (Int) -> Unit,
    onNavigateToLanguageSettings: () -> Unit,
    onNavigateToRecordingDetail: (String) -> Unit,
    shouldStartRecording: Boolean = false,
    onRecordingStarted: () -> Unit = {},
    shouldShowUpgradePaywall: Boolean = false,
    onUpgradePaywallShown: () -> Unit = {},
    viewModel: MainViewModel = hiltViewModel()
) {
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }
    val recordings by viewModel.recordings.collectAsState()
    val recordingState by viewModel.recordingState.collectAsState()
    val error by viewModel.error.collectAsState()
    val onDeviceTranscriptionEnabled by viewModel.onDeviceTranscriptionEnabled.collectAsState()
    val autoStopOnSilenceEnabled by viewModel.autoStopOnSilenceEnabled.collectAsState()
    val onDeviceModelState by viewModel.onDeviceModelState.collectAsState()
    val usageStatus by viewModel.usageStatus.collectAsState()
    val paywallState by viewModel.paywallState.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    val currentRecordingState by rememberUpdatedState(recordingState)
    val currentAutoStopOnSilenceEnabled by rememberUpdatedState(autoStopOnSilenceEnabled)
    var showUpgradePaywall by rememberSaveable { mutableStateOf(false) }

    // Audio recorder state
    var audioRecorder by remember { mutableStateOf<AudioRecorder?>(null) }
    var activeRecordingFile by remember { mutableStateOf<File?>(null) }
    val audioLevel = audioRecorder?.audioLevel?.collectAsState()?.value ?: 0f
    val frequencyBands = audioRecorder?.frequencyBands?.collectAsState()?.value
    val shouldAutoStop = audioRecorder?.shouldAutoStop?.collectAsState()?.value ?: false

    fun createAudioRecorder() = AudioRecorder(
        context = context,
        autoStopOnSilenceEnabled = currentAutoStopOnSilenceEnabled
    )

    fun finalizeRecording() {
        val recorder = audioRecorder
        val expectedAudioFile = activeRecordingFile
        if (viewModel.finalizeRecording(recorder, expectedAudioFile)) {
            audioRecorder = null
            activeRecordingFile = null
        }
    }

    // Keep the screen awake while dictation is recording or processing
    KeepScreenOn(enabled = recordingState != RecordingState.Idle)

    // Show error in snackbar
    LaunchedEffect(error) {
        error?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearError()
        }
    }

    LaunchedEffect(showUpgradePaywall, usageStatus.isAuthenticated) {
        if (showUpgradePaywall && usageStatus.isAuthenticated) {
            viewModel.preparePaywall()
        }
    }

    LaunchedEffect(Unit) {
        viewModel.showUpgradePaywall.collect {
            showUpgradePaywall = true
        }
    }

    LaunchedEffect(shouldShowUpgradePaywall) {
        if (shouldShowUpgradePaywall) {
            showUpgradePaywall = true
            onUpgradePaywallShown()
        }
    }

    // Handle external start recording trigger
    LaunchedEffect(Unit) {
        viewModel.startRecordingTrigger.collect {
            if (currentRecordingState == RecordingState.Idle) {
                val recorder = createAudioRecorder()
                audioRecorder = recorder
                val file = recorder.start()
                if (file != null) {
                    activeRecordingFile = file
                    viewModel.startRecording()
                } else {
                    audioRecorder = null
                    activeRecordingFile = null
                    viewModel.reportRecordingStartFailure()
                }
            }
        }
    }

    // Handle initial start recording from navigation
    LaunchedEffect(shouldStartRecording) {
        if (shouldStartRecording && recordingState == RecordingState.Idle) {
            val recorder = createAudioRecorder()
            audioRecorder = recorder
            val file = recorder.start()
            if (file != null) {
                activeRecordingFile = file
                viewModel.startRecording()
            } else {
                audioRecorder = null
                activeRecordingFile = null
                viewModel.reportRecordingStartFailure()
            }
            onRecordingStarted()
        }
    }

    // Auto-stop when VAD detects silence after speech
    LaunchedEffect(shouldAutoStop) {
        if (shouldAutoStop && recordingState == RecordingState.Recording) {
            finalizeRecording()
        }
    }

    // Cleanup audio recorder
    DisposableEffect(Unit) {
        onDispose {
            audioRecorder?.release()
            viewModel.cancelRecording(activeRecordingFile)
        }
    }

    fun toggleRecording() {
        when (recordingState) {
            RecordingState.Idle -> {
                val recorder = createAudioRecorder()
                audioRecorder = recorder
                val file = recorder.start()
                if (file != null) {
                    activeRecordingFile = file
                    viewModel.startRecording()
                } else {
                    audioRecorder = null
                    activeRecordingFile = null
                    viewModel.reportRecordingStartFailure()
                }
            }
            RecordingState.Recording -> {
                finalizeRecording()
            }
            RecordingState.Processing -> Unit
        }
    }

    if (showUpgradePaywall) {
        UpgradePaywallDialog(
            isAuthenticated = usageStatus.isAuthenticated,
            monthlyPrice = paywallState.monthlyPrice,
            operation = paywallState.operation,
            message = paywallState.message,
            onDismiss = {
                showUpgradePaywall = false
                viewModel.resetPaywall()
            },
            onContinue = {
                if (usageStatus.isAuthenticated) {
                    (context as? Activity)?.let(viewModel::purchaseFromPaywall)
                } else {
                    viewModel.openLogin()
                }
            },
            onRetryPlan = { viewModel.preparePaywall(forceRefresh = true) },
            onRestorePurchases = viewModel::restorePurchasesFromPaywall
        )
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        bottomBar = {
            NavigationBar(
                containerColor = MaterialTheme.colorScheme.surface,
                contentColor = MaterialTheme.colorScheme.onSurface
            ) {
                NavigationBarItem(
                    icon = { Icon(Icons.Default.History, contentDescription = null) },
                    label = { Text(stringResource(R.string.tab_history)) },
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    colors = aidictationNavigationItemColors()
                )

                Box(
                    modifier = Modifier
                        .weight(1f)
                        .width(88.dp),
                    contentAlignment = Alignment.Center
                ) {
                    CircularMicButton(
                        state = when (recordingState) {
                            RecordingState.Idle -> MicButtonState.Idle
                            RecordingState.Recording -> MicButtonState.Recording
                            RecordingState.Processing -> MicButtonState.Processing
                        },
                        audioLevel = audioLevel,
                        frequencyBands = frequencyBands,
                        onClick = { toggleRecording() },
                        size = 60.dp
                    )
                }

                NavigationBarItem(
                    icon = { Icon(Icons.Default.Settings, contentDescription = null) },
                    label = { Text(stringResource(R.string.tab_settings)) },
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    colors = aidictationNavigationItemColors()
                )
            }
        }
    ) { paddingValues ->
        when (selectedTab) {
            0 -> HistoryTab(
                recordings = recordings,
                onDelete = { viewModel.deleteRecording(it) },
                onCopy = { copyToClipboard(context, it.transcription) },
                onSelect = { onNavigateToRecordingDetail(it.id) },
                modifier = Modifier.padding(paddingValues)
            )
            1 -> SettingsScreen(
                recordings = recordings,
                onClearHistory = { viewModel.clearAllHistory() },
                onNavigateToPostProcessingSettings = onNavigateToPostProcessingSettings,
                onNavigateToLanguageSettings = onNavigateToLanguageSettings,
                onDeviceTranscriptionEnabled = onDeviceTranscriptionEnabled,
                onDeviceModelState = onDeviceModelState,
                onOnDeviceTranscriptionToggled = { viewModel.setOnDeviceTranscriptionEnabled(it) },
                autoStopOnSilenceEnabled = autoStopOnSilenceEnabled,
                onAutoStopOnSilenceToggled = { viewModel.setAutoStopOnSilenceEnabled(it) },
                usageStatus = usageStatus,
                onSignIn = { viewModel.openLogin() },
                onSignOut = { viewModel.signOut() },
                onUpgrade = { showUpgradePaywall = true },
                onRestorePurchases = { viewModel.restorePurchases() },
                onShareInvite = { viewModel.shareReferralInvite() },
                onRedeemInvite = { viewModel.redeemReferralCode(it) },
                modifier = Modifier.padding(paddingValues)
            )
        }
    }
}

@Composable
private fun aidictationNavigationItemColors() = NavigationBarItemDefaults.colors(
    selectedIconColor = MaterialTheme.colorScheme.primary,
    selectedTextColor = MaterialTheme.colorScheme.onSurface,
    indicatorColor = MaterialTheme.colorScheme.surfaceVariant,
    unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
    unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryTab(
    recordings: List<Recording>,
    onDelete: (Recording) -> Unit,
    onCopy: (Recording) -> Unit,
    onSelect: (Recording) -> Unit,
    modifier: Modifier = Modifier
) {
    if (recordings.isEmpty()) {
        Box(
            modifier = modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Icon(
                    imageVector = Icons.Default.History,
                    contentDescription = null,
                    modifier = Modifier.size(64.dp),
                    tint = MaterialTheme.colorScheme.outlineVariant
                )
                Text(
                    text = stringResource(R.string.no_recordings),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    } else {
        LazyColumn(
            modifier = modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items(
                items = recordings,
                key = { it.id }
            ) { recording ->
                val dismissState = rememberSwipeToDismissBoxState(
                    confirmValueChange = { value ->
                        when (value) {
                            SwipeToDismissBoxValue.EndToStart -> {
                                onDelete(recording)
                                true
                            }
                            SwipeToDismissBoxValue.StartToEnd -> {
                                onCopy(recording)
                                false
                            }
                            SwipeToDismissBoxValue.Settled -> false
                        }
                    }
                )

                SwipeToDismissBox(
                    state = dismissState,
                    backgroundContent = {
                        val direction = dismissState.dismissDirection
                        val color = when (direction) {
                            SwipeToDismissBoxValue.EndToStart -> MaterialTheme.colorScheme.error
                            SwipeToDismissBoxValue.StartToEnd -> MaterialTheme.colorScheme.primary
                            else -> MaterialTheme.colorScheme.surface
                        }
                        val icon = when (direction) {
                            SwipeToDismissBoxValue.EndToStart -> Icons.Default.Delete
                            SwipeToDismissBoxValue.StartToEnd -> Icons.Default.ContentCopy
                            else -> null
                        }
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .background(color, MaterialTheme.shapes.medium)
                                .padding(horizontal = 20.dp),
                            contentAlignment = when (direction) {
                                SwipeToDismissBoxValue.StartToEnd -> Alignment.CenterStart
                                else -> Alignment.CenterEnd
                            }
                        ) {
                            icon?.let {
                                Icon(
                                    imageVector = it,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onError
                                )
                            }
                        }
                    }
                ) {
                    RecordingItem(
                        recording = recording,
                        onClick = { onSelect(recording) }
                    )
                }
            }
        }
    }
}

@Composable
private fun RecordingItem(
    recording: Recording,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Row(
            modifier = Modifier.padding(16.dp)
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = recording.transcription,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    text = recording.formattedDate,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp)
                )
                recording.formattedDuration?.let { duration ->
                    Text(
                        text = duration,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.align(Alignment.CenterVertically)
            )
        }
    }
}

private fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clip = ClipData.newPlainText("Transcription", text)
    clipboard.setPrimaryClip(clip)
}
