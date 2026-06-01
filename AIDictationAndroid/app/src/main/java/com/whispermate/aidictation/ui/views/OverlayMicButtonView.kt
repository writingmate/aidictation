package com.whispermate.aidictation.ui.views

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
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

    private var idleColor: Int = 0xFFFF6300.toInt()
    private var activeColor: Int = 0xFFFF6300.toInt()
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
    private val processingHeights = FloatArray(TOTAL_BARS)

    private val barAnimators = arrayOfNulls<ValueAnimator>(TOTAL_BARS)
    private var processingAnimator: ValueAnimator? = null

    private val springInterpolator = OvershootInterpolator(1.2f)

    companion object {
        private const val TOTAL_BARS = 5
        private const val MIN_ACTIVE_BARS = 3
        private const val BACKGROUND_ALPHA = 0.82f
        private const val PRIMARY_BUTTON_ALPHA = 0.88f
        private const val SECONDARY_SURFACE_ALPHA = 0.34f
        private const val WAVEFORM_LEVEL_GAIN = 1.35f
        private const val WAVEFORM_LEVEL_MIX = 0.08f
        private const val WAVEFORM_CONTRAST = 0.8f
        private const val WAVEFORM_FLOOR_THRESHOLD = 0.045f
        private const val WAVEFORM_ACTIVE_FLOOR = 0.16f
        private val FROZEN_HEIGHTS = floatArrayOf(0.56f, 1f, 0.56f, 1f, 0.56f)
        private val CIRCLE_ENVELOPE_HEIGHTS = floatArrayOf(0.72f, 0.94f, 1f, 0.94f, 0.72f)
    }

    init {
        context.theme.obtainStyledAttributes(attrs, R.styleable.CircularMicButtonView, 0, 0).apply {
            try {
                idleColor = getColor(R.styleable.CircularMicButtonView_idleColor, idleColor)
                activeColor = getColor(R.styleable.CircularMicButtonView_activeColor, activeColor)
            } finally {
                recycle()
            }
        }
        isClickable = true
        isFocusable = true
    }

    fun preferredWidthDp(): Int = when (state) {
        State.Recording, State.Processing -> 250
        State.Idle -> 55
    }

    fun preferredHeightDp(): Int = 55

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

    fun setColors(idle: Int, active: Int) {
        idleColor = idle
        activeColor = active
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

    private fun drawOverlay(canvas: Canvas) {
        val h = height.toFloat()
        val currentWidth = width.toFloat()
        val surfaceSize = h * 0.86f
        val surfaceInset = (h - surfaceSize) / 2f
        val gap = h * 0.13f

        acceptRect.set(
            currentWidth - surfaceInset - surfaceSize,
            surfaceInset,
            currentWidth - surfaceInset,
            surfaceInset + surfaceSize
        )
        cancelRect.set(surfaceInset, surfaceInset, surfaceInset + surfaceSize, surfaceInset + surfaceSize)
        pillRect.set(cancelRect.right + gap, surfaceInset, acceptRect.left - gap, surfaceInset + surfaceSize)

        val expanded = if (state == State.Idle) 0f else 1f
        val primaryColor = if (state == State.Idle) idleColor else activeColor

        if (pillRect.width() > 0f) {
            pillPaint.color = withAlpha(activeColor, SECONDARY_SURFACE_ALPHA * expanded)
            canvas.drawRoundRect(pillRect, surfaceSize / 2f, surfaceSize / 2f, pillPaint)
        }

        backgroundPaint.color = withAlpha(activeColor, SECONDARY_SURFACE_ALPHA * expanded)
        if (expanded > 0f && state == State.Recording) {
            canvas.drawCircle(cancelRect.centerX(), cancelRect.centerY(), surfaceSize / 2f, backgroundPaint)
        }

        backgroundPaint.color = withAlpha(primaryColor, PRIMARY_BUTTON_ALPHA)
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
        val barWidth = bounds.height() * 0.092f
        val barSpacing = bounds.height() * if (circleSpacing) 0.044f else 0.14f
        val maxBarHeight = bounds.height() * if (circleSpacing) 0.496f else 0.48f
        val dotSize = barWidth
        val totalBarsWidth = (barWidth * TOTAL_BARS) + (barSpacing * (TOTAL_BARS - 1))
        val startX = bounds.centerX() - (totalBarsWidth / 2f) + (barWidth / 2f)
        barPaint.color = withAlpha(Color.WHITE, alpha)

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
        iconPaint.color = withAlpha(Color.WHITE, alpha)
        iconPaint.strokeWidth = bounds.width() * 0.052f
        val inset = bounds.width() * 0.41f
        canvas.drawLine(bounds.left + inset, bounds.top + inset, bounds.right - inset, bounds.bottom - inset, iconPaint)
        canvas.drawLine(bounds.right - inset, bounds.top + inset, bounds.left + inset, bounds.bottom - inset, iconPaint)
    }

    private fun drawCheck(canvas: Canvas, bounds: RectF, alpha: Float) {
        iconPaint.color = withAlpha(Color.WHITE, alpha)
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
