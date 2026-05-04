package com.whispermate.aidictation.data.local

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.FloatBuffer
import java.nio.IntBuffer
import java.nio.LongBuffer
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.min

@Singleton
class ParakeetTranscriber @Inject constructor(
    private val modelAssets: ParakeetModelAssets
) {
    companion object {
        private const val TAG = "ParakeetTranscriber"
        private const val BLANK_TOKEN = "<blk>"
        private const val MAX_TOKENS_PER_STEP = 10
        private const val SAMPLE_RATE = 16_000
        private const val DECODER_STATE_LAYERS = 2
        private const val DECODER_STATE_SIZE = 640
        private const val ENCODER_SIZE = 1024
    }

    private val mutex = Mutex()
    private val audioDecoder = AndroidAudioDecoder()
    private val ortEnvironment: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var model: LoadedParakeetModel? = null

    suspend fun transcribe(audioFile: File): Result<String> = withContext(Dispatchers.Default) {
        runCatching {
            mutex.withLock {
                val loadedModel = model ?: loadModel().also { model = it }
                val samples = audioDecoder.decodeToMono16k(audioFile)
                if (samples.isEmpty()) return@withLock ""

                Log.d(TAG, "Running Parakeet on ${samples.size} samples at ${SAMPLE_RATE}Hz")
                val features = loadedModel.runPreprocessor(samples)
                val encoded = loadedModel.runEncoder(features)
                val tokenIds = loadedModel.decode(encoded)
                val text = loadedModel.decodeTokens(tokenIds)
                Log.d(TAG, "LOCAL_TRANSCRIPTION_OK ${text.take(100)}")
                text
            }
        }
    }

    private suspend fun loadModel(): LoadedParakeetModel {
        val directory = modelAssets.requireModelDirectory()
        Log.d(TAG, "Loading Parakeet model from ${directory.absolutePath}")
        return LoadedParakeetModel(
            environment = ortEnvironment,
            directory = directory
        )
    }

    private class LoadedParakeetModel(
        private val environment: OrtEnvironment,
        directory: File
    ) {
        private val sessionOptions = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setIntraOpNumThreads(Runtime.getRuntime().availableProcessors().coerceAtMost(4))
        }
        private val preprocessor = environment.createSession(
            File(directory, "nemo128.onnx").absolutePath,
            sessionOptions
        )
        private val encoder = environment.createSession(
            File(directory, "encoder-model.int8.onnx").absolutePath,
            sessionOptions
        )
        private val decoderJoint = environment.createSession(
            File(directory, "decoder_joint-model.int8.onnx").absolutePath,
            sessionOptions
        )
        private val vocab = loadVocabulary(File(directory, "vocab.txt"))
        private val blankIndex = vocab.indexOf(BLANK_TOKEN).takeIf { it >= 0 }
            ?: error("Parakeet vocabulary is missing $BLANK_TOKEN")
        private val vocabSize = vocab.size

        fun runPreprocessor(samples: FloatArray): Features {
            val waveformShape = longArrayOf(1, samples.size.toLong())
            val lengthShape = longArrayOf(1)
            OnnxTensor.createTensor(environment, FloatBuffer.wrap(samples), waveformShape).use { waveformTensor ->
                OnnxTensor.createTensor(environment, LongBuffer.wrap(longArrayOf(samples.size.toLong())), lengthShape)
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
                            return Features(features, featuresLength)
                        }
                    }
            }
        }

        fun runEncoder(features: Features): EncodedAudio {
            OnnxTensor.createTensor(
                environment,
                FloatBuffer.wrap(features.values),
                longArrayOf(1, 128, features.length)
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
                .filterNot { token -> token == BLANK_TOKEN || token.startsWith("<|") }
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
            OnnxTensor.createTensor(
                environment,
                FloatBuffer.wrap(encoderFrame),
                longArrayOf(1, ENCODER_SIZE.toLong(), 1)
            ).use { encoderTensor ->
                OnnxTensor.createTensor(environment, IntBuffer.wrap(intArrayOf(previousToken)), longArrayOf(1, 1))
                    .use { targetsTensor ->
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
                                        decoderJoint.run(
                                            mapOf(
                                                "encoder_outputs" to encoderTensor,
                                                "targets" to targetsTensor,
                                                "target_length" to targetLengthTensor,
                                                "input_states_1" to state1Tensor,
                                                "input_states_2" to state2Tensor
                                            )
                                        ).use { results ->
                                            val outputTensor = results[0] as OnnxTensor
                                            val logits = outputTensor.floatBuffer.toFloatArray()
                                            val outputState1 = (results[2] as OnnxTensor).floatBuffer.toFloatArray()
                                            val outputState2 = (results[3] as OnnxTensor).floatBuffer.toFloatArray()
                                            val duration = argmax(logits, vocabSize, logits.size) - vocabSize
                                            return DecoderStep(logits, duration, outputState1, outputState2)
                                        }
                                    }
                                }
                            }
                    }
            }
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
            val length: Long
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
