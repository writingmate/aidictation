package com.whispermate.aidictation.data.local

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.util.Log
import com.whispermate.aidictation.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.FloatBuffer
import java.nio.IntBuffer
import java.nio.LongBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.min

internal enum class ParakeetAbandonAction { IGNORE_IDLE, RETIRE, QUARANTINE }

internal fun parakeetAbandonAction(
    activeTranscriptions: Int,
    retiredGenerations: Int,
    maximumRetiredGenerations: Int = 1
): ParakeetAbandonAction = when {
    activeTranscriptions == 0 -> ParakeetAbandonAction.IGNORE_IDLE
    retiredGenerations >= maximumRetiredGenerations -> ParakeetAbandonAction.QUARANTINE
    else -> ParakeetAbandonAction.RETIRE
}

@Singleton
class ParakeetTranscriber @Inject constructor(
    private val modelAssets: ParakeetModelAssets
) {
    companion object {
        private const val TAG = "ParakeetTranscriber"
        private const val BLANK_TOKEN = "<blk>"
        private const val MAX_TOKENS_PER_STEP = 10
        private const val SAMPLE_RATE = 16_000
        private const val MAX_CHUNK_SECONDS = 30
        private const val DECODER_STATE_LAYERS = 2
        private const val DECODER_STATE_SIZE = 640
        private const val ENCODER_SIZE = 1024
        private const val MAX_RETIRED_GENERATIONS = 1
    }

    private class Generation(id: Int) {
        val mutex = Mutex()
        val dispatcher: ExecutorCoroutineDispatcher = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "parakeet-generation-$id").apply { isDaemon = true }
        }.asCoroutineDispatcher()
        var onnxModel: LoadedParakeetModel? = null
        var onnxEncoderModel: LoadedParakeetModel? = null
        var liteRtModel: ParakeetLiteRtModel? = null
        var activeUsers: Int = 0
        var activeTranscriptions: Int = 0
        var retired: Boolean = false
        var quarantined: Boolean = false
        var closeScheduled: Boolean = false

        fun closeModels() {
            val fullOnnx = onnxModel.also { onnxModel = null }
            val encoderOnnx = onnxEncoderModel.also { onnxEncoderModel = null }
            val liteRt = liteRtModel.also { liteRtModel = null }
            runCatching { liteRt?.close() }
            runCatching { encoderOnnx?.close() }
            runCatching { fullOnnx?.close() }
            dispatcher.close()
        }
    }

    private val generationLock = Any()
    private val generationCounter = AtomicInteger()
    private val retiredGenerations = mutableSetOf<Generation>()
    private val retirementScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var generation = newGeneration()
    private val audioDecoder = AndroidAudioDecoder()
    private val ortEnvironment: OrtEnvironment = OrtEnvironment.getEnvironment()

    /**
     * Detaches native work that ignored cancellation. At most one stuck generation is retained;
     * further local attempts fail fast instead of repeatedly loading models and consuming workers.
     */
    fun abandonCurrentGeneration(): Boolean {
        synchronized(generationLock) {
            val current = generation
            when (parakeetAbandonAction(
                current.activeTranscriptions,
                retiredGenerations.size,
                MAX_RETIRED_GENERATIONS
            )) {
                ParakeetAbandonAction.IGNORE_IDLE -> return false
                ParakeetAbandonAction.QUARANTINE -> {
                    current.quarantined = true
                    return false
                }
                ParakeetAbandonAction.RETIRE -> Unit
            }
            current.retired = true
            retiredGenerations += current
            generation = newGeneration()
            return true
        }
    }

    suspend fun prewarm(): Result<Unit> {
        val activeGeneration = runCatching { acquireGeneration(transcription = false) }
            .getOrElse { return Result.failure(it) }
        return try {
            withContext(activeGeneration.dispatcher) {
                runCatching {
                    activeGeneration.mutex.withLock {
                        val runtime = ParakeetRuntime.fromConfig(BuildConfig.PARAKEET_RUNTIME)
                        val startMs = System.currentTimeMillis()
                        Log.d(TAG, "Prewarming Parakeet ${runtime.displayName}")
                        when (runtime) {
                            ParakeetRuntime.ONNX -> {
                                if (activeGeneration.onnxModel == null) {
                                    activeGeneration.onnxModel = loadOnnxModel()
                                }
                            }
                            ParakeetRuntime.LITERT -> {
                                if (activeGeneration.onnxEncoderModel == null) {
                                    activeGeneration.onnxEncoderModel = loadOnnxModel(
                                        loadDecoder = false,
                                        runtime = ParakeetRuntime.LITERT
                                    )
                                }
                                if (activeGeneration.liteRtModel == null) {
                                    activeGeneration.liteRtModel = loadLiteRtModel()
                                }
                            }
                        }
                        Log.d(TAG, "Prewarmed Parakeet ${runtime.displayName} in ${System.currentTimeMillis() - startMs}ms")
                        Unit
                    }
                }
            }
        } finally {
            releaseGeneration(activeGeneration, transcription = false)
        }
    }

    suspend fun transcribe(audioFile: File): Result<String> {
        val activeGeneration = runCatching { acquireGeneration(transcription = true) }
            .getOrElse { return Result.failure(it) }
        return try {
            withContext(activeGeneration.dispatcher) {
                runCatching {
                    activeGeneration.mutex.withLock {
                        val runtime = ParakeetRuntime.fromConfig(BuildConfig.PARAKEET_RUNTIME)
                        val samples = audioDecoder.decodeToMono16k(audioFile)
                        if (samples.isEmpty()) return@withLock ""

                        Log.d(TAG, "Running Parakeet ${runtime.displayName} on ${samples.size} samples at ${SAMPLE_RATE}Hz")
                        val text = when (runtime) {
                            ParakeetRuntime.ONNX -> {
                                val loadedModel = activeGeneration.onnxModel
                                    ?: loadOnnxModel().also { activeGeneration.onnxModel = it }
                                val encoded = loadedModel.encodeSamples(samples)
                                val tokenIds = loadedModel.decode(encoded)
                                loadedModel.decodeTokens(tokenIds)
                            }
                            ParakeetRuntime.LITERT -> {
                                val encoderModel = activeGeneration.onnxEncoderModel
                                    ?: loadOnnxModel(loadDecoder = false, runtime = ParakeetRuntime.LITERT)
                                        .also { activeGeneration.onnxEncoderModel = it }
                                val loadedModel = activeGeneration.liteRtModel
                                    ?: loadLiteRtModel().also { activeGeneration.liteRtModel = it }
                                encoderModel.decodeWithLiteRt(samples, loadedModel)
                            }
                        }
                        Log.d(TAG, "Local transcription succeeded")
                        text
                    }
                }
            }
        } finally {
            releaseGeneration(activeGeneration, transcription = true)
        }
    }

    private fun newGeneration(): Generation = Generation(generationCounter.incrementAndGet())

    private fun acquireGeneration(transcription: Boolean): Generation = synchronized(generationLock) {
        val current = generation
        check(!current.quarantined) {
            "Offline transcription is recovering from an earlier attempt. Switch to cloud mode or restart the app."
        }
        current.activeUsers += 1
        if (transcription) current.activeTranscriptions += 1
        current
    }

    private fun releaseGeneration(released: Generation, transcription: Boolean) {
        var shouldClose = false
        synchronized(generationLock) {
            released.activeUsers = (released.activeUsers - 1).coerceAtLeast(0)
            if (transcription) {
                released.activeTranscriptions = (released.activeTranscriptions - 1).coerceAtLeast(0)
            }
            if (!released.retired && released.activeTranscriptions == 0) {
                released.quarantined = false
            }
            if (released.retired && released.activeUsers == 0 && !released.closeScheduled) {
                released.closeScheduled = true
                shouldClose = true
            }
        }
        if (shouldClose) {
            retirementScope.launch {
                try {
                    released.closeModels()
                } finally {
                    synchronized(generationLock) { retiredGenerations.remove(released) }
                }
            }
        }
    }

    private suspend fun loadOnnxModel(
        loadDecoder: Boolean = true,
        runtime: ParakeetRuntime = ParakeetRuntime.ONNX
    ): LoadedParakeetModel {
        val directory = modelAssets.requireModelDirectory(runtime)
        Log.d(TAG, "Loading on-device transcription model")
        return LoadedParakeetModel(
            environment = ortEnvironment,
            directory = directory,
            loadDecoder = loadDecoder
        )
    }

    private suspend fun loadLiteRtModel(): ParakeetLiteRtModel {
        val directory = modelAssets.requireModelDirectory(ParakeetRuntime.LITERT)
        Log.d(TAG, "Loading on-device LiteRT transcription model")
        return ParakeetLiteRtModel.load(directory)
    }

    private class LoadedParakeetModel(
        private val environment: OrtEnvironment,
        directory: File,
        loadDecoder: Boolean
    ) : AutoCloseable {
        private val sessionOptions = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.NO_OPT)
            setIntraOpNumThreads(Runtime.getRuntime().availableProcessors().coerceAtMost(4))
        }
        private val preprocessor = createSession(directory, "nemo128.onnx")
        private val encoder = createSession(directory, "encoder-model.int8.onnx")
        private val decoderJoint = if (loadDecoder) createSession(directory, "decoder_joint-model.int8.onnx") else null
        private val vocab = loadVocabulary(File(directory, "vocab.txt"))
        private val blankIndex = vocab.indexOf(BLANK_TOKEN).takeIf { it >= 0 }
            ?: error("Parakeet vocabulary is missing $BLANK_TOKEN")
        private val vocabSize = vocab.size

        override fun close() {
            runCatching { decoderJoint?.close() }
            runCatching { encoder.close() }
            runCatching { preprocessor.close() }
            runCatching { sessionOptions.close() }
        }

        fun encodeSamples(samples: FloatArray): EncodedAudio {
            val chunks = mutableListOf<EncodedAudio>()
            var offset = 0

            while (offset < samples.size) {
                val chunkSize = min(SAMPLE_RATE * MAX_CHUNK_SECONDS, samples.size - offset)
                val chunk = FloatArray(chunkSize)
                samples.copyInto(chunk, startIndex = offset, endIndex = offset + chunkSize)

                val features = runPreprocessor(chunk, chunkSize)
                chunks.add(runEncoder(features))
                offset += chunkSize
            }

            return concatenateEncodedAudio(chunks)
        }

        fun decodeWithLiteRt(samples: FloatArray, liteRtModel: ParakeetLiteRtModel): String {
            val encoded = encodeSamples(samples)
            return liteRtModel.transcribeEncoded(encoded.values, encoded.length, encoded.timeSteps)
        }

        private fun createSession(directory: File, fileName: String): OrtSession {
            val file = File(directory, fileName)
            val startMs = System.currentTimeMillis()
            Log.d(TAG, "Opening Parakeet ONNX session $fileName (${file.length()} bytes)")
            return environment.createSession(file.absolutePath, sessionOptions).also {
                Log.d(TAG, "Opened Parakeet ONNX session $fileName in ${System.currentTimeMillis() - startMs}ms")
            }
        }

        private fun runPreprocessor(samples: FloatArray, validSampleCount: Int): Features {
            val waveformShape = longArrayOf(1, samples.size.toLong())
            val lengthShape = longArrayOf(1)
            OnnxTensor.createTensor(environment, FloatBuffer.wrap(samples), waveformShape).use { waveformTensor ->
                OnnxTensor.createTensor(environment, LongBuffer.wrap(longArrayOf(validSampleCount.toLong())), lengthShape)
                    .use { lengthTensor ->
                        preprocessor.run(
                            mapOf(
                                "waveforms" to waveformTensor,
                                "waveforms_lens" to lengthTensor
                            )
                        ).use { results ->
                            val featuresTensor = results[0] as OnnxTensor
                            val features = featuresTensor.floatBuffer.toFloatArray()
                            val featuresLengthTensor = results[1] as OnnxTensor
                            val featuresLength = featuresLengthTensor.longBuffer.get(0)
                            return Features(features, featuresLength, features.size / 128)
                        }
                    }
            }
        }

        fun runEncoder(features: Features): EncodedAudio {
            OnnxTensor.createTensor(
                environment,
                FloatBuffer.wrap(features.values),
                longArrayOf(1, 128, features.timeSteps.toLong())
            ).use { audioSignalTensor ->
                OnnxTensor.createTensor(environment, LongBuffer.wrap(longArrayOf(features.length)), longArrayOf(1))
                    .use { lengthTensor ->
                        encoder.run(
                            mapOf(
                                "audio_signal" to audioSignalTensor,
                                "length" to lengthTensor
                            )
                        ).use { results ->
                            val outputsTensor = results[0] as OnnxTensor
                            val outputs = outputsTensor.floatBuffer.toFloatArray()
                            val encodedLengthTensor = results[1] as OnnxTensor
                            val encodedLength = encodedLengthTensor.longBuffer.get(0).toInt()
                            val timeSteps = (outputs.size / ENCODER_SIZE).coerceAtLeast(0)
                            return EncodedAudio(outputs, min(encodedLength, timeSteps), timeSteps)
                        }
                    }
            }
        }

        private fun concatenateEncodedAudio(chunks: List<EncodedAudio>): EncodedAudio {
            val totalLength = chunks.sumOf { it.length }
            if (totalLength == 0) return EncodedAudio(FloatArray(0), 0, 0)

            val values = FloatArray(ENCODER_SIZE * totalLength)
            var targetTime = 0

            for (chunk in chunks) {
                for (timeIndex in 0 until chunk.length) {
                    for (dimension in 0 until ENCODER_SIZE) {
                        values[(dimension * totalLength) + targetTime + timeIndex] =
                            chunk.values[(dimension * chunk.timeSteps) + timeIndex]
                    }
                }
                targetTime += chunk.length
            }

            return EncodedAudio(values, totalLength, totalLength)
        }

        fun decode(encoded: EncodedAudio): List<Int> {
            val tokens = mutableListOf<Int>()
            var state1 = FloatArray(DECODER_STATE_LAYERS * DECODER_STATE_SIZE)
            var state2 = FloatArray(DECODER_STATE_LAYERS * DECODER_STATE_SIZE)
            var timeIndex = 0
            var emittedTokens = 0

            while (timeIndex < encoded.length) {
                val frame = encoded.frameAt(timeIndex)
                val stepResult = runDecoder(frame, tokens.lastOrNull() ?: blankIndex, state1, state2)
                val token = argmax(stepResult.logits, 0, vocabSize)

                if (token != blankIndex) {
                    tokens.add(token)
                    state1 = stepResult.state1
                    state2 = stepResult.state2
                    emittedTokens += 1
                }

                when {
                    stepResult.duration > 0 -> {
                        timeIndex += stepResult.duration
                        emittedTokens = 0
                    }
                    token == blankIndex || emittedTokens == MAX_TOKENS_PER_STEP -> {
                        timeIndex += 1
                        emittedTokens = 0
                    }
                }
            }

            return tokens
        }

        fun decodeTokens(tokenIds: List<Int>): String {
            val joined = tokenIds.asSequence()
                .mapNotNull { id -> vocab.getOrNull(id) }
                .filterNot { token -> token == BLANK_TOKEN || (token.startsWith("<") && token.endsWith(">")) }
                .joinToString("")
                .replace('\u2581', ' ')
            return joined
                .replace(Regex("^\\s+"), "")
                .replace(Regex("\\s+([,.;:!?%])"), "$1")
                .replace(Regex("\\s+"), " ")
                .trim()
        }

        private fun runDecoder(
            encoderFrame: FloatArray,
            previousToken: Int,
            state1: FloatArray,
            state2: FloatArray
        ): DecoderStep {
            lateinit var decoderOutput: FloatArray
            lateinit var outputState1: FloatArray
            lateinit var outputState2: FloatArray

            OnnxTensor.createTensor(
                environment,
                FloatBuffer.wrap(encoderFrame),
                longArrayOf(1, ENCODER_SIZE.toLong(), 1)
            ).use { encoderTensor ->
                OnnxTensor.createTensor(environment, IntBuffer.wrap(intArrayOf(previousToken)), longArrayOf(1, 1))
                    .use { targetTensor ->
                        OnnxTensor.createTensor(environment, IntBuffer.wrap(intArrayOf(1)), longArrayOf(1))
                            .use { targetLengthTensor ->
                                OnnxTensor.createTensor(
                                    environment,
                                    FloatBuffer.wrap(state1),
                                    longArrayOf(DECODER_STATE_LAYERS.toLong(), 1, DECODER_STATE_SIZE.toLong())
                                ).use { state1Tensor ->
                                    OnnxTensor.createTensor(
                                        environment,
                                        FloatBuffer.wrap(state2),
                                        longArrayOf(DECODER_STATE_LAYERS.toLong(), 1, DECODER_STATE_SIZE.toLong())
                                    ).use { state2Tensor ->
                                        requireNotNull(decoderJoint) { "Parakeet ONNX decoder-joint model was not loaded" }.run(
                                            mapOf(
                                                "encoder_outputs" to encoderTensor,
                                                "targets" to targetTensor,
                                                "target_length" to targetLengthTensor,
                                                "input_states_1" to state1Tensor,
                                                "input_states_2" to state2Tensor
                                            )
                                        ).use { results ->
                                            decoderOutput = (results.get("outputs").get() as OnnxTensor).floatBuffer.toFloatArray()
                                            outputState1 = (results.get("output_states_1").get() as OnnxTensor).floatBuffer.toFloatArray()
                                            outputState2 = (results.get("output_states_2").get() as OnnxTensor).floatBuffer.toFloatArray()
                                        }
                                    }
                                }
                            }
                    }
                }
            val duration = argmax(decoderOutput, vocabSize, decoderOutput.size) - vocabSize
            return DecoderStep(decoderOutput, duration, outputState1, outputState2)
        }

        private fun EncodedAudio.frameAt(timeIndex: Int): FloatArray {
            return FloatArray(ENCODER_SIZE) { dimension ->
                values[(dimension * timeSteps) + timeIndex]
            }
        }

        private fun loadVocabulary(file: File): List<String> {
            val tokensById = mutableMapOf<Int, String>()
            file.forEachLine(Charsets.UTF_8) { line ->
                val separator = line.lastIndexOf(' ')
                if (separator <= 0) return@forEachLine
                val token = line.substring(0, separator)
                val id = line.substring(separator + 1).toIntOrNull() ?: return@forEachLine
                tokensById[id] = token
            }
            return List((tokensById.keys.maxOrNull() ?: -1) + 1) { id -> tokensById[id].orEmpty() }
        }

        private fun argmax(values: FloatArray, fromInclusive: Int, toExclusive: Int): Int {
            var bestIndex = fromInclusive
            var bestValue = Float.NEGATIVE_INFINITY
            for (index in fromInclusive until toExclusive) {
                val value = values[index]
                if (value > bestValue) {
                    bestValue = value
                    bestIndex = index
                }
            }
            return bestIndex
        }

        private fun FloatBuffer.toFloatArray(): FloatArray {
            val duplicate = duplicate()
            duplicate.rewind()
            return FloatArray(duplicate.remaining()).also { duplicate.get(it) }
        }

        private data class Features(
            val values: FloatArray,
            val length: Long,
            val timeSteps: Int
        )

        private data class EncodedAudio(
            val values: FloatArray,
            val length: Int,
            val timeSteps: Int
        )

        private data class DecoderStep(
            val logits: FloatArray,
            val duration: Int,
            val state1: FloatArray,
            val state2: FloatArray
        )
    }
}
