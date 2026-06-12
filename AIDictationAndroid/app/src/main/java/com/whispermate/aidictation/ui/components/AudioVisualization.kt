package com.whispermate.aidictation.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.sin
import kotlin.random.Random

/**
 * iOS-style audio visualization with 14 bars.
 * Bars animate from center outward based on audio level.
 * Inactive bars show as small dots.
 */
@Composable
fun AudioVisualization(
    audioLevel: Float,
    modifier: Modifier = Modifier,
    barColor: Color = MaterialTheme.colorScheme.primary
) {
    val totalBars = 14
    val barWidth = 4.dp
    val barSpacing = 2.dp
    val maxBarHeight = 32.dp
    val dotSize = 3.dp
    val minActiveBars = 4

    // Random factors for organic variation
    val randomFactors = remember { List(totalBars) { Random.nextFloat() * 0.4f + 0.8f } }

    // Calculate how many bars should be active based on audio level
    val activeBarCount = remember(audioLevel) {
        val range = totalBars - minActiveBars
        val count = minActiveBars + (range * audioLevel).toInt()
        count.coerceIn(minActiveBars, totalBars)
    }

    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(barSpacing),
        verticalAlignment = Alignment.CenterVertically
    ) {
        repeat(totalBars) { index ->
            val height = calculateBarHeight(
                index = index,
                totalBars = totalBars,
                activeBarCount = activeBarCount,
                audioLevel = audioLevel,
                maxBarHeight = maxBarHeight,
                dotSize = dotSize,
                randomFactor = randomFactors[index]
            )

            val animatedHeight by animateFloatAsState(
                targetValue = height.value,
                animationSpec = tween(durationMillis = 120),
                label = "bar_height_$index"
            )

            Box(
                modifier = Modifier
                    .width(barWidth)
                    .height(animatedHeight.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(barColor)
            )
        }
    }
}

private fun calculateBarHeight(
    index: Int,
    totalBars: Int,
    activeBarCount: Int,
    audioLevel: Float,
    maxBarHeight: Dp,
    dotSize: Dp,
    randomFactor: Float
): Dp {
    // Calculate position from center (0.0 = center, 1.0 = edge)
    val center = (totalBars - 1) / 2.0
    val distanceFromCenter = abs(index - center) / center

    // Check if this bar should be active
    val barsFromEdge = (totalBars - activeBarCount) / 2
    val distanceFromStart = index
    val distanceFromEnd = totalBars - 1 - index
    val minDistance = minOf(distanceFromStart, distanceFromEnd)
    val isActive = minDistance >= barsFromEdge

    // If not active, return dot size
    if (!isActive) {
        return dotSize
    }

    // Quadratic falloff from center for dramatic curve
    val waveformFactor = 1.0 - (distanceFromCenter * distanceFromCenter)

    // Calculate height
    val heightRange = maxBarHeight.value - dotSize.value
    val baseHeight = dotSize.value + (heightRange * audioLevel * waveformFactor.toFloat() * randomFactor)

    return baseHeight.coerceIn(dotSize.value, maxBarHeight.value).dp
}

/**
 * iOS-style processing wave animation.
 * Shows a smooth sine wave that moves left to right.
 */
@Composable
fun ProcessingWaveView(
    modifier: Modifier = Modifier,
    barColor: Color = MaterialTheme.colorScheme.primary
) {
    val totalBars = 14
    val barWidth = 4.dp
    val barSpacing = 2.dp
    val maxBarHeight = 18.dp
    val minBarHeight = 4.dp
    val cycleDuration = 900 // ms

    val infiniteTransition = rememberInfiniteTransition(label = "processing_wave")
    val phase by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * Math.PI).toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = cycleDuration, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "wave_phase"
    )

    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(barSpacing),
        verticalAlignment = Alignment.CenterVertically
    ) {
        repeat(totalBars) { index ->
            val normalizedIndex = index.toFloat() / (totalBars - 1)
            val wavePosition = normalizedIndex * 2f * Math.PI.toFloat() - phase
            val sineValue = (sin(wavePosition) + 1f) / 2f

            val heightRange = maxBarHeight.value - minBarHeight.value
            val height = minBarHeight.value + (heightRange * sineValue)

            Box(
                modifier = Modifier
                    .width(barWidth)
                    .height(height.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(barColor)
            )
        }
    }
}
