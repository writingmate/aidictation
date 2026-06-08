package com.whispermate.aidictation

import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import com.whispermate.aidictation.data.preferences.OverlayBubblePreferences
import com.whispermate.aidictation.data.repository.AuthRepository
import com.whispermate.aidictation.service.OverlayDictationAccessibilityService
import com.whispermate.aidictation.ui.AIDictationNavHost
import com.whispermate.aidictation.ui.theme.AIDictationTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.launch

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var authRepository: AuthRepository

    private var shouldStartRecording by mutableStateOf(false)
    private var appAccentColor by mutableIntStateOf(OverlayBubblePreferences.DEFAULT_COLOR)
    private var overlayPreferenceListener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        handleIntent(intent)
        appAccentColor = OverlayBubblePreferences.getResolvedBubbleColor(this)
        registerOverlayColorListener()
        enableEdgeToEdge()
        setContent {
            AIDictationTheme(accentColor = Color(appAccentColor)) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    AIDictationNavHost(
                        shouldStartRecording = shouldStartRecording,
                        onRecordingStarted = { shouldStartRecording = false }
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        appAccentColor = OverlayBubblePreferences.getResolvedBubbleColor(this)
    }

    override fun onDestroy() {
        overlayPreferenceListener?.let {
            OverlayBubblePreferences.prefs(this).unregisterOnSharedPreferenceChangeListener(it)
        }
        overlayPreferenceListener = null
        super.onDestroy()
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == OverlayDictationAccessibilityService.ACTION_START_DICTATION) {
            shouldStartRecording = true
        }
        intent?.data?.let { uri ->
            if (uri.scheme == "aidictation" && uri.host == "auth-callback") {
                lifecycleScope.launch {
                    authRepository.handleAuthCallback(uri)
                }
            }
        }
    }

    private fun registerOverlayColorListener() {
        val prefs = OverlayBubblePreferences.prefs(this)
        overlayPreferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == OverlayBubblePreferences.COLOR_KEY) {
                appAccentColor = OverlayBubblePreferences.getResolvedBubbleColor(this)
            }
        }
        prefs.registerOnSharedPreferenceChangeListener(overlayPreferenceListener)
    }
}
