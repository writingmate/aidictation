package com.whispermate.aidictation.ui.views

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.text.method.ScrollingMovementMethod
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.animation.AccelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.Space
import android.widget.TextView
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import com.whispermate.aidictation.R
import kotlin.math.max
import kotlin.math.min

/** The actions offered in the rewrite panel, in display order. */
enum class RewriteAction(@DrawableRes val iconRes: Int, @StringRes val labelRes: Int) {
    FixGrammar(R.drawable.ic_cleanup, R.string.overlay_action_fix_grammar),
    Rephrase(R.drawable.ic_rephrase, R.string.overlay_action_rephrase),
    Shorter(R.drawable.ic_shorter, R.string.overlay_action_shorter),
    Longer(R.drawable.ic_longer, R.string.overlay_action_longer)
}

/**
 * The panel opened from the wand button beside the dictation bubble: the working text on
 * top, one row below with the action icons on the left and close / apply on the right.
 *
 * Presentation invariants:
 * - Opens by blooming out of the wand (scale from the wand's centre with a small
 *   overshoot), the text rises in, then the icons pop in one after another.
 * - While an action runs, its icon is filled and pulses, a thin progress bar sweeps
 *   along the top edge, the text dims, and the other actions and apply are disabled.
 * - A result replaces the working text with a short cross-fade and the icon nods.
 * - Close withers back into the wand; apply settles down towards the field.
 */
class OverlayRewritePanelView(context: Context) : LinearLayout(context) {

    var onAction: ((RewriteAction) -> Unit)? = null
    var onClose: (() -> Unit)? = null
    var onApply: (() -> Unit)? = null

    private val surfaceColor: Int
    private val onSurfaceColor: Int
    private var accent: Int = 0xFFFF6300.toInt()
    private var onAccent: Int = Color.WHITE

    private val backgroundShape = GradientDrawable().apply { shape = GradientDrawable.RECTANGLE }
    private val progressBar: IndeterminateBar
    private val textView: TextView
    private val actionButtons: Map<RewriteAction, ImageView>
    private val closeButton: ImageView
    private val applyButton: ImageView

    private var workingAction: RewriteAction? = null
    private var throbAnimator: ValueAnimator? = null
    private var cornerAnimator: ValueAnimator? = null

    val isWorking: Boolean
        get() = workingAction != null

