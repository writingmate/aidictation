package com.whispermate.aidictation.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayRecordingPresentationTest {

    // There is no startup state: a tap goes straight to recording, so the bubble
    // shows the waveform immediately and never a microphone glyph.

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

    // The wand button: shown and tappable, or not shown at all.

    @Test
    fun `wand appears only for a selection next to an idle bubble`() {
        assertTrue(
            shouldShowWandButton(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = false,
                hasSelection = true,
                panelOpen = false
            )
        )
        assertFalse(
            shouldShowWandButton(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = false,
                hasSelection = false,
                panelOpen = false
            )
        )
    }

    @Test
    fun `wand hides while the bubble is busy or a dictation delivery is pending`() {
        assertFalse(
            shouldShowWandButton(
                recordingState = OverlayRecordingState.Recording,
                workflowActive = true,
                hasSelection = true,
                panelOpen = false
            )
        )
        assertFalse(
            shouldShowWandButton(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = true,
                hasSelection = true,
                panelOpen = false
            )
        )
    }

    @Test
    fun `wand hides while its panel is open`() {
        assertFalse(
            shouldShowWandButton(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = false,
                hasSelection = true,
                panelOpen = true
            )
        )
    }
}
