package com.whispermate.aidictation.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardProbeWindowTest {

    private val minimum = 300

    @Test
    fun `full height window means no keyboard`() {
        assertFalse(KeyboardProbeWindow.isKeyboardHeight(tallestSeen = 2400, height = 2400, minimumKeyboardPx = minimum))
    }

    @Test
    fun `window shortened by a keyboard-sized amount means keyboard`() {
        assertTrue(KeyboardProbeWindow.isKeyboardHeight(tallestSeen = 2400, height = 1500, minimumKeyboardPx = minimum))
    }

    @Test
    fun `small shrink such as a toolbar or bar is not a keyboard`() {
        assertFalse(KeyboardProbeWindow.isKeyboardHeight(tallestSeen = 2400, height = 2300, minimumKeyboardPx = minimum))
    }

    @Test
    fun `no layout yet reports no keyboard`() {
        assertFalse(KeyboardProbeWindow.isKeyboardHeight(tallestSeen = 0, height = 0, minimumKeyboardPx = minimum))
        assertFalse(KeyboardProbeWindow.isKeyboardHeight(tallestSeen = 2400, height = 0, minimumKeyboardPx = minimum))
    }
}
