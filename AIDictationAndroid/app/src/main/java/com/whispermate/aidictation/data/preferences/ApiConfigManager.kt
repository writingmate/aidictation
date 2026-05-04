package com.whispermate.aidictation.data.preferences

import com.whispermate.aidictation.BuildConfig
import javax.inject.Inject
import javax.inject.Singleton

enum class ApiProvider {
    PARAKEET,
    WRITINGMATE,
    OPENAI,
    GROQ;

    fun transcriptionEndpoint(): String = when (this) {
        PARAKEET -> ""
        WRITINGMATE -> "https://writingmate.ai/api/openai/v1/audio/transcriptions"
        OPENAI -> "https://api.openai.com/v1/audio/transcriptions"
        GROQ -> "https://api.groq.com/openai/v1/audio/transcriptions"
    }

    fun llmEndpoint(): String = when (this) {
        PARAKEET -> ""
        WRITINGMATE -> "https://writingmate.ai/api/openai/v1/chat/completions"
        OPENAI -> "https://api.openai.com/v1/chat/completions"
        GROQ -> "https://api.groq.com/openai/v1/chat/completions"
    }
}

data class ApiConfig(
    val provider: ApiProvider,
    val apiKey: String,
    val model: String,
    val endpoint: String
)

// Runtime API configuration mirrors the macOS bundled AIDictation provider.
// Android no longer exposes provider/model/key editing, so stale local UI
// preferences cannot change which transcription endpoint or model is used.
@Singleton
class ApiConfigManager @Inject constructor() {
    companion object {
        @Volatile
        var instance: ApiConfigManager? = null
            private set

        fun defaultTranscriptionModel(provider: ApiProvider): String = when (provider) {
            ApiProvider.PARAKEET -> "parakeet-tdt-0.6b"
            ApiProvider.WRITINGMATE -> "groq/whisper-large-v3-turbo"
            ApiProvider.OPENAI -> "whisper-1"
            ApiProvider.GROQ -> "whisper-large-v3-turbo"
        }

        fun defaultPostProcessingModel(): String = "openai/gpt-oss-20b"
    }

    private val transcriptionConfig = buildDefaultTranscriptionConfig()
    private val postProcessingConfig = buildDefaultPostProcessingConfig()

    init {
        instance = this
    }

    fun getTranscriptionConfig(): ApiConfig = transcriptionConfig

    fun getPostProcessingConfig(): ApiConfig = postProcessingConfig

    private fun defaultTranscriptionProvider(): ApiProvider {
        val endpoint = BuildConfig.TRANSCRIPTION_ENDPOINT
        return when {
            endpoint.contains("writingmate", ignoreCase = true) -> ApiProvider.WRITINGMATE
            endpoint.contains("groq", ignoreCase = true) -> ApiProvider.GROQ
            endpoint.contains("openai", ignoreCase = true) -> ApiProvider.OPENAI
            else -> ApiProvider.WRITINGMATE
        }
    }

    private fun defaultPostProcessingProvider(): ApiProvider {
        val endpoint = BuildConfig.AIDICTATION_POST_PROCESSING_ENDPOINT
        return when {
            endpoint.contains("writingmate", ignoreCase = true) -> ApiProvider.WRITINGMATE
            endpoint.contains("groq", ignoreCase = true) -> ApiProvider.GROQ
            endpoint.contains("openai", ignoreCase = true) -> ApiProvider.OPENAI
            else -> ApiProvider.WRITINGMATE
        }
    }

    private fun buildDefaultTranscriptionConfig(): ApiConfig {
        val provider = defaultTranscriptionProvider()
        return ApiConfig(
            provider = provider,
            apiKey = BuildConfig.TRANSCRIPTION_API_KEY,
            model = BuildConfig.TRANSCRIPTION_MODEL.ifEmpty { defaultTranscriptionModel(provider) },
            endpoint = BuildConfig.TRANSCRIPTION_ENDPOINT.ifEmpty { provider.transcriptionEndpoint() }
        )
    }

    private fun buildDefaultPostProcessingConfig(): ApiConfig {
        val provider = defaultPostProcessingProvider()
        return ApiConfig(
            provider = provider,
            apiKey = BuildConfig.AIDICTATION_POST_PROCESSING_KEY,
            model = BuildConfig.AIDICTATION_POST_PROCESSING_MODEL.ifEmpty { defaultPostProcessingModel() },
            endpoint = BuildConfig.AIDICTATION_POST_PROCESSING_ENDPOINT.ifEmpty { provider.llmEndpoint() }
        )
    }
}
