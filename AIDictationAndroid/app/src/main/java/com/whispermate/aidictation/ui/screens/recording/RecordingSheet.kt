package com.whispermate.aidictation.ui.screens.recording

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.media.MediaPlayer
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.hilt.navigation.compose.hiltViewModel
import com.whispermate.aidictation.R
import com.whispermate.aidictation.domain.model.Recording
import com.whispermate.aidictation.service.AndroidAudioAttemptOwner
import com.whispermate.aidictation.ui.components.CircularMicButton
import com.whispermate.aidictation.ui.components.KeepScreenOn
import com.whispermate.aidictation.ui.components.MicButtonState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

enum class RecordingState {
    Recording,
    Processing,
    Viewing
}

@Composable
fun RecordingSheet(
    onDismiss: () -> Unit,
    onRecordingComplete: (Recording) -> Unit,
    viewModel: RecordingViewModel = hiltViewModel()
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var state by remember { mutableStateOf(RecordingState.Processing) }
    var transcription by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var audioFile by remember { mutableStateOf<File?>(null) }
    var durationMs by remember { mutableStateOf<Long?>(null) }
    var savedRecording by remember { mutableStateOf<Recording?>(null) }
    var isCopied by remember { mutableStateOf(false) }
    var isPlaying by remember { mutableStateOf(false) }

    val audioLevel by viewModel.audioLevel.collectAsState()
    val frequencyBands by viewModel.frequencyBands.collectAsState()
    val shouldAutoStop by viewModel.shouldAutoStop.collectAsState()

    var mediaPlayer by remember { mutableStateOf<MediaPlayer?>(null) }

    fun finishRecording() {
        if (state != RecordingState.Recording) return
        state = RecordingState.Processing
        scope.launch {
            viewModel.stopAndTranscribe().fold(
                onSuccess = { recording ->
                    savedRecording = recording
                    transcription = recording.transcription
                    durationMs = recording.durationMs
                    audioFile = recording.audioFilePath?.let(::File)
                    state = RecordingState.Viewing
                },
                onFailure = { failure ->
                    error = failure.message
                    state = RecordingState.Viewing
                }
            )
        }
    }

    // Start recording when sheet opens
    LaunchedEffect(Unit) {
        viewModel.start().fold(
            onSuccess = { state = RecordingState.Recording },
            onFailure = {
                error = "The microphone could not start."
                state = RecordingState.Viewing
            }
        )
    }
    LaunchedEffect(Unit) {
        viewModel.failureEvents.collect { event ->
            if (event.owner == AndroidAudioAttemptOwner.RECORDING_SHEET &&
                (state == RecordingState.Recording || state == RecordingState.Processing)
            ) {
                error = event.message
                state = RecordingState.Viewing
            }
        }
    }
    LaunchedEffect(shouldAutoStop) {
        if (shouldAutoStop) finishRecording()
    }

    // Cleanup on dismiss
    DisposableEffect(Unit) {
        onDispose {
            viewModel.cancel()
            mediaPlayer?.release()
        }
    }

    Dialog(
        onDismissRequest = {
            viewModel.cancel()
            onDismiss()
        },
        properties = DialogProperties(
            dismissOnBackPress = true,
            dismissOnClickOutside = false,
            usePlatformDefaultWidth = false
        )
    ) {
        // Keep the screen awake while dictation is recording or processing
        KeepScreenOn(enabled = state != RecordingState.Viewing)
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = Color.Black.copy(alpha = 0.95f)
        ) {
            AnimatedContent(
                targetState = state,
                transitionSpec = { fadeIn() togetherWith fadeOut() },
                label = "recording_state"
            ) { currentState ->
                when (currentState) {
                    RecordingState.Recording -> RecordingContent(
                        audioLevel = audioLevel,
                        frequencyBands = frequencyBands,
                        onCancel = {
                            viewModel.cancel()
                            onDismiss()
                        },
                        onStop = ::finishRecording
                    )

                    RecordingState.Processing -> ProcessingContent(
                        onCancel = {
                            viewModel.cancel()
                            onDismiss()
                        }
                    )

                    RecordingState.Viewing -> ViewingContent(
                        transcription = transcription,
                        error = error,
                        durationMs = durationMs,
                        audioFile = audioFile,
                        isPlaying = isPlaying,
                        isCopied = isCopied,
                        onPlayPause = {
                            audioFile?.let { file ->
                                if (isPlaying) {
                                    mediaPlayer?.pause()
                                    isPlaying = false
                                } else {
                                    if (mediaPlayer == null) {
                                        mediaPlayer = MediaPlayer().apply {
                                            setDataSource(file.absolutePath)
                                            prepare()
                                            setOnCompletionListener {
                                                isPlaying = false
                                            }
                                        }
                                    }
                                    mediaPlayer?.start()
                                    isPlaying = true
                                }
                            }
                        },
                        onCopy = {
                            copyToClipboard(context, transcription)
                            isCopied = true
                            scope.launch {
                                delay(1500)
                                isCopied = false
                            }
                        },
                        onDone = {
                            if (transcription.isNotEmpty() && savedRecording != null) {
                                onRecordingComplete(savedRecording!!)
                            } else {
                                onDismiss()
                            }
                        },
                        onDismiss = onDismiss
                    )
                }
            }
        }
    }
}

