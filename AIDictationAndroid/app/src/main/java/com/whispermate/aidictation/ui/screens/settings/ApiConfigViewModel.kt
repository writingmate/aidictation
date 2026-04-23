package com.whispermate.aidictation.ui.screens.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import com.whispermate.aidictation.data.preferences.ApiProvider
import com.whispermate.aidictation.data.remote.ModelListClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ApiConfigUiState(
    val transcriptionProvider: ApiProvider = ApiProvider.WRITINGMATE,
    val transcriptionApiKey: String = "",
    val transcriptionModel: String = "",
    val transcriptionModels: List<String> = emptyList(),
    val isLoadingTranscriptionModels: Boolean = false,
    val postProcessingProvider: ApiProvider = ApiProvider.GROQ,
    val postProcessingApiKey: String = "",
    val postProcessingModel: String = "",
    val postProcessingModels: List<String> = emptyList(),
    val isLoadingPostProcessingModels: Boolean = false
)

@HiltViewModel
class ApiConfigViewModel @Inject constructor(
    private val apiConfigManager: ApiConfigManager
) : ViewModel() {

    // MARK: - Published Properties

    private val _uiState = MutableStateFlow(ApiConfigUiState())
    val uiState: StateFlow<ApiConfigUiState> = _uiState.asStateFlow()

    // MARK: - Initialization

    init {
        val transcription = apiConfigManager.getTranscriptionConfig()
        val postProcessing = apiConfigManager.getPostProcessingConfig()
        _uiState.value = ApiConfigUiState(
            transcriptionProvider = transcription.provider,
            transcriptionApiKey = transcription.apiKey,
            transcriptionModel = transcription.model,
            postProcessingProvider = postProcessing.provider,
            postProcessingApiKey = postProcessing.apiKey,
            postProcessingModel = postProcessing.model
        )
        fetchTranscriptionModels(transcription.provider, transcription.apiKey)
        fetchPostProcessingModels(postProcessing.provider, postProcessing.apiKey)
    }

    // MARK: - Public API

    fun setTranscriptionProvider(provider: ApiProvider) {
        _uiState.update { it.copy(transcriptionProvider = provider) }
        viewModelScope.launch { apiConfigManager.setTranscriptionProvider(provider) }
        fetchTranscriptionModels(provider, _uiState.value.transcriptionApiKey)
    }

    fun setTranscriptionApiKey(key: String) {
        _uiState.update { it.copy(transcriptionApiKey = key) }
        viewModelScope.launch { apiConfigManager.setTranscriptionApiKey(key) }
    }

    fun setTranscriptionModel(model: String) {
        _uiState.update { it.copy(transcriptionModel = model) }
        viewModelScope.launch { apiConfigManager.setTranscriptionModel(model) }
    }

    fun setPostProcessingProvider(provider: ApiProvider) {
        _uiState.update { it.copy(postProcessingProvider = provider) }
        viewModelScope.launch { apiConfigManager.setPostProcessingProvider(provider) }
        fetchPostProcessingModels(provider, _uiState.value.postProcessingApiKey)
    }

    fun setPostProcessingApiKey(key: String) {
        _uiState.update { it.copy(postProcessingApiKey = key) }
        viewModelScope.launch { apiConfigManager.setPostProcessingApiKey(key) }
    }

    fun setPostProcessingModel(model: String) {
        _uiState.update { it.copy(postProcessingModel = model) }
        viewModelScope.launch { apiConfigManager.setPostProcessingModel(model) }
    }

    fun resetToDefaults() {
        viewModelScope.launch {
            apiConfigManager.resetToDefaults()
            val transcription = apiConfigManager.getTranscriptionConfig()
            val postProcessing = apiConfigManager.getPostProcessingConfig()
            _uiState.update {
                it.copy(
                    transcriptionProvider = transcription.provider,
                    transcriptionApiKey = transcription.apiKey,
                    transcriptionModel = transcription.model,
                    postProcessingProvider = postProcessing.provider,
                    postProcessingApiKey = postProcessing.apiKey,
                    postProcessingModel = postProcessing.model
                )
            }
        }
    }

    // MARK: - Private Methods

    private fun fetchTranscriptionModels(provider: ApiProvider, apiKey: String) {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingTranscriptionModels = true) }
            val models = ModelListClient.fetchTranscriptionModels(provider, apiKey)
            _uiState.update { state ->
                val currentModel = state.transcriptionModel
                val resolvedModel = if (currentModel in models) currentModel
                    else models.firstOrNull() ?: currentModel
                state.copy(
                    transcriptionModels = models,
                    transcriptionModel = resolvedModel,
                    isLoadingTranscriptionModels = false
                )
            }
        }
    }

    private fun fetchPostProcessingModels(provider: ApiProvider, apiKey: String) {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingPostProcessingModels = true) }
            val models = ModelListClient.fetchPostProcessingModels(provider, apiKey)
            _uiState.update { state ->
                val currentModel = state.postProcessingModel
                val resolvedModel = if (currentModel in models) currentModel
                    else models.firstOrNull() ?: currentModel
                state.copy(
                    postProcessingModels = models,
                    postProcessingModel = resolvedModel,
                    isLoadingPostProcessingModels = false
                )
            }
        }
    }
}
