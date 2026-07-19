package com.whispermate.aidictation.ui.screens.main

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.local.ParakeetModelAssets
import com.whispermate.aidictation.data.local.ParakeetRuntime
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.repository.RecordingRepository
import com.whispermate.aidictation.data.repository.SubscriptionRepository
import com.whispermate.aidictation.data.repository.TranscriptionRepository
import com.whispermate.aidictation.domain.model.Recording
import com.whispermate.aidictation.domain.model.AudioAttemptLease
import com.whispermate.aidictation.service.AndroidAudioAttemptOwner
import com.whispermate.aidictation.service.AndroidAudioProcessingCoordinator
import com.whispermate.aidictation.service.AndroidAudioProcessingState
import com.whispermate.aidictation.service.ExclusiveRequestFence
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject

enum class RecordingState {
    Idle,
    Recording,
    Processing
}

data class OnDeviceModelUiState(
    val isInstalled: Boolean = false,
    val isDownloading: Boolean = false,
    val downloadProgress: Float? = null
)

@HiltViewModel
class MainViewModel @Inject constructor(
    private val recordingRepository: RecordingRepository,
    private val transcriptionRepository: TranscriptionRepository,
    private val parakeetModelAssets: ParakeetModelAssets,
    private val subscriptionRepository: SubscriptionRepository,
    private val appPreferences: AppPreferences,
    private val audioProcessingCoordinator: AndroidAudioProcessingCoordinator
) : ViewModel() {
    companion object {
        private const val TAG = "MainViewModel"
        private const val ACCESS_CHECK_TIMEOUT_MS = 15_000L
        private const val SETTINGS_SNAPSHOT_TIMEOUT_MS = 5_000L
    }

    private val parakeetRuntime = ParakeetRuntime.fromConfig(BuildConfig.PARAKEET_RUNTIME)
    private var onDeviceSetupRequestId = 0

    val recordings: StateFlow<List<Recording>> = recordingRepository.recordings
        .stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

    val multilingualEnabled: StateFlow<Boolean> = appPreferences.multilingualEnabled
        .stateIn(viewModelScope, SharingStarted.Lazily, true)

    val postProcessingEnabled: StateFlow<Boolean> = appPreferences.postProcessingEnabled
        .stateIn(viewModelScope, SharingStarted.Lazily, true)

    val onDeviceTranscriptionEnabled: StateFlow<Boolean> = appPreferences.onDeviceTranscriptionEnabled
        .stateIn(viewModelScope, SharingStarted.Lazily, false)

    val autoStopOnSilenceEnabled: StateFlow<Boolean> = appPreferences.autoStopOnSilenceEnabled
        .stateIn(viewModelScope, SharingStarted.Lazily, false)

    val usageStatus = subscriptionRepository.usageStatus

    private val _onDeviceModelState = MutableStateFlow(OnDeviceModelUiState())
    val onDeviceModelState: StateFlow<OnDeviceModelUiState> = _onDeviceModelState.asStateFlow()

    init {
        refreshOnDeviceModelState()
    }

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

    fun setAutoStopOnSilenceEnabled(enabled: Boolean) {
        viewModelScope.launch {
            appPreferences.setAutoStopOnSilenceEnabled(enabled)
        }
    }

    fun setOnDeviceTranscriptionEnabled(enabled: Boolean) {
        viewModelScope.launch {
            val requestId = ++onDeviceSetupRequestId
            if (!enabled) {
                appPreferences.setOnDeviceTranscriptionEnabled(false)
                _onDeviceModelState.value = _onDeviceModelState.value.copy(
                    isDownloading = false,
                    downloadProgress = null
                )
                return@launch
            }

            if (_onDeviceModelState.value.isDownloading) return@launch

            try {
                _onDeviceModelState.value = _onDeviceModelState.value.copy(
                    isDownloading = true,
                    downloadProgress = 0f
                )
                withContext(Dispatchers.IO) {
                    parakeetModelAssets.ensureModelDirectory(parakeetRuntime) { progress ->
                        if (requestId != onDeviceSetupRequestId) return@ensureModelDirectory
                        _onDeviceModelState.value = _onDeviceModelState.value.copy(
                            isDownloading = true,
                            downloadProgress = progress
                        )
                    }
                }
                if (requestId != onDeviceSetupRequestId) return@launch
                appPreferences.setOnDeviceTranscriptionEnabled(true)
                _onDeviceModelState.value = OnDeviceModelUiState(isInstalled = true)
                prewarmOnDeviceTranscriber()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (requestId != onDeviceSetupRequestId) return@launch
                appPreferences.setOnDeviceTranscriptionEnabled(false)
                _onDeviceModelState.value = OnDeviceModelUiState(
                    isInstalled = withContext(Dispatchers.IO) {
                        parakeetModelAssets.isModelInstalled(parakeetRuntime)
                    }
                )
                _error.value = error.message ?: "Offline transcription setup failed"
            }
        }
    }

    private fun refreshOnDeviceModelState() {
        viewModelScope.launch {
            val isInstalled = withContext(Dispatchers.IO) {
                parakeetModelAssets.isModelInstalled(parakeetRuntime)
            }
            _onDeviceModelState.value = _onDeviceModelState.value.copy(
                isInstalled = isInstalled,
                isDownloading = false,
                downloadProgress = null
            )
            if (!isInstalled && appPreferences.onDeviceTranscriptionEnabled.first()) {
                appPreferences.setOnDeviceTranscriptionEnabled(false)
            }
            if (isInstalled && appPreferences.onDeviceTranscriptionEnabled.first()) {
                prewarmOnDeviceTranscriber()
            }
        }
    }

    private fun prewarmOnDeviceTranscriber() {
        viewModelScope.launch(Dispatchers.Default) {
            transcriptionRepository.prewarmOnDeviceIfEnabled()
                .onFailure { error ->
                    Log.w(TAG, "Unable to prewarm on-device transcription", error)
                }
        }
    }

    private val _preflightActive = MutableStateFlow(false)
    private val preflightFence = ExclusiveRequestFence()
    private var preflightJob: Job? = null
    private var activeCaptureLease: AudioAttemptLease? = null
    private var activeCaptureWorkflowToken: Long? = null

    // Recording state for inline recording
    val recordingState: StateFlow<RecordingState> = combine(
        audioProcessingCoordinator.state,
        audioProcessingCoordinator.owner,
        _preflightActive
    ) { state, owner, preflightActive ->
        if (preflightActive ||
            (state != AndroidAudioProcessingState.IDLE && owner != AndroidAudioAttemptOwner.MAIN)
        ) {
            RecordingState.Processing
        } else {
            when (state) {
                AndroidAudioProcessingState.IDLE -> RecordingState.Idle
                AndroidAudioProcessingState.RECORDING -> RecordingState.Recording
                AndroidAudioProcessingState.STARTING,
                AndroidAudioProcessingState.FINALIZING,
                AndroidAudioProcessingState.PROCESSING -> RecordingState.Processing
            }
        }
    }
        .stateIn(viewModelScope, SharingStarted.Eagerly, RecordingState.Idle)

    val audioLevel = audioProcessingCoordinator.audioLevel
    val frequencyBands = audioProcessingCoordinator.frequencyBands
    val shouldAutoStop = audioProcessingCoordinator.shouldAutoStop

    // Trigger for starting recording from outside (e.g. shortcut)
    private val _startRecordingTrigger = MutableSharedFlow<Unit>(replay = 0)
    val startRecordingTrigger: SharedFlow<Unit> = _startRecordingTrigger.asSharedFlow()

    // Selected recording for detail view
    private val _selectedRecording = MutableStateFlow<Recording?>(null)
    val selectedRecording: StateFlow<Recording?> = _selectedRecording.asStateFlow()

    // Error state
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    init {
        viewModelScope.launch {
            audioProcessingCoordinator.failureEvents.collect { event ->
                if (event.matches(
                        AndroidAudioAttemptOwner.MAIN,
                        activeCaptureLease,
                        activeCaptureWorkflowToken
                    )
                ) {
                    activeCaptureLease = null
                    activeCaptureWorkflowToken = null
                    _error.value = event.message
                }
            }
        }
    }

    fun startRecording() {
        val requestId = reservePreflight() ?: return
        activeCaptureLease = null
        activeCaptureWorkflowToken = requestId
        preflightJob = viewModelScope.launch {
            try {
                val contextRules = try {
                    withTimeout(SETTINGS_SNAPSHOT_TIMEOUT_MS) {
                        appPreferences.getInstructionsForApp(null)
                    }
                } catch (error: TimeoutCancellationException) {
                    _error.value = "Your recording settings took too long to load. Try again."
                    return@launch
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    _error.value = "Your recording settings could not be loaded. Try again."
                    return@launch
                }
                if (!ownsPreflight(requestId)) return@launch
                val started = audioProcessingCoordinator.startCapture(
                    owner = AndroidAudioAttemptOwner.MAIN,
                    workflowToken = requestId,
                    autoStopOnSilence = autoStopOnSilenceEnabled.value,
                    contextRules = contextRules
                )
                val lease = started.getOrElse {
                    activeCaptureWorkflowToken = null
                    _error.value = "Your recording could not start. Check microphone access and storage, then try again."
                    return@launch
                }
                activeCaptureLease = lease
                if (!audioProcessingCoordinator.isCaptureCurrent(AndroidAudioAttemptOwner.MAIN, lease)) {
                    activeCaptureLease = null
                    activeCaptureWorkflowToken = null
                    _error.value = "The microphone stopped before recording became active. Try again."
                }
            } finally {
                if (activeCaptureLease == null && activeCaptureWorkflowToken == requestId) {
                    activeCaptureWorkflowToken = null
                }
                finishPreflight(requestId)
            }
        }
    }

    fun cancelRecording() {
        val lease = activeCaptureLease
        val workflowToken = activeCaptureWorkflowToken ?: preflightFence.currentToken()
        activeCaptureLease = null
        activeCaptureWorkflowToken = null
        cancelPreflight()
        viewModelScope.launch {
            audioProcessingCoordinator.cancelCapture(
                AndroidAudioAttemptOwner.MAIN,
                expectedLease = lease,
                expectedWorkflowToken = workflowToken
            )
        }
    }

    fun triggerStartRecording() {
        viewModelScope.launch {
            _startRecordingTrigger.emit(Unit)
        }
    }

    fun finalizeRecording() {
        if (recordingState.value != RecordingState.Recording) return
        viewModelScope.launch {
            val finalized = audioProcessingCoordinator.stopCapture(AndroidAudioAttemptOwner.MAIN).getOrElse { error ->
                activeCaptureLease = null
                activeCaptureWorkflowToken = null
                Log.e(TAG, "Recording finalization failed", error)
                _error.value = "Your recording could not be finalized. The recoverable audio was kept."
                return@launch
            }
            activeCaptureLease = finalized.lease
            if (finalized.durationMs < 300 || !finalized.speechDetected) {
                val message = "No speech was recognized. Your audio remains in History."
                audioProcessingCoordinator.failBeforeRecognition(finalized, message)
                activeCaptureLease = null
                activeCaptureWorkflowToken = null
                _error.value = message
                return@launch
            }
            val access = checkAccessForFinalizedRecording(finalized)
            access.onFailure { error ->
                audioProcessingCoordinator.failBeforeRecognition(
                    finalized,
                    error.message ?: "Transcription is not available right now. Your audio was saved."
                )
                activeCaptureLease = null
                activeCaptureWorkflowToken = null
                _error.value = error.message
                return@launch
            }

            val outcome = audioProcessingCoordinator.processRecognition(finalized)
            activeCaptureLease = null
            activeCaptureWorkflowToken = null
            outcome
                .onSuccess { result ->
                    subscriptionRepository.recordUsageClaim(result.usageClaimId)
                    _selectedRecording.value = try {
                        recordingRepository.getRecordingById(result.recordingId)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        _error.value = "Your transcription was saved, but History could not be refreshed."
                        null
                    }
                }
                .onFailure { error ->
                    Log.e(TAG, "Transcription failed", error)
                    _error.value = error.message
                        ?: "Your recording could not be transcribed. Its audio is available to retry."
                }
        }
    }

    private suspend fun checkAccessForFinalizedRecording(
        finalized: com.whispermate.aidictation.service.FinalizedAndroidCapture
    ): Result<Unit> = try {
        withTimeout(ACCESS_CHECK_TIMEOUT_MS) {
            subscriptionRepository.checkCanTranscribe()
        }
    } catch (error: TimeoutCancellationException) {
        Result.failure(IllegalStateException("Access check timed out. Your audio was saved.", error))
    } catch (error: CancellationException) {
        withContext(NonCancellable) {
            audioProcessingCoordinator.failBeforeRecognition(
                finalized,
                "Transcription was cancelled. Your audio was saved."
            )
        }
        throw error
    } catch (error: Throwable) {
        Result.failure(
            IllegalStateException(
                "Transcription access could not be checked. Your audio was saved.",
                error
            )
        )
    }

    fun retryRecording(recording: Recording) {
        if (!recording.canRetry) return
        val requestId = reservePreflight() ?: return
        preflightJob = viewModelScope.launch {
            try {
                val access = withTimeoutOrNull(ACCESS_CHECK_TIMEOUT_MS) {
                    subscriptionRepository.checkCanTranscribe()
                } ?: Result.failure(IllegalStateException("Access check timed out. Try again."))
                access.onFailure { error ->
                    _error.value = error.message
                    return@launch
                }
                val rules = try {
                    withTimeout(SETTINGS_SNAPSHOT_TIMEOUT_MS) {
                        appPreferences.getInstructionsForApp(null)
                    }
                } catch (error: TimeoutCancellationException) {
                    _error.value = "Your transcription settings took too long to load. Try again."
                    return@launch
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    _error.value = "Your transcription settings could not be loaded. Try again."
                    return@launch
                }
                if (!ownsPreflight(requestId)) return@launch
                val outcome = audioProcessingCoordinator.retry(
                    AndroidAudioAttemptOwner.MAIN,
                    requestId,
                    recording.id,
                    null,
                    rules
                )
                // Recognition is already durable and the coordinator has returned to idle.
                // History refresh and usage accounting are delivery work, not processing state.
                finishPreflight(requestId)
                outcome.onSuccess { result ->
                        subscriptionRepository.recordUsageClaim(result.usageClaimId)
                        _selectedRecording.value = try {
                            recordingRepository.getRecordingById(result.recordingId)
                        } catch (error: CancellationException) {
                            throw error
                        } catch (error: Throwable) {
                            _error.value = "Your transcription was saved, but History could not be refreshed."
                            null
                        }
                    }
                    .onFailure { error ->
                        _error.value = error.message
                            ?: "Retry could not finish. Your saved audio is still available."
                    }
            } finally {
                finishPreflight(requestId)
            }
        }
    }

    private fun reservePreflight(): Long? {
        if (_preflightActive.value || recordingState.value != RecordingState.Idle) return null
        val requestId = preflightFence.reserve() ?: return null
        _preflightActive.value = true
        return requestId
    }

    private fun finishPreflight(requestId: Long) {
        if (!preflightFence.finish(requestId)) return
        preflightJob = null
        _preflightActive.value = false
    }

    private fun ownsPreflight(requestId: Long): Boolean =
        _preflightActive.value && preflightFence.owns(requestId)

    private fun cancelPreflight() {
        preflightFence.cancelCurrent()
        preflightJob?.cancel()
        preflightJob = null
        _preflightActive.value = false
    }

    fun openLogin() {
        subscriptionRepository.openLogin()
    }

    fun openUpgrade() {
        subscriptionRepository.openUpgrade()
    }

    fun shareReferralInvite() {
        viewModelScope.launch {
            subscriptionRepository.shareReferralInvite().onFailure { error ->
                _error.value = error.message ?: "Could not share invite"
            }
        }
    }

    fun redeemReferralCode(code: String) {
        viewModelScope.launch {
            subscriptionRepository.redeemReferralCode(code).onFailure { error ->
                _error.value = error.message ?: "Could not apply invite code"
            }
        }
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
            val deleted = audioProcessingCoordinator.deleteRecording(recording)
            if (deleted) {
                if (_selectedRecording.value?.id == recording.id) _selectedRecording.value = null
            } else if (recording.isProcessing) {
                _error.value = "Wait for this recording to finish before deleting it."
            } else {
                _error.value = "The recording was removed from History, but its saved audio could not be deleted yet. Try again after restarting the app."
            }
        }
    }

    fun clearAllHistory() {
        viewModelScope.launch {
            if (!audioProcessingCoordinator.clearHistory()) {
                _error.value = "History could not be fully cleared. Wait for active recordings to finish, or restart the app to retry saved-audio cleanup."
            }
        }
    }

    override fun onCleared() {
        val lease = activeCaptureLease
        val workflowToken = activeCaptureWorkflowToken ?: preflightFence.currentToken()
        cancelPreflight()
        audioProcessingCoordinator.cancelCaptureFromLifecycle(
            AndroidAudioAttemptOwner.MAIN,
            "Recording screen closed",
            expectedLease = lease,
            expectedWorkflowToken = workflowToken
        )
        super.onCleared()
    }
}
