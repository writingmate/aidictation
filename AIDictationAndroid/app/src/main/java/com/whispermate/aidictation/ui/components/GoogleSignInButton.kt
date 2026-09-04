package com.whispermate.aidictation.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.whispermate.aidictation.R

/**
 * "Continue with Google" per Google's sign-in branding guidelines: the untinted "G" at
 * 20 dp with 12 dp to the label, medium-weight text, and the light theme's white fill with
 * a #747775 outline (dark: #131314 fill, #8E918F outline, #E3E3E3 text). Pill shape is one
 * of the three permitted variants.
 */
@Composable
fun GoogleSignInButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    val dark = isSystemInDarkTheme()
    val fill = if (dark) Color(0xFF131314) else Color.White
    val outline = if (dark) Color(0xFF8E918F) else Color(0xFF747775)
    val label = if (dark) Color(0xFFE3E3E3) else Color(0xFF1F1F1F)
    OutlinedButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        shape = RoundedCornerShape(50),
        border = BorderStroke(1.dp, outline),
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = fill,
            contentColor = label,
            disabledContainerColor = fill.copy(alpha = 0.6f),
            disabledContentColor = label.copy(alpha = 0.38f)
        )
    ) {
        Icon(
            painter = painterResource(R.drawable.ic_google_g),
            contentDescription = null,
            tint = Color.Unspecified,
            modifier = Modifier.size(20.dp)
        )
        Spacer(modifier = Modifier.width(12.dp))
        Text(
            text = stringResource(R.string.account_continue_with_google),
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.Medium
        )
    }
}
