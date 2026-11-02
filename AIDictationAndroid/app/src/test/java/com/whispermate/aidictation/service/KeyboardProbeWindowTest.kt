package com.whispermate.aidictation.service

import com.whispermate.aidictation.service.KeyboardProbeWindow.ProbeState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardProbeWindowTest {

    @Test
    fun `reports unknown until the keyboard has been seen`() {
        val state = ProbeState().observe(imeVisible = false, imeBottom = 0, windowBottom = 2400)
        assertNull(state.keyboardVisible)
        assertNull(state.keyboardTop)
    }

    @Test
    fun `a keyboard with height proves the probe and places its top edge`() {
        val state = ProbeState().observe(imeVisible = true, imeBottom = 900, windowBottom = 2400)
        assertTrue(state.keyboardVisible == true)
        assertEquals(1500, state.keyboardTop)
    }

    @Test
    fun `a hidden report is trusted once proven`() {
        val state = ProbeState()
            .observe(imeVisible = true, imeBottom = 900, windowBottom = 2400)
            .observe(imeVisible = false, imeBottom = 0, windowBottom = 2400)
        assertFalse(state.keyboardVisible != false)
        assertNull(state.keyboardTop)
    }

    @Test
    fun `visible insets without height do not count as a keyboard`() {
        val state = ProbeState().observe(imeVisible = true, imeBottom = 0, windowBottom = 2400)
        assertNull(state.keyboardVisible)
    }

    @Test
    fun `the window changing size is not a keyboard`() {
        // Rotation, folding or a full-screen app resize the probe; only insets may prove it.
        val state = ProbeState()
            .observe(imeVisible = false, imeBottom = 0, windowBottom = 2400)
            .observe(imeVisible = false, imeBottom = 0, windowBottom = 1080)
            .observe(imeVisible = false, imeBottom = 0, windowBottom = 2400)
        assertNull(state.keyboardVisible)
    }
}
