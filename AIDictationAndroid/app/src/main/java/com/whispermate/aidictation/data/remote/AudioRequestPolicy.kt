package com.whispermate.aidictation.data.remote

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

sealed class AudioRequestException(message: String, cause: Throwable? = null) : IOException(message, cause)

class AudioHttpException(
    val statusCode: Int,
    val responseBody: String,
    val retryAfterMillis: Long? = null
) : AudioRequestException("Transcription request failed ($statusCode)")

class AudioMalformedResponseException(message: String, cause: Throwable? = null) :
    AudioRequestException(message, cause)

class AudioEmptyResponseException : AudioRequestException("No speech was returned for an audio segment")

class AudioCheckpointException : AudioRequestException("The transcription checkpoint could not be saved")

class AudioSplitException(message: String, cause: Throwable? = null) : AudioRequestException(message, cause)

/** Keeps one-stage and two-stage cleanup mutually exclusive while preserving the exact prompt. */
internal class AudioCleanupRoute(
    private val prompt: String?,
    oneStageRequested: Boolean,
    initialLeafCount: Int
) {
    @Volatile
    private var oneStageStillValid = oneStageRequested && initialLeafCount == 1 && !prompt.isNullOrBlank()

    fun serverPrompt(isInitialLeaf: Boolean): String? =
        prompt?.takeIf { oneStageStillValid && isInitialLeaf }

    fun invalidateForSplit() {
        oneStageStillValid = false
    }

    fun clientCleanupPrompt(): String? = prompt?.takeIf { !oneStageStillValid }
}

/** A complete HTTP 200 body. Error bodies are deliberately never drained. */
internal data class CompleteAudioHttpResponse(
    val body: String,
    val contentType: String?
)

/**
 * Classifies the response from its headers before reading any body bytes. This matters for a
 * permanent 4xx (and for 413): a server that stalls or disconnects its diagnostic body must not
 * turn a known status into a retryable transport failure. A 200 is different; it is accepted only
 * after OkHttp has drained the complete body, so a mid-body disconnect remains retryable I/O.
 */
