package com.whispermate.aidictation.service

import android.annotation.SuppressLint
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionService
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import com.squareup.moshi.Moshi
import com.whispermate.aidictation.data.local.ParakeetModelAssets
import com.whispermate.aidictation.data.local.ParakeetTranscriber
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.repository.TranscriptionRepository
import com.whispermate.aidictation.util.SileroVAD
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Custom speech recognition service that uses Whisper API for transcription.
 * This service can be used by any app that requests speech recognition on Android.
 */
class WhisperRecognitionService : RecognitionService() {

    companion object {
        private const val TAG = "WhisperRecognitionService"
        private const val SAMPLE_RATE = 16000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val SILENCE_DURATION_MS = 1500L
        private const val MIN_RECORDING_MS = 500L
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var recordingJob: Job? = null
    private var audioRecord: AudioRecord? = null
    private var sileroVAD: SileroVAD? = null
    private var currentCallback: Callback? = null
    private var isListening = false
    private val appPreferences by lazy { AppPreferences(applicationContext, Moshi.Builder().build()) }
    private val parakeetTranscriber by lazy {
        ParakeetTranscriber(ParakeetModelAssets(applicationContext))
    }
    private val transcriptionRepository by lazy {
        TranscriptionRepository(appPreferences, parakeetTranscriber)
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "WhisperRecognitionService created")
        try {
            sileroVAD = SileroVAD(this)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize VAD", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "WhisperRecognitionService destroyed")
        stopListeningInternal()
        sileroVAD?.release()
        sileroVAD = null
        serviceScope.cancel()
    }

    override fun onStartListening(recognizerIntent: Intent, listener: Callback) {
        Log.d(TAG, "onStartListening called")
        currentCallback = listener

        if (isListening) {
            Log.w(TAG, "Already listening, stopping previous session")
            stopListeningInternal()
        }

        // Extract intent parameters
        val language = recognizerIntent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE)
            ?: recognizerIntent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE)
            ?: "en-US"
        val partialResults = recognizerIntent.getBooleanExtra(
            RecognizerIntent.EXTRA_PARTIAL_RESULTS, false
        )
        val maxResults = recognizerIntent.getIntExtra(
            RecognizerIntent.EXTRA_MAX_RESULTS, 1
        )

        Log.d(TAG, "Language: $language, partialResults: $partialResults, maxResults: $maxResults")

