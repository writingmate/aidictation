package com.whispermate.aidictation.ui.permissions

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.whispermate.aidictation.service.KeyboardProbeWindow
import com.whispermate.aidictation.service.OverlayDictationAccessibilityService

/**
 * The three permissions the floating mic needs, read and requested from one place so
 * onboarding, Settings and the shortcut activity agree on what "granted" means.
 */
object OverlayPermissions {

    fun hasMicrophone(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    /** Whether the dictation accessibility service is switched on in Android settings. */
    fun isAccessibilityServiceEnabled(context: Context): Boolean {
        val enabled = Settings.Secure.getInt(
            context.contentResolver,
            Settings.Secure.ACCESSIBILITY_ENABLED,
            0
        ) == 1
        if (!enabled) return false

        val enabledServices = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        val expected = ComponentName(context, OverlayDictationAccessibilityService::class.java)
        return enabledServices.split(':').any { serviceId ->
            ComponentName.unflattenFromString(serviceId) == expected
        }
    }

    fun canDrawOverlays(context: Context): Boolean = KeyboardProbeWindow.canDrawOverlays(context)

    fun read(context: Context): PermissionsState = PermissionsState(
        microphone = hasMicrophone(context),
        accessibility = isAccessibilityServiceEnabled(context),
        overlay = canDrawOverlays(context)
    )

    fun openAccessibilitySettings(context: Context) {
        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        context.startActivity(intent)
    }

    fun openDisplayOverAppsSettings(context: Context) {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${context.packageName}")
        ).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        context.startActivity(intent)
    }
}

/** Snapshot of the three permissions. Microphone and accessibility are required to dictate. */
data class PermissionsState(
    val microphone: Boolean,
    val accessibility: Boolean,
    val overlay: Boolean
) {
    val canContinue: Boolean
        get() = microphone && accessibility
}

/** What the line under the Continue button should say. */
enum class PermissionsHint {
    NeedMicAndAccessibility,
    NeedMic,
    NeedAccessibility,
    OverlayLater,
    AllSet
}

fun permissionsHint(state: PermissionsState): PermissionsHint = when {
    !state.microphone && !state.accessibility -> PermissionsHint.NeedMicAndAccessibility
    !state.microphone -> PermissionsHint.NeedMic
    !state.accessibility -> PermissionsHint.NeedAccessibility
    !state.overlay -> PermissionsHint.OverlayLater
    else -> PermissionsHint.AllSet
}
