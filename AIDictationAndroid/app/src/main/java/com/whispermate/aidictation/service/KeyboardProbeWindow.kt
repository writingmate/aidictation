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
import kotlin.math.max

/**
 * Reports whether the soft keyboard is on screen, and where its top edge is, by watching
 * a hidden application overlay window.
 *
 * The accessibility window list is the only keyboard signal available to an
 * accessibility service on its own, and it lags, flaps during keyboard animations and
 * misses keyboards that expose no accessibility tree. An application overlay window
 * (which needs the "display over other apps" permission) is laid out by the window
 * manager like any other window: it is resized when the keyboard appears and, on
 * Android 11 and later, receives the keyboard insets directly. That gives an exact,
 * event-driven signal.
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
    private var tallestSeen = 0
    private var layoutSaysVisible = false
    private var insetsSayVisible = false
    private var layoutKeyboardTop: Int? = null
    private var insetsKeyboardTop: Int? = null
    private var reportedVisible: Boolean? = null
    private var proven = false

    /** True while the overlay window is attached. */
    val isAttached: Boolean
        get() = probe != null

    /**
     * Whether the keyboard is showing, or `null` while the probe is not attached or has
     * not yet seen the keyboard on this device.
     */
    val keyboardVisible: Boolean?
        get() = if (proven) reportedVisible else null

    /** Screen y of the keyboard's top edge while it is showing, else `null`. */
    val keyboardTop: Int?
        get() = if (keyboardVisible == true) insetsKeyboardTop ?: layoutKeyboardTop else null

    /** Attaches the probe if the permission is granted. Returns whether it is attached. */
    fun attach(): Boolean {
        if (probe != null) return true
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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Let the window manager shrink the frame above the keyboard.
                setFitInsetsTypes(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
            } else {
                @Suppress("DEPRECATION")
                softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
            }
        }

        view.viewTreeObserver.addOnGlobalLayoutListener { onLayout(view) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            view.setOnApplyWindowInsetsListener { v, insets ->
                onInsets(v, insets)
                insets
            }
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
        tallestSeen = 0
        layoutSaysVisible = false
        insetsSayVisible = false
        layoutKeyboardTop = null
        insetsKeyboardTop = null
        reportedVisible = null
        proven = false
    }

    private fun onLayout(view: View) {
        val height = view.height
        if (height <= 0) return
        tallestSeen = max(tallestSeen, height)
        val visible = isKeyboardHeight(tallestSeen, height, minimumKeyboardPx())
        layoutSaysVisible = visible
        layoutKeyboardTop = if (visible) screenY(view) + height else null
        publish()
    }

    private fun onInsets(view: View, insets: WindowInsets) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val bottom = insets.getInsets(WindowInsets.Type.ime()).bottom
        val visible = insets.isVisible(WindowInsets.Type.ime()) && bottom > 0
        insetsSayVisible = visible
        insetsKeyboardTop = if (visible) screenY(view) + view.height - bottom else null
        publish()
    }

    private fun publish() {
        val visible = layoutSaysVisible || insetsSayVisible
        val previous = reportedVisible
        reportedVisible = visible
        // The first keyboard sighting proves the technique works on this device; from
        // then on a hidden report is trusted too.
        if (visible) proven = true
        if (proven && previous != visible) onChanged()
    }

    private fun screenY(view: View): Int {
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        return location[1]
    }

    private fun minimumKeyboardPx(): Int =
        (MINIMUM_KEYBOARD_DP * context.resources.displayMetrics.density).toInt()

    companion object {
        private const val TAG = "KeyboardProbeWindow"

        /** Nothing shorter than this counts as a keyboard; system bars and toolbars are smaller. */
        const val MINIMUM_KEYBOARD_DP = 120

        fun canDrawOverlays(context: Context): Boolean = Settings.canDrawOverlays(context)

        /**
         * A window that is at least [minimumKeyboardPx] shorter than the tallest it has
         * been is sitting above a keyboard.
         */
        internal fun isKeyboardHeight(tallestSeen: Int, height: Int, minimumKeyboardPx: Int): Boolean =
            tallestSeen > 0 && height > 0 && tallestSeen - height >= minimumKeyboardPx
    }
}
