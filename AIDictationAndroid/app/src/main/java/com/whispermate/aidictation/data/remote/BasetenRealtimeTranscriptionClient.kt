package com.whispermate.aidictation.data.remote

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

object BasetenRealtimeTranscriptionClient {
    private const val TAG = "BasetenRealtime"
    private const val SAMPLE_RATE = 16_000
    private const val SAMPLES_PER_FRAME = 512
    private const val BYTES_PER_FRAME = SAMPLES_PER_FRAME * 2

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    private val mutex = Mutex()
    private var socket: WebSocket? = null
    private var currentConfig: Config? = null
    private var connected: CompletableDeferred<Unit>? = null
    private var failed: Throwable? = null
    private var accumulatedTranscript = ""
    private var finalTranscript = ""
    private var finish: CompletableDeferred<String?>? = null

    data class Config(
        val endpoint: String,
        val apiKey: String,
        val language: String?
    )

    suspend fun transcribe(audioFile: File, config: Config): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            val pcm = decodeToPcm16kMono(audioFile)
            mutex.withLock {
                ensureSocket(config)
                resetUtterance()
                sendFrames(pcm)
                sendTrailingSilence(seconds = 0.8)
                awaitFinalTranscript()
            }?.trim().orEmpty()
        }.mapCatching { text ->
            require(text.isNotBlank()) { "Cloud transcription did not return text" }
            text
        }
    }

    fun refreshMetadata() {
        close()
    }

    fun close() {
        socket?.close(1000, null)
        socket = null
        currentConfig = null
        connected = null
        failed = null
        finish?.complete(finalTranscript.ifBlank { accumulatedTranscript }.ifBlank { null })
        finish = null
    }

    private suspend fun ensureSocket(config: Config) {
        if (socket != null && currentConfig == config && failed == null) {
            Log.d(TAG, "Reusing cloud transcription socket")
            return
        }

        close()
        currentConfig = config
        val ready = CompletableDeferred<Unit>()
        connected = ready
        failed = null

        val request = Request.Builder()
            .url(config.endpoint)
            .addHeader("Authorization", "Api-Key ${config.apiKey}")
            .build()

        socket = client.newWebSocket(request, Listener())
        withTimeout(8_000) { ready.await() }
        sendMetadata(config)
        Log.d(TAG, "Opened cloud transcription socket")
    }

    private fun sendMetadata(config: Config) {
        val metadata = JSONObject()
            .put(
                "whisper_params",
                JSONObject()
                    .put("audio_language", config.language?.takeIf { it.isNotBlank() } ?: "auto")
                    .put("show_word_timestamps", false)
            )
            .put(
                "streaming_params",
                JSONObject()
                    .put("encoding", "pcm_s16le")
                    .put("sample_rate", SAMPLE_RATE)
                    .put("enable_partial_transcripts", true)
                    .put("partial_transcript_interval_s", 0.25)
                    .put("final_transcript_max_duration_s", 30)
            )
            .put(
                "streaming_vad_config",
                JSONObject()
                    .put("threshold", 0.5)
                    .put("min_silence_duration_ms", 300)
                    .put("speech_pad_ms", 80)
            )

        socket?.send(metadata.toString())
    }

    private fun resetUtterance() {
        accumulatedTranscript = ""
        finalTranscript = ""
        finish = CompletableDeferred()
    }

    private fun sendFrames(pcm: ByteArray) {
        var offset = 0
        while (offset < pcm.size) {
            val frame = ByteArray(BYTES_PER_FRAME)
            val count = minOf(BYTES_PER_FRAME, pcm.size - offset)
            System.arraycopy(pcm, offset, frame, 0, count)
            socket?.send(frame.toByteString())
            offset += count
        }
    }

    private fun sendTrailingSilence(seconds: Double) {
        val frames = kotlin.math.ceil(seconds * SAMPLE_RATE / SAMPLES_PER_FRAME.toDouble()).toInt().coerceAtLeast(1)
        val silence = ByteArray(BYTES_PER_FRAME)
        repeat(frames) {
            socket?.send(silence.toByteString())
        }
    }

    private suspend fun awaitFinalTranscript(): String? {
        val deferred = finish ?: return finalTranscript.ifBlank { accumulatedTranscript }.ifBlank { null }
        return try {
            withTimeout(3_000) { deferred.await() }
        } catch (_: TimeoutCancellationException) {
            finalTranscript.ifBlank { accumulatedTranscript }.ifBlank { null }
        }
    }

    private fun handleTranscription(payload: JSONObject) {
        val text = transcriptText(payload)
        if (text.isBlank()) return

        accumulatedTranscript = text
        if (payload.optBoolean("is_final", false)) {
            finalTranscript = text
            finish?.complete(text)
        }
    }

    private fun transcriptText(payload: JSONObject): String {
        payload.optString("transcript", "").trim().takeIf { it.isNotBlank() }?.let { return it }
        val segments = payload.optJSONArray("segments") ?: return ""
        return buildList {
            for (index in 0 until segments.length()) {
                segments.optJSONObject(index)?.optString("text", "")?.trim()?.takeIf { it.isNotBlank() }?.let(::add)
            }
        }.joinToString(" ").trim()
    }

    private class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            connected?.complete(Unit)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            runCatching {
                val payload = JSONObject(text)
                when (payload.optString("type")) {
                    "transcription" -> handleTranscription(payload)
                    "error" -> {
                        val message = payload.optJSONObject("body")?.optString("message")
                            ?: "Cloud transcription failed"
                        failed = IllegalStateException(message)
                        finish?.complete(null)
                        Log.w(TAG, message)
                    }
                }
            }.onFailure {
                Log.w(TAG, "Unable to parse cloud transcription event", it)
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            failed = t
            connected?.completeExceptionally(t)
            finish?.complete(null)
            socket = null
            Log.w(TAG, "Cloud transcription socket failed", t)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            socket = null
        }
    }

    private fun decodeToPcm16kMono(audioFile: File): ByteArray {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        val monoSamples = mutableListOf<Short>()
        var sourceSampleRate = 44_100

        try {
            extractor.setDataSource(audioFile.absolutePath)
            val track = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: error("No audio track found")

            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: error("Missing audio mime")
            sourceSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            extractor.selectTrack(track)

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val info = MediaCodec.BufferInfo()
            var sawInputEnd = false
            var sawOutputEnd = false
            var channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)

            while (!sawOutputEnd) {
                if (!sawInputEnd) {
                    val inputIndex = codec.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        val inputBuffer = codec.getInputBuffer(inputIndex) ?: ByteBuffer.allocate(0)
                        inputBuffer.clear()
                        val size = extractor.readSampleData(inputBuffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            sawInputEnd = true
                        } else {
                            codec.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                when (val outputIndex = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val outputFormat = codec.outputFormat
                        sourceSampleRate = outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channelCount = outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> if (outputIndex >= 0) {
                        val outputBuffer = codec.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && info.size > 0) {
                            outputBuffer.position(info.offset)
                            outputBuffer.limit(info.offset + info.size)
                            appendMonoSamples(outputBuffer.slice(), channelCount, monoSamples)
                        }
                        sawOutputEnd = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                }
            }
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            extractor.release()
        }

        val resampled = resample(monoSamples, sourceSampleRate, SAMPLE_RATE)
        val out = ByteArrayOutputStream(resampled.size * 2)
        val buffer = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN)
        resampled.forEach { sample ->
            buffer.clear()
            buffer.putShort(sample)
            out.write(buffer.array())
        }
        return out.toByteArray()
    }

    private fun appendMonoSamples(buffer: ByteBuffer, channels: Int, output: MutableList<Short>) {
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        while (buffer.remaining() >= channels * 2) {
            var sum = 0
            repeat(channels) {
                sum += buffer.short.toInt()
            }
            output += (sum / channels).toShort()
        }
    }

    private fun resample(input: List<Short>, sourceRate: Int, targetRate: Int): ShortArray {
        if (input.isEmpty()) return ShortArray(0)
        if (sourceRate == targetRate) return input.toShortArray()

        val outputSize = ((input.size.toLong() * targetRate) / sourceRate).toInt().coerceAtLeast(1)
        return ShortArray(outputSize) { index ->
            val sourcePosition = index * sourceRate.toDouble() / targetRate.toDouble()
            val left = sourcePosition.toInt().coerceIn(0, input.lastIndex)
            val right = (left + 1).coerceIn(0, input.lastIndex)
            val fraction = sourcePosition - left
            ((input[left] * (1.0 - fraction)) + (input[right] * fraction)).roundToInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                .toShort()
        }
    }
}
