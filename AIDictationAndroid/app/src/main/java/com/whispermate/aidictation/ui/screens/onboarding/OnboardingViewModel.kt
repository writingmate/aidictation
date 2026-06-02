package com.whispermate.aidictation.ui.screens.onboarding

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.local.ParakeetModelAssets
import com.whispermate.aidictation.data.local.ParakeetRuntime
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.repository.TranscriptionRepository
import com.whispermate.aidictation.domain.model.WhisperLanguages
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject

data class OnboardingOnDeviceModelState(
    val isInstalled: Boolean = false,
    val isDownloading: Boolean = false,
    val downloadProgress: Float? = null,
    val errorMessage: String? = null
)

data class OnboardingDemoUiState(
    val isProcessing: Boolean = false,
    val resultText: String? = null,
    val errorMessage: String? = null
)

@HiltViewModel
class OnboardingViewModel @Inject constructor(
    private val appPreferences: AppPreferences,
    private val parakeetModelAssets: ParakeetModelAssets,
    private val transcriptionRepository: TranscriptionRepository
) : ViewModel() {
    private companion object {
        const val TAG = "OnboardingViewModel"
    }

    private val parakeetRuntime = ParakeetRuntime.fromConfig(BuildConfig.PARAKEET_RUNTIME)
    private var onDeviceSetupRequestId = 0

    val hasCompletedOnboarding: StateFlow<Boolean> = appPreferences.hasCompletedOnboarding
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    val onDeviceTranscriptionEnabled: StateFlow<Boolean> = appPreferences.onDeviceTranscriptionEnabled
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    val selectedLanguages: StateFlow<List<String>> = appPreferences.selectedLanguages
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _onDeviceModelState = MutableStateFlow(OnboardingOnDeviceModelState())
    val onDeviceModelState: StateFlow<OnboardingOnDeviceModelState> = _onDeviceModelState.asStateFlow()

    private val _demoState = MutableStateFlow(OnboardingDemoUiState())
    val demoState: StateFlow<OnboardingDemoUiState> = _demoState.asStateFlow()

    init {
        refreshOnDeviceModelState()
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

    fun transcribeDemo(audioFile: File?, durationMs: Long) {
        if (audioFile == null || durationMs < 300) {
            _demoState.value = OnboardingDemoUiState(errorMessage = "Try speaking for a little longer.")
            return
        }

        viewModelScope.launch {
            _demoState.value = OnboardingDemoUiState(isProcessing = true)
            val prompt = transcriptionRepository.buildPrompt()
            val result = transcriptionRepository.transcribe(audioFile, prompt.ifEmpty { null })
            audioFile.delete()
            _demoState.value = result.fold(
                onSuccess = { text ->
                    OnboardingDemoUiState(resultText = text.ifBlank { "I did not catch that. Try again." })
                },
                onFailure = { error ->
                    OnboardingDemoUiState(errorMessage = error.message ?: "Transcription failed. Try again.")
                }
            )
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
                    Log.w(TAG, "Unable to prewarm on-device transcription during onboarding", error)
                }
        }
    }
}
