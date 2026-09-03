package com.whispermate.aidictation.ui.views

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Build
import android.util.AttributeSet
import android.view.View
import android.view.ViewOutlineProvider
import android.view.animation.OvershootInterpolator
import com.whispermate.aidictation.R
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt
import kotlin.math.sin

class OverlayMicButtonView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    enum class State { Idle, Recording, Processing }

    /** Themed white: the surface the bubble and its pill are filled with. */
    private var fillColor: Int = Color.WHITE
    /** Themed black: bars, icons and the spinner. */
    private var glyphColor: Int = 0xFF1B1D22.toInt()
    /** Pill and cancel circle: the glyph colour laid lightly over the fill, kept opaque. */
    private var secondaryFillColor: Int = 0xFFE8E9EC.toInt()
    private var state: State = State.Idle
    private var audioLevel: Float = 0f
    private var frequencyBands: FloatArray? = null
    private var processingPhaseDegrees: Float = 0f

    private val barHeights = FloatArray(TOTAL_BARS) { FROZEN_HEIGHTS[it] }
    private val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val spinnerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }

    private val tempRect = RectF()
    private val cancelRect = RectF()
    private val acceptRect = RectF()
    private val pillRect = RectF()
    private val barRect = RectF()
    private val outlinePath = Path()
    private val processingHeights = FloatArray(TOTAL_BARS)

    private val barAnimators = arrayOfNulls<ValueAnimator>(TOTAL_BARS)
    private var processingAnimator: ValueAnimator? = null

    private val springInterpolator = OvershootInterpolator(1.2f)

    companion object {
        /** Height of the button in every state and width of the idle circle, shadow margin excluded. */
        const val BUTTON_SIZE_DP = 55
        /** Width of the recording and processing pill, shadow margin excluded. */
        const val PILL_WIDTH_DP = 250
        /**
         * Transparent margin kept around the drawn surface on every side. The overlay window is
         * exactly this view's size, so the elevation shadow needs room inside it or it is clipped.
         */
        const val SHADOW_PADDING_DP = 6
        /** Size of the whole view (and its overlay window) while idle. */
        const val IDLE_SIZE_DP = BUTTON_SIZE_DP + 2 * SHADOW_PADDING_DP
        /** Standard resting elevation of a floating button. */
        const val ELEVATION_DP = 6f
        /** Every overlay button is drawn slightly translucent so the field underneath shows through. */
        const val SURFACE_ALPHA = 0.9f
        /** The waveform logo sits a little smaller inside the idle circle. */
        private const val LOGO_SCALE = 0.9f
        private const val TOTAL_BARS = 5
        private const val MIN_ACTIVE_BARS = 3
        /** How much of the glyph colour tints the pill and cancel circle over the fill. */
        private const val SECONDARY_SURFACE_ALPHA = 0.1f
        private const val WAVEFORM_LEVEL_GAIN = 1.35f
        private const val WAVEFORM_LEVEL_MIX = 0.08f
        private const val WAVEFORM_CONTRAST = 0.8f
        private const val WAVEFORM_FLOOR_THRESHOLD = 0.045f
        private const val WAVEFORM_ACTIVE_FLOOR = 0.16f
        private val FROZEN_HEIGHTS = floatArrayOf(0.56f, 1f, 0.56f, 1f, 0.56f)
        private val CIRCLE_ENVELOPE_HEIGHTS = floatArrayOf(0.72f, 0.94f, 1f, 0.94f, 0.72f)

        /** Width in dp of the whole view, shadow margin included, for [state]. */
        fun widthDp(state: State): Int = when (state) {
            State.Recording, State.Processing -> PILL_WIDTH_DP + 2 * SHADOW_PADDING_DP
            State.Idle -> IDLE_SIZE_DP
        }

        /** Height in dp of the whole view, shadow margin included. */
        fun heightDp(): Int = IDLE_SIZE_DP
    }

    init {
        context.theme.obtainStyledAttributes(attrs, R.styleable.CircularMicButtonView, 0, 0).apply {
            try {
                fillColor = getColor(R.styleable.CircularMicButtonView_idleColor, fillColor)
                glyphColor = getColor(R.styleable.CircularMicButtonView_activeColor, glyphColor)
                secondaryFillColor = blend(glyphColor, fillColor, SECONDARY_SURFACE_ALPHA)
            } finally {
                recycle()
            }
        }
        isClickable = true
        isFocusable = true
        elevation = ELEVATION_DP * resources.displayMetrics.density
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                layoutSurfaces()
                buildOutline(outline)
                outline.alpha = SURFACE_ALPHA
            }
        }
    }

    /**
     * The shadow follows the drawn surfaces: the idle circle alone, or the cancel circle
     * (while recording), the pill and the accept circle each with their own shadow. Before
     * Android 10 an outline has to be convex, so there one rounded shape spans all three.
     */
    private fun buildOutline(outline: Outline) {
        val radius = acceptRect.height() / 2f
        if (state == State.Idle) {
            outline.setOval(
                acceptRect.left.toInt(),
                acceptRect.top.toInt(),
                acceptRect.right.toInt(),
                acceptRect.bottom.toInt()
            )
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            outlinePath.rewind()
            if (state == State.Recording) outlinePath.addOval(cancelRect, Path.Direction.CW)
            if (pillRect.width() > 0f) outlinePath.addRoundRect(pillRect, radius, radius, Path.Direction.CW)
            outlinePath.addOval(acceptRect, Path.Direction.CW)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                outline.setPath(outlinePath)
            } else {
                // Misnamed until API 30: non-convex paths are accepted from API 29.
                @Suppress("DEPRECATION")
                outline.setConvexPath(outlinePath)
            }
            return
        }
        val left = if (state == State.Recording) cancelRect.left else pillRect.left
        outline.setRoundRect(
            left.toInt(),
            acceptRect.top.toInt(),
            acceptRect.right.toInt(),
            acceptRect.bottom.toInt(),
            radius
        )
    }

    fun preferredWidthDp(): Int = widthDp(state)

    fun preferredHeightDp(): Int = heightDp()

    fun isCancelHit(x: Float, y: Float): Boolean {
        return state == State.Recording && cancelRect.contains(x, y)
    }

    fun isAcceptHit(x: Float, y: Float): Boolean {
        return state == State.Recording && acceptRect.contains(x, y)
    }

    fun setOnClickCallback(callback: () -> Unit) {
        setOnClickListener {
            if (state != State.Processing) callback()
        }
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    fun setState(newState: State) {
        if (state == newState) {
            if (state == State.Processing && processingAnimator == null) {
                startProcessingAnimation()
            }
            return
        }
        state = newState
        if (state == State.Processing) {
            startProcessingAnimation()
        } else {
            stopProcessingAnimation()
        }
        updateBarHeights(animate = false)
        invalidateOutline()
        invalidate()
    }

    fun setAudioLevel(level: Float) {
        audioLevel = level.coerceIn(0f, 1f)
        if (state == State.Recording) updateBarHeights()
    }

    fun setFrequencyBands(bands: FloatArray?) {
        frequencyBands = bands
        if (state == State.Recording) updateBarHeights()
    }

    /**
     * [fill] is the surface the button is drawn in (themed white), [glyph] the colour of
     * the bars and icons (themed black). Same palette in every state.
     */
    fun setPalette(fill: Int, glyph: Int) {
        if (fillColor == fill && glyphColor == glyph) return
        fillColor = fill
        glyphColor = glyph
        secondaryFillColor = blend(glyph, fill, SECONDARY_SURFACE_ALPHA)
        invalidate()
    }

    private fun updateBarHeights(animate: Boolean = state == State.Recording) {
        val activeBarCount = when (state) {
            State.Idle -> TOTAL_BARS
            State.Recording -> {
                val range = TOTAL_BARS - MIN_ACTIVE_BARS
                val boostedLevel = boostWaveformLevel(audioLevel)
                (MIN_ACTIVE_BARS + (range * boostedLevel * 2.5f).toInt()).coerceIn(MIN_ACTIVE_BARS, TOTAL_BARS)
            }
            State.Processing -> TOTAL_BARS
        }

        for (i in 0 until TOTAL_BARS) {
            val targetHeight = when (state) {
                State.Idle -> FROZEN_HEIGHTS[i]
                State.Recording -> {
                    val barsFromEdge = (TOTAL_BARS - activeBarCount) / 2
                    val minDistance = minOf(i, TOTAL_BARS - 1 - i)
                    if (minDistance < barsFromEdge) {
                        0f
                    } else {
                        boostWaveformLevel(recordingBandValue(i), audioLevel) * CIRCLE_ENVELOPE_HEIGHTS[i]
                    }
                }
                State.Processing -> CIRCLE_ENVELOPE_HEIGHTS[i]
            }
            if (state != State.Processing) {
                if (animate) {
                    animateBarTo(i, targetHeight)
                } else {
                    barAnimators[i]?.cancel()
                    barHeights[i] = targetHeight
                }
            }
        }
    }

    private fun recordingBandValue(index: Int): Float {
        val bands = frequencyBands
        if (bands == null || bands.isEmpty()) return audioLevel

        val sourcePosition = if (TOTAL_BARS == 1) 0f else index * (bands.lastIndex.toFloat() / (TOTAL_BARS - 1))
        val lowerIndex = sourcePosition.toInt().coerceIn(0, bands.lastIndex)
        val upperIndex = (lowerIndex + 1).coerceAtMost(bands.lastIndex)
        val fraction = sourcePosition - lowerIndex
        val lower = bands[lowerIndex].coerceIn(0f, 1f)
        val upper = bands[upperIndex].coerceIn(0f, 1f)
        val interpolated = lower + ((upper - lower) * fraction)
        val average = bands.map { it.coerceIn(0f, 1f) }.average().toFloat()
        val contrasted = interpolated + ((interpolated - average) * WAVEFORM_CONTRAST)
        val floor = if (audioLevel > WAVEFORM_FLOOR_THRESHOLD) audioLevel * 0.18f else 0f
        return max(contrasted, floor).coerceIn(0f, 1f)
    }

    private fun boostWaveformLevel(level: Float, overallLevel: Float = level): Float {
        val mixed = (level * WAVEFORM_LEVEL_GAIN + overallLevel * WAVEFORM_LEVEL_MIX).coerceIn(0f, 1f)
        val eased = sqrt(mixed)
        val floor = if (overallLevel > WAVEFORM_FLOOR_THRESHOLD) WAVEFORM_ACTIVE_FLOOR else 0f
        return max(eased, floor).coerceIn(0f, 1f)
    }

    private fun animateBarTo(index: Int, targetHeight: Float) {
        barAnimators[index]?.cancel()
        barAnimators[index] = ValueAnimator.ofFloat(barHeights[index], targetHeight).apply {
            duration = 150
            interpolator = springInterpolator
            addUpdateListener {
                barHeights[index] = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    private fun startProcessingAnimation() {
        processingAnimator?.cancel()
        processingAnimator = ValueAnimator.ofFloat(0f, 360f).apply {
            duration = 900
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.RESTART
            addUpdateListener {
                processingPhaseDegrees = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    private fun stopProcessingAnimation() {
        processingAnimator?.cancel()
        processingAnimator = null
        processingPhaseDegrees = 0f
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val desiredWidth = (preferredWidthDp() * resources.displayMetrics.density).toInt()
        val desiredHeight = (preferredHeightDp() * resources.displayMetrics.density).toInt()
        setMeasuredDimension(resolveSize(desiredWidth, widthMeasureSpec), resolveSize(desiredHeight, heightMeasureSpec))
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        drawOverlay(canvas)
    }

    /**
     * Places the cancel circle, pill and accept circle inside the view, leaving the shadow
     * margin free on every side.
     */
    private fun layoutSurfaces() {
        val pad = SHADOW_PADDING_DP * resources.displayMetrics.density
        val innerTop = pad
        val innerLeft = pad
        val innerRight = width - pad
        val h = height - 2f * pad
        val surfaceSize = h * 0.86f
        val surfaceInset = (h - surfaceSize) / 2f
        val gap = h * 0.13f

        acceptRect.set(
            innerRight - surfaceInset - surfaceSize,
            innerTop + surfaceInset,
            innerRight - surfaceInset,
            innerTop + surfaceInset + surfaceSize
        )
        cancelRect.set(
            innerLeft + surfaceInset,
            innerTop + surfaceInset,
            innerLeft + surfaceInset + surfaceSize,
            innerTop + surfaceInset + surfaceSize
        )
        pillRect.set(cancelRect.right + gap, acceptRect.top, acceptRect.left - gap, acceptRect.bottom)
    }

    private fun drawOverlay(canvas: Canvas) {
        layoutSurfaces()
        val surfaceSize = acceptRect.height()

        val expanded = if (state == State.Idle) 0f else 1f

        if (pillRect.width() > 0f) {
            pillPaint.color = withAlpha(secondaryFillColor, expanded * SURFACE_ALPHA)
            canvas.drawRoundRect(pillRect, surfaceSize / 2f, surfaceSize / 2f, pillPaint)
        }

        backgroundPaint.color = withAlpha(secondaryFillColor, expanded * SURFACE_ALPHA)
        if (expanded > 0f && state == State.Recording) {
            canvas.drawCircle(cancelRect.centerX(), cancelRect.centerY(), surfaceSize / 2f, backgroundPaint)
        }

        backgroundPaint.color = withAlpha(fillColor, SURFACE_ALPHA)
        canvas.drawCircle(acceptRect.centerX(), acceptRect.centerY(), surfaceSize / 2f, backgroundPaint)

        if (state == State.Processing) {
            drawProcessingBars(canvas, pillRect)
            drawSpinner(canvas, acceptRect)
        } else {
            drawBars(canvas, pillRect, barHeights, expanded, circleSpacing = false)
            if (state == State.Recording) {
                drawX(canvas, cancelRect, expanded)
            }
            drawCheck(canvas, acceptRect, expanded)
            if (expanded < 1f) {
                drawBars(canvas, acceptRect, FROZEN_HEIGHTS, 1f - expanded, circleSpacing = true)
            }
        }
    }


    private fun drawProcessingBars(canvas: Canvas, bounds: RectF) {
        val phase = (processingPhaseDegrees / 360f) * (2f * PI.toFloat())
        for (i in 0 until TOTAL_BARS) {
            val normalizedIndex = if (TOTAL_BARS == 1) 0f else i.toFloat() / (TOTAL_BARS - 1)
            val wavePosition = normalizedIndex * 2f * PI.toFloat() - phase
            val sineValue = (sin(wavePosition) + 1f) / 2f
            processingHeights[i] = sineValue * CIRCLE_ENVELOPE_HEIGHTS[i]
        }
        drawBars(canvas, bounds, processingHeights, 1f, circleSpacing = false)
    }

    private fun drawBars(
        canvas: Canvas,
        bounds: RectF,
        heights: FloatArray,
        alpha: Float,
        circleSpacing: Boolean
    ) {
        if (alpha <= 0f) return
        // The idle logo (circle spacing) is scaled down a little; the live waveform in the pill is not.
        val scale = if (circleSpacing) LOGO_SCALE else 1f
        val barWidth = bounds.height() * 0.092f * scale
        val barSpacing = bounds.height() * (if (circleSpacing) 0.044f else 0.14f) * scale
        val maxBarHeight = bounds.height() * (if (circleSpacing) 0.496f else 0.48f) * scale
        val dotSize = barWidth
        val totalBarsWidth = (barWidth * TOTAL_BARS) + (barSpacing * (TOTAL_BARS - 1))
        val startX = bounds.centerX() - (totalBarsWidth / 2f) + (barWidth / 2f)
        barPaint.color = withAlpha(glyphColor, alpha)

        for (i in 0 until TOTAL_BARS) {
            val heightFraction = heights[i].coerceIn(0f, 1f)
            val barHeight = dotSize + (maxBarHeight - dotSize) * heightFraction
            val barCenterX = startX + i * (barWidth + barSpacing)
            barRect.set(
                barCenterX - barWidth / 2f,
                bounds.centerY() - barHeight / 2f,
                barCenterX + barWidth / 2f,
                bounds.centerY() + barHeight / 2f
            )
            canvas.drawRoundRect(barRect, barWidth / 2f, barWidth / 2f, barPaint)
        }
    }

    private fun drawX(canvas: Canvas, bounds: RectF, alpha: Float) {
        iconPaint.color = withAlpha(glyphColor, alpha)
        iconPaint.strokeWidth = bounds.width() * 0.052f
        val inset = bounds.width() * 0.41f
        canvas.drawLine(bounds.left + inset, bounds.top + inset, bounds.right - inset, bounds.bottom - inset, iconPaint)
        canvas.drawLine(bounds.right - inset, bounds.top + inset, bounds.left + inset, bounds.bottom - inset, iconPaint)
    }

    private fun drawCheck(canvas: Canvas, bounds: RectF, alpha: Float) {
        iconPaint.color = withAlpha(glyphColor, alpha)
        iconPaint.strokeWidth = bounds.width() * 0.056f
        canvas.drawLine(
            bounds.left + bounds.width() * 0.37f,
            bounds.top + bounds.height() * 0.54f,
            bounds.left + bounds.width() * 0.46f,
            bounds.top + bounds.height() * 0.63f,
            iconPaint
        )
        canvas.drawLine(
            bounds.left + bounds.width() * 0.46f,
            bounds.top + bounds.height() * 0.63f,
            bounds.left + bounds.width() * 0.65f,
            bounds.top + bounds.height() * 0.42f,
            iconPaint
        )
    }

    private fun drawSpinner(canvas: Canvas, bounds: RectF) {
        spinnerPaint.color = glyphColor
        spinnerPaint.strokeWidth = bounds.width() * 0.056f
        tempRect.set(
            bounds.left + bounds.width() * 0.34f,
            bounds.top + bounds.height() * 0.34f,
            bounds.right - bounds.width() * 0.34f,
            bounds.bottom - bounds.height() * 0.34f
        )
        canvas.drawArc(tempRect, processingPhaseDegrees - 90f, 260f, false, spinnerPaint)
    }

    private fun withAlpha(color: Int, alphaFraction: Float): Int {
        val alpha = (alphaFraction.coerceIn(0f, 1f) * 255).toInt()
        return (color and 0x00FFFFFF) or (alpha shl 24)
    }

    /** Opaque result of laying [top] at [fraction] over [base]. */
    private fun blend(top: Int, base: Int, fraction: Float): Int {
        val f = fraction.coerceIn(0f, 1f)
        fun mix(channel: (Int) -> Int) = (channel(top) * f + channel(base) * (1f - f)).toInt().coerceIn(0, 255)
        return Color.rgb(mix(Color::red), mix(Color::green), mix(Color::blue))
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (state == State.Processing) {
            startProcessingAnimation()
        }
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        barAnimators.forEach { it?.cancel() }
        stopProcessingAnimation()
    }
}
