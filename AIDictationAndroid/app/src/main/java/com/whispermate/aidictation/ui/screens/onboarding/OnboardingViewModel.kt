package com.whispermate.aidictation.ui.screens.onboarding

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.local.ParakeetModelAssets
import com.whispermate.aidictation.data.local.ParakeetRuntime
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.repository.TranscriptionRepository
import com.whispermate.aidictation.service.AndroidAudioAttemptOwner
import com.whispermate.aidictation.service.AndroidAudioProcessingCoordinator
import com.whispermate.aidictation.service.ExclusiveRequestFence
import com.whispermate.aidictation.domain.model.WhisperLanguages
import com.whispermate.aidictation.domain.model.AudioAttemptLease
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import com.whispermate.aidictation.data.repository.SubscriptionRepository
import com.whispermate.aidictation.domain.model.UsageStatus
import com.whispermate.aidictation.domain.model.PaymentPlan
import android.content.Context
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import dagger.hilt.android.qualifiers.ApplicationContext

data class OnboardingOnDeviceModelState(
    val isInstalled: Boolean = false,
    val isDownloading: Boolean = false,
    val downloadProgress: Float? = null,
    val errorMessage: String? = null
)

data class OnboardingDemoUiState(
    val isRecording: Boolean = false,
    val isProcessing: Boolean = false,
    val resultText: String? = null,
    val errorMessage: String? = null,
    val audioLevel: Float = 0f,
    val frequencyBands: FloatArray = FloatArray(6)
)

