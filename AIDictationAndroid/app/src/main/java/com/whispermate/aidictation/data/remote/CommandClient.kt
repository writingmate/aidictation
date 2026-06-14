package com.whispermate.aidictation.data.remote

import android.util.Log
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import com.whispermate.aidictation.domain.model.Command
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Client for executing text transformation commands via LLM.
 * Used for button-triggered commands (voice commands are handled in TranscriptionClient).
 */
object CommandClient {
    private const val TAG = "CommandClient"

    private val okHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .build()
    }

    /**
     * Execute a command on the given text.
     *
     * @param command The command to execute
     * @param targetText The text to transform
     * @param context Optional context (text before the target)
     * @param additionalInstructions Optional additional instructions (e.g., from context rules)
     * @return The transformed text
     */
    suspend fun execute(
        command: Command,
        targetText: String,
        context: String = "",
        additionalInstructions: String? = null
    ): Result<String> = withContext(Dispatchers.IO) {
        try {
            val apiConfig = ApiConfigManager.instance?.getPostProcessingConfig()
            val apiKey = apiConfig?.apiKey ?: BuildConfig.AIDICTATION_POST_PROCESSING_KEY
            val endpoint = apiConfig?.endpoint ?: BuildConfig.AIDICTATION_POST_PROCESSING_ENDPOINT
            val model = apiConfig?.model ?: BuildConfig.AIDICTATION_POST_PROCESSING_MODEL
            if (apiKey.isEmpty()) {
                return@withContext Result.failure(Exception("Post-processing API key not configured"))
            }

            if (targetText.isBlank()) {
                return@withContext Result.success(targetText)
            }

            // Build system prompt with optional additional instructions
            val systemPrompt = buildString {
                append(command.systemPrompt)
                append("\n\nReturn ONLY the transformed text, nothing else.")
                if (!additionalInstructions.isNullOrEmpty()) {
                    append("\n\nAdditional instructions: ")
                    append(additionalInstructions)
                }
            }

            val userContent = if (context.isNotBlank()) {
                "Context before: \"$context\"\n\nText to transform: \"$targetText\""
            } else {
                "Text to transform: \"$targetText\""
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
                        put("content", userContent)
                    })
                })
                put("max_tokens", 2000)
                put("temperature", 0.3)
                put("reasoning_effort", "low")
            }

            Log.d(TAG, "Executing command")

            val request = Request.Builder()
                .url(endpoint)
                .addHeader("Authorization", "Bearer $apiKey")
                .addHeader("Content-Type", "application/json")
                .post(requestJson.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val response = okHttpClient.newCall(request).execute()

            if (!response.isSuccessful) {
                Log.e(TAG, "Command request failed: ${response.code}")
                return@withContext Result.failure(Exception("Command request failed: ${response.code}"))
            }

            val responseBody = response.body?.string() ?: "{}"
            val json = JSONObject(responseBody)
            val message = json
                .getJSONArray("choices")
                .getJSONObject(0)
                .getJSONObject("message")

            val content = message.getString("content").trim()

            Log.d(TAG, "Command completed")
            Result.success(content)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to execute command", e)
            Result.failure(e)
        }
    }

    /**
     * Execute a free-form voice instruction on the given text.
     * This allows the user to say any instruction, not just predefined commands.
     *
     * @param instruction The voice instruction (e.g., "make it more formal", "translate to Spanish")
     * @param targetText The text to transform
     * @param context Optional context (text before the target)
     * @param additionalInstructions Optional additional instructions (e.g., from context rules)
     * @return The transformed text
     */
    suspend fun executeInstruction(
        instruction: String,
        targetText: String,
        context: String = "",
        additionalInstructions: String? = null
    ): Result<String> = withContext(Dispatchers.IO) {
        try {
            val apiConfig = ApiConfigManager.instance?.getPostProcessingConfig()
            val apiKey = apiConfig?.apiKey ?: BuildConfig.AIDICTATION_POST_PROCESSING_KEY
            val endpoint = apiConfig?.endpoint ?: BuildConfig.AIDICTATION_POST_PROCESSING_ENDPOINT
            val model = apiConfig?.model ?: BuildConfig.AIDICTATION_POST_PROCESSING_MODEL
            if (apiKey.isEmpty()) {
                return@withContext Result.failure(Exception("Post-processing API key not configured"))
            }

            if (targetText.isBlank()) {
                return@withContext Result.success(targetText)
            }

            // Build system prompt for free-form instruction
            val systemPrompt = buildString {
                append("You are a text transformation assistant. ")
                append("Apply the user's instruction to transform the given text. ")
                append("Return ONLY the transformed text, nothing else. ")
                append("Do not add explanations, quotes, or formatting - just the transformed text.")
                if (!additionalInstructions.isNullOrEmpty()) {
                    append("\n\nAdditional context: ")
                    append(additionalInstructions)
                }
            }

            val userContent = buildString {
                append("Instruction: $instruction\n\n")
                if (context.isNotBlank()) {
                    append("Context before: \"$context\"\n\n")
                }
                append("Text to transform: \"$targetText\"")
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
                        put("content", userContent)
                    })
                })
                put("max_tokens", 2000)
                put("temperature", 0.3)
                put("reasoning_effort", "low")
            }

            Log.d(TAG, "Executing instruction")

            val request = Request.Builder()
                .url(endpoint)
                .addHeader("Authorization", "Bearer $apiKey")
                .addHeader("Content-Type", "application/json")
                .post(requestJson.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val response = okHttpClient.newCall(request).execute()

            if (!response.isSuccessful) {
                Log.e(TAG, "Instruction request failed: ${response.code}")
                return@withContext Result.failure(Exception("Instruction request failed: ${response.code}"))
            }

            val responseBody = response.body?.string() ?: "{}"
            val json = JSONObject(responseBody)
            val message = json
                .getJSONArray("choices")
                .getJSONObject(0)
                .getJSONObject("message")

            val content = message.getString("content").trim()

            Log.d(TAG, "Instruction completed")
            Result.success(content)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to execute instruction", e)
            Result.failure(e)
        }
    }
}
