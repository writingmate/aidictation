package com.whispermate.aidictation

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import com.whispermate.aidictation.service.OverlayDictationAccessibilityService
import com.whispermate.aidictation.ui.permissions.OverlayPermissions

/**
 * A transparent activity that handles the shortcut intent.
 * It immediately starts the service and finishes to return focus
 * to the previously active app.
 */
class ShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        try {
            if (isAccessibilityServiceEnabled()) {
                val serviceIntent = Intent(this, OverlayDictationAccessibilityService::class.java)
                serviceIntent.action = OverlayDictationAccessibilityService.ACTION_START_DICTATION
                startService(serviceIntent)
            } else {
                Toast.makeText(this, "Please enable AIDictation accessibility service", Toast.LENGTH_LONG).show()
                val intent = Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                }
                startActivity(intent)
            }
        } finally {
            finish()
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean =
        OverlayPermissions.isAccessibilityServiceEnabled(this)
}
