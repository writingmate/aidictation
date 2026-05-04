package com.whispermate.aidictation.data.local

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.floor
import kotlin.math.roundToInt

class AndroidAudioDecoder {
    companion object {
        private const val TAG = "AndroidAudioDecoder"
        private const val TIMEOUT_US = 10_000L
        private const val TARGET_SAMPLE_RATE = 16_000
    }

    fun decodeToMono16k(audioFile: File): FloatArray {
        val decoded = decodeToMono(audioFile)
        if (decoded.sampleRate == TARGET_SAMPLE_RATE) return decoded.samples
        return resample(decoded.samples, decoded.sampleRate, TARGET_SAMPLE_RATE)
    }

    private fun decodeToMono(audioFile: File): DecodedAudio {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null

        try {
            extractor.setDataSource(audioFile.absolutePath)
            val trackIndex = findAudioTrack(extractor)
                ?: throw IllegalArgumentException("No audio track in ${audioFile.name}")
            extractor.selectTrack(trackIndex)

            val format = extractor.getTrackFormat(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalArgumentException("Audio track is missing MIME type")
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val pcm = ArrayList<Float>(estimateCapacity(format))
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var outputSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var outputChannelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var outputEncoding = AudioFormat.ENCODING_PCM_16BIT

            while (!outputDone) {
                if (!inputDone) {
                    val inputIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val inputBuffer = codec.getInputBuffer(inputIndex)
                            ?: throw IllegalStateException("Decoder input buffer unavailable")
                        inputBuffer.clear()
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(
                                inputIndex,
                                0,
                                sampleSize,
                                extractor.sampleTime,
                                0
                            )
                            extractor.advance()
                        }
                    }
                }

                when (val outputIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val outputFormat = codec.outputFormat
                        outputSampleRate = outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        outputChannelCount = outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        outputEncoding = if (outputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        } else {
                            AudioFormat.ENCODING_PCM_16BIT
                        }
                    }
                    else -> {
                        if (outputIndex >= 0) {
                            val outputBuffer = codec.getOutputBuffer(outputIndex)
                            if (outputBuffer != null && info.size > 0) {
                                outputBuffer.position(info.offset)
                                outputBuffer.limit(info.offset + info.size)
                                appendMonoSamples(
                                    outputBuffer.slice().order(ByteOrder.LITTLE_ENDIAN),
                                    outputEncoding,
                                    outputChannelCount,
                                    pcm
                                )
                            }
                            outputDone = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            codec.releaseOutputBuffer(outputIndex, false)
                        }
                    }
                }
            }

            return DecodedAudio(pcm.toFloatArray(), outputSampleRate)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to decode ${audioFile.name}", e)
            throw e
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            extractor.release()
        }
    }

    private fun findAudioTrack(extractor: MediaExtractor): Int? {
        for (index in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(index)
            val mime = format.getString(MediaFormat.KEY_MIME)
            if (mime?.startsWith("audio/") == true) return index
        }
        return null
    }

    private fun estimateCapacity(format: MediaFormat): Int {
        val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
            format.getLong(MediaFormat.KEY_DURATION)
        } else {
            0L
        }
        val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        return ((durationUs / 1_000_000.0) * sampleRate).roundToInt().coerceAtLeast(sampleRate)
    }

    private fun appendMonoSamples(
        buffer: ByteBuffer,
        encoding: Int,
        channelCount: Int,
        output: MutableList<Float>
    ) {
        val channels = channelCount.coerceAtLeast(1)
        when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> appendFloatPcm(buffer, channels, output)
            AudioFormat.ENCODING_PCM_8BIT -> append8BitPcm(buffer, channels, output)
            else -> append16BitPcm(buffer, channels, output)
        }
    }

    private fun append16BitPcm(buffer: ByteBuffer, channels: Int, output: MutableList<Float>) {
        val frameBytes = channels * 2
        while (buffer.remaining() >= frameBytes) {
            var sum = 0f
            repeat(channels) {
                sum += (buffer.getShort() / 32768f).coerceIn(-1f, 1f)
            }
            output.add(sum / channels)
        }
    }

    private fun appendFloatPcm(buffer: ByteBuffer, channels: Int, output: MutableList<Float>) {
        val frameBytes = channels * 4
        while (buffer.remaining() >= frameBytes) {
            var sum = 0f
            repeat(channels) {
                sum += buffer.getFloat().coerceIn(-1f, 1f)
            }
            output.add(sum / channels)
        }
    }

    private fun append8BitPcm(buffer: ByteBuffer, channels: Int, output: MutableList<Float>) {
        val frameBytes = channels
        while (buffer.remaining() >= frameBytes) {
            var sum = 0f
            repeat(channels) {
                sum += ((buffer.get().toInt() and 0xff) - 128) / 128f
            }
            output.add((sum / channels).coerceIn(-1f, 1f))
        }
    }

    private fun resample(samples: FloatArray, sourceRate: Int, targetRate: Int): FloatArray {
        if (samples.isEmpty()) return samples
        if (sourceRate <= 0) return samples

        val outputSize = ((samples.size.toDouble() * targetRate) / sourceRate)
            .roundToInt()
            .coerceAtLeast(1)
        val ratio = sourceRate.toDouble() / targetRate
        return FloatArray(outputSize) { outputIndex ->
            val sourcePosition = outputIndex * ratio
            val lower = floor(sourcePosition).toInt().coerceIn(samples.indices)
            val upper = (lower + 1).coerceAtMost(samples.lastIndex)
            val fraction = (sourcePosition - lower).toFloat()
            samples[lower] + ((samples[upper] - samples[lower]) * fraction)
        }
    }

    private data class DecodedAudio(
        val samples: FloatArray,
        val sampleRate: Int
    )
}
