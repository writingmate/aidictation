package com.whispermate.aidictation.ui.components

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Space between the segments of a grouped list; the page colour shows through it. */
val GroupedListGap: Dp = 2.dp

private val OuterCorner = 24.dp
private val InnerCorner = 4.dp

/**
 * Shape for item [index] of [count] in a grouped list, the way Android's own Settings
 * draws them: the group's outer corners are big, the seams between items barely rounded.
 */
fun groupedItemShape(index: Int, count: Int): Shape {
    val first = index == 0
    val last = index == count - 1
    return RoundedCornerShape(
        topStart = if (first) OuterCorner else InnerCorner,
        topEnd = if (first) OuterCorner else InnerCorner,
        bottomEnd = if (last) OuterCorner else InnerCorner,
        bottomStart = if (last) OuterCorner else InnerCorner
    )
}
