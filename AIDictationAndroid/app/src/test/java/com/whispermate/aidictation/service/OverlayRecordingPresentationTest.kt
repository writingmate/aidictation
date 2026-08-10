package com.whispermate.aidictation.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayRecordingPresentationTest {

    @Test
    fun `capture startup presents a non processing microphone state`() {
        assertEquals(
            OverlayBubblePresentation.Starting,
            OverlayRecordingState.Starting.bubblePresentation()
        )
        assertFalse(OverlayRecordingState.Starting.streamsAudioLevels)
    }

    @Test
    fun `live capture presents recording controls and audio levels`() {
        assertEquals(
            OverlayBubblePresentation.Recording,
            OverlayRecordingState.Recording.bubblePresentation()
        )
        assertTrue(OverlayRecordingState.Recording.streamsAudioLevels)
    }

    @Test
    fun `post capture work remains visibly processing`() {
        assertEquals(
            OverlayBubblePresentation.Processing,
            OverlayRecordingState.Processing.bubblePresentation()
        )
        assertFalse(OverlayRecordingState.Processing.streamsAudioLevels)
    }

    @Test
    fun `idle state remains collapsed and does not stream audio levels`() {
        assertEquals(
            OverlayBubblePresentation.Idle,
            OverlayRecordingState.Idle.bubblePresentation()
        )
        assertFalse(OverlayRecordingState.Idle.streamsAudioLevels)
    }

    @Test
    fun `selection commands stay disabled while delivery owns the workflow`() {
        assertFalse(
            canStartSelectionCommand(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = true
            )
        )
    }

    @Test
    fun `selection commands are enabled only when fully idle`() {
        assertTrue(
            canStartSelectionCommand(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = false
            )
        )
        assertFalse(
            canStartSelectionCommand(
                recordingState = OverlayRecordingState.Processing,
                workflowActive = false
            )
        )
    }
}
