package com.whispermate.aidictation.ui.views

import android.animation.ArgbEvaluator
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

/**
 * Custom View version of CircularMicButton for use in XML layouts.
 * Displays a circular button with animated audio bars inside.
 *
 * States:
 * - Idle: black background, frozen sine wave pattern
 * - Recording: brand orange background, bars respond to audio/frequency bands
 * - Processing: brand orange background, animated sine wave
 */
class CircularMicButtonView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    enum class State { Idle, Recording, Processing }

    // Configuration
    private var idleColor: Int = 0xFF120B00.toInt()
    private var activeColor: Int = 0xFFFF6300.toInt() // Brand orange

    // State
    private var state: State = State.Idle
    private var audioLevel: Float = 0f
    private var frequencyBands: FloatArray? = null

    // Animation values
    private var currentBackgroundColor: Int = idleColor
    private val barHeights = FloatArray(TOTAL_BARS) { FROZEN_HEIGHTS[it] }
    private var processingPhase: Float = 0f

    // Animators
    private var colorAnimator: ValueAnimator? = null
    private val barAnimators = arrayOfNulls<ValueAnimator>(TOTAL_BARS)
    private var processingAnimator: ValueAnimator? = null

    // Paint objects
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
    }
    private val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val barRect = RectF()

    // Click handling
    private var onClickCallback: (() -> Unit)? = null

    // Spring-like interpolator (overshoot simulates bounce)
    private val springInterpolator = OvershootInterpolator(1.5f)

    companion object {
        private const val TOTAL_BARS = 6
        private const val MIN_ACTIVE_BARS = 3
        private const val WAVEFORM_LEVEL_GAIN = 1.65f
        private const val WAVEFORM_LEVEL_MIX = 0.3f
        private const val WAVEFORM_FLOOR_THRESHOLD = 0.045f
        private const val WAVEFORM_ACTIVE_FLOOR = 0.16f
        private val FROZEN_HEIGHTS = floatArrayOf(0.51f, 0.86f, 0.99f, 0.99f, 0.86f, 0.51f)
    }

    init {
        // Read custom attributes
        context.theme.obtainStyledAttributes(attrs, R.styleable.CircularMicButtonView, 0, 0).apply {
            try {
                idleColor = getColor(R.styleable.CircularMicButtonView_idleColor, idleColor)
                activeColor = getColor(R.styleable.CircularMicButtonView_activeColor, activeColor)
            } finally {
                recycle()
            }
        }

        currentBackgroundColor = idleColor
        isClickable = true
        isFocusable = true
    }

    fun setOnClickCallback(callback: () -> Unit) {
        onClickCallback = callback
        setOnClickListener {
            if (state != State.Processing) {
                callback()
            }
        }
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    fun setState(newState: State) {
        if (state == newState) return
        state = newState

        // Animate color
        val targetColor = when (state) {
            State.Idle -> idleColor
            State.Recording, State.Processing -> activeColor
        }
        animateColorTo(targetColor)

        // Handle processing animation
        when (state) {
            State.Processing -> startProcessingAnimation()
            else -> stopProcessingAnimation()
        }

        // Update bar heights
        updateBarHeights()
    }

    fun setAudioLevel(level: Float) {
        audioLevel = level.coerceIn(0f, 1f)
        if (state == State.Recording) {
            updateBarHeights()
        }
    }

    fun setFrequencyBands(bands: FloatArray?) {
        frequencyBands = bands
        if (state == State.Recording) {
            updateBarHeights()
        }
    }

    fun setColors(idle: Int, active: Int) {
        idleColor = idle
        activeColor = active
        val targetColor = when (state) {
            State.Idle -> idleColor
            State.Recording, State.Processing -> activeColor
        }
        currentBackgroundColor = targetColor
        invalidate()
    }

    private fun animateColorTo(targetColor: Int) {
        colorAnimator?.cancel()
        colorAnimator = ValueAnimator.ofObject(ArgbEvaluator(), currentBackgroundColor, targetColor).apply {
            duration = 300
            addUpdateListener { animator ->
                currentBackgroundColor = animator.animatedValue as Int
                invalidate()
            }
            start()
        }
    }

    private fun updateBarHeights() {
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
                    val isActive = minDistance >= barsFromEdge

                    if (!isActive) {
                        0f // Dot size (will be scaled in onDraw)
                    } else {
                        val bandValue = frequencyBands?.getOrNull(i)?.coerceIn(0f, 1f) ?: audioLevel
                        boostWaveformLevel(bandValue, audioLevel) * FROZEN_HEIGHTS[i]
                    }
                }
                State.Processing -> {
                    // Calculated in onDraw based on processingPhase
                    FROZEN_HEIGHTS[i]
                }
            }

            if (state != State.Processing) {
                animateBarTo(i, targetHeight)
            }
        }
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
            duration = 170
            interpolator = springInterpolator
            addUpdateListener { animator ->
                barHeights[index] = animator.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    private fun startProcessingAnimation() {
        stopProcessingAnimation()
        processingAnimator = ValueAnimator.ofFloat(0f, (2 * PI).toFloat()).apply {
            duration = 900
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.RESTART
            addUpdateListener { animator ->
                processingPhase = animator.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    private fun stopProcessingAnimation() {
        processingAnimator?.cancel()
        processingAnimator = null
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val desiredSize = (40 * resources.displayMetrics.density).toInt() // 40dp default
        val width = resolveSize(desiredSize, widthMeasureSpec)
        val height = resolveSize(desiredSize, heightMeasureSpec)
        val size = min(width, height)
        setMeasuredDimension(size, size)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val size = min(width, height).toFloat()
        val centerX = width / 2f
        val centerY = height / 2f
        val radius = size / 2f

        // Draw a subtle shadow under the button for better depth on all backgrounds.
        shadowPaint.alpha = if (state == State.Idle) 58 else 72
        canvas.drawCircle(centerX, centerY + (radius * 0.08f), radius * 1.03f, shadowPaint)

        // Draw circular background
        backgroundPaint.color = currentBackgroundColor
        canvas.drawCircle(centerX, centerY, radius, backgroundPaint)

        // Calculate bar dimensions (scaled from 100dp design)
        val scale = size / (100 * resources.displayMetrics.density)
        val barWidth = 8 * resources.displayMetrics.density * scale
        val barSpacing = 2 * resources.displayMetrics.density * scale
        val maxBarHeight = 58 * resources.displayMetrics.density * scale
        val dotSize = 8 * resources.displayMetrics.density * scale
        val barCornerRadius = barWidth / 2

        // Calculate total width of all bars
        val totalBarsWidth = (barWidth * TOTAL_BARS) + (barSpacing * (TOTAL_BARS - 1))
        val startX = centerX - (totalBarsWidth / 2) + (barWidth / 2)

        // Draw each bar
        for (i in 0 until TOTAL_BARS) {
            val barCenterX = startX + i * (barWidth + barSpacing)

            // Calculate height based on state
            val heightFraction = if (state == State.Processing) {
                val normalizedIndex = i.toFloat() / (TOTAL_BARS - 1)
                val wavePosition = normalizedIndex * 2f * PI.toFloat() - processingPhase
                val sineValue = (sin(wavePosition) + 1f) / 2f
                sineValue * FROZEN_HEIGHTS[i]
            } else {
                barHeights[i]
            }

            val barHeight = dotSize + (maxBarHeight - dotSize) * heightFraction

            val left = barCenterX - barWidth / 2
            val top = centerY - barHeight / 2
            val right = barCenterX + barWidth / 2
            val bottom = centerY + barHeight / 2

            barRect.set(left, top, right, bottom)
            canvas.drawRoundRect(barRect, barCornerRadius, barCornerRadius, barPaint)
        }
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        colorAnimator?.cancel()
        processingAnimator?.cancel()
        barAnimators.forEach { it?.cancel() }
    }
}
