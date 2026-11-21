package com.whispermate.aidictation

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import com.revenuecat.purchases.ui.revenuecatui.PaywallDialog
import com.revenuecat.purchases.ui.revenuecatui.PaywallDialogOptions
import com.whispermate.aidictation.data.billing.PRO_ENTITLEMENT
import com.whispermate.aidictation.data.repository.AuthRepository
import com.whispermate.aidictation.data.repository.SubscriptionRepository
import com.whispermate.aidictation.telemetry.InstallationAnalytics
import com.whispermate.aidictation.service.OverlayDictationAccessibilityService
import com.whispermate.aidictation.ui.AIDictationNavHost
import com.whispermate.aidictation.ui.theme.AIDictationTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.launch

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var authRepository: AuthRepository
    @Inject lateinit var installationAnalytics: InstallationAnalytics
    @Inject lateinit var subscriptionRepository: SubscriptionRepository

    private var shouldStartRecording by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        handleIntent(intent)
        enableEdgeToEdge()
        setContent {
            AIDictationTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    AIDictationNavHost(
                        shouldStartRecording = shouldStartRecording,
                        onRecordingStarted = { shouldStartRecording = false }
                    )
                    val paywallRequested by subscriptionRepository.paywallRequested.collectAsState()
                    if (paywallRequested) {
                        // RevenueCat's paywall for the current offering. It stays closed for
                        // an account that already holds the entitlement.
                        PaywallDialog(
                            remember {
                                PaywallDialogOptions.Builder()
                                    .setRequiredEntitlementIdentifier(PRO_ENTITLEMENT)
                                    .setDismissRequest(subscriptionRepository::onStoreScreenClosed)
                                    .build()
                            }
                        )
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        installationAnalytics.appOpened()
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
}
