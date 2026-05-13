package com.whispermate.aidictation.ui.components

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.Drawable
import android.util.AttributeSet
import android.view.View
import android.view.animation.LinearInterpolator
import androidx.core.content.ContextCompat
import com.whispermate.aidictation.R

/**
 * Animated mic button with pulsing circles when recording.
 * The circles expand outward from the mic icon based on audio level.
 */
class AnimatedMicButton @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }

    private var micDrawable: Drawable? = ContextCompat.getDrawable(context, R.drawable.ic_mic_toolbar)

    private val activeColor = 0xFFFF6300.toInt()
    private val idleColor = ContextCompat.getColor(context, R.color.brand_black)

    private var audioLevel = 0f
    private var isRecording = false
    private var isProcessing = false
    private var animator: ValueAnimator? = null

    // Animation phase
    private var pulsePhase = 0f
    private val pulseSpeed = 0.04f

    // Circle animation - 2 filled circles (outer lighter, inner darker)
    private var outerCircleRadius = 0f
    private var outerCircleAlpha = 0f
    private var innerCircleRadius = 0f
    private var innerCircleAlpha = 0f

    private val minCircleRadius get() = width * 0.35f
    private val maxCircleRadius get() = width * 1.0f

    init {
        isClickable = true
        isFocusable = true

        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1000L
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener {
                if (isRecording || isProcessing) {
                    updateAnimation()
                    invalidate()
                }
            }
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        animator?.start()
    }

    override fun onDetachedFromWindow() {
        animator?.cancel()
        super.onDetachedFromWindow()
    }

    private fun updateAnimation() {
        pulsePhase += pulseSpeed
        if (pulsePhase >= 1f) pulsePhase -= 1f

        if (isRecording) {
            // Audio-reactive circles - expand based on audio level
            val effectiveLevel = (audioLevel * 1.5f).coerceIn(0f, 1f)
            val targetOuterRadius = minCircleRadius + (maxCircleRadius - minCircleRadius) * effectiveLevel

            // Outer circle - lighter, larger, follows audio
            outerCircleRadius += (targetOuterRadius - outerCircleRadius) * 0.2f
            outerCircleAlpha = 0.15f + 0.1f * effectiveLevel // lighter: 15-25% opacity

            // Inner circle - darker, smaller, follows with slight delay
            val targetInnerRadius = outerCircleRadius * 0.65f
            innerCircleRadius += (targetInnerRadius - innerCircleRadius) * 0.15f
            innerCircleAlpha = 0.3f + 0.15f * effectiveLevel // darker: 30-45% opacity

        } else if (isProcessing) {
            // Processing: gentle pulsing animation
            val pulse = (kotlin.math.sin(pulsePhase * 2 * Math.PI) + 1f) / 2f
            outerCircleRadius = minCircleRadius + (maxCircleRadius - minCircleRadius) * 0.3f * pulse.toFloat()
            outerCircleAlpha = 0.15f + 0.1f * pulse.toFloat()
            innerCircleRadius = outerCircleRadius * 0.65f
            innerCircleAlpha = 0.3f + 0.1f * pulse.toFloat()
        } else {
            // Idle: shrink circles
            outerCircleRadius *= 0.85f
            outerCircleAlpha *= 0.85f
            innerCircleRadius *= 0.85f
            innerCircleAlpha *= 0.85f
        }
    }

    fun setAudioLevel(level: Float) {
        audioLevel = level.coerceIn(0f, 1f)
    }

    fun startRecording() {
        isRecording = true
        isProcessing = false
        audioLevel = 0f
        outerCircleRadius = minCircleRadius
        outerCircleAlpha = 0.15f
        innerCircleRadius = minCircleRadius * 0.65f
        innerCircleAlpha = 0.3f
        // Tint mic orange
        micDrawable?.setTint(activeColor)
        invalidate()
    }

    fun startProcessing() {
        isRecording = false
        isProcessing = true
        audioLevel = 0f
        invalidate()
    }

    fun stopRecording() {
        isRecording = false
        isProcessing = false
        audioLevel = 0f
        // Reset circles immediately
        outerCircleRadius = 0f
        outerCircleAlpha = 0f
        innerCircleRadius = 0f
        innerCircleAlpha = 0f
        // Restore original tint
        micDrawable?.setTint(idleColor)
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val centerX = width / 2f
        val centerY = height / 2f

        // Draw expanding filled circles behind mic (only when recording/processing)
        // Outer circle - lighter
        if (outerCircleAlpha > 0.01f && outerCircleRadius > 0) {
            circlePaint.color = activeColor
            circlePaint.alpha = (outerCircleAlpha * 255).toInt()
            canvas.drawCircle(centerX, centerY, outerCircleRadius, circlePaint)
        }
        // Inner circle - darker
        if (innerCircleAlpha > 0.01f && innerCircleRadius > 0) {
            circlePaint.color = activeColor
            circlePaint.alpha = (innerCircleAlpha * 255).toInt()
            canvas.drawCircle(centerX, centerY, innerCircleRadius, circlePaint)
        }

        // Draw mic icon in center
        micDrawable?.let { drawable ->
            val iconSize = (width * 0.5f).toInt()
            val left = (width - iconSize) / 2
            val top = (height - iconSize) / 2
            drawable.setBounds(left, top, left + iconSize, top + iconSize)
            drawable.draw(canvas)
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // Initialize mic drawable tint
        micDrawable?.setTint(idleColor)
    }
}
