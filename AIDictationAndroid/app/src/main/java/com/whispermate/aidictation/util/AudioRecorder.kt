package com.whispermate.aidictation.util

import android.annotation.SuppressLint
import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale
import kotlin.math.pow

class AudioRecorder(
    private val context: Context,
    private val autoStopOnSilenceEnabled: Boolean = false
) {
    companion object {
        private const val TAG = "AudioRecorder"
        private const val MAX_AMPLITUDE = 32767f
        private const val BASE_NOISE_FLOOR = 260f
        private const val MIN_NOISE_FLOOR = 140f
        private const val MAX_NOISE_FLOOR = 6500f
        private const val NOISE_ALPHA_RISE = 0.06f
        private const val NOISE_ALPHA_FALL = 0.015f
        private const val START_THRESHOLD_RATIO = 2.6f
        private const val STOP_THRESHOLD_RATIO = 1.7f
        private const val MIN_START_THRESHOLD = 820f
        private const val MIN_STOP_THRESHOLD = 500f
        private const val SPEECH_START_FRAMES = 2
        private const val FRAME_LOG_INTERVAL = 20
    }

    private var mediaRecorder: MediaRecorder? = null
    private var audioLevelJob: Job? = null
    private var outputFile: File? = null
    private var startTime: Long = 0
    private var frequencyAnalyzer: FrequencyAnalyzer? = null

    // Speech detection with adaptive thresholding
    private var speechDetected = false
    private var speechActive = false
    private var silenceStartTime: Long = 0
    private val silenceDurationMs = 1500L
    private var noiseFloor: Float = BASE_NOISE_FLOOR
    private var speechStartThreshold: Float = MIN_START_THRESHOLD
    private var speechStopThreshold: Float = MIN_STOP_THRESHOLD
    private var aboveStartFrames: Int = 0

    // Debug metrics for tuning in adb logcat
    private var metricFrameCount: Int = 0
    private var metricSpeechFrames: Int = 0
    private var metricNoiseFrames: Int = 0
    private var metricSpeechTransitions: Int = 0
    private var metricMaxAmplitude: Int = 0
    private var metricAmplitudeSum: Long = 0
    private var metricNoiseAmplitudeSum: Long = 0
    private var metricSpeechAmplitudeSum: Long = 0

    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _audioLevel = MutableStateFlow(0f)
    val audioLevel: StateFlow<Float> = _audioLevel.asStateFlow()

    private val _frequencyBands = MutableStateFlow(FloatArray(6) { 0f })
    val frequencyBands: StateFlow<FloatArray> = _frequencyBands.asStateFlow()

    private val _speechProbability = MutableStateFlow(0f)
    val speechProbability: StateFlow<Float> = _speechProbability.asStateFlow()

    private val _shouldAutoStop = MutableStateFlow(false)
    val shouldAutoStop: StateFlow<Boolean> = _shouldAutoStop.asStateFlow()

    init {
        frequencyAnalyzer = FrequencyAnalyzer(sampleRate = 44100, bandCount = 6)
    }

    @SuppressLint("MissingPermission")
    fun start(): File? {
        try {
            val recordingsDir = File(context.filesDir, "recordings")
            recordingsDir.mkdirs()
            outputFile = File(recordingsDir, "recording_${System.currentTimeMillis()}.m4a")

            // Start MediaRecorder for high-quality output
            mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioSamplingRate(44100)
                setAudioEncodingBitRate(128000)
                setOutputFile(outputFile?.absolutePath)
                prepare()
                start()
            }

            startTime = System.currentTimeMillis()
            _isRecording.value = true
            _shouldAutoStop.value = false
            speechDetected = false
            speechActive = false
            silenceStartTime = 0
            noiseFloor = BASE_NOISE_FLOOR
            speechStartThreshold = MIN_START_THRESHOLD
            speechStopThreshold = MIN_STOP_THRESHOLD
            aboveStartFrames = 0
            metricFrameCount = 0
            metricSpeechFrames = 0
            metricNoiseFrames = 0
            metricSpeechTransitions = 0
            metricMaxAmplitude = 0
            metricAmplitudeSum = 0
            metricNoiseAmplitudeSum = 0
            metricSpeechAmplitudeSum = 0
            frequencyAnalyzer?.reset()

            // Start audio level monitoring and speech detection
            audioLevelJob = CoroutineScope(Dispatchers.Default).launch {
                var smoothedLevel = 0f
                while (isActive && _isRecording.value) {
                    try {
                        val maxAmplitude = mediaRecorder?.maxAmplitude ?: 0
                        metricFrameCount++
                        metricMaxAmplitude = maxOf(metricMaxAmplitude, maxAmplitude)
                        metricAmplitudeSum += maxAmplitude.toLong()

                        if (!speechActive || maxAmplitude <= speechStopThreshold) {
                            val alpha = if (maxAmplitude > noiseFloor) NOISE_ALPHA_RISE else NOISE_ALPHA_FALL
                            noiseFloor = ((1f - alpha) * noiseFloor + alpha * maxAmplitude)
                                .coerceIn(MIN_NOISE_FLOOR, MAX_NOISE_FLOOR)
                        }

                        speechStartThreshold = maxOf(MIN_START_THRESHOLD, noiseFloor * START_THRESHOLD_RATIO)
                        speechStopThreshold = maxOf(MIN_STOP_THRESHOLD, noiseFloor * STOP_THRESHOLD_RATIO)

                        val now = System.currentTimeMillis()
                        val aboveStart = maxAmplitude >= speechStartThreshold
                        val belowStop = maxAmplitude <= speechStopThreshold

                        if (!speechActive) {
                            aboveStartFrames = if (aboveStart) aboveStartFrames + 1 else 0
                            if (aboveStartFrames >= SPEECH_START_FRAMES) {
                                speechActive = true
                                speechDetected = true
                                silenceStartTime = 0L
                                metricSpeechTransitions += 1
                            }
                        } else {
                            if (belowStop) {
                                if (silenceStartTime == 0L) {
                                    silenceStartTime = now
                                } else if (autoStopOnSilenceEnabled && now - silenceStartTime > silenceDurationMs) {
                                    _shouldAutoStop.value = true
                                }
                            } else {
                                silenceStartTime = 0L
                            }
                        }

                        if (speechActive) {
                            metricSpeechFrames += 1
                            metricSpeechAmplitudeSum += maxAmplitude.toLong()
                        } else {
                            metricNoiseFrames += 1
                            metricNoiseAmplitudeSum += maxAmplitude.toLong()
                        }

                        val snrRatio = if (noiseFloor > 1f) {
                            maxAmplitude.toFloat() / noiseFloor
                        } else {
                            0f
                        }
                        val rawProbability = ((snrRatio - 1.1f) / (START_THRESHOLD_RATIO - 1.1f)).coerceIn(0f, 1f)
                        val probability = if (speechActive) {
                            maxOf(rawProbability, 0.75f)
                        } else {
                            rawProbability * 0.65f
                        }
                        _speechProbability.value = probability

                        val gate = speechStopThreshold
                        val normalizedLevel = if (maxAmplitude > gate.toInt()) {
                            val gated = ((maxAmplitude - gate) / (MAX_AMPLITUDE - gate).coerceAtLeast(1f))
                                .coerceIn(0f, 1f)
                            val perceptual = (gated.pow(0.45f) * 1.2f).coerceIn(0f, 1f)
                            smoothedLevel = (smoothedLevel * 0.72f) + (perceptual * 0.28f)
                            smoothedLevel
                        } else {
                            smoothedLevel *= 0.72f
                            if (smoothedLevel < 0.01f) 0f else smoothedLevel
                        }
                        _audioLevel.value = normalizedLevel

                        // Generate synthetic frequency bands that track speech energy without overreacting to noise.
                        val bands = FloatArray(6) { i ->
                            val wave = (kotlin.math.sin((i * 0.85f) + metricFrameCount * 0.12f).toFloat() + 1f) * 0.5f
                            val floor = if (speechActive && normalizedLevel > 0.06f) 0.12f else 0f
                            val shaped = (normalizedLevel * 0.62f) + (wave * normalizedLevel * 0.62f)
                            (floor + shaped).coerceIn(0f, 1f)
                        }
                        _frequencyBands.value = bands

                        if (metricFrameCount % FRAME_LOG_INTERVAL == 0) {
                            Log.d(
                                TAG,
                                "VAD_FRAME frame=$metricFrameCount amp=$maxAmplitude " +
                                    "noiseFloor=${noiseFloor.toInt()} start=${speechStartThreshold.toInt()} " +
                                    "stop=${speechStopThreshold.toInt()} speech=$speechActive " +
                                    "prob=${format2(probability)} level=${format2(normalizedLevel)}"
                            )
                        }
                    } catch (_: Exception) { }
                    delay(50)
                }
            }

            return outputFile
        } catch (e: Exception) {
            e.printStackTrace()
            release()
            return null
        }
    }

    fun stop(): Pair<File?, Long>? {
        return try {
            val duration = System.currentTimeMillis() - startTime

            audioLevelJob?.cancel()
            _audioLevel.value = 0f
            _frequencyBands.value = FloatArray(6) { 0f }
            _speechProbability.value = 0f
            _shouldAutoStop.value = false
            _isRecording.value = false

            mediaRecorder?.apply {
                stop()
                release()
            }
            mediaRecorder = null

            val avgAmplitude = if (metricFrameCount > 0) {
                metricAmplitudeSum.toFloat() / metricFrameCount
            } else {
                0f
            }
            val avgNoiseAmplitude = if (metricNoiseFrames > 0) {
                metricNoiseAmplitudeSum.toFloat() / metricNoiseFrames
            } else {
                0f
            }
            val avgSpeechAmplitude = if (metricSpeechFrames > 0) {
                metricSpeechAmplitudeSum.toFloat() / metricSpeechFrames
            } else {
                0f
            }
            val speechRatio = if (metricFrameCount > 0) {
                metricSpeechFrames.toFloat() / metricFrameCount
            } else {
                0f
            }

            Log.i(
                TAG,
                "VAD_SUMMARY durationMs=$duration frames=$metricFrameCount " +
                    "speechFrames=$metricSpeechFrames noiseFrames=$metricNoiseFrames " +
                    "speechRatio=${format2(speechRatio)} transitions=$metricSpeechTransitions " +
                    "avgAmp=${avgAmplitude.toInt()} avgNoiseAmp=${avgNoiseAmplitude.toInt()} " +
                    "avgSpeechAmp=${avgSpeechAmplitude.toInt()} maxAmp=$metricMaxAmplitude " +
                    "noiseFloor=${noiseFloor.toInt()} start=${speechStartThreshold.toInt()} stop=${speechStopThreshold.toInt()} " +
                    "speechDetected=$speechDetected"
            )
            Pair(outputFile, duration)
        } catch (e: Exception) {
            e.printStackTrace()
            release()
            null
        }
    }

    fun release() {
        audioLevelJob?.cancel()

        _audioLevel.value = 0f
        _frequencyBands.value = FloatArray(6) { 0f }
        _speechProbability.value = 0f
        _shouldAutoStop.value = false
        _isRecording.value = false
        speechActive = false
        aboveStartFrames = 0

        try {
            mediaRecorder?.release()
        } catch (_: Exception) { }
        mediaRecorder = null
    }

    /**
     * Check if speech was detected during recording.
     */
    fun hasSpeechBeenDetected(): Boolean = speechDetected

    private fun format2(value: Float): String {
        return String.format(Locale.US, "%.2f", value)
    }
}