    init {
        surfaceColor = themeColor(
            android.R.attr.colorBackgroundFloating,
            themeColor(android.R.attr.colorBackground, 0xFF1A1A1A.toInt())
        )
        onSurfaceColor = themeColor(android.R.attr.textColorPrimary, Color.WHITE)

        orientation = VERTICAL
        clipChildren = false
        clipToPadding = false
        elevation = dp(8f)
        val padding = dp(PADDING_DP).toInt()
        setPadding(padding, 0, padding, padding)
        backgroundShape.cornerRadius = dp(CORNER_DP)
        backgroundShape.setColor(surfaceColor)
        background = backgroundShape
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES

        progressBar = IndeterminateBar(context)
        addView(progressBar, LayoutParams(LayoutParams.MATCH_PARENT, dp(3f).toInt()).apply {
            leftMargin = dp(6f).toInt()
            rightMargin = dp(6f).toInt()
        })

        textView = TextView(context).apply {
            setTextColor(onSurfaceColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setLineSpacing(0f, 1.15f)
            maxLines = MAX_TEXT_LINES
            movementMethod = ScrollingMovementMethod.getInstance()
            isVerticalScrollBarEnabled = true
            val inset = dp(6f).toInt()
            setPadding(inset, inset, inset, inset)
        }
        addView(textView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(6f).toInt()
        })

        val row = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            clipChildren = false
            clipToPadding = false
        }
        val buttonSize = dp(BUTTON_DP).toInt()
        val gap = dp(BUTTON_GAP_DP).toInt()
        actionButtons = RewriteAction.entries.associateWith { action ->
            circleButton(action.iconRes, context.getString(action.labelRes)) {
                onAction?.invoke(action)
            }.also { button ->
                row.addView(button, LayoutParams(buttonSize, buttonSize).apply { rightMargin = gap })
            }
        }
        row.addView(Space(context), LayoutParams(0, 1, 1f))
        closeButton = circleButton(R.drawable.ic_close, context.getString(R.string.overlay_panel_close)) {
            onClose?.invoke()
        }
        row.addView(closeButton, LayoutParams(buttonSize, buttonSize).apply { rightMargin = gap })
        applyButton = circleButton(R.drawable.ic_check, context.getString(R.string.overlay_panel_apply)) {
            onApply?.invoke()
        }
        row.addView(applyButton, LayoutParams(buttonSize, buttonSize))
        addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(10f).toInt()
        })

        applyStyles()
    }

    // MARK: - Public API

    fun setAccent(accent: Int, onAccent: Int) {
        this.accent = accent
        this.onAccent = onAccent
        applyStyles()
    }

    fun setText(text: CharSequence, animate: Boolean) {
        textView.text = text
        textView.scrollTo(0, 0)
        if (!animate) return
        textView.animate().cancel()
        textView.alpha = 0f
        textView.translationY = dp(6f)
        textView.animate()
            .alpha(if (isWorking) WORKING_TEXT_ALPHA else 1f)
            .translationY(0f)
            .setDuration(SWAP_MS)
            .setInterpolator(DecelerateInterpolator())
            .start()
    }

    /** Marks [action] as running, or clears the running state when null. */
    fun setWorking(action: RewriteAction?) {
        workingAction = action
        applyStyles()
        progressBar.setRunning(action != null)
        textView.animate().cancel()
        textView.animate().alpha(if (action != null) WORKING_TEXT_ALPHA else 1f).setDuration(200).start()
    }

    /** Small acknowledgement on the icon whose result just landed. */
    fun nod(action: RewriteAction) {
        val button = actionButtons[action] ?: return
        button.animate().cancel()
        button.scaleX = 1f
        button.scaleY = 1f
        button.animate()
            .scaleX(NOD_SCALE)
            .scaleY(NOD_SCALE)
            .setDuration(NOD_MS / 2)
            .setInterpolator(DecelerateInterpolator())
            .withEndAction {
                button.animate().scaleX(1f).scaleY(1f).setDuration(NOD_MS / 2).start()
            }
            .start()
    }

    /**
     * Bloom: grow out of ([pivotX], [pivotY]) in this view's coordinates, then stagger
     * the contents in. Safe to call right after the view is attached.
     */
    fun playOpen(pivotX: Float, pivotY: Float) {
        cancelAnimations()
        this.pivotX = pivotX
        this.pivotY = pivotY
        scaleX = OPEN_START_SCALE
        scaleY = OPEN_START_SCALE
        alpha = 0f
        translationY = 0f
        textView.alpha = 0f
        textView.translationY = dp(10f)
        val staggered = actionButtons.values + closeButton + applyButton
        staggered.forEach { button ->
            button.alpha = 0f
            button.scaleX = POP_START_SCALE
            button.scaleY = POP_START_SCALE
        }

        animate()
            .scaleX(1f)
            .scaleY(1f)
            .setDuration(OPEN_MS)
            .setInterpolator(OvershootInterpolator(OPEN_OVERSHOOT))
            .start()
        ValueAnimator.ofFloat(0f, 1f).apply {
            duration = OPEN_FADE_MS
            addUpdateListener { alpha = it.animatedValue as Float }
            start()
        }
        cornerAnimator?.cancel()
        cornerAnimator = ValueAnimator.ofFloat(dp(OPEN_START_CORNER_DP), dp(CORNER_DP)).apply {
            duration = OPEN_MS
            interpolator = DecelerateInterpolator()
            addUpdateListener { backgroundShape.cornerRadius = it.animatedValue as Float }
            start()
        }

        textView.animate()
            .alpha(1f)
            .translationY(0f)
            .setStartDelay(TEXT_DELAY_MS)
            .setDuration(TEXT_RISE_MS)
            .setInterpolator(DecelerateInterpolator())
            .start()
        staggered.forEachIndexed { index, button ->
            button.animate()
                .alpha(1f)
                .scaleX(1f)
                .scaleY(1f)
                .setStartDelay(ICON_DELAY_MS + ICON_STAGGER_MS * index)
                .setDuration(POP_MS)
                .setInterpolator(OvershootInterpolator(POP_OVERSHOOT))
                .start()
        }
    }

    /** Wither: shrink back into ([pivotX], [pivotY]) and fade, then [onEnd]. */
    fun playClose(pivotX: Float, pivotY: Float, onEnd: () -> Unit) {
        cancelAnimations()
        this.pivotX = pivotX
        this.pivotY = pivotY
        animate()
            .scaleX(OPEN_START_SCALE)
            .scaleY(OPEN_START_SCALE)
            .alpha(0f)
            .setDuration(CLOSE_MS)
            .setInterpolator(AccelerateInterpolator())
            .withEndAction(onEnd)
            .start()
    }

    /** Settle: drop towards the field and fade, then [onEnd]. */
    fun playApply(onEnd: () -> Unit) {
        cancelAnimations()
        pivotX = width / 2f
        pivotY = height / 2f
        animate()
            .translationY(dp(APPLY_DROP_DP))
            .scaleX(APPLY_END_SCALE)
            .scaleY(APPLY_END_SCALE)
            .alpha(0f)
            .setDuration(APPLY_MS)
            .setInterpolator(AccelerateInterpolator())
            .withEndAction(onEnd)
            .start()
    }

    fun cancelAnimations() {
        animate().cancel()
        cornerAnimator?.cancel()
        cornerAnimator = null
        textView.animate().cancel()
        (actionButtons.values + closeButton + applyButton).forEach { it.animate().cancel() }
    }

    // MARK: - Private

    private fun applyStyles() {
        backgroundShape.setColor(surfaceColor)
        progressBar.setColor(accent)
        val working = workingAction
        actionButtons.forEach { (action, button) ->
            val active = action == working
            styleCircle(button, filled = active)
            button.isEnabled = working == null || active
            button.alpha = if (working != null && !active) DISABLED_ALPHA else 1f
        }
        styleCircle(closeButton, filled = false)
        styleCircle(applyButton, filled = true)
        applyButton.isEnabled = working == null
        applyButton.alpha = if (working == null) 1f else APPLY_DISABLED_ALPHA
        updateThrob()
    }

    private fun updateThrob() {
        throbAnimator?.cancel()
        throbAnimator = null
        val button = workingAction?.let { actionButtons[it] } ?: return
        throbAnimator = ValueAnimator.ofFloat(1f, THROB_SCALE).apply {
            duration = THROB_MS
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            addUpdateListener {
                val scale = it.animatedValue as Float
                button.scaleX = scale
                button.scaleY = scale
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    button.scaleX = 1f
                    button.scaleY = 1f
                }
            })
            start()
        }
    }

    private fun circleButton(@DrawableRes iconRes: Int, label: String, onClick: () -> Unit): ImageView {
        return ImageView(context).apply {
            setImageResource(iconRes)
            scaleType = ImageView.ScaleType.CENTER
            contentDescription = label
            tooltipText = label
            isClickable = true
            isFocusable = true
            isHapticFeedbackEnabled = true
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                onClick()
            }
        }
    }

    /** Solid-border circle: surface fill with an accent stroke and icon, or filled accent. */
    private fun styleCircle(button: ImageView, filled: Boolean) {
        val fill = if (filled) accent else surfaceColor
        val foreground = if (filled) onAccent else accent
        button.imageTintList = ColorStateList.valueOf(foreground)
        val content = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(fill)
            setStroke(dp(STROKE_DP).toInt().coerceAtLeast(1), accent)
        }
        val mask = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.WHITE)
        }
        button.background = RippleDrawable(ColorStateList.valueOf(withAlpha(foreground, RIPPLE_ALPHA)), content, mask)
    }

    private fun themeColor(attr: Int, fallback: Int): Int {
        val array = context.theme.obtainStyledAttributes(intArrayOf(attr))
        return try {
            array.getColor(0, fallback)
        } finally {
            array.recycle()
        }
    }

    private fun dp(value: Float): Float = value * resources.displayMetrics.density

    private fun withAlpha(color: Int, fraction: Float): Int =
        (color and 0x00FFFFFF) or ((fraction.coerceIn(0f, 1f) * 255f).toInt() shl 24)

    /** Thin indeterminate bar: a segment sweeping left to right along a faint track. */
    private class IndeterminateBar(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val track = RectF()
        private val segment = RectF()
        private var color = 0xFFFF6300.toInt()
        private var phase = 0f
        private var animator: ValueAnimator? = null
        private var running = false

        init { visibility = INVISIBLE }

        fun setColor(color: Int) {
            this.color = color
            invalidate()
        }

        fun setRunning(running: Boolean) {
            this.running = running
            visibility = if (running) VISIBLE else INVISIBLE
            animator?.cancel()
            animator = null
            if (!running) return
            animator = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = SWEEP_MS
                repeatCount = ValueAnimator.INFINITE
                addUpdateListener {
                    phase = it.animatedValue as Float
                    invalidate()
                }
                start()
            }
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            if (!running) return
            val h = height.toFloat()
            track.set(0f, 0f, width.toFloat(), h)
            paint.color = (color and 0x00FFFFFF) or (0x40 shl 24)
            canvas.drawRoundRect(track, h / 2f, h / 2f, paint)

            val trackWidth = track.width()
            val segmentWidth = trackWidth * SEGMENT_FRACTION
            val eased = phase * phase * (3f - 2f * phase)
            val left = -segmentWidth + eased * (trackWidth + segmentWidth)
            val visibleLeft = max(left, 0f)
            val visibleRight = min(left + segmentWidth, trackWidth)
            if (visibleRight <= visibleLeft) return
            segment.set(visibleLeft, 0f, visibleRight, h)
            paint.color = color
            canvas.drawRoundRect(segment, h / 2f, h / 2f, paint)
        }

        override fun onDetachedFromWindow() {
            super.onDetachedFromWindow()
            animator?.cancel()
            animator = null
        }

        private companion object {
            const val SWEEP_MS = 1300L
            const val SEGMENT_FRACTION = 0.34f
        }
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        cancelAnimations()
        throbAnimator?.cancel()
        throbAnimator = null
    }

    private companion object {
        const val PADDING_DP = 12f
        const val CORNER_DP = 18f
        const val BUTTON_DP = 44f
        const val BUTTON_GAP_DP = 10f
        const val STROKE_DP = 1.5f
        const val MAX_TEXT_LINES = 6
        const val RIPPLE_ALPHA = 0.24f
        const val DISABLED_ALPHA = 0.5f
        const val APPLY_DISABLED_ALPHA = 0.35f
        const val WORKING_TEXT_ALPHA = 0.4f

        const val OPEN_MS = 460L
        const val OPEN_FADE_MS = 200L
        const val OPEN_START_SCALE = 0.12f
        const val OPEN_START_CORNER_DP = 40f
        const val OPEN_OVERSHOOT = 1.1f
        const val TEXT_DELAY_MS = 120L
        const val TEXT_RISE_MS = 400L
        const val ICON_DELAY_MS = 180L
        const val ICON_STAGGER_MS = 50L
        const val POP_MS = 380L
        const val POP_START_SCALE = 0.4f
        const val POP_OVERSHOOT = 1.4f
        const val CLOSE_MS = 240L
        const val APPLY_MS = 260L
        const val APPLY_DROP_DP = 46f
        const val APPLY_END_SCALE = 0.96f
        const val SWAP_MS = 400L
        const val NOD_MS = 400L
        const val NOD_SCALE = 1.12f
        const val THROB_MS = 600L
        const val THROB_SCALE = 1.06f
    }
}
