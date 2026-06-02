package com.whispermate.aidictation.util

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import com.whispermate.aidictation.data.preferences.OverlayBubblePreferences

object LauncherIconSwitcher {
    private val aliases = listOf(
        ".LauncherDefault",
        ".LauncherRed",
        ".LauncherPurple",
        ".LauncherBlue",
        ".LauncherTeal",
        ".LauncherBlack"
    )

    fun applyColor(context: Context, color: Int) {
        val targetAlias = aliasForColor(color)
        val packageManager = context.packageManager
        val activeAlias = aliases.firstOrNull { alias ->
            isAliasEnabled(context, packageManager, alias)
        } ?: ".LauncherDefault"

        if (activeAlias == targetAlias) return

        val target = ComponentName(context.packageName, context.packageName + targetAlias)

        packageManager.setComponentEnabledSetting(
            target,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )

        packageManager.setComponentEnabledSetting(
            ComponentName(context.packageName, context.packageName + activeAlias),
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
    }

    private fun isAliasEnabled(
        context: Context,
        packageManager: PackageManager,
        alias: String
    ): Boolean {
        val state = packageManager.getComponentEnabledSetting(
            ComponentName(context.packageName, context.packageName + alias)
        )
        return state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED ||
            (alias == ".LauncherDefault" && state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT)
    }

    private fun aliasForColor(color: Int): String {
        return when (color) {
            0xFFE11D48.toInt() -> ".LauncherRed"
            0xFF7C3AED.toInt() -> ".LauncherPurple"
            0xFF2563EB.toInt() -> ".LauncherBlue"
            0xFF0D9488.toInt() -> ".LauncherTeal"
            OverlayBubblePreferences.BLACK_COLOR -> ".LauncherBlack"
            else -> ".LauncherDefault"
        }
    }
}
