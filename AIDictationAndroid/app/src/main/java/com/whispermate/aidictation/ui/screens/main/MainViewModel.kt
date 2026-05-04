package com.whispermate.aidictation.ui.screens.main

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.repository.RecordingRepository
import com.whispermate.aidictation.data.repository.SubscriptionRepository
import com.whispermate.aidictation.data.repository.TranscriptionRepository
import com.whispermate.aidictation.domain.model.Recording
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File
import javax.inject.Inject

enum class RecordingState {
    Idle,
    Recording,
    Processing
}

@HiltViewModel
class MainViewModel @Inject constructor(
    private val recordingRepository: RecordingRepository,
    private val transcriptionRepository: TranscriptionRepository,
    private val subscriptionRepository: SubscriptionRepository,
    private val appPreferences: AppPreferences
) : ViewModel() {

    val recordings: StateFlow<List<Recording>> = recordingRepository.recordings
        .stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

    val multilingualEnabled: StateFlow<Boolean> = appPreferences.multilingualEnabled
        .stateIn(viewModelScope, SharingStarted.Lazily, true)

    val postProcessingEnabled: StateFlow<Boolean> = appPreferences.postProcessingEnabled
        .stateIn(viewModelScope, SharingStarted.Lazily, true)

    val usageStatus = subscriptionRepository.usageStatus

    fun setMultilingualEnabled(enabled: Boolean) {
        viewModelScope.launch {
            appPreferences.setMultilingualEnabled(enabled)
        }
    }

    fun setPostProcessingEnabled(enabled: Boolean) {
        viewModelScope.launch {
            appPreferences.setPostProcessingEnabled(enabled)
        }
    }

    // Recording state for inline recording
    private val _recordingState = MutableStateFlow(RecordingState.Idle)
    val recordingState: StateFlow<RecordingState> = _recordingState.asStateFlow()

    // Trigger for starting recording from outside (e.g. shortcut)
    private val _startRecordingTrigger = MutableSharedFlow<Unit>(replay = 0)
    val startRecordingTrigger: SharedFlow<Unit> = _startRecordingTrigger.asSharedFlow()

    // Selected recording for detail view
    private val _selectedRecording = MutableStateFlow<Recording?>(null)
    val selectedRecording: StateFlow<Recording?> = _selectedRecording.asStateFlow()

    // Error state
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun startRecording() {
        _recordingState.value = RecordingState.Recording
    }

    fun triggerStartRecording() {
        viewModelScope.launch {
            _startRecordingTrigger.emit(Unit)
        }
    }

    fun stopRecording(audioFile: File?, durationMs: Long) {
        if (audioFile == null || durationMs < 300) {
            _recordingState.value = RecordingState.Idle
            return
        }

        _recordingState.value = RecordingState.Processing

        viewModelScope.launch {
            subscriptionRepository.checkCanTranscribe().onFailure { error ->
                audioFile.delete()
                _error.value = error.message
                _recordingState.value = RecordingState.Idle
                return@launch
            }

            val prompt = transcriptionRepository.buildPrompt()
            val contextRules = appPreferences.getInstructionsForApp(null)
            val result = transcriptionRepository.transcribe(audioFile, prompt.ifEmpty { null }, contextRules)

            result.fold(
                onSuccess = { rawText ->
                    val processedText = transcriptionRepository.applyPostProcessing(rawText)
                    if (processedText.isNotEmpty()) {
                        val recording = Recording(
                            transcription = processedText,
                            durationMs = durationMs,
                            audioFilePath = audioFile.absolutePath
                        )
                        recordingRepository.addRecording(recording)
                        subscriptionRepository.recordWords(processedText)
                        _selectedRecording.value = recording
                    }
                    _recordingState.value = RecordingState.Idle
                },
                onFailure = { e ->
                    _error.value = e.message ?: "Transcription failed"
                    _recordingState.value = RecordingState.Idle
                }
            )
        }
    }

    fun openLogin() {
        subscriptionRepository.openLogin()
    }

    fun openUpgrade() {
        subscriptionRepository.openUpgrade()
    }

    fun signOut() {
        viewModelScope.launch {
            subscriptionRepository.signOut()
        }
    }

    fun selectRecording(recording: Recording) {
        _selectedRecording.value = recording
    }

    fun clearSelectedRecording() {
        _selectedRecording.value = null
    }

    fun clearError() {
        _error.value = null
    }

    fun deleteRecording(recording: Recording) {
        viewModelScope.launch {
            recordingRepository.deleteRecording(recording)
            if (_selectedRecording.value?.id == recording.id) {
                _selectedRecording.value = null
            }
        }
    }

    fun clearAllHistory() {
        viewModelScope.launch {
            recordingRepository.clearAllRecordings()
        }
    }
}
