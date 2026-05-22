package com.whispermate.aidictation.ui

import android.util.Log
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.whispermate.aidictation.ui.screens.language.LanguageSettingsScreen
import com.whispermate.aidictation.ui.screens.main.MainScreen
import com.whispermate.aidictation.ui.screens.main.RecordingDetailScreen
import com.whispermate.aidictation.ui.screens.onboarding.OnboardingScreen
import com.whispermate.aidictation.ui.screens.onboarding.OnboardingViewModel
import com.whispermate.aidictation.ui.screens.transcription.TranscriptionSettingsScreen

sealed class Screen(val route: String) {
    data object Onboarding : Screen("onboarding")
    data object Main : Screen("main")
    data object PostProcessingSettings : Screen("post_processing_settings")
    data object LanguageSettings : Screen("language_settings")
    data object RecordingDetail : Screen("recording_detail/{recordingId}") {
        fun createRoute(recordingId: String) = "recording_detail/$recordingId"
    }
}

@Composable
fun AIDictationNavHost(
    navController: NavHostController = rememberNavController(),
    shouldStartRecording: Boolean = false,
    onRecordingStarted: () -> Unit = {}
) {
    val onboardingViewModel: OnboardingViewModel = hiltViewModel()
    val hasCompletedOnboarding by onboardingViewModel.hasCompletedOnboarding.collectAsState()
    val onboardingOnDeviceTranscriptionEnabled by onboardingViewModel.onDeviceTranscriptionEnabled.collectAsState()
    val onboardingOnDeviceModelState by onboardingViewModel.onDeviceModelState.collectAsState()
    val onboardingSelectedLanguages by onboardingViewModel.selectedLanguages.collectAsState()

    val startDestination = if (hasCompletedOnboarding) Screen.Main.route else Screen.Onboarding.route

    LaunchedEffect(shouldStartRecording) {
        if (shouldStartRecording && hasCompletedOnboarding) {
            navController.navigate(Screen.Main.route) {
                popUpTo(Screen.Main.route) { inclusive = true }
            }
        }
    }

    NavHost(
        navController = navController,
        startDestination = startDestination
    ) {
        composable(Screen.Onboarding.route) {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = MaterialTheme.colorScheme.background,
                contentColor = MaterialTheme.colorScheme.onBackground
            ) {
                OnboardingScreen(
                    onComplete = {
                        onboardingViewModel.completeOnboarding()
                        navController.navigate(Screen.Main.route) {
                            popUpTo(Screen.Onboarding.route) { inclusive = true }
                        }
                    },
                    onSaveContextRules = { enabledStates ->
                        onboardingViewModel.saveContextRulesFromOnboarding(enabledStates)
                    },
                    selectedLanguageCodes = onboardingSelectedLanguages,
                    onToggleLanguage = onboardingViewModel::toggleLanguage,
                    onDeviceTranscriptionEnabled = onboardingOnDeviceTranscriptionEnabled,
                    onDeviceModelState = onboardingOnDeviceModelState,
                    onSetOnDeviceTranscriptionEnabled = onboardingViewModel::setOnDeviceTranscriptionEnabled
                )
            }
        }

        composable(Screen.Main.route) {
            MainScreen(
                onNavigateToPostProcessingSettings = {
                    navController.navigate(Screen.PostProcessingSettings.route)
                },
                onNavigateToLanguageSettings = {
                    navController.navigate(Screen.LanguageSettings.route)
                },
                onNavigateToRecordingDetail = { recordingId ->
                    Log.d("Navigation", "Navigating to recording detail: $recordingId")
                    navController.navigate(Screen.RecordingDetail.createRoute(recordingId))
                },
                shouldStartRecording = shouldStartRecording,
                onRecordingStarted = onRecordingStarted
            )
        }

        composable(Screen.PostProcessingSettings.route) {
            TranscriptionSettingsScreen(
                onNavigateBack = { navController.popBackStack() }
            )
        }

        composable(Screen.LanguageSettings.route) {
            LanguageSettingsScreen(
                onNavigateBack = { navController.popBackStack() }
            )
        }

        composable(
            route = Screen.RecordingDetail.route,
            arguments = listOf(navArgument("recordingId") { type = NavType.StringType })
        ) { backStackEntry ->
            val recordingId = backStackEntry.arguments?.getString("recordingId") ?: return@composable
            RecordingDetailScreen(
                recordingId = recordingId,
                onNavigateBack = { navController.popBackStack() }
            )
        }
    }
}
