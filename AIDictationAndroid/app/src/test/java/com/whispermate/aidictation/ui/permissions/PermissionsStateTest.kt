package com.whispermate.aidictation.ui.permissions

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PermissionsStateTest {

    @Test
    fun `continue needs microphone and accessibility, not overlay`() {
        assertTrue(PermissionsState(microphone = true, accessibility = true, overlay = false).canContinue)
        assertTrue(PermissionsState(microphone = true, accessibility = true, overlay = true).canContinue)
        assertFalse(PermissionsState(microphone = false, accessibility = true, overlay = true).canContinue)
        assertFalse(PermissionsState(microphone = true, accessibility = false, overlay = true).canContinue)
        assertFalse(PermissionsState(microphone = false, accessibility = false, overlay = true).canContinue)
    }

    @Test
    fun `hint names what is still missing`() {
        assertEquals(
            PermissionsHint.NeedMicAndAccessibility,
            permissionsHint(PermissionsState(microphone = false, accessibility = false, overlay = false))
        )
        assertEquals(
            PermissionsHint.NeedMic,
            permissionsHint(PermissionsState(microphone = false, accessibility = true, overlay = true))
        )
        assertEquals(
            PermissionsHint.NeedAccessibility,
            permissionsHint(PermissionsState(microphone = true, accessibility = false, overlay = true))
        )
    }

    @Test
    fun `hint points to settings for the optional overlay, then all set`() {
        assertEquals(
            PermissionsHint.OverlayLater,
            permissionsHint(PermissionsState(microphone = true, accessibility = true, overlay = false))
        )
        assertEquals(
            PermissionsHint.AllSet,
            permissionsHint(PermissionsState(microphone = true, accessibility = true, overlay = true))
        )
    }
}
