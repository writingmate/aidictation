package com.whispermate.aidictation.data.remote

import android.util.Log
import com.whispermate.aidictation.data.preferences.ApiProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/// Fetches available model IDs from an OpenAI-compatible /v1/models endpoint.
/// Falls back to hardcoded model lists if the fetch fails or the API key is empty.
object ModelListClient {
    private const val TAG = "ModelListClient"

    private val okHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .build()
    }

    // MARK: - Fallback lists

    private val transcriptionFallbacks = mapOf(
        ApiProvider.WRITINGMATE to listOf("gpt-4o-transcribe", "whisper-1"),
        ApiProvider.OPENAI to listOf("whisper-1"),
        ApiProvider.GROQ to listOf("whisper-large-v3-turbo", "whisper-large-v3", "distil-whisper-large-v3-en")
    )

    private val postProcessingFallbacks = mapOf(
        ApiProvider.WRITINGMATE to listOf("gpt-4o-mini", "gpt-4o", "gpt-4.1-nano", "gpt-4.1-mini", "gpt-4.1"),
        ApiProvider.OPENAI to listOf("gpt-4o-mini", "gpt-4o", "gpt-4.1-nano", "gpt-4.1-mini", "gpt-4.1"),
        ApiProvider.GROQ to listOf(
            "openai/gpt-oss-20b",
            "llama-3.3-70b-versatile",
            "llama-3.1-8b-instant",
            "mixtral-8x7b-32768"
        )
    )

    // MARK: - Public API

    suspend fun fetchTranscriptionModels(provider: ApiProvider, apiKey: String): List<String> =
        withContext(Dispatchers.IO) {
            if (apiKey.isEmpty()) return@withContext transcriptionFallbacks[provider] ?: emptyList()
            fetchModels(provider.baseUrl(), apiKey)
                .filter { isTranscriptionModel(it) }
                .takeIf { it.isNotEmpty() }
                ?: transcriptionFallbacks[provider]
                ?: emptyList()
        }

    suspend fun fetchPostProcessingModels(provider: ApiProvider, apiKey: String): List<String> =
        withContext(Dispatchers.IO) {
            if (apiKey.isEmpty()) return@withContext postProcessingFallbacks[provider] ?: emptyList()
            fetchModels(provider.baseUrl(), apiKey)
                .filter { isPostProcessingModel(it) }
                .takeIf { it.isNotEmpty() }
                ?: postProcessingFallbacks[provider]
                ?: emptyList()
        }

    // MARK: - Private Methods

    private fun fetchModels(baseUrl: String, apiKey: String): List<String> {
        return try {
            val request = Request.Builder()
                .url("$baseUrl/v1/models")
                .addHeader("Authorization", "Bearer $apiKey")
                .get()
                .build()

            val response = okHttpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                Log.w(TAG, "Model list fetch failed: ${response.code}")
                return emptyList()
            }

            val body = response.body?.string() ?: return emptyList()
            val json = JSONObject(body)
            val data = json.getJSONArray("data")
            (0 until data.length()).map { data.getJSONObject(it).getString("id") }
        } catch (e: Exception) {
            Log.w(TAG, "Model list fetch exception", e)
            emptyList()
        }
    }

    private fun isTranscriptionModel(modelId: String): Boolean {
        val lower = modelId.lowercase()
        return lower.contains("whisper")
    }

    private fun isPostProcessingModel(modelId: String): Boolean {
        val lower = modelId.lowercase()
        return !lower.contains("whisper") &&
            !lower.contains("embedding") &&
            !lower.contains("tts") &&
            !lower.contains("dall-e") &&
            !lower.contains("moderation") &&
            !lower.contains("babbage") &&
            !lower.contains("davinci") &&
            !lower.contains("ada")
    }
}
