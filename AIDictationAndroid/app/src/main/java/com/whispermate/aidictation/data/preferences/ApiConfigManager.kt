package com.whispermate.aidictation.data.preferences

import android.content.Context
import android.content.SharedPreferences
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.whispermate.aidictation.BuildConfig
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

enum class ApiProvider(val displayName: String) {
    OPENAI("OpenAI"),
    GROQ("Groq");

    fun transcriptionEndpoint(): String = when (this) {
        OPENAI -> "https://api.openai.com/v1/audio/transcriptions"
        GROQ -> "https://api.groq.com/openai/v1/audio/transcriptions"
    }

    fun llmEndpoint(): String = when (this) {
        OPENAI -> "https://api.openai.com/v1/chat/completions"
        GROQ -> "https://api.groq.com/openai/v1/chat/completions"
    }

    fun baseUrl(): String = when (this) {
        OPENAI -> "https://api.openai.com"
        GROQ -> "https://api.groq.com/openai"
    }
}

data class ApiConfig(
    val provider: ApiProvider,
    val apiKey: String,
    val model: String,
    val endpoint: String
)

private val Context.apiConfigDataStore: DataStore<Preferences> by preferencesDataStore(name = "api_config")

/// Manages runtime API configuration for transcription and post-processing.
/// Stores API keys in EncryptedSharedPreferences and provider/model selections in DataStore.
/// Exposes StateFlows for UI observation and synchronous getters for use by object clients.
@Singleton
class ApiConfigManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    // MARK: - Companion

    companion object {
        @Volatile
        var instance: ApiConfigManager? = null
            private set

        fun defaultTranscriptionModel(provider: ApiProvider): String = when (provider) {
            ApiProvider.OPENAI -> "whisper-1"
            ApiProvider.GROQ -> "whisper-large-v3-turbo"
        }

        fun defaultPostProcessingModel(provider: ApiProvider): String = when (provider) {
            ApiProvider.OPENAI -> "gpt-4o-mini"
            ApiProvider.GROQ -> "openai/gpt-oss-20b"
        }
    }

    // MARK: - Private Properties

    private object Keys {
        val TRANSCRIPTION_PROVIDER = stringPreferencesKey("transcription_provider")
        val TRANSCRIPTION_MODEL = stringPreferencesKey("transcription_model")
        val POSTPROCESSING_PROVIDER = stringPreferencesKey("postprocessing_provider")
        val POSTPROCESSING_MODEL = stringPreferencesKey("postprocessing_model")
    }

    private object SecureKeys {
        const val TRANSCRIPTION_API_KEY = "transcription_api_key"
        const val POSTPROCESSING_API_KEY = "postprocessing_api_key"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val securePrefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "secure_api_keys",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    // MARK: - Published Properties

    private val _transcriptionConfig = MutableStateFlow(buildDefaultTranscriptionConfig())
    val transcriptionConfigFlow: StateFlow<ApiConfig> = _transcriptionConfig.asStateFlow()

    private val _postProcessingConfig = MutableStateFlow(buildDefaultPostProcessingConfig())
    val postProcessingConfigFlow: StateFlow<ApiConfig> = _postProcessingConfig.asStateFlow()

    // MARK: - Initialization

    init {
        instance = this
        scope.launch {
            context.apiConfigDataStore.data.collect { prefs ->
                val provider = prefs[Keys.TRANSCRIPTION_PROVIDER]
                    ?.let { runCatching { ApiProvider.valueOf(it) }.getOrNull() }
                    ?: defaultTranscriptionProvider()
                val model = prefs[Keys.TRANSCRIPTION_MODEL]
                    ?: defaultTranscriptionModel(provider)
                val apiKey = runCatching {
                    securePrefs.getString(SecureKeys.TRANSCRIPTION_API_KEY, null)
                }.getOrNull() ?: BuildConfig.TRANSCRIPTION_API_KEY.ifEmpty { "" }
                _transcriptionConfig.value = ApiConfig(
                    provider = provider,
                    apiKey = apiKey,
                    model = model,
                    endpoint = provider.transcriptionEndpoint()
                )
            }
        }
        scope.launch {
            context.apiConfigDataStore.data.collect { prefs ->
                val provider = prefs[Keys.POSTPROCESSING_PROVIDER]
                    ?.let { runCatching { ApiProvider.valueOf(it) }.getOrNull() }
                    ?: defaultPostProcessingProvider()
                val model = prefs[Keys.POSTPROCESSING_MODEL]
                    ?: defaultPostProcessingModel(provider)
                val apiKey = runCatching {
                    securePrefs.getString(SecureKeys.POSTPROCESSING_API_KEY, null)
                }.getOrNull() ?: BuildConfig.GROQ_API_KEY.ifEmpty { "" }
                _postProcessingConfig.value = ApiConfig(
                    provider = provider,
                    apiKey = apiKey,
                    model = model,
                    endpoint = provider.llmEndpoint()
                )
            }
        }
    }

    // MARK: - Public API

    fun getTranscriptionConfig(): ApiConfig = _transcriptionConfig.value

    fun getPostProcessingConfig(): ApiConfig = _postProcessingConfig.value

    suspend fun setTranscriptionProvider(provider: ApiProvider) {
        context.apiConfigDataStore.edit { prefs ->
            prefs[Keys.TRANSCRIPTION_PROVIDER] = provider.name
            prefs[Keys.TRANSCRIPTION_MODEL] = defaultTranscriptionModel(provider)
        }
    }

    suspend fun setTranscriptionModel(model: String) {
        context.apiConfigDataStore.edit { prefs ->
            prefs[Keys.TRANSCRIPTION_MODEL] = model
        }
    }

    suspend fun setTranscriptionApiKey(key: String) {
        runCatching {
            securePrefs.edit().putString(SecureKeys.TRANSCRIPTION_API_KEY, key).apply()
        }
        _transcriptionConfig.value = _transcriptionConfig.value.copy(apiKey = key)
    }

    suspend fun setPostProcessingProvider(provider: ApiProvider) {
        context.apiConfigDataStore.edit { prefs ->
            prefs[Keys.POSTPROCESSING_PROVIDER] = provider.name
            prefs[Keys.POSTPROCESSING_MODEL] = defaultPostProcessingModel(provider)
        }
    }

    suspend fun setPostProcessingModel(model: String) {
        context.apiConfigDataStore.edit { prefs ->
            prefs[Keys.POSTPROCESSING_MODEL] = model
        }
    }

    suspend fun setPostProcessingApiKey(key: String) {
        runCatching {
            securePrefs.edit().putString(SecureKeys.POSTPROCESSING_API_KEY, key).apply()
        }
        _postProcessingConfig.value = _postProcessingConfig.value.copy(apiKey = key)
    }

    suspend fun resetToDefaults() {
        runCatching {
            securePrefs.edit()
                .remove(SecureKeys.TRANSCRIPTION_API_KEY)
                .remove(SecureKeys.POSTPROCESSING_API_KEY)
                .apply()
        }
        context.apiConfigDataStore.edit { prefs ->
            prefs.remove(Keys.TRANSCRIPTION_PROVIDER)
            prefs.remove(Keys.TRANSCRIPTION_MODEL)
            prefs.remove(Keys.POSTPROCESSING_PROVIDER)
            prefs.remove(Keys.POSTPROCESSING_MODEL)
        }
    }

    // MARK: - Private Methods

    private fun defaultTranscriptionProvider(): ApiProvider {
        return if (BuildConfig.TRANSCRIPTION_ENDPOINT.contains("groq")) ApiProvider.GROQ else ApiProvider.OPENAI
    }

    private fun defaultPostProcessingProvider(): ApiProvider {
        return if (BuildConfig.GROQ_ENDPOINT.contains("groq")) ApiProvider.GROQ else ApiProvider.OPENAI
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
            apiKey = BuildConfig.GROQ_API_KEY,
            model = BuildConfig.GROQ_MODEL.ifEmpty { defaultPostProcessingModel(provider) },
            endpoint = BuildConfig.GROQ_ENDPOINT.ifEmpty { provider.llmEndpoint() }
        )
    }
}