@Composable
private fun RecordingContent(
    audioLevel: Float,
    frequencyBands: FloatArray,
    onCancel: () -> Unit,
    onStop: () -> Unit
) {
    Box(
        modifier = Modifier.fillMaxSize()
    ) {
        // Cancel button
        IconButton(
            onClick = onCancel,
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(16.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = stringResource(R.string.cancel),
                tint = Color.White
            )
        }

        // Circular mic button with visualization - tap to stop
        Column(
            modifier = Modifier.align(Alignment.Center),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            CircularMicButton(
                state = MicButtonState.Recording,
                audioLevel = audioLevel,
                frequencyBands = frequencyBands,
                onClick = onStop,
                size = 160.dp
            )
            Spacer(modifier = Modifier.height(24.dp))
            Text(
                text = stringResource(R.string.recording),
                style = MaterialTheme.typography.bodyLarge,
                color = Color.White.copy(alpha = 0.7f)
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "Tap to stop",
                style = MaterialTheme.typography.bodySmall,
                color = Color.White.copy(alpha = 0.5f)
            )
        }
    }
}

@Composable
private fun ProcessingContent(onCancel: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        IconButton(
            onClick = onCancel,
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(16.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = stringResource(R.string.cancel),
                tint = Color.White
            )
        }
        Column(
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            CircularMicButton(
                state = MicButtonState.Processing,
                audioLevel = 0f,
                frequencyBands = null,
                onClick = { },
                size = 160.dp
            )
            Spacer(modifier = Modifier.height(24.dp))
            Text(
                text = stringResource(R.string.processing),
                style = MaterialTheme.typography.bodyLarge,
                color = Color.White.copy(alpha = 0.7f)
            )
        }
    }
}

@Composable
private fun ViewingContent(
    transcription: String,
    error: String?,
    durationMs: Long?,
    audioFile: File?,
    isPlaying: Boolean,
    isCopied: Boolean,
    onPlayPause: () -> Unit,
    onCopy: () -> Unit,
    onDone: () -> Unit,
    onDismiss: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        // Top bar
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onDismiss) {
                Icon(
                    imageVector = Icons.Default.Close,
                    contentDescription = stringResource(R.string.cancel),
                    tint = Color.White
                )
            }

            // Audio playback controls
            if (audioFile != null && durationMs != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    IconButton(onClick = onPlayPause) {
                        Icon(
                            imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                            contentDescription = stringResource(R.string.play),
                            tint = Color.White
                        )
                    }
                    Text(
                        text = formatDuration(durationMs),
                        style = MaterialTheme.typography.bodyMedium,
                        color = Color.White.copy(alpha = 0.7f)
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Transcription text
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
        ) {
            if (error != null) {
                Text(
                    text = error,
                    style = MaterialTheme.typography.bodyLarge,
                    color = Color(0xFFFF3B30),
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(24.dp)
                )
            } else {
                Text(
                    text = transcription,
                    style = MaterialTheme.typography.bodyLarge,
                    color = Color.White,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 24.dp)
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Copy button
        if (transcription.isNotEmpty()) {
            Button(
                onClick = {
                    onCopy()
                    onDone()
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (isCopied) Color(0xFF34C759) else MaterialTheme.colorScheme.primary
                )
            ) {
                Icon(
                    imageVector = if (isCopied) Icons.Default.Check else Icons.Default.ContentCopy,
                    contentDescription = null
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = if (isCopied) stringResource(R.string.copied) else stringResource(R.string.copy),
                    style = MaterialTheme.typography.titleMedium
                )
            }
        }
    }
}

private fun formatDuration(ms: Long): String {
    val seconds = ms / 1000
    val minutes = seconds / 60
    val remainingSeconds = seconds % 60
    return "${minutes}:${remainingSeconds.toString().padStart(2, '0')}"
}

private fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clip = ClipData.newPlainText("Transcription", text)
    clipboard.setPrimaryClip(clip)
}
