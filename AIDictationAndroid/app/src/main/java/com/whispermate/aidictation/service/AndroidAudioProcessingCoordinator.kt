package com.whispermate.aidictation.service

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import com.whispermate.aidictation.data.repository.AuthRepository
import com.whispermate.aidictation.data.repository.RecordingRepository
import com.whispermate.aidictation.data.repository.TranscriptionAttemptConfiguration
import com.whispermate.aidictation.data.repository.TranscriptionRepository
import com.whispermate.aidictation.data.repository.finalizedAudioMarkerFile
import com.whispermate.aidictation.data.repository.writeFinalizedAudioMarker
import com.whispermate.aidictation.data.remote.AudioCheckpointException
import com.whispermate.aidictation.data.remote.AudioEmptyResponseException
import com.whispermate.aidictation.data.remote.AudioHttpException
import com.whispermate.aidictation.data.remote.AudioMalformedResponseException
import com.whispermate.aidictation.data.remote.AudioSplitException
import com.whispermate.aidictation.domain.model.AudioAttemptLease
import com.whispermate.aidictation.domain.model.AudioProcessingStatus
import com.whispermate.aidictation.domain.model.Recording
import com.whispermate.aidictation.domain.model.UsageClaimDestination
import com.whispermate.aidictation.domain.model.audioUsageClaimId
import com.whispermate.aidictation.util.AudioRecorder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

enum class AndroidAudioProcessingState {
    IDLE, RECORDING, FINALIZING, PROCESSING
}

enum class AndroidAudioAttemptOwner {
    MAIN, OVERLAY, ONBOARDING, RECORDING_SHEET
}

data class AndroidAudioFailureEvent(
    val owner: AndroidAudioAttemptOwner,
    val recordingId: String,
    val attemptId: String,
    val generation: Long,
    val workflowToken: Long,
    val message: String
) {
    fun matches(
        expectedOwner: AndroidAudioAttemptOwner,
        expectedLease: AudioAttemptLease?,
        expectedWorkflowToken: Long?
    ): Boolean = expectedLease != null && expectedWorkflowToken != null &&
        owner == expectedOwner &&
        recordingId == expectedLease.recordingId &&
        attemptId == expectedLease.attemptId &&
        generation == expectedLease.generation &&
        workflowToken == expectedWorkflowToken
}

data class FinalizedAndroidCapture(
    val lease: AudioAttemptLease,
    val workflowToken: Long,
    val sourceFile: File,
    val durationMs: Long,
    val speechDetected: Boolean,
    val owner: AndroidAudioAttemptOwner,
    val transcriptionConfiguration: TranscriptionAttemptConfiguration
)

data class AndroidProcessingResult(
    val recordingId: String,
    val rawText: String,
    val text: String,
    val usageClaimId: String?
)

private class AudioAttemptUnavailableException(message: String) : IllegalStateException(message)

internal suspend fun <T> withAudioPersistenceDeadline(
    operationScope: CoroutineScope,
    timeoutMillis: Long,
    onLateCompletion: suspend (Result<T>, Throwable) -> Unit = { _, _ -> },
    block: suspend () -> T
): T {
    val operation = operationScope.async(Dispatchers.IO) { runCatching { block() } }
    val outcome = try {
        withTimeout(timeoutMillis) { operation.await() }
    } catch (error: TimeoutCancellationException) {
        val deadlineError = IOException("Audio processing storage timed out", error)
        operationScope.launch {
            runCatching { onLateCompletion(operation.await(), deadlineError) }
        }
        throw deadlineError
    } catch (error: CancellationException) {
        operationScope.launch {
            runCatching { onLateCompletion(operation.await(), error) }
        }
        throw error
    }
    return outcome.getOrThrow()
}

internal interface AndroidTranscriptionOperations {
    suspend fun captureAttemptConfiguration(
        additionalPrompt: String?,
        contextRules: String?
    ): TranscriptionAttemptConfiguration

    suspend fun transcribe(
        audioFile: File,
        configuration: TranscriptionAttemptConfiguration,
        checkpoint: suspend (mergedText: String, completedLeafCount: Int) -> Boolean,
        rawComplete: suspend (rawText: String) -> Boolean
    ): Result<String>

    fun abandonLocalRecognition()
}

private class RepositoryAndroidTranscriptionOperations(
    private val repository: TranscriptionRepository
) : AndroidTranscriptionOperations {
    override suspend fun captureAttemptConfiguration(
        additionalPrompt: String?,
        contextRules: String?
    ): TranscriptionAttemptConfiguration =
        repository.captureAttemptConfiguration(additionalPrompt, contextRules)

    override suspend fun transcribe(
        audioFile: File,
        configuration: TranscriptionAttemptConfiguration,
        checkpoint: suspend (mergedText: String, completedLeafCount: Int) -> Boolean,
        rawComplete: suspend (rawText: String) -> Boolean
    ): Result<String> = repository.transcribe(
        audioFile = audioFile,
        configuration = configuration,
        checkpoint = checkpoint,
        rawComplete = rawComplete
    )

    override fun abandonLocalRecognition() {
        repository.abandonLocalRecognition()
    }
}

private fun readAndroidAudioDurationMs(file: File): Long {
    val extractor = MediaExtractor()
    return try {
        extractor.setDataSource(file.absolutePath)
        (0 until extractor.trackCount).firstNotNullOfOrNull { index ->
            val format = extractor.getTrackFormat(index)
            val mime = format.getString(MediaFormat.KEY_MIME).orEmpty()
            if (!mime.startsWith("audio/") || !format.containsKey(MediaFormat.KEY_DURATION)) null
            else format.getLong(MediaFormat.KEY_DURATION) / 1_000L
        } ?: throw IllegalStateException("The finalized file has no audio track")
    } finally {
        extractor.release()
    }
}

/**
 * The only production owner of Android's MediaRecorder and audio attempt lifecycle. Each capture
 * has a disposable native executor so an ignored cancellation cannot poison the next recording.
 */