@HiltViewModel
class OnboardingViewModel @Inject constructor(
    private val appPreferences: AppPreferences,
    private val parakeetModelAssets: ParakeetModelAssets,
    private val transcriptionRepository: TranscriptionRepository,
    private val audioProcessingCoordinator: AndroidAudioProcessingCoordinator,
    private val subscriptionRepository: SubscriptionRepository,
    @ApplicationContext private val appContext: Context
) : ViewModel() {

    /** Account state for the closing sign-in step. */
    val usageStatus: StateFlow<UsageStatus> = subscriptionRepository.usageStatus

    val isGoogleSignInConfigured: Boolean
        get() = subscriptionRepository.isGoogleSignInConfigured()

    val hasPaymentLinks: Boolean
        get() = subscriptionRepository.hasPaymentLinks()

    /** Opens Stripe checkout for [plan] in the browser; the user comes back to finish onboarding. */
    fun openUpgrade(plan: PaymentPlan) {
        subscriptionRepository.openUpgrade(plan)
    }

    private val _isSigningIn = MutableStateFlow(false)
    val isSigningIn: StateFlow<Boolean> = _isSigningIn.asStateFlow()

    /** [activityContext] must be an Activity: the Google account picker is shown from it. */
    fun signInWithGoogle(activityContext: Context) {
        if (_isSigningIn.value) return
        viewModelScope.launch {
            _isSigningIn.value = true
            try {
                subscriptionRepository.signInWithGoogle(activityContext)
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    private companion object {
        const val TAG = "OnboardingViewModel"
    }

    private val parakeetRuntime = ParakeetRuntime.fromConfig(BuildConfig.PARAKEET_RUNTIME)
    private var onDeviceSetupRequestId = 0
    private val demoFence = ExclusiveRequestFence()
    private var demoCaptureLease: AudioAttemptLease? = null

    val hasCompletedOnboarding: StateFlow<Boolean> = appPreferences.hasCompletedOnboarding
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    val onDeviceTranscriptionEnabled: StateFlow<Boolean> = appPreferences.onDeviceTranscriptionEnabled
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    val selectedLanguages: StateFlow<List<String>> = appPreferences.selectedLanguages
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _onDeviceModelState = MutableStateFlow(OnboardingOnDeviceModelState())
    val onDeviceModelState: StateFlow<OnboardingOnDeviceModelState> = _onDeviceModelState.asStateFlow()

    init {
        preselectDeviceLanguages()
    }

    /**
     * First run: start the language step with the phone's own languages ticked, so most
     * people can just continue. Only fills an empty choice, and only before onboarding is
     * done, so a deliberate empty selection later is left alone.
     */
    private fun preselectDeviceLanguages() {
        viewModelScope.launch {
            if (appPreferences.hasCompletedOnboarding.first()) return@launch
            if (appPreferences.selectedLanguages.first().isNotEmpty()) return@launch
            val locales = appContext.resources.configuration.locales
            val supported = OnboardingSupportedLanguageCodes.toSet()
            val fromDevice = (0 until locales.size())
                .map { locales.get(it).language.lowercase() }
                .filter { it in supported && WhisperLanguages.getLanguage(it) != null }
                .distinct()
            appPreferences.saveSelectedLanguages(fromDevice.ifEmpty { listOf("en") })
        }
    }

    private val _demoState = MutableStateFlow(OnboardingDemoUiState())
    val demoState: StateFlow<OnboardingDemoUiState> = _demoState.asStateFlow()

    init {
        refreshOnDeviceModelState()
        viewModelScope.launch {
            audioProcessingCoordinator.audioLevel.collect { level ->
                _demoState.value = _demoState.value.copy(audioLevel = level)
            }
        }
        viewModelScope.launch {
            audioProcessingCoordinator.frequencyBands.collect { bands ->
                _demoState.value = _demoState.value.copy(frequencyBands = bands)
            }
        }
        viewModelScope.launch {
            audioProcessingCoordinator.failureEvents.collect { event ->
                val token = demoFence.currentToken()
                if (event.matches(
                        AndroidAudioAttemptOwner.ONBOARDING,
                        demoCaptureLease,
                        token
                    ) &&
                    (_demoState.value.isRecording || _demoState.value.isProcessing)
                ) {
                    token ?: return@collect
                    if (demoFence.finish(token)) {
                        demoCaptureLease = null
                        _demoState.value = OnboardingDemoUiState(errorMessage = event.message)
                    }
                }
            }
        }
        viewModelScope.launch {
            audioProcessingCoordinator.shouldAutoStop.collect { shouldStop ->
                if (shouldStop && _demoState.value.isRecording) stopDemoRecording()
            }
        }
    }

    fun completeOnboarding() {
        viewModelScope.launch {
            appPreferences.setOnboardingCompleted(true)
        }
    }

    fun saveContextRulesFromOnboarding(enabledStates: List<Boolean>) {
        viewModelScope.launch {
            val defaultRules = AppPreferences.defaultContextRules
            val updatedRules = defaultRules.mapIndexed { index, rule ->
                rule.copy(isEnabled = enabledStates.getOrElse(index) { false })
            }
            appPreferences.saveContextRules(updatedRules)
        }
    }

    fun toggleLanguage(code: String) {
        if (WhisperLanguages.getLanguage(code) == null) return

        viewModelScope.launch {
            val current = appPreferences.selectedLanguages.first().toMutableList()
            if (current.contains(code)) {
                current.remove(code)
            } else {
                current.add(code)
            }
            appPreferences.saveSelectedLanguages(current)
        }
    }

    fun setOnDeviceTranscriptionEnabled(enabled: Boolean) {
        viewModelScope.launch {
            val requestId = ++onDeviceSetupRequestId
            if (!enabled) {
                appPreferences.setOnDeviceTranscriptionEnabled(false)
                _onDeviceModelState.value = _onDeviceModelState.value.copy(
                    isDownloading = false,
                    downloadProgress = null,
                    errorMessage = null
                )
                return@launch
            }

            if (_onDeviceModelState.value.isDownloading) return@launch

            try {
                _onDeviceModelState.value = _onDeviceModelState.value.copy(
                    isDownloading = true,
                    downloadProgress = 0f,
                    errorMessage = null
                )
                withContext(Dispatchers.IO) {
                    parakeetModelAssets.ensureModelDirectory(parakeetRuntime) { progress ->
                        if (requestId != onDeviceSetupRequestId) return@ensureModelDirectory
                        _onDeviceModelState.value = _onDeviceModelState.value.copy(
                            isDownloading = true,
                            downloadProgress = progress.coerceIn(0f, 1f),
                            errorMessage = null
                        )
                    }
                }
                if (requestId != onDeviceSetupRequestId) return@launch
                appPreferences.setOnDeviceTranscriptionEnabled(true)
                _onDeviceModelState.value = OnboardingOnDeviceModelState(isInstalled = true)
                prewarmOnDeviceTranscriber()
            } catch (error: Throwable) {
                if (requestId != onDeviceSetupRequestId) return@launch
                Log.w(TAG, "Unable to enable on-device transcription during onboarding", error)
                appPreferences.setOnDeviceTranscriptionEnabled(false)
                _onDeviceModelState.value = OnboardingOnDeviceModelState(
                    isInstalled = withContext(Dispatchers.IO) {
                        parakeetModelAssets.isModelInstalled(parakeetRuntime)
                    },
                    errorMessage = error.message ?: "Offline transcription setup failed"
                )
            }
        }
    }

    fun startDemoRecording() {
        if (_demoState.value.isRecording || _demoState.value.isProcessing) return
        val token = demoFence.reserve() ?: return
        _demoState.value = OnboardingDemoUiState(isProcessing = true)
        viewModelScope.launch {
            val result = audioProcessingCoordinator.startCapture(
                owner = AndroidAudioAttemptOwner.ONBOARDING,
                workflowToken = token,
                autoStopOnSilence = false
            )
            if (!demoFence.owns(token)) {
                result.getOrNull()?.let { staleLease ->
                    audioProcessingCoordinator.cancelCapture(
                        AndroidAudioAttemptOwner.ONBOARDING,
                        "Onboarding demo was cancelled before recording started",
                        expectedLease = staleLease,
                        expectedWorkflowToken = token
                    )
                }
                return@launch
            }
            val lease = result.getOrElse {
                demoFence.finish(token)
                demoCaptureLease = null
                _demoState.value = OnboardingDemoUiState(
                    errorMessage = "The microphone could not start. Try again."
                )
                return@launch
            }
            demoCaptureLease = lease
            val captureIsCurrent = audioProcessingCoordinator.isCaptureCurrent(
                AndroidAudioAttemptOwner.ONBOARDING,
                lease
            )
            if (!captureIsCurrent || !demoFence.owns(token)) {
                if (captureIsCurrent) {
                    audioProcessingCoordinator.cancelCapture(
                        AndroidAudioAttemptOwner.ONBOARDING,
                        "Onboarding demo was replaced before its UI became active",
                        expectedLease = lease,
                        expectedWorkflowToken = token
                    )
                }
                if (demoFence.finish(token)) _demoState.value = OnboardingDemoUiState()
                demoCaptureLease = null
                return@launch
            }
            _demoState.value = OnboardingDemoUiState(isRecording = true)
        }
    }

    fun stopDemoRecording() {
        if (!_demoState.value.isRecording) return
        val token = demoFence.currentToken() ?: return
        if (!demoFence.beginTerminal(token)) return
        _demoState.value = _demoState.value.copy(isRecording = false, isProcessing = true)
        viewModelScope.launch {
            val finalized = audioProcessingCoordinator.stopCapture(AndroidAudioAttemptOwner.ONBOARDING).getOrElse {
                if (demoFence.finish(token)) {
                    demoCaptureLease = null
                    _demoState.value = OnboardingDemoUiState(
                        errorMessage = "The recording could not be finalized. Its recoverable audio was kept."
                    )
                }
                return@launch
            }
            demoCaptureLease = finalized.lease
            if (!demoFence.owns(token)) return@launch
            if (finalized.durationMs < 300 || !finalized.speechDetected) {
                audioProcessingCoordinator.failBeforeRecognition(
                    finalized,
                    "No speech was heard. The saved audio is available in History."
                )
                if (demoFence.finish(token)) {
                    demoCaptureLease = null
                    _demoState.value = OnboardingDemoUiState(errorMessage = "Try speaking for a little longer.")
                }
                return@launch
            }
            val result = audioProcessingCoordinator.processRecognition(finalized)
            if (!demoFence.finish(token)) return@launch
            demoCaptureLease = null
            _demoState.value = result.fold(
                onSuccess = { processed ->
                    OnboardingDemoUiState(resultText = processed.text.ifBlank { "I did not catch that. Try again." })
                },
                onFailure = { error ->
                    OnboardingDemoUiState(errorMessage = error.message ?: "Transcription failed. Try again.")
                }
            )
        }
    }

    fun cancelDemoRecording() {
        val lease = demoCaptureLease
        val token = demoFence.currentToken()
        demoFence.cancelCurrent()
        demoCaptureLease = null
        _demoState.value = OnboardingDemoUiState()
        audioProcessingCoordinator.cancelCaptureFromLifecycle(
            AndroidAudioAttemptOwner.ONBOARDING,
            "Onboarding demo cancelled",
            expectedLease = lease,
            expectedWorkflowToken = token
        )
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
                    Log.w(TAG, "Unable to prewarm on-device transcription during onboarding", error)
                }
        }
    }

    override fun onCleared() {
        val lease = demoCaptureLease
        val token = demoFence.currentToken()
        demoFence.cancelCurrent()
        audioProcessingCoordinator.cancelCaptureFromLifecycle(
            AndroidAudioAttemptOwner.ONBOARDING,
            "Onboarding recording closed",
            expectedLease = lease,
            expectedWorkflowToken = token
        )
        super.onCleared()
    }
}
