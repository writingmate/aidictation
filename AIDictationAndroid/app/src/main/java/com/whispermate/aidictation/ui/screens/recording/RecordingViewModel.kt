package com.whispermate.aidictation.ui.screens.recording

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.whispermate.aidictation.service.AndroidAudioAttemptOwner
import com.whispermate.aidictation.service.AndroidAudioProcessingCoordinator
import com.whispermate.aidictation.service.ExclusiveRequestFence
import com.whispermate.aidictation.domain.model.Recording
import com.whispermate.aidictation.domain.model.AudioProcessingStatus
import com.whispermate.aidictation.domain.model.AudioSourceIntegrity
import com.whispermate.aidictation.domain.model.AudioAttemptLease
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.onEach

@HiltViewModel
class RecordingViewModel @Inject constructor(
    private val audioProcessingCoordinator: AndroidAudioProcessingCoordinator
) : ViewModel() {
    private val workflowFence = ExclusiveRequestFence()
    private var activeCaptureLease: AudioAttemptLease? = null
    private var activeWorkflowToken: Long? = null
    val audioLevel = audioProcessingCoordinator.audioLevel
    val frequencyBands = audioProcessingCoordinator.frequencyBands
    val shouldAutoStop = audioProcessingCoordinator.shouldAutoStop
    val failureEvents = audioProcessingCoordinator.failureEvents
        .filter { event ->
            event.matches(
                AndroidAudioAttemptOwner.RECORDING_SHEET,
                activeCaptureLease,
                activeWorkflowToken
            )
        }
        .onEach {
            activeCaptureLease = null
            activeWorkflowToken?.let(workflowFence::finish)
            activeWorkflowToken = null
        }

    suspend fun start(): Result<Unit> {
        val workflowToken = workflowFence.reserve()
            ?: return Result.failure(IllegalStateException("Another recording is already starting"))
        activeWorkflowToken = workflowToken
        val lease = audioProcessingCoordinator.startCapture(
            owner = AndroidAudioAttemptOwner.RECORDING_SHEET,
            workflowToken = workflowToken,
            autoStopOnSilence = false
        ).getOrElse {
            workflowFence.finish(workflowToken)
            activeWorkflowToken = null
            return Result.failure(it)
        }
        if (!workflowFence.owns(workflowToken)) {
            audioProcessingCoordinator.cancelCapture(
                AndroidAudioAttemptOwner.RECORDING_SHEET,
                "Recording sheet was replaced before capture started",
                expectedLease = lease
            )
            return Result.failure(IllegalStateException("The recording stopped before it became active"))
        }
        activeCaptureLease = lease
        if (!audioProcessingCoordinator.isCaptureCurrent(
                AndroidAudioAttemptOwner.RECORDING_SHEET,
                lease
            )
        ) {
            activeCaptureLease = null
            activeWorkflowToken = null
            workflowFence.finish(workflowToken)
            return Result.failure(IllegalStateException("The recording stopped before it became active"))
        }
        return Result.success(Unit)
    }

    suspend fun stopAndTranscribe(): Result<Recording> {
        val finalized = audioProcessingCoordinator.stopCapture(AndroidAudioAttemptOwner.RECORDING_SHEET)
            .getOrElse {
                activeCaptureLease = null
                activeWorkflowToken?.let(workflowFence::finish)
                activeWorkflowToken = null
                return Result.failure(it)
            }
        activeCaptureLease = finalized.lease
        if (finalized.durationMs < 300 || !finalized.speechDetected) {
            audioProcessingCoordinator.failBeforeRecognition(
                finalized,
                "No speech was heard. The saved audio is available in History."
            )
            activeCaptureLease = null
            activeWorkflowToken?.let(workflowFence::finish)
            activeWorkflowToken = null
            return Result.failure(IllegalStateException("Try speaking for a little longer"))
        }
        val processed = audioProcessingCoordinator.processRecognition(finalized)
            .getOrElse {
                activeCaptureLease = null
                activeWorkflowToken?.let(workflowFence::finish)
                activeWorkflowToken = null
                return Result.failure(it)
            }
        activeCaptureLease = null
        activeWorkflowToken?.let(workflowFence::finish)
        activeWorkflowToken = null
        return Result.success(
            Recording(
                id = processed.recordingId,
                transcription = processed.text,
                durationMs = finalized.durationMs,
                audioFilePath = finalized.sourceFile.absolutePath,
                status = AudioProcessingStatus.SUCCESS,
                rawTranscription = processed.rawText,
                checkpointText = processed.rawText,
                completedLeafCount = 1,
                recognitionComplete = true,
                attemptId = finalized.lease.attemptId,
                generation = finalized.lease.generation,
                sourceIntegrity = AudioSourceIntegrity.COMPLETE
            )
        )
    }

    fun cancel() {
        val lease = activeCaptureLease
        val workflowToken = activeWorkflowToken
        activeCaptureLease = null
        activeWorkflowToken = null
        workflowFence.cancelCurrent()
        viewModelScope.launch {
            audioProcessingCoordinator.cancelCapture(
                AndroidAudioAttemptOwner.RECORDING_SHEET,
                expectedLease = lease,
                expectedWorkflowToken = workflowToken
            )
        }
    }

    override fun onCleared() {
        val lease = activeCaptureLease
        val workflowToken = activeWorkflowToken
        workflowFence.cancelCurrent()
        activeCaptureLease = null
        activeWorkflowToken = null
        audioProcessingCoordinator.cancelCaptureFromLifecycle(
            AndroidAudioAttemptOwner.RECORDING_SHEET,
            "Recording sheet closed",
            expectedLease = lease,
            expectedWorkflowToken = workflowToken
        )
        super.onCleared()
    }
}
