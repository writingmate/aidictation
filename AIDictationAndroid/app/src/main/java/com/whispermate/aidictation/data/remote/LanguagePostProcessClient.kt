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

/**
 * LLM-based post-processing for transcription results.
 * When multiple language candidates are provided, picks the best match and corrects errors.
 * When a single candidate is provided, corrects transcription errors only.
 * Context rules are appended to the prompt when present.
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
     * With multiple candidates: picks the one that matches the language actually spoken,
     * then lightly corrects obvious speech-to-text errors in the winner.
     * With a single candidate: corrects errors only (no language selection).
     * Context rules are appended to the prompt when provided.
     *
     * @param candidates Map of language name → transcription text (e.g. "Ukrainian" → "Добре")
     * @param languageNames Ordered list of language names the user speaks
     * @param contextRules Optional additional instructions from context rules (e.g. app-specific rules)
     * @return The corrected winning transcription, or the best-looking candidate on failure
     */
    suspend fun postProcess(
        candidates: Map<String, String>,
        languageNames: List<String>,
        contextRules: String? = null
    ): String = withContext(Dispatchers.IO) {
        if (candidates.isEmpty()) return@withContext ""

        val config = ApiConfigManager.instance?.getPostProcessingConfig()
        val apiKey = config?.apiKey ?: BuildConfig.AIDICTATION_POST_PROCESSING_KEY
        val endpoint = config?.endpoint ?: BuildConfig.AIDICTATION_POST_PROCESSING_ENDPOINT
        val model = config?.model ?: BuildConfig.AIDICTATION_POST_PROCESSING_MODEL
        if (apiKey.isEmpty()) {
            Log.w(TAG, "Post-processing API key not configured, returning best candidate")
            return@withContext bestCandidate(candidates)
        }

        val languageList = languageNames.joinToString(", ")
        val numberedEntries = candidates.entries.toList()
        val candidateLines = numberedEntries.mapIndexed { i, (lang, text) ->
            "${i + 1}. [$lang] $text"
        }.joinToString("\n")

        val systemPrompt = buildString {
            if (candidates.size > 1) {
                append("The user is speaking one of the following languages: $languageList.\n")
                append("You will receive numbered Whisper transcriptions of the exact same audio clip, each forced to a different language.\n")
                append("Identify the best match: Determine which numbered transcription accurately reflects the language that was actually spoken.\n\n")
            }
            append("Correct basic errors in the transcription:\n")
            append("Split improperly merged words (e.g., \"заросмова\" → \"зараз мова\").\n")
            append("Correct obvious spelling and grammatical forms (e.g., \"украинська\" → \"українська\").\n")
            append("Fix missing apostrophes and capitalization (e.g., \"dont\" → \"don't\").\n")
            append("Clean up stutters and repeated words or phrases.\n\n")
            append("STRICT CONSTRAINTS:\n")
            append("DO NOT translate, rephrase, or summarize the text.\n")
            append("DO NOT remove any spoken concepts or skip unrecognizable words. If unsure about a word, leave it exactly as-is.\n")
            append("Keep the corrected text in the original language spoken.\n\n")
            if (!contextRules.isNullOrBlank()) {
                append("Additional instructions: $contextRules\n\n")
            }
            append("OUTPUT FORMAT:\n")
            append("Return ONLY the corrected transcription text. Do not include the transcription number, language labels, explanations, or quotation marks.")
        }

        Log.d(TAG, "=== LanguagePostProcess ===")
        Log.d(TAG, "Candidates:\n$candidateLines")

        try {
            val requestJson = JSONObject().apply {
                put("model", model)
                put("messages", JSONArray().apply {
                    put(JSONObject().apply {
                        put("role", "system")
                        put("content", systemPrompt)
                    })
                    put(JSONObject().apply {
                        put("role", "user")
                        put("content", candidateLines)
                    })
                })
                put("max_tokens", 300)
                put("temperature", 0.0)
            }

            val request = Request.Builder()
                .url(endpoint)
                .addHeader("Authorization", "Bearer $apiKey")
                .addHeader("Content-Type", "application/json")
                .post(requestJson.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val response = okHttpClient.newCall(request).execute()

            if (!response.isSuccessful) {
                Log.e(TAG, "Post-process request failed: ${response.code} - ${response.body?.string()}")
                return@withContext bestCandidate(candidates)
            }

            val rawResponse = response.body?.string() ?: "{}"
            Log.d(TAG, "LLM raw response: $rawResponse")

            val rawResult = JSONObject(rawResponse)
                .getJSONArray("choices")
                .getJSONObject(0)
                .getJSONObject("message")
                .getString("content")
                .trim()
                .trimQuotes()

            Log.d(TAG, "Result raw: $rawResult")

            // Validate: if the LLM hallucinated something that doesn't resemble any candidate,
            // fall back to the best candidate without correction
            val result = if (rawResult.isNotEmpty() && resemblesAnyCandidate(rawResult, candidates)) {
                rawResult
            } else {
                Log.w(TAG, "LLM output doesn't resemble any candidate, using best fallback")
                bestCandidate(candidates)
            }

            Log.d(TAG, "Result final: $result")

            result.ifEmpty { bestCandidate(candidates) }
        } catch (e: Exception) {
            Log.e(TAG, "Post-process failed, returning best candidate", e)
            bestCandidate(candidates)
        }
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

    /**
     * Returns true if the LLM output loosely resembles at least one candidate —
     * i.e. shares enough words to not be a hallucination.
     * Uses a simple word-overlap heuristic: at least 40% of LLM words appear in some candidate.
     */
    private fun resemblesAnyCandidate(llmOutput: String, candidates: Map<String, String>): Boolean {
        val llmWords = llmOutput.lowercase().split(Regex("\\W+")).filter { it.length > 2 }.toSet()
        if (llmWords.isEmpty()) return true // short output, give benefit of the doubt
        return candidates.values.any { candidate ->
            val candidateWords = candidate.lowercase().split(Regex("\\W+")).filter { it.length > 2 }.toSet()
            val overlap = llmWords.intersect(candidateWords).size
            overlap.toDouble() / llmWords.size >= 0.4
        }
    }

    private fun String.trimQuotes() = trim('"', '\'', '\u201C', '\u201D')
}