@Singleton
class AndroidAudioProcessingCoordinator internal constructor(
    private val context: Context,
    private val recordingRepository: RecordingRepository,
    private val transcriptionOperations: AndroidTranscriptionOperations,
    private val audioDurationReader: (File) -> Long,
    private val recognitionTimeoutMillis: (Long) -> Long,
    private val usageDestinationProvider: () -> String? = { null }
) {
    @Inject
    constructor(
        @ApplicationContext context: Context,
        recordingRepository: RecordingRepository,
        transcriptionRepository: TranscriptionRepository,
        authRepository: AuthRepository
    ) : this(
        context = context,
        recordingRepository = recordingRepository,
        transcriptionOperations = RepositoryAndroidTranscriptionOperations(transcriptionRepository),
        audioDurationReader = ::readAndroidAudioDurationMs,
        recognitionTimeoutMillis = { durationMs ->
            (durationMs * 2 + 60_000L).coerceIn(
                MIN_RECOGNITION_TIMEOUT_MS,
                MAX_RECOGNITION_TIMEOUT_MS
            )
        },
        usageDestinationProvider = authRepository::currentUsageDestination
    )

    companion object {
        private const val START_TIMEOUT_MS = 8_000L
        private const val FINALIZE_TIMEOUT_MS = 10_000L
        private const val RELEASE_TIMEOUT_MS = 2_000L
        private const val CONFIGURATION_TIMEOUT_MS = 5_000L
        private const val PERSISTENCE_TIMEOUT_MS = 5_000L
        private const val MAX_LOCAL_CAPTURE_DURATION_MS = 2 * 60 * 1000L
        private const val MAX_CLOUD_CAPTURE_DURATION_MS = 30 * 60 * 1000L
        private const val CAPTURE_AUTO_STOP_GRACE_MS = 2_000L
        private const val MAX_LOCAL_PROCESSABLE_DURATION_MS =
            MAX_LOCAL_CAPTURE_DURATION_MS + CAPTURE_AUTO_STOP_GRACE_MS + 5_000L
        private const val MIN_RECOGNITION_TIMEOUT_MS = 90_000L
        private const val MAX_RECOGNITION_TIMEOUT_MS = 600_000L
    }

    private data class ActiveCapture(
        val attemptToken: String,
        val workflowToken: Long,
        val lease: AudioAttemptLease,
        val owner: AndroidAudioAttemptOwner,
        val recorder: AudioRecorder,
        val executor: ExecutorService,
        val transcriptionConfiguration: TranscriptionAttemptConfiguration
    )

    private data class ActiveStart(
        val token: String,
        val workflowToken: Long,
        val owner: AndroidAudioAttemptOwner,
        val provisionalLease: AudioAttemptLease,
        val lease: AtomicReference<AudioAttemptLease?>,
        val recorder: AudioRecorder,
        val executor: ExecutorService,
        val callerJob: Job,
        val usageDestination: String
    )

    private data class ActiveFinalization(
        val token: String,
        val capture: ActiveCapture
    )

    private data class ActiveRecognition(
        val lease: AudioAttemptLease,
        val workflowToken: Long,
        val owner: AndroidAudioAttemptOwner,
        val job: Job,
        val configuration: TranscriptionAttemptConfiguration,
        val rawComplete: AtomicReference<String>
    )

    private data class ActiveRetryPreparation(
        val lease: AudioAttemptLease,
        val workflowToken: Long,
        val owner: AndroidAudioAttemptOwner,
        val job: Deferred<Long>,
        val configuration: TranscriptionAttemptConfiguration
    )

    private data class ActiveRetryStart(
        val token: String,
        val workflowToken: Long,
        val recordingId: String,
        val owner: AndroidAudioAttemptOwner,
        val callerJob: Job,
        val lease: AtomicReference<AudioAttemptLease?>,
        val usageDestination: String
    )

    private data class CancellationTarget(
        val lease: AudioAttemptLease?,
        val activeStart: ActiveStart? = null,
        val activeCapture: ActiveCapture? = null,
        val activeRetryStart: ActiveRetryStart? = null,
        val activeRetryPreparation: ActiveRetryPreparation? = null,
        val activeRecognition: ActiveRecognition? = null,
        val workflowToken: Long? = null,
        val preserveRecognitionProgress: Boolean = false,
        val hasDurableLease: Boolean = true,
        val resetImmediately: Boolean = true
    )

    private val mutex = Mutex()
    private val captureNativeFence = CaptureNativeFence()
    private val retryStartFence = RetryStartFence()
    private val meterEmissionFence = AttemptEmissionFence()
    private val detachedScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var activeStart: ActiveStart? = null
    private var activeCapture: ActiveCapture? = null
    private var activeFinalization: ActiveFinalization? = null
    private var pendingFinalized: FinalizedAndroidCapture? = null
    private var activeRetryStart: ActiveRetryStart? = null
    private var activeRetryPreparation: ActiveRetryPreparation? = null
    private var activeRecognition: ActiveRecognition? = null
    private var meterJobs: List<Job> = emptyList()
    private var captureDeadlineJob: Job? = null

    private val _state = MutableStateFlow(AndroidAudioProcessingState.IDLE)
    val state: StateFlow<AndroidAudioProcessingState> = _state.asStateFlow()
    private val _owner = MutableStateFlow<AndroidAudioAttemptOwner?>(null)
    val owner: StateFlow<AndroidAudioAttemptOwner?> = _owner.asStateFlow()
    private val _audioLevel = MutableStateFlow(0f)
    val audioLevel: StateFlow<Float> = _audioLevel.asStateFlow()
    private val _frequencyBands = MutableStateFlow(FloatArray(6))
    val frequencyBands: StateFlow<FloatArray> = _frequencyBands.asStateFlow()
    private val _shouldAutoStop = MutableStateFlow(false)
    val shouldAutoStop: StateFlow<Boolean> = _shouldAutoStop.asStateFlow()
    private val _failureEvents = MutableSharedFlow<AndroidAudioFailureEvent>(extraBufferCapacity = 1)
    val failureEvents: SharedFlow<AndroidAudioFailureEvent> = _failureEvents.asSharedFlow()

    /** Completes once startup recovery is out of the tap-to-record critical path. */
    suspend fun awaitCaptureReadiness() {
        recordingRepository.awaitStartupRecovery()
    }

    suspend fun startCapture(
        owner: AndroidAudioAttemptOwner,
        workflowToken: Long,
        autoStopOnSilence: Boolean,
        additionalPrompt: String? = null,
        contextRules: String? = null
    ): Result<AudioAttemptLease> {
        val start = mutex.withLock {
            if (_state.value != AndroidAudioProcessingState.IDLE ||
                activeStart != null || activeCapture != null || pendingFinalized != null ||
                activeRetryStart != null || activeRetryPreparation != null || activeRecognition != null
            ) {
                return Result.failure(IllegalStateException("Another recording is already active"))
            }
            val recordingId = UUID.randomUUID().toString()
            val attemptId = UUID.randomUUID().toString()
            val partial = managedSourceFile(recordingId)
            val provisionalLease = AudioAttemptLease(
                recordingId,
                attemptId,
                generation = 1,
                sourcePath = partial.absolutePath,
                status = AudioProcessingStatus.CAPTURING
            )
            ActiveStart(
                token = UUID.randomUUID().toString(),
                workflowToken = workflowToken,
                owner = owner,
                provisionalLease = provisionalLease,
                lease = AtomicReference(null),
                recorder = AudioRecorder(context, autoStopOnSilence),
                executor = newNativeExecutor(recordingId),
                callerJob = checkNotNull(kotlin.coroutines.coroutineContext[Job]),
                usageDestination = owner.capturedUsageDestination()
            ).also {
                check(captureNativeFence.reserveStart(it.token))
                activeStart = it
                _owner.value = owner
                // A tap goes straight to recording. Ownership of the in-flight start is
                // tracked by activeStart's token and captureNativeFence, which are what
                // actually make the start/stop races deterministic.
                _state.value = AndroidAudioProcessingState.RECORDING
            }
        }
        val partial = File(start.provisionalLease.sourcePath)
        var transcriptionConfiguration: TranscriptionAttemptConfiguration? = null
        try {
            transcriptionConfiguration = withTimeout(CONFIGURATION_TIMEOUT_MS) {
                recordingRepository.awaitStartupRecovery()
                transcriptionOperations.captureAttemptConfiguration(additionalPrompt, contextRules)
            }
            val lease = withPersistenceDeadline(
                onLateCompletion = { result, abandonment ->
                    result.getOrNull()?.let { lateLease ->
                        reconcileAbandonedCapture(
                            lateLease,
                            abandonment,
                            "The recording journal timed out before capture could start."
                        )
                    }
                }
            ) {
                recordingRepository.beginCapture(
                    start.provisionalLease.recordingId,
                    start.provisionalLease.attemptId,
                    partial.absolutePath,
                    usageEligible = owner.recordsUsage,
                    usageDestination = start.usageDestination
                )
            }
            start.lease.set(lease)

            val started = withTimeout(START_TIMEOUT_MS) {
                submitCancellable(
                    executor = start.executor,
                    onLateResult = { start.recorder.release() }
                ) { start.recorder.start(partial) }
            }
            if (started == null || started.absolutePath != partial.absolutePath) {
                throw IllegalStateException("The microphone could not start")
            }
            start.recorder.captureError()?.let { throw it }
            val active = ActiveCapture(
                start.token,
                start.workflowToken,
                lease,
                owner,
                start.recorder,
                start.executor,
                checkNotNull(transcriptionConfiguration)
            )
            val installed = withContext(NonCancellable) {
                mutex.withLock {
                    if (activeStart?.token == start.token && start.callerJob.isActive &&
                        _owner.value == owner && _state.value == AndroidAudioProcessingState.RECORDING &&
                        captureNativeFence.promoteToRecording(start.token)
                    ) {
                        activeStart = null
                        activeCapture = active
                        _state.value = AndroidAudioProcessingState.RECORDING
                        bindMeters(active)
                        bindCaptureDeadline(active)
                        true
                    } else {
                        false
                    }
                }
            }
            if (!installed) throw CancellationException("Recording start was cancelled")
            return Result.success(lease)
        } catch (error: Throwable) {
            start.executor.shutdownNow()
            var terminalSaved = true
            withContext(NonCancellable) {
                val abandonedByThisCall = mutex.withLock {
                    if (activeStart?.token == start.token) {
                        activeStart = null
                        captureNativeFence.cancel(start.token)
                        resetMeters()
                        resetAttemptState()
                        true
                    } else {
                        false
                    }
                }
                releaseRecorderOutOfBand(start.provisionalLease.recordingId, start.recorder)
                if (abandonedByThisCall) {
                    start.lease.get()?.let { lease ->
                        val status =
                            if (error is CancellationException && error !is TimeoutCancellationException) {
                                AudioProcessingStatus.CANCELLED
                            } else {
                                AudioProcessingStatus.FAILED
                            }
                        val message = if (transcriptionConfiguration == null) {
                            "Recording setup did not finish, so no audio was captured."
                        } else {
                            "The recording could not start, so no audio was sent for transcription."
                        }
                        terminalSaved = persistFailureTerminal(
                            lease,
                            status,
                            message,
                            preserveRecognitionProgress = false
                        )
                        if (!terminalSaved) {
                            retryFailureTerminalInBackground(
                                lease,
                                status,
                                message,
                                preserveRecognitionProgress = false
                            )
                        }
                    }
                }
            }
            if (error is CancellationException && error !is TimeoutCancellationException) throw error
            return Result.failure(
                if (terminalSaved) error else IllegalStateException(
                    historyUpdateFailure("The recording could not start."),
                    error
                )
            )
        }
    }

    suspend fun stopCapture(
        owner: AndroidAudioAttemptOwner,
        expectedLease: AudioAttemptLease? = null
    ): Result<FinalizedAndroidCapture> {
        val finalization = mutex.withLock {
            val current = activeCapture
                ?: return Result.failure(AudioAttemptUnavailableException("No recording is active"))
            if (current.owner != owner) {
                return Result.failure(AudioAttemptUnavailableException("This recording belongs to another workflow"))
            }
            if (expectedLease != null && current.lease != expectedLease) {
                return Result.failure(AudioAttemptUnavailableException("This recording attempt is no longer current"))
            }
            if (_state.value != AndroidAudioProcessingState.RECORDING) {
                return Result.failure(AudioAttemptUnavailableException("The recording is already stopping"))
            }
            _state.value = AndroidAudioProcessingState.FINALIZING
            val stopToken = UUID.randomUUID().toString()
            check(captureNativeFence.reserveFinalization(current.attemptToken, stopToken))
            ActiveFinalization(stopToken, current).also {
                activeFinalization = it
            }
        }
        val active = finalization.capture

        return try {
            val markedFinalizing = withPersistenceDeadline(
                onLateCompletion = { result, abandonment ->
                    if (result.getOrDefault(false)) {
                        reconcileAbandonedCapture(
                            active.lease,
                            abandonment,
                            "Recording finalization did not enter a durable state in time."
                        )
                    }
                }
            ) { recordingRepository.markFinalizing(active.lease) }
            if (!markedFinalizing) {
                throw AudioAttemptUnavailableException("The recording is no longer current")
            }
            val stillOwned = mutex.withLock {
                activeFinalization?.token == finalization.token &&
                    activeCapture === active &&
                    captureNativeFence.ownsFinalization(active.attemptToken, finalization.token) &&
                    _owner.value == active.owner &&
                    _state.value == AndroidAudioProcessingState.FINALIZING
            }
            if (!stillOwned) {
                throw CancellationException("Recording finalization was cancelled")
            }

            val speechDetected = active.recorder.hasSpeechBeenDetected()
            val stopped = withTimeout(FINALIZE_TIMEOUT_MS) {
                submitCancellable(
                    executor = active.executor,
                    onLateResult = { lateResult ->
                        lateResult.first?.let { source ->
                            detachedScope.launch {
                                runCatching {
                                    withPersistenceDeadline {
                                        recordingRepository.recoverFinalizedSource(
                                            active.lease,
                                            source
                                        )
                                    }
                                }
                            }
                        }
                    }
                ) {
                    val result = active.recorder.stop()
                        ?: throw IllegalStateException("The recording could not be finalized")
                    active.recorder.captureError()?.let { throw it }
                    val partial = result.first
                        ?: throw IllegalStateException("The recording source is missing")
                    require(recordingRepository.isManagedFinalizedSource(active.lease, partial)) {
                        "The finalized recording source is outside managed storage"
                    }
                    validateFinalizedAudio(partial)
                    FileOutputStream(partial, true).use { output -> output.fd.sync() }
                    writeFinalizedAudioMarker(active.lease, partial, result.second)
                    result
                }
            }
            val committedSource = stopped.first
                ?: throw IllegalStateException("The recording source is missing")
            val processingLease = withPersistenceDeadline(
                onLateCompletion = { result, abandonment ->
                    result.getOrNull()?.let { lateLease ->
                        reconcileAbandonedCapture(
                            lateLease,
                            abandonment,
                            "The finalized recording was saved after its workflow ended."
                        )
                    }
                }
            ) {
                recordingRepository.acceptFinalizedSource(
                    active.lease,
                    committedSource.absolutePath,
                    stopped.second
                )
            } ?: throw IllegalStateException("The recording was replaced before it could be saved")
            finalizedAudioMarkerFile(committedSource).delete()
            releaseRecorderOutOfBand(active)

            val finalized = FinalizedAndroidCapture(
                processingLease,
                active.workflowToken,
                committedSource,
                stopped.second,
                speechDetected,
                active.owner,
                active.transcriptionConfiguration
            )
            val installed = mutex.withLock {
                if (activeFinalization?.token != finalization.token || activeCapture !== active ||
                    !captureNativeFence.acceptsFinalized(active.attemptToken, finalization.token)
                ) {
                    false
                } else {
                    activeFinalization = null
                    activeCapture = null
                    pendingFinalized = finalized
                    active.executor.shutdownNow()
                    resetMeters()
                    _state.value = AndroidAudioProcessingState.PROCESSING
                    true
                }
            }
            if (!installed) throw CancellationException("Recording finalization was cancelled")
            Result.success(finalized)
        } catch (error: Throwable) {
            active.executor.shutdownNow()
            var terminalSaved = true
            val abandonedByThisCall = withContext(NonCancellable) {
                mutex.withLock {
                    if (activeFinalization?.token == finalization.token && activeCapture === active) {
                        activeFinalization = null
                        activeCapture = null
                        captureNativeFence.cancel(active.attemptToken)
                        resetMeters()
                        resetAttemptState()
                        true
                    } else {
                        false
                    }
                }
            }
            if (abandonedByThisCall) {
                withContext(NonCancellable) {
                    releaseRecorderOutOfBand(active)
                    val status =
                        if (error is CancellationException && error !is TimeoutCancellationException) {
                            AudioProcessingStatus.CANCELLED
                        } else {
                            AudioProcessingStatus.FAILED
                        }
                    val message = when {
                        error is TimeoutCancellationException ->
                            "The recording took too long to finish. The recoverable source was kept."
                        error is CancellationException ->
                            "Recording finalization was cancelled. The recoverable source was kept."
                        else ->
                            "The recording could not be finalized. The recoverable source was kept."
                    }
                    terminalSaved = persistFailureTerminal(
                        active.lease,
                        status,
                        message,
                        preserveRecognitionProgress = false
                    )
                    if (!terminalSaved) {
                        retryFailureTerminalInBackground(
                            active.lease,
                            status,
                            message,
                            preserveRecognitionProgress = false
                        )
                    }
                }
            }
            if (error is CancellationException && error !is TimeoutCancellationException) throw error
            Result.failure(
                if (terminalSaved) error else IllegalStateException(
                    historyUpdateFailure("The recording could not be finalized."),
                    error
                )
            )
        }
    }

    suspend fun cancelCapture(
        owner: AndroidAudioAttemptOwner,
        reason: String = "Recording cancelled",
        expectedLease: AudioAttemptLease? = null,
        expectedWorkflowToken: Long? = null
    ): Boolean {
        val target = mutex.withLock {
            val start = activeStart
            val retryStart = activeRetryStart
            val capture = activeCapture
            val finalized = pendingFinalized
            val preparation = activeRetryPreparation
            val recognition = activeRecognition
            when {
                start != null && start.owner == owner &&
                    (expectedLease == null || start.lease.get() == expectedLease) &&
                    (expectedWorkflowToken == null || start.workflowToken == expectedWorkflowToken) -> {
                    activeStart = null
                    captureNativeFence.cancel(start.token)
                    CancellationTarget(
                        lease = start.lease.get() ?: start.provisionalLease,
                        activeStart = start,
                        workflowToken = start.workflowToken,
                        hasDurableLease = start.lease.get() != null
                    )
                }
                retryStart != null && retryStart.owner == owner &&
                    (expectedLease == null || retryStart.lease.get() == expectedLease) &&
                    (expectedWorkflowToken == null || retryStart.workflowToken == expectedWorkflowToken) -> {
                    activeRetryStart = null
                    retryStartFence.cancel(retryStart.token)
                    CancellationTarget(
                        lease = retryStart.lease.get(),
                        activeRetryStart = retryStart,
                        workflowToken = retryStart.workflowToken,
                        preserveRecognitionProgress = true,
                        hasDurableLease = retryStart.lease.get() != null
                    )
                }
                capture != null && capture.owner == owner &&
                    (expectedLease == null || capture.lease == expectedLease) &&
                    (expectedWorkflowToken == null || capture.workflowToken == expectedWorkflowToken) -> {
                    activeCapture = null
                    if (activeFinalization?.capture === capture) activeFinalization = null
                    captureNativeFence.cancel(capture.attemptToken)
                    CancellationTarget(
                        capture.lease,
                        activeCapture = capture,
                        workflowToken = capture.workflowToken,
                        resetImmediately = true
                    )
                }
                finalized != null && finalized.owner == owner &&
                    (expectedLease == null || finalized.lease == expectedLease) &&
                    (expectedWorkflowToken == null || finalized.workflowToken == expectedWorkflowToken) -> {
                    pendingFinalized = null
                    CancellationTarget(
                        finalized.lease,
                        workflowToken = finalized.workflowToken,
                        preserveRecognitionProgress = true
                    )
                }
                preparation != null && preparation.owner == owner &&
                    (expectedLease == null || preparation.lease == expectedLease) &&
                    (expectedWorkflowToken == null || preparation.workflowToken == expectedWorkflowToken) -> {
                    activeRetryPreparation = null
                    CancellationTarget(
                        preparation.lease,
                        activeRetryPreparation = preparation,
                        workflowToken = preparation.workflowToken,
                        preserveRecognitionProgress = true
                    )
                }
                recognition != null && recognition.owner == owner &&
                    (expectedLease == null || recognition.lease == expectedLease) &&
                    (expectedWorkflowToken == null || recognition.workflowToken == expectedWorkflowToken) -> {
                    activeRecognition = null
                    CancellationTarget(
                        recognition.lease,
                        activeRecognition = recognition,
                        workflowToken = recognition.workflowToken,
                        preserveRecognitionProgress = true
                    )
                }
                start != null || retryStart != null || capture != null || finalized != null ||
                    preparation != null || recognition != null -> return false
                else -> return true
            }.also {
                if (it.resetImmediately) resetAttemptState()
                resetMeters()
            }
        }
        target.activeStart?.let { start ->
            start.callerJob.cancel(CancellationException(reason))
            start.executor.shutdownNow()
            detachedScope.launch {
                releaseRecorderOutOfBand(start.provisionalLease.recordingId, start.recorder)
            }
        }
        target.activeRetryStart?.callerJob?.cancel(CancellationException(reason))
        target.activeCapture?.let { capture ->
            capture.executor.shutdownNow()
            detachedScope.launch {
                releaseRecorderOutOfBand(capture.lease.recordingId, capture.recorder)
            }
        }
        target.activeRetryPreparation?.job?.cancel(CancellationException(reason))
        target.activeRecognition?.let { recognition ->
            recognition.job.cancel(CancellationException(reason))
            if (recognition.configuration.useLocalRecognition && recognition.rawComplete.get().isBlank()) {
                transcriptionOperations.abandonLocalRecognition()
            }
        }
        val durableLease = target.lease
        if (!target.hasDurableLease || durableLease == null) return true
        return withContext(NonCancellable) {
            // A cancellation with nothing transcribed is not a result worth keeping.
            // Writing it as a CANCELLED terminal put a note in History for every
            // aborted attempt — closing the recording screen left one reading
            // "Recording screen closed". Drop the attempt instead, and only fall
            // back to recording the terminal if the delete does not land.
            if (!target.preserveRecognitionProgress && discardCancelledAttempt(durableLease)) {
                return@withContext true
            }
            val saved = persistFailureTerminal(
                durableLease,
                AudioProcessingStatus.CANCELLED,
                reason,
                target.preserveRecognitionProgress
            )
            if (!saved) {
                retryFailureTerminalInBackground(
                    durableLease,
                    AudioProcessingStatus.CANCELLED,
                    reason,
                    target.preserveRecognitionProgress
                )
                target.workflowToken?.let { workflowToken ->
                    _failureEvents.emit(
                        failureEvent(
                            owner,
                            durableLease,
                            workflowToken,
                            historyUpdateFailure("The recording was cancelled.")
                        )
                    )
                }
            }
            saved
        }
    }

    fun cancelCaptureFromLifecycle(
        owner: AndroidAudioAttemptOwner,
        reason: String,
        expectedLease: AudioAttemptLease? = null,
        expectedWorkflowToken: Long? = null
    ) {
        detachedScope.launch(start = CoroutineStart.UNDISPATCHED) {
            cancelCapture(owner, reason, expectedLease, expectedWorkflowToken)
        }
    }

    suspend fun isCaptureCurrent(owner: AndroidAudioAttemptOwner, lease: AudioAttemptLease): Boolean =
        mutex.withLock {
            activeCapture?.owner == owner && activeCapture?.lease == lease &&
                _owner.value == owner && _state.value == AndroidAudioProcessingState.RECORDING
        }

    suspend fun processRecognition(finalized: FinalizedAndroidCapture): Result<AndroidProcessingResult> {
        if (finalized.transcriptionConfiguration.useLocalRecognition &&
            finalized.durationMs > MAX_LOCAL_PROCESSABLE_DURATION_MS
        ) {
            val message = "This recording is too long for offline mode. Switch to cloud mode and retry."
            failBeforeRecognition(finalized, message)
            return Result.failure(IllegalStateException(message))
        }

        val rawComplete = AtomicReference("")
        val completedLeaves = AtomicInteger(0)
        val worker = detachedScope.async(start = CoroutineStart.LAZY) {
            transcriptionOperations.transcribe(
                audioFile = finalized.sourceFile,
                configuration = finalized.transcriptionConfiguration,
                checkpoint = { merged, count ->
                    val saved = withPersistenceDeadline {
                        recordingRepository.checkpoint(finalized.lease, merged, count)
                    }
                    if (saved) {
                        completedLeaves.set(count)
                    }
                    saved
                },
                rawComplete = { raw ->
                    val saved = withPersistenceDeadline {
                        recordingRepository.markRecognitionComplete(
                            finalized.lease,
                            raw,
                            completedLeaves.get().coerceAtLeast(1)
                        )
                    }
                    if (saved) rawComplete.set(raw)
                    saved
                }
            )
        }
        val recognition = ActiveRecognition(
            lease = finalized.lease,
            workflowToken = finalized.workflowToken,
            owner = finalized.owner,
            job = worker,
            configuration = finalized.transcriptionConfiguration,
            rawComplete = rawComplete
        )
        val ownsPendingAttempt = mutex.withLock {
            val pending = pendingFinalized
            if (pending?.lease != finalized.lease || pending.owner != finalized.owner ||
                _state.value != AndroidAudioProcessingState.PROCESSING
            ) {
                false
            } else {
                pendingFinalized = null
                _owner.value = finalized.owner
                activeRecognition = recognition
                true
            }
        }
        if (!ownsPendingAttempt) {
            worker.cancel()
            return Result.failure(IllegalStateException("This transcription attempt is no longer active"))
        }
        worker.start()

        return try {
            val recognized = withTimeout(recognitionTimeoutMillis(finalized.durationMs)) { worker.await() }
                .getOrThrow()
                .trim()
            if (recognized.isEmpty()) throw IllegalStateException("No speech was recognized")
            val raw = rawComplete.get().ifBlank {
                throw IllegalStateException("The complete raw transcription was not saved")
            }
            if (!withPersistenceDeadline {
                    recordingRepository.finishAttempt(
                        finalized.lease,
                        AudioProcessingStatus.SUCCESS,
                        transcription = recognized,
                        rawTranscription = raw,
                        checkpointText = raw,
                        completedLeafCount = completedLeaves.get().coerceAtLeast(1)
                    )
                }
            ) {
                throw IllegalStateException("The transcription finished after this attempt was replaced")
            }
            Result.success(
                AndroidProcessingResult(
                    finalized.lease.recordingId,
                    raw,
                    recognized,
                    finalized.usageClaimId
                )
            )
        } catch (error: Throwable) {
            worker.cancel()
            Log.e("AndroidAudioProcessing", "Transcription attempt failed", error)
            val durableRaw = rawComplete.get()
            if (durableRaw.isNotBlank()) {
                val saved = withContext(NonCancellable) {
                    runCatching {
                        withPersistenceDeadline {
                            recordingRepository.finishAttempt(
                                finalized.lease,
                                AudioProcessingStatus.SUCCESS,
                                transcription = durableRaw,
                                rawTranscription = durableRaw,
                                checkpointText = durableRaw,
                                completedLeafCount = completedLeaves.get().coerceAtLeast(1)
                            )
                        }
                    }.getOrDefault(false)
                }
                if (error is CancellationException && error !is TimeoutCancellationException) throw error
                if (saved) {
                    return Result.success(
                        AndroidProcessingResult(
                            finalized.lease.recordingId,
                            durableRaw,
                            durableRaw,
                            finalized.usageClaimId
                        )
                    )
                }
            } else if (finalized.transcriptionConfiguration.useLocalRecognition) {
                transcriptionOperations.abandonLocalRecognition()
            }
            val message = userFacingRecognitionFailure(error)
            val terminalStatus =
                if (error is CancellationException && error !is TimeoutCancellationException) {
                    AudioProcessingStatus.CANCELLED
                } else {
                    AudioProcessingStatus.FAILED
                }
            val terminalSaved = withContext(NonCancellable) {
                persistFailureTerminal(
                    finalized.lease,
                    terminalStatus,
                    message,
                    preserveRecognitionProgress = true
                )
            }
            if (!terminalSaved) {
                retryFailureTerminalInBackground(
                    finalized.lease,
                    terminalStatus,
                    message,
                    preserveRecognitionProgress = true
                )
            }
            if (error is CancellationException && error !is TimeoutCancellationException) throw error
            Result.failure(
                IllegalStateException(
                    if (terminalSaved) message else historyUpdateFailure(message),
                    error
                )
            )
        } finally {
            finishRecognitionInMemory(finalized.lease)
        }
    }

    suspend fun failBeforeRecognition(finalized: FinalizedAndroidCapture, message: String): Boolean {
        val ownsPendingAttempt = withContext(NonCancellable) {
            mutex.withLock {
                if (pendingFinalized?.lease == finalized.lease &&
                    pendingFinalized?.owner == finalized.owner &&
                    _state.value == AndroidAudioProcessingState.PROCESSING
                ) {
                    pendingFinalized = null
                    true
                } else {
                    false
                }
            }
        }
        if (!ownsPendingAttempt) return false
        return try {
            val saved = withContext(NonCancellable) {
                persistFailureTerminal(
                    finalized.lease,
                    AudioProcessingStatus.FAILED,
                    message,
                    preserveRecognitionProgress = true
                )
            }
            if (!saved) {
                retryFailureTerminalInBackground(
                    finalized.lease,
                    AudioProcessingStatus.FAILED,
                    message,
                    preserveRecognitionProgress = true
                )
            }
            saved
        } finally {
            withContext(NonCancellable) {
                mutex.withLock {
                    if (_owner.value == finalized.owner &&
                        _state.value == AndroidAudioProcessingState.PROCESSING &&
                        pendingFinalized == null && activeRecognition == null &&
                        activeRetryPreparation == null
                    ) {
                        resetAttemptState()
                    }
                }
            }
        }
    }

    suspend fun retry(
        owner: AndroidAudioAttemptOwner,
        workflowToken: Long,
        recordingId: String,
        additionalPrompt: String?,
        contextRules: String?
    ): Result<AndroidProcessingResult> {
        val retryStart = mutex.withLock {
            if (_state.value != AndroidAudioProcessingState.IDLE || activeRetryStart != null) {
                return Result.failure(
                    IllegalStateException("Another recording is already active")
                )
            }
            ActiveRetryStart(
                token = UUID.randomUUID().toString(),
                workflowToken = workflowToken,
                recordingId = recordingId,
                owner = owner,
                callerJob = checkNotNull(kotlin.coroutines.coroutineContext[Job]),
                lease = AtomicReference(null),
                usageDestination = owner.capturedUsageDestination()
            ).also {
                check(retryStartFence.reserve(it.token))
                activeRetryStart = it
                _owner.value = owner
                // A retry re-transcribes an existing recording, so it is processing
                // from the outset; nothing is being captured.
                _state.value = AndroidAudioProcessingState.PROCESSING
            }
        }

        var claimed: AudioAttemptLease? = null
        var validationWorker: Deferred<Long>? = null
        var installedPreparation: ActiveRetryPreparation? = null
        try {
            val configuration = withTimeout(CONFIGURATION_TIMEOUT_MS) {
                recordingRepository.awaitStartupRecovery()
                transcriptionOperations.captureAttemptConfiguration(additionalPrompt, contextRules)
            }
            claimed = withPersistenceDeadline(
                onLateCompletion = { result, abandonment ->
                    result.getOrNull()?.let { lateLease ->
                        reconcileAbandonedRecognition(
                            lateLease,
                            abandonment,
                            "Retry ownership was acquired after its workflow ended."
                        )
                    }
                }
            ) {
                recordingRepository.claimRetry(
                    recordingId,
                    usageEligible = owner.recordsUsage,
                    usageDestination = retryStart.usageDestination
                )
            }
                ?: throw AudioAttemptUnavailableException(
                    "This recording is already active or cannot be retried"
                )
            retryStart.lease.set(claimed)

            val source = File(claimed.sourcePath)
            val validationExecutor = newNativeExecutor(recordingId)
            validationWorker = detachedScope.async(start = CoroutineStart.LAZY) {
                try {
                    withTimeout(FINALIZE_TIMEOUT_MS) {
                        submitCancellable(validationExecutor) { audioDurationReader(source) }
                    }
                } finally {
                    validationExecutor.shutdownNow()
                }
            }
            val candidate = ActiveRetryPreparation(
                claimed,
                workflowToken,
                owner,
                validationWorker,
                configuration
            )
            installedPreparation = candidate
            val installed = withContext(NonCancellable) {
                mutex.withLock {
                    if (activeRetryStart?.token == retryStart.token && retryStart.callerJob.isActive &&
                        _owner.value == owner && _state.value == AndroidAudioProcessingState.PROCESSING &&
                        retryStartFence.install(retryStart.token)
                    ) {
                        activeRetryStart = null
                        activeRetryPreparation = candidate
                        _state.value = AndroidAudioProcessingState.PROCESSING
                        true
                    } else {
                        false
                    }
                }
            }
            if (!installed) throw CancellationException("Retry was cancelled before it could start")
        } catch (error: Throwable) {
            validationWorker?.cancel()
            var terminalSaved = true
            withContext(NonCancellable) {
                mutex.withLock {
                    if (activeRetryStart?.token == retryStart.token) {
                        activeRetryStart = null
                        retryStartFence.cancel(retryStart.token)
                        resetAttemptState()
                    }
                }
                claimed?.let { lease ->
                    val status =
                        if (error is CancellationException && error !is TimeoutCancellationException) {
                            AudioProcessingStatus.CANCELLED
                        } else {
                            AudioProcessingStatus.FAILED
                        }
                    val message = if (error is CancellationException) {
                        "Retry was cancelled. Your saved audio is still available."
                    } else {
                        "Retry could not start. Your saved audio is still available."
                    }
                    terminalSaved = persistFailureTerminal(
                        lease,
                        status,
                        message,
                        preserveRecognitionProgress = true
                    )
                    if (!terminalSaved) {
                        retryFailureTerminalInBackground(
                            lease,
                            status,
                            message,
                            preserveRecognitionProgress = true
                        )
                    }
                }
            }
            if (error is CancellationException && error !is TimeoutCancellationException) throw error
            return Result.failure(
                if (terminalSaved) error else IllegalStateException(
                    historyUpdateFailure("Retry could not start."),
                    error
                )
            )
        }
        val preparation = checkNotNull(installedPreparation)
        val lease = preparation.lease
        val configuration = preparation.configuration
        val source = File(lease.sourcePath)
        preparation.job.start()
        val duration = try {
            preparation.job.await()
        } catch (error: Throwable) {
            preparation.job.cancel()
            val owned = withContext(NonCancellable) {
                mutex.withLock {
                    if (activeRetryPreparation?.lease == lease) {
                        activeRetryPreparation = null
                        resetAttemptState()
                        true
                    } else {
                        false
                    }
                }
            }
            var terminalSaved = true
            if (owned) {
                withContext(NonCancellable) {
                    val status =
                        if (error is CancellationException && error !is TimeoutCancellationException) {
                            AudioProcessingStatus.CANCELLED
                        } else {
                            AudioProcessingStatus.FAILED
                        }
                    val message = when {
                        error is TimeoutCancellationException ->
                            "Checking the saved audio took too long. It is still available to retry."
                        error is CancellationException ->
                            "Retry was cancelled. Your saved audio is still available."
                        else -> "The saved audio could not be opened."
                    }
                    terminalSaved = persistFailureTerminal(
                        lease,
                        status,
                        message,
                        preserveRecognitionProgress = true
                    )
                    if (!terminalSaved) {
                        retryFailureTerminalInBackground(
                            lease,
                            status,
                            message,
                            preserveRecognitionProgress = true
                        )
                    }
                }
            }
            if (error is CancellationException && error !is TimeoutCancellationException) throw error
            return Result.failure(
                if (terminalSaved) error else IllegalStateException(
                    historyUpdateFailure("The saved audio could not be opened."),
                    error
                )
            )
        }
        val finalized = FinalizedAndroidCapture(
            lease,
            workflowToken,
            source,
            duration,
            true,
            owner,
            configuration
        )
        val installed = withContext(NonCancellable) {
            mutex.withLock {
                if (activeRetryPreparation?.lease == lease &&
                    activeRetryPreparation?.owner == owner &&
                    _state.value == AndroidAudioProcessingState.PROCESSING
                ) {
                    activeRetryPreparation = null
                    pendingFinalized = finalized
                    true
                } else {
                    false
                }
            }
        }
        if (!installed) {
            val error = CancellationException("This retry attempt is no longer active")
            if (!kotlin.coroutines.coroutineContext[Job]!!.isActive) throw error
            return Result.failure(error)
        }
        return processRecognition(finalized)
    }

    suspend fun deleteRecording(recording: Recording): Boolean = mutex.withLock {
        val ready = try {
            withTimeout(CONFIGURATION_TIMEOUT_MS) { recordingRepository.awaitStartupRecovery() }
            true
        } catch (error: CancellationException) {
            if (error !is TimeoutCancellationException) throw error
            false
        } catch (_: Throwable) {
            false
        }
        ready && runCatching {
            withPersistenceDeadline { recordingRepository.deleteRecording(recording) }
        }.getOrDefault(false)
    }

    suspend fun clearHistory(): Boolean = mutex.withLock {
        if (_state.value != AndroidAudioProcessingState.IDLE || activeRetryStart != null) {
            return false
        }
        val ready = try {
            withTimeout(CONFIGURATION_TIMEOUT_MS) { recordingRepository.awaitStartupRecovery() }
            true
        } catch (error: CancellationException) {
            if (error !is TimeoutCancellationException) throw error
            false
        } catch (_: Throwable) {
            false
        }
        ready && runCatching {
            withPersistenceDeadline { recordingRepository.clearAllRecordings() }
        }.getOrDefault(false)
    }

    private fun bindMeters(active: ActiveCapture) {
        meterJobs.forEach(Job::cancel)
        val attemptToken = active.attemptToken
        val recorder = active.recorder
        meterEmissionFence.activate(attemptToken)
        meterJobs = listOf(
            detachedScope.launch {
                recorder.audioLevel.collectLatest {
                    meterEmissionFence.emitIfCurrent(attemptToken) { _audioLevel.value = it }
                }
            },
            detachedScope.launch {
                recorder.frequencyBands.collectLatest {
                    meterEmissionFence.emitIfCurrent(attemptToken) { _frequencyBands.value = it }
                }
            },
            detachedScope.launch {
                recorder.shouldAutoStop.collectLatest {
                    meterEmissionFence.emitIfCurrent(attemptToken) { _shouldAutoStop.value = it }
                }
            },
            detachedScope.launch {
                recorder.isRecording.collectLatest { recording ->
                    val failure = recorder.captureError()
                    if (!recording && failure != null) {
                        meterEmissionFence.emitIfCurrent(attemptToken) {
                            detachedScope.launch { handleCaptureFailure(recorder, failure) }
                        }
                    }
                }
            }
        )
    }

    private fun bindCaptureDeadline(active: ActiveCapture) {
        captureDeadlineJob?.cancel()
        val maximumDurationMs = if (active.transcriptionConfiguration.useLocalRecognition) {
            MAX_LOCAL_CAPTURE_DURATION_MS
        } else {
            MAX_CLOUD_CAPTURE_DURATION_MS
        }
        captureDeadlineJob = detachedScope.launch {
            kotlinx.coroutines.delay(maximumDurationMs)
            val stillRecording = mutex.withLock {
                activeCapture?.lease == active.lease &&
                    activeCapture?.owner == active.owner &&
                    _state.value == AndroidAudioProcessingState.RECORDING
            }
            if (!stillRecording) return@launch
            _shouldAutoStop.value = true
            kotlinx.coroutines.delay(CAPTURE_AUTO_STOP_GRACE_MS)
            val needsEnforcement = mutex.withLock {
                activeCapture?.lease == active.lease &&
                    activeCapture?.owner == active.owner &&
                    _state.value == AndroidAudioProcessingState.RECORDING
            }
            if (needsEnforcement) {
                detachedScope.launch { enforceCaptureDeadline(active) }
            }
        }
    }

    private suspend fun enforceCaptureDeadline(active: ActiveCapture) {
        val message = "The recording reached its maximum length. Its audio was saved in History."
        val finalized = stopCapture(active.owner, expectedLease = active.lease).getOrElse { error ->
            if (error is AudioAttemptUnavailableException) return
            Log.e("AndroidAudioProcessing", "Unable to finalize capture at its deadline", error)
            _failureEvents.emit(
                active.failureEvent(
                    error.message
                        ?: "The recording reached its maximum length but could not be finalized. Recoverable audio was kept."
                )
            )
            return
        }
        failBeforeRecognition(finalized, message)
        _failureEvents.emit(active.failureEvent(message))
    }

    private suspend fun handleCaptureFailure(recorder: AudioRecorder, error: Throwable) {
        Log.e("AndroidAudioProcessing", "Audio capture stopped unexpectedly", error)
        val message = "Audio capture stopped unexpectedly. Your recoverable audio was kept."
        val active = mutex.withLock {
            val current = activeCapture
                ?.takeIf { it.recorder === recorder && _state.value == AndroidAudioProcessingState.RECORDING }
                ?: return
            activeCapture = null
            captureNativeFence.cancel(current.attemptToken)
            resetAttemptState()
            resetMeters()
            current
        }
        active.executor.shutdownNow()
        detachedScope.launch { runCatching { active.recorder.release() } }
        val terminalSaved = withContext(NonCancellable) {
            persistFailureTerminal(
                active.lease,
                AudioProcessingStatus.FAILED,
                message,
                preserveRecognitionProgress = false
            )
        }
        if (!terminalSaved) {
            retryFailureTerminalInBackground(
                active.lease,
                AudioProcessingStatus.FAILED,
                message,
                preserveRecognitionProgress = false
            )
        }
        _failureEvents.emit(
            active.failureEvent(if (terminalSaved) message else historyUpdateFailure(message))
        )
    }

    private fun ActiveCapture.failureEvent(message: String) = AndroidAudioFailureEvent(
        owner = owner,
        recordingId = lease.recordingId,
        attemptId = lease.attemptId,
        generation = lease.generation,
        workflowToken = workflowToken,
        message = message
    )

    private fun failureEvent(
        owner: AndroidAudioAttemptOwner,
        lease: AudioAttemptLease,
        workflowToken: Long,
        message: String
    ) = AndroidAudioFailureEvent(
        owner = owner,
        recordingId = lease.recordingId,
        attemptId = lease.attemptId,
        generation = lease.generation,
        workflowToken = workflowToken,
        message = message
    )

    private suspend fun reconcileAbandonedCapture(
        lease: AudioAttemptLease,
        abandonment: Throwable,
        message: String
    ) {
        val status = terminalStatusForAbandonment(abandonment)
        if (!persistFailureTerminal(lease, status, message, preserveRecognitionProgress = false)) {
            retryFailureTerminalInBackground(
                lease,
                status,
                message,
                preserveRecognitionProgress = false
            )
        }
    }

    private suspend fun reconcileAbandonedRecognition(
        lease: AudioAttemptLease,
        abandonment: Throwable,
        message: String
    ) {
        val status = terminalStatusForAbandonment(abandonment)
        if (!persistFailureTerminal(lease, status, message, preserveRecognitionProgress = true)) {
            retryFailureTerminalInBackground(
                lease,
                status,
                message,
                preserveRecognitionProgress = true
            )
        }
    }

    /** Removes an aborted attempt so it never surfaces in History. Returns false
     *  when the row cannot be read or deleted, so the caller can still record a
     *  terminal rather than leave the attempt stuck in an active state. */
    private suspend fun discardCancelledAttempt(lease: AudioAttemptLease): Boolean {
        val lookup = runCatching {
            withPersistenceDeadline { recordingRepository.getRecordingById(lease.recordingId) }
        }
        if (lookup.isFailure) return false
        val current = lookup.getOrNull() ?: return true
        // Someone else already moved this recording on; leave it alone.
        if (current.generation != lease.generation || current.attemptId != lease.attemptId) {
            return true
        }
        return runCatching {
            withPersistenceDeadline { recordingRepository.deleteRecording(current) }
        }.getOrDefault(false)
    }

    private suspend fun persistFailureTerminal(
        lease: AudioAttemptLease,
        status: AudioProcessingStatus,
        message: String,
        preserveRecognitionProgress: Boolean
    ): Boolean {
        val written = runCatching {
            withPersistenceDeadline {
                if (preserveRecognitionProgress) {
                    recordingRepository.finishRecognitionPreservingProgress(lease, status, message)
                } else {
                    recordingRepository.finishAttempt(lease, status, errorMessage = message)
                }
            }
        }.getOrNull()
        if (written == true) return true

        val lookup = runCatching {
            withPersistenceDeadline { recordingRepository.getRecordingById(lease.recordingId) }
        }
        if (lookup.isFailure) return false
        val current = lookup.getOrNull()
        return current == null || current.generation != lease.generation ||
            current.attemptId != lease.attemptId || !current.status.isActive
    }

    private fun retryFailureTerminalInBackground(
        lease: AudioAttemptLease,
        status: AudioProcessingStatus,
        message: String,
        preserveRecognitionProgress: Boolean
    ) {
        detachedScope.launch {
            repeat(3) { attempt ->
                if (attempt > 0) kotlinx.coroutines.delay(250L * attempt)
                if (persistFailureTerminal(lease, status, message, preserveRecognitionProgress)) {
                    return@launch
                }
            }
            Log.e(
                "AndroidAudioProcessing",
                "History could not be terminalized for ${lease.recordingId}/${lease.generation}"
            )
        }
    }

    private fun historyUpdateFailure(message: String): String =
        "$message Your audio was kept, but History could not be updated. Restart the app before retrying or clearing it."

    private suspend fun finishRecognitionInMemory(lease: AudioAttemptLease) {
        withContext(NonCancellable) {
            mutex.withLock {
                if (activeRecognition?.lease == lease) {
                    activeRecognition = null
                    resetAttemptState()
                }
            }
        }
    }

    private fun terminalStatusForAbandonment(error: Throwable): AudioProcessingStatus =
        if (error is CancellationException) {
            AudioProcessingStatus.CANCELLED
        } else {
            AudioProcessingStatus.FAILED
        }

    private fun resetAttemptState() {
        _state.value = AndroidAudioProcessingState.IDLE
        _owner.value = null
    }

    private fun resetMeters() {
        captureDeadlineJob?.cancel()
        captureDeadlineJob = null
        meterJobs.forEach(Job::cancel)
        meterJobs = emptyList()
        meterEmissionFence.invalidateAndReset {
            _audioLevel.value = 0f
            _frequencyBands.value = FloatArray(6)
            _shouldAutoStop.value = false
        }
    }

    private fun validateFinalizedAudio(file: File) {
        require(file.isFile && file.length() > 0L) { "The finalized audio is empty" }
        require(audioDurationReader(file) > 0) { "The finalized audio has no duration" }
    }

    private suspend fun <T> withPersistenceDeadline(
        onLateCompletion: suspend (Result<T>, Throwable) -> Unit = { _, _ -> },
        block: suspend () -> T
    ): T = withAudioPersistenceDeadline(
        operationScope = detachedScope,
        timeoutMillis = PERSISTENCE_TIMEOUT_MS,
        onLateCompletion = onLateCompletion,
        block = block
    )

    private fun userFacingRecognitionFailure(error: Throwable): String = when (error) {
        is TimeoutCancellationException ->
            "Transcription took too long. Your audio is available to retry."
        is CancellationException ->
            "Transcription was cancelled. Your audio is available to retry."
        is AudioHttpException -> when {
            error.statusCode == 401 || error.statusCode == 403 ->
                "Cloud transcription could not be authorized. Check your account settings, then retry."
            error.statusCode == 404 ->
                "Cloud transcription could not be reached with the current settings. Your audio is available to retry."
            error.statusCode == 408 || error.statusCode == 429 || error.statusCode in 500..599 ->
                "Cloud transcription is temporarily unavailable. Your audio is available to retry."
            error.statusCode == 413 ->
                "The recording was too large to process safely. Your audio is available to retry."
            else ->
                "The transcription request was not accepted. Check your settings, then retry."
        }
        is AudioMalformedResponseException, is AudioEmptyResponseException ->
            "The transcription service returned an incomplete result. Your audio is available to retry."
        is AudioCheckpointException ->
            "Progress could not be saved, so transcription stopped. Your audio is available to retry."
        is AudioSplitException ->
            "The recording could not be prepared for upload. Your original audio is available to retry."
        is IOException ->
            "A network or storage problem interrupted transcription. Your audio is available to retry."
        else ->
            "Transcription could not finish. Your audio is available to retry."
    }

    private fun managedSourceFile(recordingId: String): File =
        recordingRepository.managedSourceFile(recordingId)

    private val AndroidAudioAttemptOwner.recordsUsage: Boolean
        get() = this == AndroidAudioAttemptOwner.MAIN || this == AndroidAudioAttemptOwner.OVERLAY

    private fun AndroidAudioAttemptOwner.capturedUsageDestination(): String =
        if (recordsUsage) {
            usageDestinationProvider() ?: UsageClaimDestination.UNATTRIBUTED
        } else {
            UsageClaimDestination.UNATTRIBUTED
        }

    private val FinalizedAndroidCapture.usageClaimId: String?
        get() = if (owner.recordsUsage) {
            audioUsageClaimId(lease.recordingId, lease.generation)
        } else {
            null
        }

    private fun newNativeExecutor(recordingId: String): ExecutorService {
        val counter = AtomicInteger()
        return Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "audio-native-$recordingId-${counter.incrementAndGet()}").apply { isDaemon = true }
        }
    }

    private suspend fun releaseRecorderOutOfBand(active: ActiveCapture) {
        releaseRecorderOutOfBand(active.lease.recordingId, active.recorder)
    }

    private suspend fun releaseRecorderOutOfBand(recordingId: String, recorder: AudioRecorder) {
        val releaseExecutor = newNativeExecutor("$recordingId-release")
        try {
            withTimeout(RELEASE_TIMEOUT_MS) {
                submitCancellable(releaseExecutor) { recorder.release() }
            }
        } catch (error: Throwable) {
            Log.e("AndroidAudioProcessing", "Unable to release recorder after finalization failure", error)
        } finally {
            releaseExecutor.shutdownNow()
        }
    }

    private suspend fun <T> submitCancellable(
        executor: ExecutorService,
        onLateResult: (T) -> Unit = {},
        block: () -> T
    ): T =
        suspendCancellableCoroutine { continuation ->
            var future: Future<*>? = null
            future = executor.submit {
                try {
                    val value = block()
                    continuation.resume(value) { _, lateValue, _ ->
                        onLateResult(lateValue)
                    }
                } catch (error: Throwable) {
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
            }
            continuation.invokeOnCancellation { future?.cancel(true) }
        }
}
