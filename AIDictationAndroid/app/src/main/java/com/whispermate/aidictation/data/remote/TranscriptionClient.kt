package com.whispermate.aidictation.data.remote

import android.util.Log
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import com.whispermate.aidictation.domain.model.Command
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Result of transcription that may include command execution.
 * @param text The final text to insert/replace
 * @param executedCommand The command ID if a voice command was detected and executed, null otherwise
 * @param originalTranscription The raw transcription before command processing
 */
data class TranscriptionResult(
    val text: String,
    val executedCommand: String? = null,
    val originalTranscription: String = text
)

object TranscriptionClient {
    private const val TAG = "TranscriptionClient"

    private val okHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .build()
    }

    suspend fun transcribe(
        audioFile: File,
        prompt: String? = null,
        language: String? = null,
        sttPrompt: String? = null,
        postProcessingPrompt: String? = null
    ): Result<String> = withContext(Dispatchers.IO) {
        try {
            val config = ApiConfigManager.instance?.getTranscriptionConfig()
            val apiKey = config?.apiKey ?: BuildConfig.TRANSCRIPTION_API_KEY
            val endpoint = config?.endpoint ?: BuildConfig.TRANSCRIPTION_ENDPOINT
            val model = config?.model ?: BuildConfig.TRANSCRIPTION_MODEL
            Log.d(TAG, "Transcribing file: ${audioFile.absolutePath}, size: ${audioFile.length()} bytes")
            Log.d(TAG, "Endpoint: $endpoint")
            Log.d(TAG, "Model: $model")
            Log.d(
                TAG,
                "Language: ${language ?: "auto-detect"}, promptLength: ${prompt?.length ?: 0}, " +
                    "sttPromptLength: ${sttPrompt?.length ?: 0}, " +
                    "postProcessingPromptLength: ${postProcessingPrompt?.length ?: 0}"
            )

            if (apiKey.isEmpty()) {
                Log.e(TAG, "API key is empty!")
                return@withContext Result.failure(Exception("API key not configured"))
            }

            val primary = executeTranscriptionRequest(
                audioFile = audioFile,
                prompt = prompt,
                language = language,
                sttPrompt = sttPrompt,
                postProcessingPrompt = postProcessingPrompt,
                endpoint = endpoint,
                apiKey = apiKey,
                model = model
            )

            primary
        } catch (e: Exception) {
            Log.e(TAG, "Transcription exception", e)
            Result.failure(e)
        }
    }

    private fun executeTranscriptionRequest(
        audioFile: File,
        prompt: String?,
        language: String?,
        sttPrompt: String?,
        postProcessingPrompt: String?,
        endpoint: String,
        apiKey: String,
        model: String
    ): Result<String> {
        return try {
            val requestBody = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart(
                    "file",
                    audioFile.name,
                    audioFile.asRequestBody("audio/m4a".toMediaType())
                )
                .addFormDataPart("model", model)
                .addFormDataPart("temperature", "0")
                .addFormDataPart("response_format", "text")
                .apply {
                    if (!prompt.isNullOrEmpty()) {
                        addFormDataPart("prompt", prompt)
                    }
                    if (!sttPrompt.isNullOrEmpty()) {
                        addFormDataPart("stt_prompt", sttPrompt)
                    }
                    if (!postProcessingPrompt.isNullOrEmpty()) {
                        addFormDataPart("post_processing_prompt", postProcessingPrompt)
                    }
                    if (!language.isNullOrEmpty()) {
                        addFormDataPart("language", language)
                        Log.d(TAG, "Language: $language")
                    }
                }
                .build()

            val request = Request.Builder()
                .url(endpoint)
                .addHeader("Authorization", "Bearer $apiKey")
                .post(requestBody)
                .build()

            Log.d(TAG, "Sending transcription request with model: $model")
            val response = okHttpClient.newCall(request).execute()
            Log.d(TAG, "Response code: ${response.code}")

            if (!response.isSuccessful) {
                val errorBody = response.body?.string() ?: "Unknown error"
                Log.e(TAG, "Transcription failed: ${response.code} - $errorBody")
                return Result.failure(TranscriptionHttpException(response.code, errorBody))
            }

            val responseBody = response.body?.string()
            Log.d(TAG, "Response body: $responseBody")
            val text = parseTranscriptionText(responseBody)
            Log.d(TAG, "Transcribed text: '$text'")

            Result.success(text)
        } catch (e: Exception) {
            Log.e(TAG, "Transcription exception", e)
            Result.failure(e)
        }
    }

    private fun parseTranscriptionText(responseBody: String?): String {
        val trimmed = responseBody?.trim().orEmpty()
        if (!trimmed.startsWith("{")) return trimmed
        return runCatching { JSONObject(trimmed).optString("text", "").trim() }
            .getOrDefault(trimmed)
    }

    private class TranscriptionHttpException(
        val statusCode: Int,
        val errorBody: String
    ) : Exception("Transcription failed: $statusCode - $errorBody")

    /**
     * Transcribes the audio once per language in parallel.
     * Each call forces Whisper to a specific language, yielding the best possible
     * transcription for that language. Returns a map of languageCode → transcription
     * for successful calls only.
     */
    suspend fun transcribeForLanguages(
        audioFile: File,
        languages: List<String>,
        prompt: String? = null
    ): Map<String, String> = coroutineScope {
        Log.d(TAG, "=== Parallel transcription for languages: $languages ===")
        val deferred = languages.map { lang ->
            lang to async(Dispatchers.IO) { transcribe(audioFile, prompt, lang) }
        }
        val results = deferred.mapNotNull { (lang, job) ->
            job.await().getOrNull()?.let { lang to it }
        }.toMap()
        Log.d(TAG, "Parallel results: ${results.entries.joinToString { (lang, text) -> "$lang → \"$text\"" }}")

        // If all forced-language calls returned empty, fall back to auto-detect.
        // Forcing a language makes Whisper conservative — it may return empty rather
        // than transcribe audio that doesn't clearly match the forced language.
        if (results.values.all { it.isBlank() }) {
            Log.d(TAG, "All forced-language results empty, trying auto-detect fallback")
            val fallback = transcribe(audioFile, prompt, null).getOrNull()
            if (!fallback.isNullOrBlank()) {
                Log.d(TAG, "Auto-detect fallback result: $fallback")
                return@coroutineScope mapOf(languages.first() to fallback)
            }
            Log.d(TAG, "Auto-detect fallback also empty — audio may be silence")
        }

        results
    }

    /**
     * Detects voice command triggers in already-transcribed text and executes the matched command.
     * Use this after transcription (and optional LLM post-processing) to preserve command support.
     */
    suspend fun detectAndExecuteCommands(
        rawText: String,
        contextText: String = "",
        commands: List<Command>,
        additionalInstructions: String? = null
    ): Result<TranscriptionResult> {
        if (rawText.isBlank()) return Result.success(TranscriptionResult(rawText))

        val detectedCommand = detectCommand(rawText, commands)
        if (detectedCommand != null) {
            Log.d(TAG, "Detected voice command: ${detectedCommand.first.name}")
            val textBeforeCommand = detectedCommand.second.trim()
            val targetText = textBeforeCommand.ifEmpty { contextText.trim() }

            if (targetText.isEmpty()) {
                return Result.success(TranscriptionResult(rawText, originalTranscription = rawText))
            }

            val commandResult = CommandClient.execute(
                command = detectedCommand.first,
                targetText = targetText,
                context = if (textBeforeCommand.isNotEmpty()) contextText else "",
                additionalInstructions = additionalInstructions
            )
            return commandResult.fold(
                onSuccess = { transformed ->
                    Result.success(TranscriptionResult(transformed, detectedCommand.first.id, rawText))
                },
                onFailure = {
                    Result.success(TranscriptionResult(rawText, originalTranscription = rawText))
                }
            )
        }
        return Result.success(TranscriptionResult(rawText, originalTranscription = rawText))
    }

    /**
     * Detect if the transcription ends with a voice command trigger.
     * Returns the matched command and the text before the trigger, or null if no command detected.
     */
    private fun detectCommand(text: String, commands: List<Command>): Pair<Command, String>? {
        val lowerText = text.lowercase().trim()

        for (command in commands) {
            for (trigger in command.voiceTriggers) {
                val lowerTrigger = trigger.lowercase()

                // Check if text ends with the trigger (with some flexibility for punctuation)
                val cleanedText = lowerText.trimEnd('.', ',', '!', '?', ' ')
                if (cleanedText.endsWith(lowerTrigger)) {
                    // Extract text before the trigger
                    val triggerStart = cleanedText.length - lowerTrigger.length
                    val textBefore = text.substring(0, triggerStart).trimEnd('.', ',', '!', '?', ' ')
                    return Pair(command, textBefore)
                }

                // Also check for trigger at the start followed by content (e.g., "rewrite this: ...")
                // Less common but possible pattern
            }
        }

        return null
    }
}
