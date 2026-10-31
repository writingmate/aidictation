package com.whispermate.aidictation.service

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager

/**
 * Reports whether the soft keyboard is on screen, and where its top edge is, by watching
 * the keyboard insets delivered to a hidden application overlay window.
 *
 * The accessibility window list is the only keyboard signal available to an
 * accessibility service on its own, and it lags, flaps during keyboard animations and
 * misses keyboards that expose no accessibility tree. An application overlay window
 * (which needs the "display over other apps" permission) receives the keyboard insets
 * directly on Android 11 and later, which gives an exact, event-driven signal.
 *
 * Only the insets are trusted. The window's own height is not a keyboard signal: an
 * overlay sits above the keyboard, so the window manager never shrinks it for one, while
 * it does change size on rotation, folding and full-screen apps. Reading those changes as
 * a keyboard inverted the bubble on such devices: it stayed away while typing and showed
 * up without a keyboard.
 *
 * The probe is one pixel wide, full height, invisible and untouchable. Until it has
 * observed the keyboard at least once its reports are unknown (`null`) so a device
 * where the technique does not apply falls back to the accessibility signal.
 */
class KeyboardProbeWindow(
    private val context: Context,
    private val windowManager: WindowManager,
    private val onChanged: () -> Unit
) {

    private var probe: View? = null
    private var state = ProbeState()

    /** True while the overlay window is attached. */
    val isAttached: Boolean
        get() = probe != null

    /**
     * Whether the keyboard is showing, or `null` while the probe is not attached or has
     * not yet seen the keyboard on this device.
     */
    val keyboardVisible: Boolean?
        get() = state.keyboardVisible

    /** Screen y of the keyboard's top edge while it is showing, else `null`. */
    val keyboardTop: Int?
        get() = state.keyboardTop

    /** Attaches the probe if the permission is granted. Returns whether it is attached. */
    fun attach(): Boolean {
        if (probe != null) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        if (!canDrawOverlays(context)) return false

        val view = View(context)
        val params = WindowManager.LayoutParams(
            1,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            title = "AIDictation keyboard probe"
            windowAnimations = 0
            // Keep the frame stable: the keyboard is read from the insets, never from the size.
            setFitInsetsTypes(0)
        }

        view.setOnApplyWindowInsetsListener { v, insets ->
            onInsets(v, insets)
            insets
        }

        return try {
            windowManager.addView(view, params)
            probe = view
            Log.i(TAG, "Keyboard probe attached")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Failed to attach keyboard probe", e)
            false
        }
    }

    fun detach() {
        val view = probe ?: return
        probe = null
        try {
            windowManager.removeViewImmediate(view)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to detach keyboard probe", e)
        }
        state = ProbeState()
    }

    private fun onInsets(view: View, insets: WindowInsets) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val bottom = insets.getInsets(WindowInsets.Type.ime()).bottom
        val imeVisible = insets.isVisible(WindowInsets.Type.ime())
        val previous = state
        state = previous.observe(imeVisible, bottom, screenY(view) + view.height)
        if (state.keyboardVisible != previous.keyboardVisible) onChanged()
    }

    private fun screenY(view: View): Int {
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        return location[1]
    }

    /**
     * The probe's report, derived only from keyboard insets. Pure so the proving rule
     * can be tested without a window.
     */
    internal data class ProbeState(
        private val proven: Boolean = false,
        private val visible: Boolean = false,
        val keyboardTop: Int? = null
    ) {
        val keyboardVisible: Boolean?
            get() = if (proven) visible else null

        /**
         * Folds in one insets report. [windowBottom] is the screen y of the probe's
         * bottom edge; the keyboard's top edge is [imeBottom] above it.
         */
        fun observe(imeVisible: Boolean, imeBottom: Int, windowBottom: Int): ProbeState {
            val showing = imeVisible && imeBottom > 0
            return ProbeState(
                // The first keyboard sighting proves the technique works on this device;
                // from then on a hidden report is trusted too.
                proven = proven || showing,
                visible = showing,
                keyboardTop = if (showing) windowBottom - imeBottom else null
            )
        }
    }

    companion object {
        private const val TAG = "KeyboardProbeWindow"

        fun canDrawOverlays(context: Context): Boolean = Settings.canDrawOverlays(context)
    }
}
