package com.whispermate.aidictation.util

import android.annotation.SuppressLint
import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import com.whispermate.aidictation.data.local.ManagedAudioSourceFiles
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
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.pow

/** A one-shot ownership fence: retirement wins even when it happens before registration. */
internal class TerminalResourceFence<T : Any>(
    private val releaseResource: (T) -> Unit
) {
    private val lock = Any()
    private var terminal = false
    private var resource: T? = null

    fun register(candidate: T): Boolean {
        val accepted = synchronized(lock) {
            if (terminal || resource != null) {
                false
            } else {
                resource = candidate
                true
            }
        }
        if (!accepted) releaseSafely(candidate)
        return accepted
    }

    fun current(): T? = synchronized(lock) { resource }

    fun publishIfCurrent(candidate: T, publish: () -> Unit): Boolean = synchronized(lock) {
        if (terminal || resource !== candidate) {
            false
        } else {
            publish()
            true
        }
    }

    fun retire() {
        val retired = synchronized(lock) {
            terminal = true
            resource.also { resource = null }
        }
        retired?.let(::releaseSafely)
    }

    private fun releaseSafely(candidate: T) {
        try {
            releaseResource(candidate)
        } catch (_: Exception) {
        }
    }
}

internal class AudioRecorder(
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

    private val recorderFence = TerminalResourceFence<MediaRecorder> { it.release() }
    private val managedAudioSources = ManagedAudioSourceFiles(context)
    private var audioLevelJob: Job? = null
    private var outputFile: File? = null
    private var startTime: Long = 0
    private var frequencyAnalyzer: FrequencyAnalyzer? = null
    private val captureFailure = AtomicReference<Throwable?>(null)

    // Speech detection with adaptive thresholding
    @Volatile private var speechDetected = false
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
    fun start(managedOutputFile: File): File? {
        try {
            outputFile = managedAudioSources.requireRecorderTarget(managedOutputFile)

            captureFailure.set(null)
            // Publish the native recorder before any potentially blocking setup call. A release
            // that races construction is remembered by recorderFence and immediately retires it.
            val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            if (!recorderFence.register(recorder)) {
                throw IllegalStateException("Recording start was already cancelled")
            }
            recorder.apply {
                setOnErrorListener { _, what, extra ->
                    captureFailure.compareAndSet(
                        null,
                        IllegalStateException("Audio capture failed ($what/$extra)")
                    )
                    _isRecording.value = false
                }
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioSamplingRate(44100)
                setAudioEncodingBitRate(128000)
                setOutputFile(checkNotNull(outputFile).absolutePath)
                prepare()
                if (recorderFence.current() !== recorder) {
                    throw IllegalStateException("Recording start was cancelled during setup")
                }
                start()
            }

            startTime = System.currentTimeMillis()
            captureFailure.get()?.let { throw it }
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

            captureFailure.get()?.let { throw it }
            if (!recorderFence.publishIfCurrent(recorder) { _isRecording.value = true }) {
                throw IllegalStateException("Recording start was cancelled")
            }
            captureFailure.get()?.let { error ->
                _isRecording.value = false
                throw error
            }

            // Start audio level monitoring and speech detection
            audioLevelJob = CoroutineScope(Dispatchers.Default).launch {
                var smoothedLevel = 0f
                while (isActive && _isRecording.value) {
                    try {
                        val maxAmplitude = recorderFence.current()?.maxAmplitude ?: 0
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

            // A successful stop closes the MP4 container. Resource release is intentionally
            // separate: release() can stall or throw, but must not make finalized audio look
            // truncated or prevent the coordinator from durably committing it.
            recorderFence.current()?.stop()
                ?: throw IllegalStateException("The recorder was released before finalization")

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

        recorderFence.retire()
    }

    /**
     * Check if speech was detected during recording.
     */
    fun hasSpeechBeenDetected(): Boolean = speechDetected

    fun captureError(): Throwable? = captureFailure.get()

    private fun format2(value: Float): String {
        return String.format(Locale.US, "%.2f", value)
    }
}
