package com.whispermate.aidictation.service

import com.whispermate.aidictation.data.local.ParakeetAbandonAction
import com.whispermate.aidictation.data.local.parakeetAbandonAction
import com.whispermate.aidictation.domain.model.AudioAttemptLease
import com.whispermate.aidictation.domain.model.AudioProcessingStatus
import com.whispermate.aidictation.util.TerminalResourceFence
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class AudioWorkflowFencesTest {
    @Test
    fun cancellationAtEveryStartingBoundaryFencesLateNativeInstall() {
        listOf("configuration", "journal", "native-start").forEach { boundary ->
            val fence = CaptureNativeFence()
            val token = "attempt-$boundary"

            assertTrue(fence.reserveStart(token))
            assertTrue(fence.cancel(token))
            assertFalse("late $boundary completion installed recording", fence.promoteToRecording(token))
            assertEquals(CaptureNativeFence.Phase.IDLE, fence.snapshot())
        }
    }

    @Test
    fun cancelWhileFinalizingFencesLateMarkAndNativeStop() {
        val fence = CaptureNativeFence()
        val attempt = "attempt"
        val stop = "stop"

        assertTrue(fence.reserveStart(attempt))
        assertTrue(fence.promoteToRecording(attempt))
        assertTrue(fence.reserveFinalization(attempt, stop))
        assertTrue(fence.cancel(attempt))

        assertFalse(fence.ownsFinalization(attempt, stop))
        assertFalse("late finalized source revived cancelled attempt", fence.acceptsFinalized(attempt, stop))
        assertEquals(CaptureNativeFence.Phase.IDLE, fence.snapshot())
    }

    @Test
    fun releaseBeforeNativeRegistrationIsRememberedAndLateStartCannotPublish() {
        data class FakeNative(var released: Int = 0)
        val fence = TerminalResourceFence<FakeNative> { it.released += 1 }
        val recorder = FakeNative()

        fence.retire()

        assertFalse(fence.register(recorder))
        assertEquals(1, recorder.released)
        assertFalse(fence.publishIfCurrent(recorder) { error("must not publish") })
        assertNull(fence.current())
    }

    @Test
    fun retirementDuringStuckNativeStartReleasesAndBlocksLatePublication() {
        data class FakeNative(var released: Int = 0)
        val fence = TerminalResourceFence<FakeNative> { it.released += 1 }
        val recorder = FakeNative()
        var published = false

        assertTrue(fence.register(recorder))
        fence.retire()

        assertEquals(1, recorder.released)
        assertFalse(fence.publishIfCurrent(recorder) { published = true })
        assertFalse(published)
    }

    @Test
    fun finalizedCommitSurvivesNativeReleaseFailure() {
        data class FakeNative(val id: String)
        val fence = TerminalResourceFence<FakeNative> { throw IllegalStateException("release stuck") }
        val recorder = FakeNative("native")
        var finalizedSourceCommitted = false

        assertTrue(fence.register(recorder))
        finalizedSourceCommitted = true
        fence.retire()

        assertTrue(finalizedSourceCommitted)
        assertNull(fence.current())
    }

    @Test
    fun parakeetRetiresOnlyFirstStuckGenerationAndIdleCancelDoesNothing() {
        assertEquals(
            ParakeetAbandonAction.IGNORE_IDLE,
            parakeetAbandonAction(activeTranscriptions = 0, retiredGenerations = 0)
        )
        assertEquals(
            ParakeetAbandonAction.RETIRE,
            parakeetAbandonAction(activeTranscriptions = 1, retiredGenerations = 0)
        )
        assertEquals(
            ParakeetAbandonAction.QUARANTINE,
            parakeetAbandonAction(activeTranscriptions = 1, retiredGenerations = 1)
        )
    }

    @Test
    fun duplicateMainPreflightsCannotQueue() {
        val fence = ExclusiveRequestFence()
        val first = fence.reserve()

        assertTrue(first != null)
        assertNull(fence.reserve())
        assertTrue(fence.finish(first!!))
        assertTrue(fence.reserve() != null)
    }

    @Test
    fun onboardingDoubleStopHasOneTerminalOwner() {
        val fence = ExclusiveRequestFence()
        val token = checkNotNull(fence.reserve())

        assertTrue(fence.beginTerminal(token))
        assertFalse(fence.beginTerminal(token))
        assertTrue(fence.owns(token))
        assertTrue(fence.finish(token))
    }

    @Test
    fun cancelledRetryStartRejectsLateClaimInstallation() {
        val fence = RetryStartFence()
        val token = "retry-start"

        assertTrue(fence.reserve(token))
        assertTrue(fence.cancel(token))
        assertFalse(fence.install(token))

        val replacement = "retry-replacement"
        assertTrue(fence.reserve(replacement))
        assertFalse(fence.install(token))
        assertTrue(fence.install(replacement))
    }

    @Test
    fun oldOverlayDeliveryAndFinallyCannotResetNewAudio() {
        val fence = ReplaceableDeliveryFence()
        val old = fence.beginAudio()
        assertTrue(fence.beginDelivery(old))

        val current = fence.beginAudio()

        assertFalse(fence.finish(old))
        assertTrue(fence.ownsAudio(current))
        assertEquals(ReplaceableDeliveryFence.Phase.AUDIO, fence.currentPhase())
    }

    @Test
    fun staleAutoStopEmissionCannotAffectReplacementCapture() {
        val fence = AttemptEmissionFence()
        fence.activate("old")
        var autoStop = false
        assertTrue(fence.emitIfCurrent("old") { autoStop = true })

        fence.invalidateAndReset { autoStop = false }
        fence.activate("new")

        assertFalse(fence.emitIfCurrent("old") { autoStop = true })
        assertTrue(fence.emitIfCurrent("new") { })
        assertFalse(autoStop)
    }

    @Test
    fun resetCannotBeOverwrittenByAlreadyAuthorizedOldEmission() {
        val fence = AttemptEmissionFence()
        val emissionEntered = CountDownLatch(1)
        val allowEmission = CountDownLatch(1)
        var autoStop = false
        fence.activate("old")

        val oldEmitter = Thread {
            fence.emitIfCurrent("old") {
                emissionEntered.countDown()
                assertTrue(allowEmission.await(1, TimeUnit.SECONDS))
                autoStop = true
            }
        }.apply { start() }
        assertTrue(emissionEntered.await(1, TimeUnit.SECONDS))

        val resetFinished = CountDownLatch(1)
        val reset = Thread {
            fence.invalidateAndReset { autoStop = false }
            resetFinished.countDown()
        }.apply { start() }
        allowEmission.countDown()

        assertTrue(resetFinished.await(1, TimeUnit.SECONDS))
        oldEmitter.join(1_000)
        reset.join(1_000)
        assertFalse(autoStop)
    }

    @Test
    fun delayedFailureEventMustMatchOwnerRecordingAttemptGenerationAndWorkflow() {
        val currentLease = AudioAttemptLease(
            recordingId = "recording-current",
            attemptId = "attempt-current",
            generation = 7,
            sourcePath = "/managed/current.m4a",
            status = AudioProcessingStatus.CAPTURING
        )
        val current = AndroidAudioFailureEvent(
            owner = AndroidAudioAttemptOwner.OVERLAY,
            recordingId = currentLease.recordingId,
            attemptId = currentLease.attemptId,
            generation = currentLease.generation,
            workflowToken = 19,
            message = "current"
        )

        assertTrue(current.matches(AndroidAudioAttemptOwner.OVERLAY, currentLease, 19))
        assertFalse(current.copy(owner = AndroidAudioAttemptOwner.MAIN).matches(
            AndroidAudioAttemptOwner.OVERLAY, currentLease, 19
        ))
        assertFalse(current.copy(recordingId = "recording-old").matches(
            AndroidAudioAttemptOwner.OVERLAY, currentLease, 19
        ))
        assertFalse(current.copy(attemptId = "attempt-old").matches(
            AndroidAudioAttemptOwner.OVERLAY, currentLease, 19
        ))
        assertFalse(current.copy(generation = 6).matches(
            AndroidAudioAttemptOwner.OVERLAY, currentLease, 19
        ))
        assertFalse(current.copy(workflowToken = 18).matches(
            AndroidAudioAttemptOwner.OVERLAY, currentLease, 19
        ))
        assertFalse(current.matches(AndroidAudioAttemptOwner.OVERLAY, null, 19))
        assertFalse(current.matches(AndroidAudioAttemptOwner.OVERLAY, currentLease, null))
    }
}
