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

    // Selection command presentation: the pressed button slides into the speak
    // button's place, then the bubble shows that command's icon with a progress bar.

    @Test
    fun `active command processing shows the command icon and progress bar`() {
        assertEquals(
            OverlayBubblePresentation.CommandProcessing,
            resolveBubblePresentation(
                recordingState = OverlayRecordingState.Processing,
                commandActive = true,
                commandSlideInProgress = false
            )
        )
    }

    @Test
    fun `dictation processing without a command keeps the spinner presentation`() {
        assertEquals(
            OverlayBubblePresentation.Processing,
            resolveBubblePresentation(
                recordingState = OverlayRecordingState.Processing,
                commandActive = false,
                commandSlideInProgress = false
            )
        )
    }

    @Test
    fun `rewrite instruction capture records like dictation`() {
        assertEquals(
            OverlayBubblePresentation.Recording,
            resolveBubblePresentation(
                recordingState = OverlayRecordingState.Recording,
                commandActive = true,
                commandSlideInProgress = false
            )
        )
    }

    @Test
    fun `bubble stays idle looking until the pressed button lands on it`() {
        for (state in OverlayRecordingState.entries) {
            assertEquals(
                OverlayBubblePresentation.Idle,
                resolveBubblePresentation(
                    recordingState = state,
                    commandActive = true,
                    commandSlideInProgress = true
                )
            )
        }
    }

    // Command button visibility: shown and tappable, or not shown at all.

    @Test
    fun `command buttons appear only for a selection next to an idle bubble`() {
        assertTrue(
            shouldShowCommandActions(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = false,
                hasSelection = true
            )
        )
        assertFalse(
            shouldShowCommandActions(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = false,
                hasSelection = false
            )
        )
    }

    @Test
    fun `command buttons hide while the bubble is busy`() {
        assertFalse(
            shouldShowCommandActions(
                recordingState = OverlayRecordingState.Recording,
                workflowActive = true,
                hasSelection = true
            )
        )
        assertFalse(
            shouldShowCommandActions(
                recordingState = OverlayRecordingState.Processing,
                workflowActive = false,
                hasSelection = true
            )
        )
    }

    @Test
    fun `command buttons hide while a dictation delivery is still pending`() {
        assertFalse(
            shouldShowCommandActions(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = true,
                hasSelection = true
            )
        )
    }

    @Test
    fun `command buttons hide while a suggestion is waiting for review`() {
        assertFalse(
            shouldShowCommandActions(
                recordingState = OverlayRecordingState.Idle,
                workflowActive = false,
                hasSelection = true,
                reviewPending = true
            )
        )
    }

    // Delivery phase: dictation frees the bubble, a rewrite keeps it busy until applied.

    @Test
    fun `dictation delivery hands the bubble back`() {
        assertFalse(deliveryKeepsBubbleBusy(rewriteInstruction = false))
    }

    @Test
    fun `rewrite delivery keeps the command presentation until the text is applied`() {
        assertTrue(deliveryKeepsBubbleBusy(rewriteInstruction = true))
    }
}
