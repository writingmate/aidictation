package com.whispermate.aidictation.data.preferences

import android.content.Context
import android.content.SharedPreferences

object OverlayBubblePreferences {
    const val PREFS_NAME = "overlay_bubble"
    const val X_KEY = "bubble_x"
    const val Y_KEY = "bubble_y"
    const val HIDDEN_KEY = "bubble_hidden"
    const val SNOOZE_UNTIL_MS_KEY = "bubble_snooze_until_ms"
    fun prefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
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
}