internal suspend fun executeAudioHttpRequest(
    client: OkHttpClient,
    request: Request,
    nowMillis: () -> Long = System::currentTimeMillis
): CompleteAudioHttpResponse = suspendCancellableCoroutine { continuation ->
    val call = client.newCall(request)
    continuation.invokeOnCancellation { call.cancel() }
    call.enqueue(object : Callback {
        override fun onFailure(call: Call, error: IOException) {
            if (continuation.isActive) continuation.resumeWithException(error)
        }

        override fun onResponse(call: Call, response: okhttp3.Response) {
            response.use {
                if (!continuation.isActive) return
                try {
                    val statusCode = it.code
                    val retryAfterMillis = parseAudioRetryAfterMillis(
                        it.header("Retry-After"),
                        nowMillis()
                    )
                    if (statusCode != 200) {
                        throw AudioHttpException(
                            statusCode = statusCode,
                            responseBody = "",
                            retryAfterMillis = retryAfterMillis
                        )
                    }
                    val completeBody = it.body?.string().orEmpty()
                    continuation.resume(
                        CompleteAudioHttpResponse(
                            body = completeBody,
                            contentType = it.header("Content-Type")
                        )
                    ) { _, _, _ -> }
                } catch (error: Throwable) {
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
            }
        }
    })
}

internal fun parseAudioRetryAfterMillis(
    value: String?,
    nowMillis: Long = System.currentTimeMillis()
): Long? {
    val normalized = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    normalized.toLongOrNull()?.let { seconds ->
        return seconds.coerceIn(0L, 10L) * 1_000L
    }
    return runCatching {
        val retryAt = ZonedDateTime.parse(normalized, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant()
        (retryAt.toEpochMilli() - nowMillis).coerceIn(0L, 10_000L)
    }.getOrNull()
}

fun interface RecoveryDelay {
    suspend fun wait(milliseconds: Long)
}

object CoroutineRecoveryDelay : RecoveryDelay {
    override suspend fun wait(milliseconds: Long) {
        delay(milliseconds)
    }
}

suspend fun preserveRawOnCleanupFailure(
    rawText: String,
    cleanup: suspend () -> String
): String {
    require(rawText.isNotBlank())
    return try {
        cleanup().trim().ifEmpty { rawText }
    } catch (_: TimeoutCancellationException) {
        rawText
    } catch (error: CancellationException) {
        throw error
    } catch (_: Throwable) {
        rawText
    }
}

internal fun completedCleanupTextOrFallback(
    fallbackText: String,
    cleanupText: String,
    finishReason: String?
): String = if (!finishReason.equals("stop", ignoreCase = true)) {
    fallbackText
} else {
    cleanupText.trim().ifEmpty { fallbackText }
}

data class AudioRetryPolicy(
    val maximumAttempts: Int = 3,
    val maximumRetryAfterMillis: Long = 10_000,
    val backoffMillis: (attempt: Int) -> Long = { attempt -> 500L * attempt }
) {
    init {
        require(maximumAttempts >= 1)
        require(maximumRetryAfterMillis >= 0)
    }

    fun shouldRetry(error: Throwable, attempt: Int): Boolean {
        if (attempt >= maximumAttempts) return false
        return when (error) {
            is CancellationException -> false
            is AudioMalformedResponseException, is AudioEmptyResponseException,
            is AudioCheckpointException, is AudioSplitException -> false
            is AudioHttpException -> error.statusCode == 408 ||
                error.statusCode == 429 || error.statusCode in 500..599
            is IOException -> true
            else -> false
        }
    }

    fun delayBeforeRetry(error: Throwable, attempt: Int): Long {
        val retryAfter = (error as? AudioHttpException)?.retryAfterMillis
        return (retryAfter ?: backoffMillis(attempt)).coerceIn(0, maximumRetryAfterMillis)
    }
}

fun interface AudioLeafTransport<L> {
    suspend fun recognize(leaf: L): String
}

fun interface AudioLeafSplitter<L> {
    /** Returns two ordered children, or null when the rejected leaf cannot be split safely. */
    suspend fun split(leaf: L, depth: Int): List<L>?
}

/**
 * Sequential recognition with per-leaf retry, recursive 413 splitting and durable ordered
 * checkpoints. A completed leaf is never replayed when a later leaf fails.
 */
class SequentialAudioRecognitionEngine<L>(
    private val transport: AudioLeafTransport<L>,
    private val splitter: AudioLeafSplitter<L>,
    private val retryPolicy: AudioRetryPolicy = AudioRetryPolicy(),
    private val recoveryDelay: RecoveryDelay = CoroutineRecoveryDelay,
    private val maximumSplitDepth: Int = 5
) {
    suspend fun recognize(
        initialLeaves: List<L>,
        initialCheckpoint: List<String> = emptyList(),
        checkpoint: suspend (mergedText: String, completedLeafCount: Int) -> Boolean
    ): String {
        require(initialLeaves.isNotEmpty())
        val completed = initialCheckpoint.toMutableList()
        for (leaf in initialLeaves) {
            recognizeLeaf(leaf, depth = 0, completed = completed, checkpoint = checkpoint)
        }
        return completed.joinToString(" ").trim()
    }

    private suspend fun recognizeLeaf(
        leaf: L,
        depth: Int,
        completed: MutableList<String>,
        checkpoint: suspend (String, Int) -> Boolean
    ) {
        try {
            val text = executeWithRetry(leaf).trim()
            if (text.isEmpty()) throw AudioEmptyResponseException()
            completed += text
            val merged = completed.joinToString(" ").trim()
            if (!checkpoint(merged, completed.size)) throw AudioCheckpointException()
        } catch (error: AudioHttpException) {
            if (error.statusCode != 413) throw error
            if (depth >= maximumSplitDepth) {
                throw AudioSplitException("The audio segment is still too large after bounded splitting", error)
            }
            val children = splitter.split(leaf, depth)
                ?.takeIf { it.size == 2 }
                ?: throw AudioSplitException("The rejected audio segment cannot be split safely", error)
            for (child in children) {
                recognizeLeaf(child, depth + 1, completed, checkpoint)
            }
        }
    }

    private suspend fun executeWithRetry(leaf: L): String {
        var attempt = 1
        while (true) {
            try {
                return transport.recognize(leaf)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (!retryPolicy.shouldRetry(error, attempt)) throw error
                recoveryDelay.wait(retryPolicy.delayBeforeRetry(error, attempt))
                attempt += 1
            }
        }
    }
}
