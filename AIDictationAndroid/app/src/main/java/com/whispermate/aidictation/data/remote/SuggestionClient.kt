package com.whispermate.aidictation.data.remote

import android.util.Log
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

object SuggestionClient {
    private const val TAG = "SuggestionClient"

    private val okHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .writeTimeout(5, TimeUnit.SECONDS)
            .build()
    }

    private val systemPrompt = """You are a keyboard autocomplete assistant. The user is typing a word. Complete it.

Return exactly 3 likely next words

Example:
Input: Hello, how are y
Output: you, your, ya"""

    suspend fun getSuggestions(text: String, isCompletingWord: Boolean): Result<List<String>> = withContext(Dispatchers.IO) {
        try {
            val config = ApiConfigManager.instance?.getPostProcessingConfig()
            val apiKey = config?.apiKey ?: BuildConfig.AIDICTATION_POST_PROCESSING_KEY
            val endpoint = config?.endpoint ?: BuildConfig.AIDICTATION_POST_PROCESSING_ENDPOINT
            val model = config?.model ?: BuildConfig.AIDICTATION_POST_PROCESSING_MODEL
            if (apiKey.isEmpty()) {
                return@withContext Result.failure(Exception("Post-processing API key not configured"))
            }

            if (text.isBlank()) {
                return@withContext Result.success(emptyList())
            }

            val requestJson = JSONObject().apply {
                put("model", model)
                put("messages", JSONArray().apply {
                    put(JSONObject().apply {
                        put("role", "system")
                        put("content", systemPrompt)
                    })
                    put(JSONObject().apply {
                        put("role", "user")
                        put("content", text)
                    })
                })
                put("max_tokens", 1000)
                put("temperature", 0.3)
                put("include_reasoning", false)
                put("reasoning_effort", "low")
            }

            val request = Request.Builder()
                .url(endpoint)
                .addHeader("Authorization", "Bearer $apiKey")
                .addHeader("Content-Type", "application/json")
                .post(requestJson.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val response = okHttpClient.newCall(request).execute()

            if (!response.isSuccessful) {
                val errorBody = response.body?.string() ?: "Unknown error"
                Log.e(TAG, "Suggestion request failed: ${response.code} - $errorBody")
                return@withContext Result.failure(Exception("Suggestion request failed: ${response.code}"))
            }

            val responseBody = response.body?.string() ?: "{}"
            Log.d(TAG, "Raw response: $responseBody")
            val json = JSONObject(responseBody)
            val message = json
                .getJSONArray("choices")
                .getJSONObject(0)
                .getJSONObject("message")

            // Some models use "reasoning" field instead of "content"
            val content = if (message.has("reasoning") && message.optString("content").isEmpty()) {
                message.getString("reasoning").trim()
            } else {
                message.getString("content").trim()
            }

            // Parse comma-separated or newline-separated suggestions
            val suggestions = content
                .split(",", "\n")
                .map { it.trim() }
                .filter { it.isNotBlank() }
                .take(3)

            Log.d(TAG, "Got suggestions: $suggestions from content: $content")
            Result.success(suggestions)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get suggestions", e)
            Result.failure(e)
        }
    }
}
