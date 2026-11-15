package com.whispermate.aidictation.service

import android.app.Activity
import android.app.Application
import android.text.InputType
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.EditText
import android.widget.TextView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Runs the dictation-target rule against the accessibility nodes real platform text
 * fields report, one test per kind of field the bubble meets in other apps.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class OverlayDictationTargetTest {

    private val activity: Activity = Robolectric.buildActivity(Activity::class.java).setup().get()

    private fun focusedField(configure: EditText.() -> Unit): AccessibilityNodeInfo {
        val field = EditText(activity).apply(configure)
        activity.setContentView(field)
        field.requestFocus()
        return field.createAccessibilityNodeInfo()
    }

    @Test
    fun `an empty chat composer showing its hint reports no caret and is still a target`() {
        val node = focusedField { hint = "Message" }

        // The platform state that used to hide the bubble: hint showing, no selection.
        assertTrue(node.isShowingHintText)
        assertEquals(-1, node.textSelectionStart)
        assertEquals(-1, node.textSelectionEnd)
        assertTrue(node.isDictationTarget())
    }

    @Test
    fun `an empty field with no hint is a target`() {
        assertTrue(focusedField { }.isDictationTarget())
    }

    @Test
    fun `a field with text is a target`() {
        assertTrue(focusedField { hint = "Message"; setText("Hello") }.isDictationTarget())
    }

    @Test
    fun `an empty multi-line field showing its hint is a target`() {
        val node = focusedField {
            hint = "Write a comment"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        }
        assertTrue(node.isDictationTarget())
    }

    @Test
    fun `an empty email or search field showing its hint is a target`() {
        assertTrue(
            focusedField {
                hint = "Email"
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
            }.isDictationTarget()
        )
        assertTrue(
            focusedField {
                hint = "Search"
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_FILTER
            }.isDictationTarget()
        )
    }

    @Test
    fun `an address bar showing its hint with no caret is not a target`() {
        val node = focusedField {
            hint = "Search or type URL"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        }
        assertFalse(node.isDictationTarget())
    }

    @Test
    fun `an address bar with text is a target`() {
        val node = focusedField {
            hint = "Search or type URL"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setText("example.com")
        }
        assertTrue(node.isDictationTarget())
    }

    @Test
    fun `password fields are never a target`() {
        assertFalse(
            focusedField {
                hint = "Password"
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            }.isDictationTarget()
        )
        assertFalse(
            focusedField {
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
                setText("1234")
            }.isDictationTarget()
        )
    }

    @Test
    fun `a disabled field is not a target`() {
        assertFalse(focusedField { hint = "Message"; isEnabled = false }.isDictationTarget())
    }

    @Test
    fun `plain text is not a target`() {
        val label = TextView(activity).apply { text = "Hello" }
        activity.setContentView(label)
        assertFalse(label.createAccessibilityNodeInfo().isDictationTarget())
    }
}
