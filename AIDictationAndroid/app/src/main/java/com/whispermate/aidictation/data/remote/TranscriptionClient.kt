package com.whispermate.aidictation.data.remote

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.local.ManagedAudioTemporaryFiles
import com.whispermate.aidictation.data.local.ManagedAudioTemporaryWorkspace
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import com.whispermate.aidictation.domain.model.Command
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.max
import kotlin.math.min

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
    private const val MAX_SINGLE_UPLOAD_AUDIO_BYTES = 3_600_000L
    private const val MAX_CHUNK_DURATION_US = 240_000_000L
    private const val MIN_CHUNK_DURATION_US = 20_000_000L
    private const val MIN_TRAILING_CHUNK_DURATION_US = 250_000L
    private const val CHUNK_DURATION_SAFETY_FACTOR = 0.9
    private const val CHUNK_EXPORT_TIMEOUT_MS = 60_000L
    private const val CLEANUP_TIMEOUT_MS = 35_000L

    private data class AudioUploadChunk(
        val file: File,
        val isTemporary: Boolean
    )

    private data class AudioMetadata(
        val durationUs: Long,
        val trackIndex: Int,
        val format: MediaFormat
    )

    data class RequestSnapshot(
        val endpoint: String,
        val apiKey: String,
        val model: String,
        val cleanupEndpoint: String,
        val cleanupApiKey: String,
        val cleanupModel: String
    )

    private val okHttpClient by lazy {
        OkHttpClient.Builder()
            .callTimeout(70, TimeUnit.SECONDS)
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
        postProcessingPrompt: String? = null,
        oneStageCleanup: Boolean = false,
        requestSnapshot: RequestSnapshot = captureRequestSnapshot(),
        checkpoint: suspend (mergedText: String, completedLeafCount: Int) -> Boolean = { _, _ -> true },
        rawComplete: suspend (rawText: String) -> Boolean = { true }
    ): Result<String> = withContext(Dispatchers.IO) {
        val temporaryFiles = linkedSetOf<File>()
        val temporaryWorkspace = ManagedAudioTemporaryFiles.openWorkspace(audioFile)
        try {
            Log.d(TAG, "Transcribing audio, size: ${audioFile.length()} bytes")
            Log.d(
                TAG,
                "Language: ${language ?: "auto-detect"}, promptLength: ${prompt?.length ?: 0}, " +
                    "sttPromptLength: ${sttPrompt?.length ?: 0}, " +
                    "postProcessingPromptLength: ${postProcessingPrompt?.length ?: 0}"
            )

            if (requestSnapshot.apiKey.isEmpty()) {
                Log.e(TAG, "Cloud mode is not configured")
                return@withContext Result.failure(AudioHttpException(401, "Cloud mode is not configured"))
            }

            val leaves = withTimeout(CHUNK_EXPORT_TIMEOUT_MS) {
                if (shouldUseChunkedUpload(requestSnapshot.endpoint) &&
                    audioFile.length() > MAX_SINGLE_UPLOAD_AUDIO_BYTES
                ) {
                    runDisposableBlocking(
                        onLateResult = { chunks ->
                            chunks.filter { it.isTemporary }.forEach { it.file.delete() }
                        }
                    ) { makeUploadChunks(audioFile, temporaryWorkspace) }
                } else {
                    listOf(AudioUploadChunk(audioFile, isTemporary = false))
                }
            }
            leaves.filter { it.isTemporary }.forEach { temporaryFiles.add(it.file) }
            val cleanupRoute = AudioCleanupRoute(
                prompt = postProcessingPrompt,
                oneStageRequested = oneStageCleanup,
                initialLeafCount = leaves.size
            )
            val oneStageLeaf = leaves.singleOrNull()

            val engine = SequentialAudioRecognitionEngine(
                transport = AudioLeafTransport<AudioUploadChunk> { leaf ->
                    val serverCleanupPrompt = cleanupRoute.serverPrompt(leaf === oneStageLeaf)
                    executeTranscriptionRequest(
                        audioFile = leaf.file,
                        prompt = prompt,
                        language = language,
                        sttPrompt = sttPrompt ?: prompt,
                        postProcessingPrompt = serverCleanupPrompt,
                        postProcessingEnabled = serverCleanupPrompt != null,
                        snapshot = requestSnapshot
                    )
                },
                splitter = AudioLeafSplitter<AudioUploadChunk> { rejected, _ ->
                    // A 413 changes this into a multi-leaf flow. Children must return raw text so
                    // the shared cleanup contract runs once after the complete ordered merge.
                    cleanupRoute.invalidateForSplit()
                    val children = withTimeout(CHUNK_EXPORT_TIMEOUT_MS) {
                        runDisposableBlocking(
                            onLateResult = { late -> late?.forEach { it.file.delete() } }
                        ) { splitRejectedLeaf(rejected.file, temporaryWorkspace) }
                    }
                    children?.onEach { child -> if (child.isTemporary) temporaryFiles += child.file }
                }
            )

            val raw = engine.recognize(leaves, checkpoint = checkpoint)
            if (raw.isBlank()) throw AudioEmptyResponseException()
            if (!rawComplete(raw)) throw AudioCheckpointException()

            val clientCleanupPrompt = cleanupRoute.clientCleanupPrompt()
            if (clientCleanupPrompt != null) {
                // Cleanup is optional and separately bounded. Its failure must never discard raw speech.
                preserveRawOnCleanupFailure(raw) {
                    withTimeout(CLEANUP_TIMEOUT_MS) {
                        refineMergedTranscript(raw, clientCleanupPrompt, requestSnapshot)
                            .trim()
                            .ifEmpty { raw }
                    }
                }.let { Result.success(it) }
            } else {
                Result.success(raw)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Log.e(TAG, "Transcription exception", e)
            Result.failure(e)
        } finally {
            temporaryFiles.forEach { file -> runCatching { file.delete() } }
            temporaryWorkspace.retire()
        }
    }

    fun captureRequestSnapshot(): RequestSnapshot {
        val config = ApiConfigManager.instance?.getTranscriptionConfig()
        val cleanupConfig = ApiConfigManager.instance?.getPostProcessingConfig()
        return RequestSnapshot(
            endpoint = config?.endpoint ?: BuildConfig.TRANSCRIPTION_ENDPOINT,
            apiKey = config?.apiKey ?: BuildConfig.TRANSCRIPTION_API_KEY,
            model = config?.model ?: BuildConfig.TRANSCRIPTION_MODEL,
            cleanupEndpoint = cleanupConfig?.endpoint ?: BuildConfig.AIDICTATION_POST_PROCESSING_ENDPOINT,
            cleanupApiKey = cleanupConfig?.apiKey ?: BuildConfig.AIDICTATION_POST_PROCESSING_KEY,
            cleanupModel = cleanupConfig?.model ?: BuildConfig.AIDICTATION_POST_PROCESSING_MODEL
        )
    }

    private suspend fun executeTranscriptionRequest(
        audioFile: File,
        prompt: String?,
        language: String?,
        sttPrompt: String?,
        postProcessingPrompt: String?,
        postProcessingEnabled: Boolean = true,
        snapshot: RequestSnapshot
    ): String {
        val requestBody = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart(
                    "file",
                    audioFile.name,
                    audioFile.asRequestBody(contentTypeFor(audioFile).toMediaType())
                )
                .addFormDataPart("model", snapshot.model)
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
                    if (!postProcessingEnabled) {
                        addFormDataPart("post_processing", "false")
                    }
                    if (!language.isNullOrEmpty()) {
                        addFormDataPart("language", language)
                    }
                }
                .build()

        val request = Request.Builder()
                .url(snapshot.endpoint)
                .addHeader("Authorization", "Bearer ${snapshot.apiKey}")
                .post(requestBody)
                .build()

        val response = executeAudioHttpRequest(okHttpClient, request)
        return parseTranscriptionText(response.body, response.contentType)
    }

    private suspend fun refineMergedTranscript(
        transcription: String,
        prompt: String,
        snapshot: RequestSnapshot
    ): String {
        if (snapshot.cleanupApiKey.isEmpty()) {
            Log.w(TAG, "Post-processing API key not configured, returning merged transcript")
            return transcription
        }

        return try {
            val requestJson = JSONObject().apply {
                put("model", snapshot.cleanupModel)
                put("messages", JSONArray().apply {
                    put(JSONObject().apply {
                        put("role", "system")
                        put("content", prompt)
                    })
                    put(JSONObject().apply {
                        put("role", "user")
                        put("content", TranscriptionCleanupPrompt.userMessage(transcription))
                    })
                })
                put("temperature", 0.0)
                put("max_tokens", 8192)
            }

            val request = Request.Builder()
                .url(snapshot.cleanupEndpoint)
                .addHeader("Authorization", "Bearer ${snapshot.cleanupApiKey}")
                .addHeader("Content-Type", "application/json")
                .post(requestJson.toString().toRequestBody("application/json".toMediaType()))
                .build()

            Log.d(TAG, "Applying one LLM post-processing pass to merged chunk transcript")
            executeCancellable(request) { response ->
                if (response.code != 200) return@executeCancellable transcription
                val responseBody = response.body?.string() ?: return@executeCancellable transcription
                val choice = JSONObject(responseBody)
                    .getJSONArray("choices")
                    .getJSONObject(0)
                val cleanupText = choice
                    .getJSONObject("message")
                    .getString("content")
                completedCleanupTextOrFallback(
                    fallbackText = transcription,
                    cleanupText = cleanupText,
                    finishReason = choice.optString("finish_reason")
                )
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Log.w(TAG, "Merged transcript post-processing failed, returning merged transcript", e)
            transcription
        }
    }

    private fun makeUploadChunks(
        audioFile: File,
        temporaryWorkspace: ManagedAudioTemporaryWorkspace
    ): List<AudioUploadChunk> {
        if (audioFile.length() <= MAX_SINGLE_UPLOAD_AUDIO_BYTES) {
            return listOf(AudioUploadChunk(audioFile, isTemporary = false))
        }

        val metadata = readAudioMetadata(audioFile)
        if (metadata.durationUs <= MIN_CHUNK_DURATION_US) {
            return listOf(AudioUploadChunk(audioFile, isTemporary = false))
        }

        val bytesPerMicrosecond = audioFile.length().toDouble() / metadata.durationUs.toDouble()
        var segmentDurationUs = min(
            MAX_CHUNK_DURATION_US,
            max(
                MIN_CHUNK_DURATION_US,
                ((MAX_SINGLE_UPLOAD_AUDIO_BYTES / max(bytesPerMicrosecond, 1.0e-9)) * CHUNK_DURATION_SAFETY_FACTOR).toLong()
            )
        )

        var largestChunkBytes = 0L
        repeat(5) {
            val chunks = writeAudioChunks(
                audioFile,
                metadata.durationUs,
                segmentDurationUs,
                temporaryWorkspace
            )
            largestChunkBytes = chunks.maxOfOrNull { it.file.length() } ?: 0L
            if (largestChunkBytes <= MAX_SINGLE_UPLOAD_AUDIO_BYTES) {
                return chunks
            }

            chunks.filter { it.isTemporary }.forEach { it.file.delete() }
            segmentDurationUs = (segmentDurationUs * 0.75).toLong()
            if (segmentDurationUs < MIN_CHUNK_DURATION_US) {
                throw IllegalStateException("Unable to split audio under upload limit; largest chunk was $largestChunkBytes bytes")
            }
        }

        throw IllegalStateException("Unable to split audio under upload limit; largest chunk was $largestChunkBytes bytes")
    }

    private fun writeAudioChunks(
        audioFile: File,
        durationUs: Long,
        segmentDurationUs: Long,
        temporaryWorkspace: ManagedAudioTemporaryWorkspace
    ): List<AudioUploadChunk> {
        val chunks = mutableListOf<AudioUploadChunk>()
        try {
            var startUs = 0L
            var index = 0
            while (startUs < durationUs) {
                val endUs = nextChunkEndUs(startUs, durationUs, segmentDurationUs)
                check(endUs > startUs) { "Audio chunking stopped making progress" }

                val chunkFile = temporaryWorkspace.createTemporaryFile(
                    "${audioFile.nameWithoutExtension}_chunk_${index}_",
                    ".m4a"
                )
                val chunk = AudioUploadChunk(chunkFile, isTemporary = true)
                chunks += chunk
                writeAudioChunk(audioFile, chunkFile, startUs, endUs)
                if (chunkFile.length() > 0L) {
                    readAudioMetadata(chunkFile)
                } else {
                    chunks.remove(chunk)
                    chunkFile.delete()
                }
                startUs = endUs
                index += 1
            }

            check(chunks.isNotEmpty()) { "Audio chunking produced no uploadable chunks" }
            return chunks
        } catch (e: Exception) {
            chunks.filter { it.isTemporary }.forEach { it.file.delete() }
            throw e
        }
    }

    /** Keeps a tiny final tail in the preceding upload while preserving half-open boundaries. */
    internal fun nextChunkEndUs(startUs: Long, durationUs: Long, segmentDurationUs: Long): Long {
        require(startUs in 0 until durationUs)
        require(segmentDurationUs > 0L)
        val proposedEndUs = startUs + min(segmentDurationUs, durationUs - startUs)
        return if (durationUs - proposedEndUs in 1 until MIN_TRAILING_CHUNK_DURATION_US) {
            durationUs
        } else {
            proposedEndUs
        }
    }

    private fun splitRejectedLeaf(
        audioFile: File,
        temporaryWorkspace: ManagedAudioTemporaryWorkspace
    ): List<AudioUploadChunk>? {
        val metadata = readAudioMetadata(audioFile)
        if (metadata.durationUs < 1_000_000L || audioFile.length() < 64_000L) return null
        val midpointUs = metadata.durationUs / 2
        if (midpointUs < 250_000L || metadata.durationUs - midpointUs < 250_000L) return null

        val left = temporaryWorkspace.createTemporaryFile(
            "${audioFile.nameWithoutExtension}_left_",
            ".m4a"
        )
        val right = temporaryWorkspace.createTemporaryFile(
            "${audioFile.nameWithoutExtension}_right_",
            ".m4a"
        )
        return try {
            writeAudioChunk(audioFile, left, 0, midpointUs)
            writeAudioChunk(audioFile, right, midpointUs, metadata.durationUs)
            if (left.length() <= 0L || right.length() <= 0L ||
                left.length() >= audioFile.length() || right.length() >= audioFile.length()
            ) {
                left.delete()
                right.delete()
                null
            } else {
                readAudioMetadata(left)
                readAudioMetadata(right)
                listOf(AudioUploadChunk(left, true), AudioUploadChunk(right, true))
            }
        } catch (error: Throwable) {
            left.delete()
            right.delete()
            throw AudioSplitException("Unable to split a rejected audio segment", error)
        }
    }

    private fun writeAudioChunk(sourceFile: File, outputFile: File, startUs: Long, endUs: Long) {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var muxerStarted = false

        var finalizationFailure: Throwable? = null
        try {
            extractor.setDataSource(sourceFile.absolutePath)
            val metadata = readAudioMetadata(extractor)
            extractor.selectTrack(metadata.trackIndex)
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

            muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val outputTrackIndex = muxer.addTrack(metadata.format)
            muxer.start()
            muxerStarted = true

            val bufferSize = if (metadata.format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                metadata.format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            } else {
                256 * 1024
            }
            val buffer = ByteBuffer.allocate(max(bufferSize, 256 * 1024))
            val bufferInfo = MediaCodec.BufferInfo()

            while (true) {
                val sampleTrackIndex = extractor.sampleTrackIndex
                if (sampleTrackIndex < 0) break
                if (sampleTrackIndex != metadata.trackIndex) {
                    extractor.advance()
                    continue
                }

                val sampleTimeUs = extractor.sampleTime
                if (sampleTimeUs < 0 || sampleTimeUs >= endUs) break
                if (sampleTimeUs < startUs) {
                    extractor.advance()
                    continue
                }

                buffer.clear()
                val sampleSize = extractor.readSampleData(buffer, 0)
                if (sampleSize < 0) break

                bufferInfo.set(
                    0,
                    sampleSize,
                    max(0L, sampleTimeUs - startUs),
                    mediaCodecBufferFlags(extractor.sampleFlags)
                )
                muxer.writeSampleData(outputTrackIndex, buffer, bufferInfo)
                extractor.advance()
            }
        } finally {
            if (muxerStarted) {
                try {
                    muxer?.stop()
                } catch (error: Throwable) {
                    finalizationFailure = error
                }
            }
            runCatching { muxer?.release() }
            extractor.release()
            finalizationFailure?.let { throw AudioSplitException("An exported audio segment could not be finalized", it) }
        }
    }

    private fun mediaCodecBufferFlags(sampleFlags: Int): Int {
        var flags = 0
        if (sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
            flags = flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
        }
        if (sampleFlags and MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME != 0) {
            flags = flags or MediaCodec.BUFFER_FLAG_PARTIAL_FRAME
        }
        return flags
    }

    private fun readAudioMetadata(audioFile: File): AudioMetadata {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(audioFile.absolutePath)
            readAudioMetadata(extractor)
        } finally {
            extractor.release()
        }
    }

    private fun readAudioMetadata(extractor: MediaExtractor): AudioMetadata {
        for (trackIndex in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(trackIndex)
            val mime = if (format.containsKey(MediaFormat.KEY_MIME)) {
                format.getString(MediaFormat.KEY_MIME).orEmpty()
            } else {
                ""
            }
            if (mime.startsWith("audio/")) {
                val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                    format.getLong(MediaFormat.KEY_DURATION)
                } else {
                    -1L
                }
                check(durationUs > 0L) { "Audio duration is unavailable" }
                return AudioMetadata(durationUs, trackIndex, format)
            }
        }

        throw IllegalArgumentException("No audio track found in ${extractor.toString()}")
    }

    private fun shouldUseChunkedUpload(endpoint: String): Boolean {
        return endpoint.contains("://writingmate.ai/", ignoreCase = true) ||
            endpoint.contains(".writingmate.ai/", ignoreCase = true)
    }

    private fun contentTypeFor(audioFile: File): String {
        return when (audioFile.extension.lowercase()) {
            "wav" -> "audio/wav"
            "mp3" -> "audio/mpeg"
            "aac" -> "audio/aac"
            else -> "audio/m4a"
        }
    }

    private fun parseTranscriptionText(responseBody: String, contentType: String?): String {
        val trimmed = responseBody.trim()
        if (trimmed.isEmpty()) throw AudioEmptyResponseException()

        val isJsonEnvelope = contentType
            ?.substringBefore(';')
            ?.trim()
            ?.lowercase()
            ?.let { it == "application/json" || it.endsWith("+json") } == true
        if (!isJsonEnvelope) return trimmed // Dictated text that looks like JSON remains literal.

        val json = try {
            JSONObject(trimmed)
        } catch (error: Throwable) {
            throw AudioMalformedResponseException("The transcription response was not valid JSON", error)
        }
        val keys = buildSet {
            val iterator = json.keys()
            while (iterator.hasNext()) add(iterator.next())
        }
        if (keys != setOf("text") || json.opt("text") !is String) {
            throw AudioMalformedResponseException("The transcription response did not match the expected envelope")
        }
        return json.getString("text").trim().ifEmpty { throw AudioEmptyResponseException() }
    }

    private suspend fun <T> executeCancellable(
        request: Request,
        transform: (Response) -> T
    ): T = suspendCancellableCoroutine { continuation ->
        val call = okHttpClient.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, error: IOException) {
                if (continuation.isActive) continuation.resumeWithException(error)
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    if (!continuation.isActive) return
                    try {
                        val value = transform(it)
                        continuation.resume(value) { _, _, _ -> }
                    } catch (error: Throwable) {
                        if (continuation.isActive) continuation.resumeWithException(error)
                    }
                }
            }
        })
    }

    /** Runs native mux/export work on a disposable worker so an ignored interrupt cannot block reuse. */
    private suspend fun <T> runDisposableBlocking(
        onLateResult: (T) -> Unit,
        block: () -> T
    ): T = suspendCancellableCoroutine { continuation ->
        val executor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "audio-export-${System.nanoTime()}").apply { isDaemon = true }
        }
        var future: Future<*>? = null
        future = executor.submit {
            try {
                val value = block()
                continuation.resume(value) { _, lateValue, _ ->
                    onLateResult(lateValue)
                }
            } catch (error: Throwable) {
                if (continuation.isActive) continuation.resumeWithException(error)
            } finally {
                executor.shutdownNow()
            }
        }
        continuation.invokeOnCancellation {
            future?.cancel(true)
            executor.shutdownNow()
        }
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
            Log.d(TAG, "Detected voice command")
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
