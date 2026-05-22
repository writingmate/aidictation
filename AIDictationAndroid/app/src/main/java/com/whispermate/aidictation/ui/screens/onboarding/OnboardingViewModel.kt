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
import javax.inject.Inject

data class OnboardingOnDeviceModelState(
    val isInstalled: Boolean = false,
    val isDownloading: Boolean = false,
    val downloadProgress: Float? = null,
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

    val hasCompletedOnboarding: StateFlow<Boolean> = appPreferences.hasCompletedOnboarding
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    val onDeviceTranscriptionEnabled: StateFlow<Boolean> = appPreferences.onDeviceTranscriptionEnabled
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    val selectedLanguages: StateFlow<List<String>> = appPreferences.selectedLanguages
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _onDeviceModelState = MutableStateFlow(OnboardingOnDeviceModelState())
    val onDeviceModelState: StateFlow<OnboardingOnDeviceModelState> = _onDeviceModelState.asStateFlow()

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
            if (!enabled) {
                appPreferences.setOnDeviceTranscriptionEnabled(false)
                refreshOnDeviceModelState()
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
                        _onDeviceModelState.value = _onDeviceModelState.value.copy(
                            isDownloading = true,
                            downloadProgress = progress.coerceIn(0f, 1f),
                            errorMessage = null
                        )
                    }
                }
                appPreferences.setOnDeviceTranscriptionEnabled(true)
                _onDeviceModelState.value = OnboardingOnDeviceModelState(isInstalled = true)
                prewarmOnDeviceTranscriber()
            } catch (error: Throwable) {
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