        startRecording(listener, language, partialResults)
    }

    override fun onStopListening(listener: Callback) {
        Log.d(TAG, "onStopListening called")
        if (currentCallback == listener) {
            stopListeningInternal()
        }
    }

    override fun onCancel(listener: Callback) {
        Log.d(TAG, "onCancel called")
        if (currentCallback == listener) {
            stopListeningInternal()
            listener.error(SpeechRecognizer.ERROR_CLIENT)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startRecording(callback: Callback, language: String, partialResults: Boolean) {
        isListening = true
        sileroVAD?.reset()

        recordingJob = serviceScope.launch(Dispatchers.IO) {
            var audioFile: File? = null
            var fileOutputStream: FileOutputStream? = null
            val audioData = mutableListOf<Short>()

            try {
                // Signal ready for speech
                launch(Dispatchers.Main) {
                    callback.readyForSpeech(Bundle())
                }

                val bufferSize = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT
                ).coerceAtLeast(512 * 2)

                audioRecord = AudioRecord(
                    MediaRecorder.AudioSource.VOICE_RECOGNITION,
                    SAMPLE_RATE,
                    CHANNEL_CONFIG,
                    AUDIO_FORMAT,
                    bufferSize * 2
                )

                if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                    Log.e(TAG, "AudioRecord failed to initialize")
                    launch(Dispatchers.Main) {
                        callback.error(SpeechRecognizer.ERROR_AUDIO)
                    }
                    return@launch
                }

                // Create temp file for audio
                audioFile = File(cacheDir, "recognition_${System.currentTimeMillis()}.wav")
                fileOutputStream = FileOutputStream(audioFile)

                // Reserve space for WAV header (will write later)
                val headerPlaceholder = ByteArray(44)
                fileOutputStream.write(headerPlaceholder)

                audioRecord?.startRecording()
                Log.d(TAG, "Recording started")

                launch(Dispatchers.Main) {
                    callback.beginningOfSpeech()
                }

                val buffer = ShortArray(512)
                var speechDetected = false
                var silenceStartTime = 0L
                val recordingStartTime = System.currentTimeMillis()
                var lastRmsTime = 0L

                while (isActive && isListening) {
                    val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0

                    if (read > 0) {
                        // Store audio data
                        for (i in 0 until read) {
                            audioData.add(buffer[i])
                        }

                        // Write to file
                        val byteBuffer = ByteBuffer.allocate(read * 2)
                        byteBuffer.order(ByteOrder.LITTLE_ENDIAN)
                        for (i in 0 until read) {
                            byteBuffer.putShort(buffer[i])
                        }
                        fileOutputStream.write(byteBuffer.array())

                        // Calculate RMS for audio level feedback
                        val currentTime = System.currentTimeMillis()
                        if (currentTime - lastRmsTime > 100) {
                            lastRmsTime = currentTime
                            val rms = calculateRms(buffer, read)
                            launch(Dispatchers.Main) {
                                val bundle = Bundle().apply {
                                    putFloat("RMS", rms)
                                }
                                callback.rmsChanged(rms)
                            }
                        }

                        // VAD processing
                        val floatBuffer = FloatArray(read) { i -> buffer[i] / 32768f }
                        val speechProbability = sileroVAD?.process(floatBuffer) ?: 0.5f

                        if (speechProbability > 0.5f) {
                            speechDetected = true
                            silenceStartTime = 0L
                        } else if (speechDetected) {
                            if (silenceStartTime == 0L) {
                                silenceStartTime = System.currentTimeMillis()
                            } else if (System.currentTimeMillis() - silenceStartTime > SILENCE_DURATION_MS) {
                                val recordingDuration = System.currentTimeMillis() - recordingStartTime
                                if (recordingDuration > MIN_RECORDING_MS) {
                                    Log.d(TAG, "Silence detected, stopping recording")
                                    break
                                }
                            }
                        }
                    }
                }

                // Stop recording
                audioRecord?.stop()
                fileOutputStream.flush()
                fileOutputStream.close()
                fileOutputStream = null

                // Write WAV header
                writeWavHeader(audioFile, audioData.size * 2)

                launch(Dispatchers.Main) {
                    callback.endOfSpeech()
                }

                if (!isListening) {
                    // Cancelled
                    audioFile.delete()
                    return@launch
                }

                // Transcribe
                Log.d(TAG, "Starting transcription, file size: ${audioFile.length()}")
                val text: String = transcriptionRepository.transcribe(audioFile).getOrElse { "" }

                Log.d(TAG, "Transcription result: $text")

                if (text.isNotEmpty()) {
                    launch(Dispatchers.Main) {
                        val results = Bundle().apply {
                            putStringArrayList(
                                SpeechRecognizer.RESULTS_RECOGNITION,
                                arrayListOf(text)
                            )
                            putFloatArray(
                                SpeechRecognizer.CONFIDENCE_SCORES,
                                floatArrayOf(1.0f)
                            )
                        }
                        callback.results(results)
                    }
                } else {
                    Log.e(TAG, "Transcription returned empty text")
                    launch(Dispatchers.Main) {
                        callback.error(SpeechRecognizer.ERROR_SERVER)
                    }
                }

                // Cleanup
                audioFile.delete()

            } catch (e: Exception) {
                Log.e(TAG, "Recording error", e)
                launch(Dispatchers.Main) {
                    callback.error(SpeechRecognizer.ERROR_CLIENT)
                }
                audioFile?.delete()
            } finally {
                fileOutputStream?.close()
                audioRecord?.release()
                audioRecord = null
                isListening = false
            }
        }
    }

    private fun stopListeningInternal() {
        Log.d(TAG, "stopListeningInternal")
        isListening = false
        recordingJob?.cancel()
        recordingJob = null

        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
    }

    private fun calculateRms(buffer: ShortArray, size: Int): Float {
        var sum = 0.0
        for (i in 0 until size) {
            sum += buffer[i] * buffer[i]
        }
        val rms = kotlin.math.sqrt(sum / size)
        // Normalize to 0-10 range for SpeechRecognizer
        return (rms / 3276.8).coerceIn(0.0, 10.0).toFloat()
    }

    private fun writeWavHeader(file: File, dataSize: Int) {
        val raf = java.io.RandomAccessFile(file, "rw")
        try {
            val channels = 1
            val bitsPerSample = 16
            val byteRate = SAMPLE_RATE * channels * bitsPerSample / 8
            val blockAlign = channels * bitsPerSample / 8
            val totalDataLen = dataSize + 36

            raf.seek(0)
            raf.writeBytes("RIFF")
            raf.write(intToByteArray(totalDataLen))
            raf.writeBytes("WAVE")
            raf.writeBytes("fmt ")
            raf.write(intToByteArray(16)) // Subchunk1 size
            raf.write(shortToByteArray(1)) // Audio format (PCM)
            raf.write(shortToByteArray(channels.toShort()))
            raf.write(intToByteArray(SAMPLE_RATE))
            raf.write(intToByteArray(byteRate))
            raf.write(shortToByteArray(blockAlign.toShort()))
            raf.write(shortToByteArray(bitsPerSample.toShort()))
            raf.writeBytes("data")
            raf.write(intToByteArray(dataSize))
        } finally {
            raf.close()
        }
    }

    private fun intToByteArray(value: Int): ByteArray {
        return byteArrayOf(
            (value and 0xff).toByte(),
            ((value shr 8) and 0xff).toByte(),
            ((value shr 16) and 0xff).toByte(),
            ((value shr 24) and 0xff).toByte()
        )
    }

    private fun shortToByteArray(value: Short): ByteArray {
        return byteArrayOf(
            (value.toInt() and 0xff).toByte(),
            ((value.toInt() shr 8) and 0xff).toByte()
        )
    }
}
