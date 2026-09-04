package com.whispermate.aidictation.ui.screens.main

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
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
import com.whispermate.aidictation.ui.screens.settings.SettingsScreen

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    onNavigateToPostProcessingSettings: (Int) -> Unit,
    onNavigateToLanguageSettings: () -> Unit,
    onNavigateToRecordingDetail: (String) -> Unit,
    shouldStartRecording: Boolean = false,
    onRecordingStarted: () -> Unit = {},
    viewModel: MainViewModel = hiltViewModel()
) {
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }
    val recordings by viewModel.recordings.collectAsState()
    val recordingState by viewModel.recordingState.collectAsState()
    val error by viewModel.error.collectAsState()
    val onDeviceTranscriptionEnabled by viewModel.onDeviceTranscriptionEnabled.collectAsState()
    val onDeviceModelState by viewModel.onDeviceModelState.collectAsState()
    val usageStatus by viewModel.usageStatus.collectAsState()
    val context = LocalContext.current
    val snackbarHostState = remember { SnackbarHostState() }
    val audioLevel by viewModel.audioLevel.collectAsState()
    val frequencyBands by viewModel.frequencyBands.collectAsState()
    val shouldAutoStop by viewModel.shouldAutoStop.collectAsState()
    val routeChangesEnabled = recordingState == RecordingState.Idle

    // Keep the screen awake while dictation is recording or processing
    KeepScreenOn(enabled = recordingState != RecordingState.Idle)

    // Show error in snackbar
    LaunchedEffect(error) {
        error?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearError()
        }
    }

    // Handle external start recording trigger
    LaunchedEffect(Unit) {
        viewModel.startRecordingTrigger.collect {
            viewModel.startRecording()
        }
    }

    // Handle initial start recording from navigation
    LaunchedEffect(shouldStartRecording) {
        if (shouldStartRecording && recordingState == RecordingState.Idle) {
            viewModel.startRecording()
            onRecordingStarted()
        }
    }

    // Auto-stop when VAD detects silence after speech
    LaunchedEffect(shouldAutoStop) {
        if (shouldAutoStop && recordingState == RecordingState.Recording) {
            viewModel.finalizeRecording()
        }
    }

    LaunchedEffect(recordingState) {
        if (recordingState != RecordingState.Idle) selectedTab = 0
    }

    fun toggleRecording() {
        when (recordingState) {
            RecordingState.Idle -> {
                viewModel.startRecording()
            }
            RecordingState.Recording -> {
                viewModel.finalizeRecording()
            }
            RecordingState.Processing -> Unit
        }
    }

    Scaffold(
        // White page; the cards carry the light grey.
        containerColor = MaterialTheme.colorScheme.surface,
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
                    enabled = routeChangesEnabled,
                    colors = aidictationNavigationItemColors()
                )
            }
        }
    ) { paddingValues ->
        when (selectedTab) {
            0 -> HistoryTab(
                recordings = recordings,
                onDelete = { viewModel.deleteRecording(it) },
                onCopy = { copyToClipboard(context, it.availableText) },
                onSelect = { onNavigateToRecordingDetail(it.id) },
                routeChangesEnabled = routeChangesEnabled,
                modifier = Modifier.padding(paddingValues)
            )
            1 -> SettingsScreen(
                recordings = recordings,
                onClearHistory = { viewModel.clearAllHistory() },
                onNavigateToPostProcessingSettings = { index ->
                    if (routeChangesEnabled) onNavigateToPostProcessingSettings(index)
                },
                onNavigateToLanguageSettings = {
                    if (routeChangesEnabled) onNavigateToLanguageSettings()
                },
                onDeviceTranscriptionEnabled = onDeviceTranscriptionEnabled,
                onDeviceModelState = onDeviceModelState,
                onOnDeviceTranscriptionToggled = { viewModel.setOnDeviceTranscriptionEnabled(it) },
                usageStatus = usageStatus,
                onSignInWithGoogle = if (viewModel.isGoogleSignInConfigured) {
                    { viewModel.signInWithGoogle(context) }
                } else {
                    null
                },
                onSignOut = { viewModel.signOut() },
                onUpgrade = { viewModel.openUpgrade() },
                modifier = Modifier.padding(paddingValues)
            )
        }
    }
}

@Composable
private fun aidictationNavigationItemColors() = NavigationBarItemDefaults.colors(
    selectedIconColor = MaterialTheme.colorScheme.onSurface,
    selectedTextColor = MaterialTheme.colorScheme.onSurface,
    indicatorColor = MaterialTheme.colorScheme.secondaryContainer,
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
    routeChangesEnabled: Boolean,
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
                                if (!recording.isProcessing) onDelete(recording)
                                !recording.isProcessing
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
                            SwipeToDismissBoxValue.StartToEnd -> MaterialTheme.colorScheme.inverseSurface
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
                        onClick = { onSelect(recording) },
                        routeChangesEnabled = routeChangesEnabled
                    )
                }
            }
        }
    }
}

@Composable
private fun RecordingItem(
    recording: Recording,
    onClick: () -> Unit,
    routeChangesEnabled: Boolean
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = routeChangesEnabled, onClick = onClick),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.background
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Row(
            modifier = Modifier.padding(16.dp)
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = when {
                        recording.isProcessing ->
                            recording.checkpointText.ifBlank { "Processing recording…" }
                        recording.transcription.isNotBlank() -> recording.transcription
                        recording.checkpointText.isNotBlank() -> recording.checkpointText
                        else -> recording.errorMessage ?: "Audio saved — retry transcription"
                    },
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
