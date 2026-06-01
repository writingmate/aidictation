package com.whispermate.aidictation.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt
import kotlin.math.sin
import kotlin.random.Random

private val activeColor = Color(0xFFFF6300)
private val idleColor = activeColor
private val barColor = Color.White
private const val minActiveBars = 3
private const val waveformLevelGain = 1.7f
private const val waveformLevelMix = 0.28f
private const val waveformFloorThreshold = 0.045f
private const val waveformActiveFloor = 0.16f

enum class MicButtonState {
    Idle,       // Frozen sine wave pattern (like app logo)
    Recording,  // Active visualization responding to audio
    Processing  // Animated wave pattern
}

/**
 * Logo-style mic button with iOS-style audio bars inside.
 * - Smooth spring animations for bouncy feel (matches iOS .easeOut)
 * - Random organic variation per bar
 * - Idle: frozen sine wave pattern
 * - Recording: bars respond to audio level with smooth animation
 * - Processing: animated sine wave
 */
@Composable
fun CircularMicButton(
    state: MicButtonState,
    audioLevel: Float = 0f,
    frequencyBands: FloatArray? = null,  // FFT frequency bands (7 values, 0-1)
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 100.dp
) {
    // Bar configuration - 6 bars, scaled proportionally to button size
    // At 100dp: barWidth=8dp, spacing=2dp, total=58dp (58% of button)
    val totalBars = 6
    val scale = size.value / 100f
    val barWidth = 8.dp * scale
    val barSpacing = 2.dp * scale
    val maxBarHeight = 58.dp * scale  // Match width for perfect circle
    val dotSize = 8.dp * scale

    // Random factors for organic variation (like iOS randomFactor 0.8-1.2)
    val randomFactors = remember { List(totalBars) { Random.nextFloat() * 0.4f + 0.8f } }

    // Pre-calculate frozen heights for idle state - mathematically fit inside circle
    // Bar centers at x = -25, -15, -5, 5, 15, 25 relative to center (R=29)
    // Height at x = 2 * sqrt(R² - x²), normalized to diameter
    val frozenHeights = remember {
        listOf(0.51f, 0.86f, 0.99f, 0.99f, 0.86f, 0.51f)
    }

    // For processing animation
    val infiniteTransition = rememberInfiniteTransition(label = "processing")
    val processingPhase by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * PI).toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "phase"
    )

    // Animated color transition
    val backgroundColor by animateColorAsState(
        targetValue = when (state) {
            MicButtonState.Idle -> idleColor
            MicButtonState.Recording -> activeColor
            MicButtonState.Processing -> activeColor
        },
        animationSpec = tween(durationMillis = 300),
        label = "bg_color"
    )

    // Calculate active bar count
    val activeBarCount = when (state) {
        MicButtonState.Idle -> totalBars
        MicButtonState.Recording -> {
            val range = totalBars - minActiveBars
            val boostedLevel = boostWaveformLevel(audioLevel)
            (minActiveBars + (range * boostedLevel * 2.5f).toInt()).coerceIn(minActiveBars, totalBars)
        }
        MicButtonState.Processing -> totalBars
    }

    // Calculate viz size for debug circle
    val vizWidth = barWidth * totalBars + barSpacing * (totalBars - 1)  // 60dp
    val vizHeight = maxBarHeight  // 60dp

    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.24f))
            .background(
                Brush.verticalGradient(
                    colors = listOf(
                        backgroundColor.blend(Color.White, 0.18f),
                        backgroundColor,
                        backgroundColor.blend(Color.Black, 0.20f)
                    )
                )
            )
            .clickable(enabled = state != MicButtonState.Processing) { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(barSpacing),
            verticalAlignment = Alignment.CenterVertically
        ) {
            repeat(totalBars) { index ->
                val center = (totalBars - 1) / 2.0
                val distanceFromCenter = abs(index - center) / center

                // Check if bar is active
                val barsFromEdge = (totalBars - activeBarCount) / 2
                val minDistance = minOf(index, totalBars - 1 - index)
                val isActive = minDistance >= barsFromEdge

                // Calculate target height
                val targetHeight = when (state) {
                    MicButtonState.Idle -> {
                        dotSize + (maxBarHeight - dotSize) * frozenHeights[index]
                    }
                    MicButtonState.Recording -> {
                        if (!isActive) {
                            dotSize
                        } else {
                            // Use frequency band directly if available, otherwise fall back to audio level
                            val bandValue = frequencyBands?.getOrNull(index)?.coerceIn(0f, 1f) ?: audioLevel
                            val boostedBand = boostWaveformLevel(bandValue, audioLevel)
                            // Max height for this bar is its frozen height (maintains circular shape)
                            val maxForThisBar = frozenHeights[index]
                            val heightRange = maxBarHeight - dotSize
                            dotSize + heightRange * boostedBand * maxForThisBar
                        }
                    }
                    MicButtonState.Processing -> {
                        val normalizedIndex = index.toFloat() / (totalBars - 1)
                        val wavePosition = normalizedIndex * 2f * PI.toFloat() - processingPhase
                        val sineValue = (sin(wavePosition) + 1f) / 2f
                        // Cap at frozen height to maintain circular shape
                        val maxForThisBar = frozenHeights[index]
                        dotSize + (maxBarHeight - dotSize) * sineValue * maxForThisBar
                    }
                }

                // Smooth spring animation for bouncy feel (like iOS .easeOut)
                val animatedHeight by animateFloatAsState(
                    targetValue = targetHeight.value,
                    animationSpec = spring(
                        dampingRatio = Spring.DampingRatioMediumBouncy,
                        stiffness = Spring.StiffnessLow
                    ),
                    label = "bar_$index"
                )

                Box(
                    modifier = Modifier
                        .width(barWidth)
                        .height(animatedHeight.dp)
                        .drawBehind {
                            val offset = 2.dp.toPx() * scale
                            drawRoundRect(
                                color = Color.Black.copy(alpha = 0.28f),
                                topLeft = Offset(0f, offset),
                                size = Size(this.size.width, this.size.height),
                                cornerRadius = CornerRadius(this.size.width / 2f, this.size.width / 2f)
                            )
                        }
                        .clip(RoundedCornerShape(barWidth / 2))
                        .background(barColor)
                )
            }
        }
    }
}

private fun Color.blend(target: Color, amount: Float): Color {
    val ratio = amount.coerceIn(0f, 1f)
    return Color(
        red = red + (target.red - red) * ratio,
        green = green + (target.green - green) * ratio,
        blue = blue + (target.blue - blue) * ratio,
        alpha = alpha
    )
}

private fun boostWaveformLevel(level: Float, overallLevel: Float = level): Float {
    val mixed = (level * waveformLevelGain + overallLevel * waveformLevelMix).coerceIn(0f, 1f)
    val eased = sqrt(mixed)
    val floor = if (overallLevel > waveformFloorThreshold) waveformActiveFloor else 0f
    return max(eased, floor).coerceIn(0f, 1f)
}
