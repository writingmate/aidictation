package com.whispermate.aidictation.data.repository

import android.app.Application
import com.squareup.moshi.Moshi
import com.whispermate.aidictation.BuildConfig
import com.whispermate.aidictation.data.local.ParakeetModelAssets
import com.whispermate.aidictation.data.local.ParakeetTranscriber
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import com.whispermate.aidictation.data.preferences.ApiProvider
import com.whispermate.aidictation.data.preferences.AppPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class TranscriptionModeSelectionTest {
    @Test
    fun cloudModeDoesNotLoadTheBundledOfflineEngine() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val preferences = AppPreferences(context, Moshi.Builder().build())
        val apiConfig = ApiConfigManager()
        val repository = TranscriptionRepository(preferences, ParakeetTranscriber(ParakeetModelAssets(context)))
        preferences.saveSelectedLanguages(listOf("en"))
        preferences.setOnDeviceTranscriptionEnabled(false)
        preferences.setPostProcessingEnabled(true)

        val cloud = repository.captureAttemptConfiguration()
        assertFalse("${BuildConfig.PARAKEET_RUNTIME} overrode cloud mode", cloud.useLocalRecognition)
        assertEquals(ApiProvider.WRITINGMATE, apiConfig.getTranscriptionConfig().provider)
        assertEquals(BuildConfig.TRANSCRIPTION_ENDPOINT, cloud.requestSnapshot.endpoint)
        assertEquals(BuildConfig.TRANSCRIPTION_MODEL, cloud.requestSnapshot.model)
        assertTrue(cloud.cleanupEnabled)
        // No offline assets are installed in this test. Cloud prewarming must not request them.
        assertTrue(repository.prewarmOnDeviceIfEnabled().isSuccess)
    }

    @Test
    fun switchingOfflineModeOffTakesEffectOnTheNextRecording() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val preferences = AppPreferences(context, Moshi.Builder().build())
        ApiConfigManager()
        val repository = TranscriptionRepository(preferences, ParakeetTranscriber(ParakeetModelAssets(context)))
        preferences.saveSelectedLanguages(listOf("en"))
        preferences.setOnDeviceTranscriptionEnabled(true)
        val offline = repository.captureAttemptConfiguration()
        assertTrue(offline.useLocalRecognition)
        assertFalse("Offline mode must not send text to cloud cleanup by default", offline.cleanupEnabled)
        assertNull(offline.postProcessingPrompt)

        preferences.setPostProcessingEnabled(true)
        assertTrue("Offline cleanup is an explicit opt-in", repository.captureAttemptConfiguration().cleanupEnabled)
        preferences.setPostProcessingEnabled(false)

        preferences.setOnDeviceTranscriptionEnabled(false)
        val cloud = repository.captureAttemptConfiguration()
        assertFalse(cloud.useLocalRecognition)
        assertTrue("The active recording keeps its captured mode", offline.useLocalRecognition)
        assertTrue("Cloud mode keeps its own cleanup setting, on by default", cloud.cleanupEnabled)
        assertFalse("The active recording keeps its captured cleanup choice", offline.cleanupEnabled)
    }
}
