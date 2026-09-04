package com.whispermate.aidictation.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.whispermate.aidictation.R

private val BrandOrange = Color(0xFFFF6300)
private val BrandOrangePressed = Color(0xFFE65A00)
private val BrandBlack = Color(0xFF120B00)
private val BrandBlack15 = Color(0xFFD1CFCC)
private val BrandGreyPrimary = Color(0xFF645B55)
private val BrandGreySecondary = Color(0xFFA09D99)
// Page and card tones follow Android's own Settings: a cool light grey page with
// near-white cards, close enough in value that the cards sit in the page rather than
// popping off it.
private val BrandLightGrey = Color(0xFFEAEEF4)
private val BrandCardWhite = Color(0xFFF8F9FD)
private val BrandWhite80 = Color(0xFFEFF2F7)

private val LightColorScheme = lightColorScheme(
    primary = BrandOrange,
    onPrimary = Color.White,
    primaryContainer = BrandWhite80,
    onPrimaryContainer = BrandBlack,
    secondary = BrandBlack,
    onSecondary = Color.White,
    secondaryContainer = BrandLightGrey,
    onSecondaryContainer = BrandBlack,
    tertiary = BrandGreyPrimary,
    onTertiary = Color.White,
    tertiaryContainer = BrandLightGrey,
    onTertiaryContainer = BrandBlack,
    error = Color(0xFFFF3B30),
    onError = Color.White,
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
    background = BrandLightGrey,
    onBackground = BrandBlack,
    surface = BrandCardWhite,
    onSurface = BrandBlack,
    surfaceVariant = BrandWhite80,
    onSurfaceVariant = BrandGreyPrimary,
    outline = BrandGreySecondary,
    outlineVariant = BrandBlack15,
    inverseSurface = BrandBlack,
    inverseOnSurface = Color.White,
    inversePrimary = BrandOrange,
    surfaceTint = BrandOrange,
)

private val DarkColorScheme = darkColorScheme(
    primary = Color(0xFFFFB18A),
    onPrimary = BrandBlack,
    primaryContainer = BrandOrangePressed,
    onPrimaryContainer = Color.White,
    secondary = BrandWhite80,
    onSecondary = BrandBlack,
    secondaryContainer = Color(0xFF2A241F),
    onSecondaryContainer = BrandWhite80,
    tertiary = BrandGreySecondary,
    onTertiary = BrandBlack,
    tertiaryContainer = BrandGreyPrimary,
    onTertiaryContainer = Color.White,
    error = Color(0xFFFF453A),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    background = BrandBlack,
    onBackground = Color.White,
    surface = Color(0xFF1E1710),
    onSurface = Color.White,
    surfaceVariant = Color(0xFF2A241F),
    onSurfaceVariant = Color(0xFFD1CFCC),
    outline = BrandGreySecondary,
    outlineVariant = BrandGreyPrimary,
    inverseSurface = BrandLightGrey,
    inverseOnSurface = BrandBlack,
    inversePrimary = BrandOrange,
    surfaceTint = BrandOrange,
)

private val FigtreeFontFamily = FontFamily(
    Font(R.font.figtree_variable, FontWeight.Normal),
    Font(R.font.figtree_variable, FontWeight.Medium),
    Font(R.font.figtree_variable, FontWeight.SemiBold),
    Font(R.font.figtree_variable, FontWeight.Bold),
    Font(R.font.figtree_variable, FontWeight.ExtraBold),
)

private fun figtreeStyle(
    size: Int,
    lineHeight: Int,
    weight: FontWeight = FontWeight.SemiBold
) = TextStyle(
    fontFamily = FigtreeFontFamily,
    fontWeight = weight,
    fontSize = size.sp,
    lineHeight = lineHeight.sp,
    letterSpacing = 0.sp
)

private val AIDictationTypography = Typography(
    displayLarge = figtreeStyle(size = 72, lineHeight = 79, weight = FontWeight.Bold),
    displayMedium = figtreeStyle(size = 48, lineHeight = 53, weight = FontWeight.Bold),
    displaySmall = figtreeStyle(size = 32, lineHeight = 38),
    headlineLarge = figtreeStyle(size = 32, lineHeight = 38),
    headlineMedium = figtreeStyle(size = 24, lineHeight = 29),
    headlineSmall = figtreeStyle(size = 24, lineHeight = 29),
    titleLarge = figtreeStyle(size = 20, lineHeight = 24),
    titleMedium = figtreeStyle(size = 16, lineHeight = 19, weight = FontWeight.Bold),
    titleSmall = figtreeStyle(size = 14, lineHeight = 17),
    bodyLarge = figtreeStyle(size = 20, lineHeight = 24),
    bodyMedium = figtreeStyle(size = 16, lineHeight = 21),
    bodySmall = figtreeStyle(size = 14, lineHeight = 17),
    labelLarge = figtreeStyle(size = 16, lineHeight = 19, weight = FontWeight.Bold),
    labelMedium = figtreeStyle(size = 14, lineHeight = 17),
    labelSmall = figtreeStyle(size = 12, lineHeight = 14)
)

/**
 * Keeps a user-selected accent usable as the control color: very dark accents
 * disappear against dark surfaces (e.g. the Black bubble color while the system
 * is in dark mode or battery saver), very light ones against light surfaces.
 */
private fun readableAccent(accent: Color, darkTheme: Boolean): Color {
    val luminance = accent.luminance()
    return when {
        darkTheme && luminance < 0.08f -> lerp(accent, Color.White, 0.5f)
        !darkTheme && luminance > 0.85f -> lerp(accent, BrandBlack, 0.4f)
        else -> accent
    }
}

private fun onColorFor(color: Color): Color {
    return if (color.luminance() > 0.5f) BrandBlack else Color.White
}

@Composable
fun AIDictationTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    accentColor: Color = BrandOrange,
    content: @Composable () -> Unit
) {
    val baseColorScheme = if (darkTheme) DarkColorScheme else LightColorScheme
    val accent = readableAccent(accentColor, darkTheme)
    // Containers are composited to opaque colors so their on-colors keep a
    // predictable contrast regardless of what they are drawn over.
    val primaryContainer = if (darkTheme) {
        accent.copy(alpha = 0.72f).compositeOver(DarkColorScheme.surface)
    } else {
        accent.copy(alpha = 0.12f).compositeOver(LightColorScheme.surface)
    }
    val colorScheme = baseColorScheme.copy(
        primary = accent,
        onPrimary = onColorFor(accent),
        primaryContainer = primaryContainer,
        onPrimaryContainer = onColorFor(primaryContainer),
        inversePrimary = accent,
        surfaceTint = accent
    )

    MaterialTheme(
        colorScheme = colorScheme,
        typography = AIDictationTypography,
        content = content
    )
}
