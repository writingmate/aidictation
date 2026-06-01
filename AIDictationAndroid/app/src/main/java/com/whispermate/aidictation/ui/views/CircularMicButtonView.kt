package com.whispermate.aidictation.ui.views

import android.animation.ArgbEvaluator
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
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
 * Custom View version of the logo-style mic button for overlay layouts.
 * Displays a rounded-square button with animated audio bars inside.
 *
 * States:
 * - Idle: brand background, frozen sine wave pattern
 * - Recording: brand background, bars respond to audio/frequency bands
 * - Processing: brand background, animated sine wave
 */
class CircularMicButtonView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    enum class State { Idle, Recording, Processing }

    // Configuration
    private var idleColor: Int = 0xFFFF6300.toInt()
    private var activeColor: Int = 0xFFFF6300.toInt()

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
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK }
    private val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val barShadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK }
    private val buttonRect = RectF()
    private val shadowRect = RectF()
    private val barRect = RectF()

    // Click handling
    private var onClickCallback: (() -> Unit)? = null

    // Spring-like interpolator (overshoot simulates bounce)
    private val springInterpolator = OvershootInterpolator(1.5f)

    companion object {
        private const val TOTAL_BARS = 5
        private const val MIN_ACTIVE_BARS = 3
        private const val WAVEFORM_LEVEL_GAIN = 1.35f
        private const val WAVEFORM_LEVEL_MIX = 0.08f
        private const val WAVEFORM_CONTRAST = 0.8f
        private const val WAVEFORM_FLOOR_THRESHOLD = 0.045f
        private const val WAVEFORM_ACTIVE_FLOOR = 0.16f
        private val FROZEN_HEIGHTS = floatArrayOf(0.56f, 1f, 0.56f, 1f, 0.56f)
        private val CIRCLE_ENVELOPE_HEIGHTS = floatArrayOf(0.72f, 0.94f, 1f, 0.94f, 0.72f)
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
                        val bandValue = recordingBandValue(i)
                        boostWaveformLevel(bandValue, audioLevel) * CIRCLE_ENVELOPE_HEIGHTS[i]
                    }
                }
                State.Processing -> {
                    // Calculated in onDraw based on processingPhase
                    CIRCLE_ENVELOPE_HEIGHTS[i]
                }
            }

            if (state != State.Processing) {
                animateBarTo(i, targetHeight)
            }
        }
    }

    private fun recordingBandValue(index: Int): Float {
        val bands = frequencyBands
        if (bands == null || bands.isEmpty()) return audioLevel

        val sourcePosition = if (TOTAL_BARS == 1) {
            0f
        } else {
            index * (bands.lastIndex.toFloat() / (TOTAL_BARS - 1))
        }
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
        val inset = size * 0.06f
        val buttonSize = size - (inset * 2f)
        val cornerRadius = buttonSize * 0.24f
        buttonRect.set(
            centerX - buttonSize / 2f,
            centerY - buttonSize / 2f,
            centerX + buttonSize / 2f,
            centerY + buttonSize / 2f
        )

        shadowPaint.alpha = if (state == State.Idle) 70 else 82
        shadowRect.set(buttonRect)
        shadowRect.offset(0f, buttonSize * 0.07f)
        canvas.drawRoundRect(shadowRect, cornerRadius, cornerRadius, shadowPaint)

        backgroundPaint.shader = LinearGradient(
            0f,
            buttonRect.top,
            0f,
            buttonRect.bottom,
            intArrayOf(
                blendColor(currentBackgroundColor, Color.WHITE, 0.18f),
                currentBackgroundColor,
                blendColor(currentBackgroundColor, Color.BLACK, 0.20f)
            ),
            floatArrayOf(0f, 0.48f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawRoundRect(buttonRect, cornerRadius, cornerRadius, backgroundPaint)
        backgroundPaint.shader = null

        val barWidth = buttonSize * 0.085f
        val barSpacing = buttonSize * 0.035f
        val maxBarHeight = buttonSize * 0.58f
        val dotSize = barWidth
        val barCornerRadius = barWidth / 2

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
                sineValue * CIRCLE_ENVELOPE_HEIGHTS[i]
            } else {
                barHeights[i]
            }

            val barHeight = dotSize + (maxBarHeight - dotSize) * heightFraction

            val left = barCenterX - barWidth / 2
            val top = centerY - barHeight / 2
            val right = barCenterX + barWidth / 2
            val bottom = centerY + barHeight / 2

            barShadowPaint.alpha = if (state == State.Idle) 72 else 58
            val barShadowOffset = buttonSize * 0.045f
            barRect.set(left, top + barShadowOffset, right, bottom + barShadowOffset)
            canvas.drawRoundRect(barRect, barCornerRadius, barCornerRadius, barShadowPaint)

            barRect.set(left, top, right, bottom)
            canvas.drawRoundRect(barRect, barCornerRadius, barCornerRadius, barPaint)
        }
    }

    private fun blendColor(from: Int, to: Int, amount: Float): Int {
        val ratio = amount.coerceIn(0f, 1f)
        val inverse = 1f - ratio
        return Color.argb(
            Color.alpha(from),
            (Color.red(from) * inverse + Color.red(to) * ratio).toInt(),
            (Color.green(from) * inverse + Color.green(to) * ratio).toInt(),
            (Color.blue(from) * inverse + Color.blue(to) * ratio).toInt()
        )
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        colorAnimator?.cancel()
        processingAnimator?.cancel()
        barAnimators.forEach { it?.cancel() }
    }
}
