package com.whispermate.aidictation.ui.components

import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * The separator between rows in a settings card: a full-width, page-coloured line, so
 * the rows read as segments of one group the way Android's own Settings lists do,
 * rather than an inset hairline.
 */
@Composable
fun SettingsRowGap(modifier: Modifier = Modifier) {
    HorizontalDivider(
        modifier = modifier,
        thickness = 2.dp,
        color = MaterialTheme.colorScheme.background
    )
}
