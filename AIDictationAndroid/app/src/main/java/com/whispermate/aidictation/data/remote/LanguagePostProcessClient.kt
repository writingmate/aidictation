package com.whispermate.aidictation.data.remote

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import java.io.IOException

/**
 * LLM-based post-processing for a complete raw transcription. The same generic prompt string is
 * also sent as `post_processing_prompt` by the one-stage cloud path.
 */
object LanguagePostProcessClient {
    private const val TAG = "LanguagePostProcessClient"

    private val okHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .build()
    }

    /**
     * Post-processes one or more transcription candidates via LLM.
     *
     * @param candidates Map of language name → transcription text (e.g. "Ukrainian" → "Добре")
     * @param languageNames Ordered language snapshot used only if a legacy caller omitted a prompt
     * @param cleanupInstructions Captured generic cleanup prompt with delimited reference context
     * @return The corrected winning transcription, or the best-looking candidate on failure
     */
    suspend fun postProcess(
        candidates: Map<String, String>,
        languageNames: List<String>,
        cleanupInstructions: String? = null,
        requestSnapshot: TranscriptionClient.RequestSnapshot = TranscriptionClient.captureRequestSnapshot()
    ): String = withContext(Dispatchers.IO) {
        if (candidates.isEmpty()) return@withContext ""

        if (requestSnapshot.cleanupApiKey.isEmpty()) {
            Log.w(TAG, "Post-processing API key not configured, returning best candidate")
            return@withContext bestCandidate(candidates)
        }

        val fallback = bestCandidate(candidates)
        if (fallback.isBlank()) return@withContext ""
        val systemPrompt = cleanupInstructions?.takeIf(String::isNotBlank)
            ?: TranscriptionCleanupPrompt.systemPrompt(
                CapturedTranscriptionCleanupContext(
                    vocabulary = emptyList(),
                    phrases = emptyList(),
                    explicitReplacements = emptyList(),
                    shortcutExpansions = emptyList(),
                    formattingInstructions = emptyList(),
                    appContext = null,
                    languageContext = languageNames
                )
            )

        Log.d(TAG, "Starting language post-processing with ${candidates.size} candidates")

        try {
            val requestJson = JSONObject().apply {
                put("model", requestSnapshot.cleanupModel)
                put("messages", JSONArray().apply {
                    put(JSONObject().apply {
                        put("role", "system")
                        put("content", systemPrompt)
                    })
                    put(JSONObject().apply {
                        put("role", "user")
                        put("content", TranscriptionCleanupPrompt.userMessage(fallback))
                    })
                })
                put("max_tokens", 8192)
                put("temperature", 0.0)
            }

            val request = Request.Builder()
                .url(requestSnapshot.cleanupEndpoint)
                .addHeader("Authorization", "Bearer ${requestSnapshot.cleanupApiKey}")
                .addHeader("Content-Type", "application/json")
                .post(requestJson.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val rawResponse = executeCancellable(request) { response ->
                if (!response.isSuccessful) {
                    Log.e(TAG, "Post-process request failed: ${response.code}")
                    return@executeCancellable null
                }
                response.body?.string()
            } ?: return@withContext bestCandidate(candidates)

            val choice = JSONObject(rawResponse)
                .getJSONArray("choices")
                .getJSONObject(0)
            val rawResult = choice
                .getJSONObject("message")
                .getString("content")

            completedCleanupTextOrFallback(
                fallbackText = fallback,
                cleanupText = rawResult,
                finishReason = choice.optString("finish_reason")
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "Post-process failed, returning best candidate", e)
            bestCandidate(candidates)
        }
    }

    private suspend fun <T> executeCancellable(request: Request, transform: (Response) -> T): T =
        suspendCancellableCoroutine { continuation ->
            val call = okHttpClient.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    if (continuation.isActive) continuation.resumeWith(Result.failure(error))
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use {
                        if (!continuation.isActive) return
                        try {
                            val value = transform(it)
                            if (continuation.isActive) continuation.resumeWith(Result.success(value))
                        } catch (error: Throwable) {
                            if (continuation.isActive) continuation.resumeWith(Result.failure(error))
                        }
                    }
                }
            })
        }

    /**
     * Heuristic fallback: pick the candidate with the highest ratio of letter characters.
     * Returns empty string if no candidate clears the minimum quality threshold (60% letters),
     * signalling the caller to use auto-detect instead.
     */
    internal fun bestCandidate(candidates: Map<String, String>): String {
        val best = candidates.values.maxByOrNull { text ->
            if (text.isEmpty()) 0.0
            else text.count { it.isLetter() }.toDouble() / text.length
        } ?: return ""
        val ratio = if (best.isEmpty()) 0.0 else best.count { it.isLetter() }.toDouble() / best.length
        return if (ratio >= 0.6) best else {
            Log.w(TAG, "Best candidate quality too low (ratio=$ratio), returning empty for auto-detect fallback")
            ""
        }
    }
}
