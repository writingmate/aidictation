package com.whispermate.aidictation.data.local

import android.util.Log
import com.google.ai.edge.litert.Accelerator
import com.google.ai.edge.litert.CompiledModel
import com.google.ai.edge.litert.Environment
import com.google.ai.edge.litert.TensorBuffer
import java.io.File

internal class ParakeetLiteRtModel private constructor(
    private val environment: Environment,
    private val decoder: CompiledModel,
    private val joint: CompiledModel,
    directory: File
) : AutoCloseable {
    private val vocab = loadVocabulary(File(directory, "vocab.txt"))
    private val blankIndex = vocab.indexOf(BLANK_TOKEN).takeIf { it >= 0 }
        ?: error("Parakeet vocabulary is missing $BLANK_TOKEN")
    private val vocabSize = vocab.size

    fun transcribeEncoded(values: FloatArray, length: Int, timeSteps: Int): String {
        val encoded = EncodedAudio(values, length, timeSteps)
        val tokenIds = decode(encoded)
        return decodeTokens(tokenIds)
    }

    private fun decode(encoded: EncodedAudio): List<Int> {
        val tokens = mutableListOf<Int>()
        var state1 = FloatArray(DECODER_STATE_LAYERS * DECODER_STATE_SIZE)
        var state2 = FloatArray(DECODER_STATE_LAYERS * DECODER_STATE_SIZE)
        var timeIndex = 0
        var emittedTokens = 0

        while (timeIndex < encoded.length) {
            val frame = encoded.frameAt(timeIndex)
            val stepResult = runDecoder(frame, tokens.lastOrNull() ?: blankIndex, state1, state2)
            val token = argmax(stepResult.tokenLogits, 0, vocabSize.coerceAtMost(stepResult.tokenLogits.size))

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

    private fun runDecoder(
        encoderFrame: FloatArray,
        previousToken: Int,
        state1: FloatArray,
        state2: FloatArray
    ): DecoderStep {
        lateinit var decoderOutput: FloatArray
        lateinit var outputState1: FloatArray
        lateinit var outputState2: FloatArray

        decoder.runWithInputs { inputs ->
            inputs.requireSize(3, "decoder inputs")
            inputs[0].writeLong(longArrayOf(previousToken.toLong()))
            inputs[1].writeFloat(state1)
            inputs[2].writeFloat(state2)
        }.useAndRead {
            it.requireSize(3, "decoder outputs")
            decoderOutput = it[0].readFloat()
            outputState1 = it[1].readFloat()
            outputState2 = it[2].readFloat()
        }

        val outputs = joint.runWithInputs { inputs ->
            inputs.requireSize(2, "joint inputs")
            inputs[0].writeFloat(encoderFrame)
            inputs[1].writeFloat(decoderOutput)
        }
        return outputs.useAndRead {
            it.requireSize(2, "joint outputs")
            val tokenLogits = it[0].readFloat()
            val durationLogits = it[1].readFloat()
            DecoderStep(
                tokenLogits = tokenLogits,
                duration = argmax(durationLogits, 0, durationLogits.size),
                state1 = outputState1,
                state2 = outputState2
            )
        }
    }

    private fun decodeTokens(tokenIds: List<Int>): String {
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

    private fun EncodedAudio.frameAt(timeIndex: Int): FloatArray {
        return FloatArray(ENCODER_SIZE) { dimension ->
            values[(dimension * timeSteps) + timeIndex]
        }
    }

    override fun close() {
        joint.close()
        decoder.close()
        environment.close()
    }

    companion object {
        private const val BLANK_TOKEN = "<blk>"
        private const val MAX_TOKENS_PER_STEP = 10
        private const val DECODER_STATE_LAYERS = 2
        private const val DECODER_STATE_SIZE = 640
        private const val ENCODER_SIZE = 1024
        private const val TAG = "ParakeetLiteRtModel"

        fun load(directory: File): ParakeetLiteRtModel {
            val environment = Environment.create()
            val options = CompiledModel.Options(Accelerator.CPU)
            Log.d(TAG, "Opening Parakeet LiteRT decoder_model_float32.tflite")
            val decoder = CompiledModel.create(
                File(directory, "decoder_model_float32.tflite").absolutePath,
                options,
                environment
            )
            Log.d(TAG, "Opening Parakeet LiteRT joint_model_float32.tflite")
            val joint = CompiledModel.create(
                File(directory, "joint_model_float32.tflite").absolutePath,
                options,
                environment
            )
            return ParakeetLiteRtModel(
                environment = environment,
                decoder = decoder,
                joint = joint,
                directory = directory
            )
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
    }

    private data class EncodedAudio(
        val values: FloatArray,
        val length: Int,
        val timeSteps: Int
    )

    private data class DecoderStep(
        val tokenLogits: FloatArray,
        val duration: Int,
        val state1: FloatArray,
        val state2: FloatArray
    )
}

private fun CompiledModel.runWithInputs(fillInputs: (List<TensorBuffer>) -> Unit): List<TensorBuffer> {
    val inputs = createInputBuffers()
    return try {
        fillInputs(inputs)
        run(inputs)
    } finally {
        inputs.closeAll()
    }
}

private inline fun <T> List<TensorBuffer>.useAndRead(block: (List<TensorBuffer>) -> T): T {
    return try {
        block(this)
    } finally {
        closeAll()
    }
}

private fun List<TensorBuffer>.closeAll() {
    forEach { buffer -> buffer.close() }
}

private fun List<TensorBuffer>.requireSize(minSize: Int, label: String) {
    require(size >= minSize) { "Parakeet LiteRT $label expected at least $minSize buffers, got $size" }
}
