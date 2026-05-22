package com.whispermate.aidictation.data.preferences

import android.content.Context
import android.content.SharedPreferences
import android.util.TypedValue

object OverlayBubblePreferences {
    const val PREFS_NAME = "overlay_bubble"
    const val X_KEY = "bubble_x"
    const val Y_KEY = "bubble_y"
    const val HIDDEN_KEY = "bubble_hidden"
    const val SNOOZE_UNTIL_MS_KEY = "bubble_snooze_until_ms"
    const val COLOR_KEY = "bubble_color"

    const val SYSTEM_COLOR: Int = Int.MIN_VALUE
    val DEFAULT_COLOR: Int = 0xFFFF6300.toInt()
    val BLACK_COLOR: Int = 0xFF000000.toInt()

    val PRESET_COLORS = intArrayOf(
        SYSTEM_COLOR,
        DEFAULT_COLOR,
        0xFFE11D48.toInt(),
        0xFF7C3AED.toInt(),
        0xFF2563EB.toInt(),
        0xFF0D9488.toInt(),
        BLACK_COLOR
    )

    fun prefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun getBubbleColor(context: Context): Int {
        return prefs(context).getInt(COLOR_KEY, DEFAULT_COLOR)
    }

    fun getResolvedBubbleColor(context: Context): Int {
        val selectedColor = getBubbleColor(context)
        if (selectedColor != SYSTEM_COLOR) return selectedColor

        return getResolvedSystemColor(context)
    }

    fun getResolvedSystemColor(context: Context): Int {
        val systemAccentResource = context.resources.getIdentifier(
            "system_accent1_600",
            "color",
            "android"
        )
        if (systemAccentResource != 0) {
            runCatching {
                return context.getColor(systemAccentResource).withOpaqueAlpha()
            }
        }

        val typedValue = TypedValue()
        val resolved = context.theme.resolveAttribute(android.R.attr.colorAccent, typedValue, true)
        return if (resolved) {
            typedValue.data.withOpaqueAlpha()
        } else {
            DEFAULT_COLOR
        }
    }

    fun setBubbleColor(context: Context, color: Int) {
        val value = if (color == SYSTEM_COLOR) color else color.withOpaqueAlpha()
        prefs(context).edit().putInt(COLOR_KEY, value).apply()
    }

    fun isSuppressed(context: Context): Boolean {
        val prefs = prefs(context)
        if (prefs.getBoolean(HIDDEN_KEY, false)) return true

        val snoozeUntil = prefs.getLong(SNOOZE_UNTIL_MS_KEY, 0L)
        if (snoozeUntil <= 0L) return false
        if (System.currentTimeMillis() < snoozeUntil) return true

        prefs.edit().remove(SNOOZE_UNTIL_MS_KEY).apply()
        return false
    }

    fun restore(context: Context) {
        prefs(context)
            .edit()
            .remove(HIDDEN_KEY)
            .remove(SNOOZE_UNTIL_MS_KEY)
            .apply()
    }

    private fun Int.withOpaqueAlpha(): Int {
        return this or 0xFF000000.toInt()
    }
}
