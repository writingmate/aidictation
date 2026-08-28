package com.whispermate.aidictation.data.repository

import com.whispermate.aidictation.data.local.ParakeetTranscriber
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import com.whispermate.aidictation.data.preferences.ApiProvider
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.remote.LanguagePostProcessClient
import com.whispermate.aidictation.data.remote.TranscriptionClient
import com.whispermate.aidictation.data.remote.CapturedTranscriptionCleanupContext
import com.whispermate.aidictation.data.remote.CleanupReplacement
import com.whispermate.aidictation.data.remote.TranscriptionCleanupPrompt
import com.whispermate.aidictation.data.remote.preserveRawOnCleanupFailure
import com.whispermate.aidictation.domain.model.WhisperLanguages
import com.whispermate.aidictation.domain.model.DictionaryEntry
import com.whispermate.aidictation.domain.model.Shortcut
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Immutable transcription settings captured before the recorder starts. An in-flight attempt must
 * never switch provider, model, language, vocabulary, cleanup rules, or shortcut expansions when the
 * user changes Settings while audio is being captured or processed.
 */
data class TranscriptionAttemptConfiguration(
    val provider: ApiProvider,
    val useLocalRecognition: Boolean,
    val cleanupEnabled: Boolean,
    val languageNames: List<String>,
    val cleanupLanguageNames: List<String>,
    val transcriptionPrompt: String?,
    val postProcessingPrompt: String?,
    val contextRules: String?,
    val requestSnapshot: TranscriptionClient.RequestSnapshot,
    val cleanupContext: CapturedTranscriptionCleanupContext
)

@Singleton
class TranscriptionRepository @Inject constructor(
    private val appPreferences: AppPreferences,
    private val parakeetTranscriber: ParakeetTranscriber
) {
    private companion object {
        const val CLEANUP_TIMEOUT_MS = 35_000L
    }

    /**
     * Loads the DataStore-backed inputs used to freeze an attempt configuration. The actual
     * immutable snapshot is still captured at tap time, but it no longer has to pay the first-read
     * disk cost while the user is waiting for the microphone.
     */
    suspend fun prewarmCaptureSettings() {
        appPreferences.selectedLanguages.first()
        appPreferences.onDeviceTranscriptionEnabled.first()
        appPreferences.dictionaryEntries.first()
        appPreferences.shortcuts.first()
    }

    suspend fun prewarmOnDeviceIfEnabled(): Result<Unit> {
        val onDeviceTranscription = appPreferences.onDeviceTranscriptionEnabled.first()
        val transcriptionConfig = ApiConfigManager.instance?.getTranscriptionConfig()
        val provider = transcriptionConfig?.provider ?: ApiProvider.WRITINGMATE

        if (!onDeviceTranscription && provider != ApiProvider.PARAKEET) {
            return Result.success(Unit)
        }

        return parakeetTranscriber.prewarm()
    }

    fun abandonLocalRecognition() {
        parakeetTranscriber.abandonCurrentGeneration()
    }

    suspend fun captureAttemptConfiguration(
        additionalPrompt: String? = null,
        contextRules: String? = null
    ): TranscriptionAttemptConfiguration {
        val languages = appPreferences.selectedLanguages.first()
            .filter { WhisperLanguages.getLanguage(it) != null }
            .distinct()
        val onDeviceRequested = appPreferences.onDeviceTranscriptionEnabled.first()
        val dictionary = appPreferences.dictionaryEntries.first()
            .filter { it.isEnabled }
        val shortcuts = appPreferences.shortcuts.first()
            .filter { it.isEnabled }

        val requiresCloud = languages.any { WhisperLanguages.requiresCloudTranscription(it) }
        if (requiresCloud) {
            appPreferences.setOnDeviceTranscriptionEnabled(false)
            ApiConfigManager.instance?.switchTranscriptionToCloud()
        }
        val transcriptionConfig = ApiConfigManager.instance?.getTranscriptionConfig()
        val provider = transcriptionConfig?.provider ?: ApiProvider.WRITINGMATE
        val useLocalRecognition = !requiresCloud && (onDeviceRequested || provider == ApiProvider.PARAKEET)
        // Cleanup remains core infrastructure after both local and cloud recognition. If its
        // separately bounded request is unavailable, preserveRawOnCleanupFailure returns raw text.
        val cleanupEnabled = true
        val languageNames = languages.mapNotNull { WhisperLanguages.getName(it) }
        val cleanupLanguageNames = if (useLocalRecognition) {
            languages
                .filter { WhisperLanguages.isReliableOffline(it) }
                .mapNotNull { WhisperLanguages.getName(it) }
                .takeIf { it.isNotEmpty() }
                ?: listOf("English")
        } else {
            languageNames.takeIf { it.isNotEmpty() } ?: listOf("auto")
        }
        val cleanupContext = captureTranscriptionCleanupContext(
            dictionary = dictionary,
            shortcuts = shortcuts,
            formattingInstructions = listOfNotNull(contextRules?.takeIf(String::isNotBlank)),
            appContext = additionalPrompt,
            languageContext = cleanupLanguageNames
        )
        val transcriptionPrompt = TranscriptionCleanupPrompt.speechRecognitionHints(cleanupContext)
        val postProcessingPrompt = if (cleanupEnabled) {
            TranscriptionCleanupPrompt.systemPrompt(cleanupContext)
        } else {
            null
        }

        return TranscriptionAttemptConfiguration(
            provider = provider,
            useLocalRecognition = useLocalRecognition,
            cleanupEnabled = cleanupEnabled,
            languageNames = languageNames.toList(),
            cleanupLanguageNames = cleanupLanguageNames.toList(),
            transcriptionPrompt = transcriptionPrompt,
            postProcessingPrompt = postProcessingPrompt,
            contextRules = contextRules?.takeIf(String::isNotBlank),
            requestSnapshot = TranscriptionClient.captureRequestSnapshot(),
            cleanupContext = cleanupContext
        )
    }

    suspend fun transcribe(
        audioFile: File,
        configuration: TranscriptionAttemptConfiguration,
        checkpoint: suspend (mergedText: String, completedLeafCount: Int) -> Boolean = { _, _ -> true },
        rawComplete: suspend (rawText: String) -> Boolean = { true }
    ): Result<String> {
        val transcriptionPrompt = configuration.transcriptionPrompt

        if (configuration.useLocalRecognition) {
            val raw = parakeetTranscriber.transcribe(audioFile)
                .getOrElse { return Result.failure(it) }
            if (raw.isBlank()) return Result.failure(IllegalStateException("No speech was recognized"))
            if (!checkpoint(raw, 1)) return Result.failure(IllegalStateException("Transcription could not be saved"))
            if (!rawComplete(raw)) return Result.failure(IllegalStateException("Transcription could not be saved"))
            return if (configuration.cleanupEnabled) {
                val cleaned = preserveRawOnCleanupFailure(raw) {
                    withTimeout(CLEANUP_TIMEOUT_MS) {
                        LanguagePostProcessClient.postProcess(
                            candidates = mapOf("auto" to raw),
                            languageNames = configuration.cleanupLanguageNames,
                            cleanupInstructions = configuration.postProcessingPrompt,
                            requestSnapshot = configuration.requestSnapshot
                        )
                    }
                }
                Result.success(cleaned)
            } else {
                Result.success(raw)
            }
        }

        if (configuration.provider == ApiProvider.WRITINGMATE) {
            return TranscriptionClient.transcribe(
                audioFile = audioFile,
                prompt = transcriptionPrompt,
                language = null,
                sttPrompt = transcriptionPrompt,
                postProcessingPrompt = null,
                oneStageCleanup = false,
                requestSnapshot = configuration.requestSnapshot,
                checkpoint = checkpoint,
                rawComplete = rawComplete
            )
        }

        return if (configuration.cleanupEnabled) {
            val raw = TranscriptionClient.transcribe(
                audioFile,
                transcriptionPrompt,
                null,
                sttPrompt = transcriptionPrompt,
                requestSnapshot = configuration.requestSnapshot,
                checkpoint = checkpoint,
                rawComplete = rawComplete
            )
                .getOrElse { return Result.failure(it) }
            val cleaned = preserveRawOnCleanupFailure(raw) {
                withTimeout(CLEANUP_TIMEOUT_MS) {
                    LanguagePostProcessClient.postProcess(
                        candidates = mapOf("auto" to raw),
                        languageNames = configuration.cleanupLanguageNames,
                        cleanupInstructions = configuration.postProcessingPrompt,
                        requestSnapshot = configuration.requestSnapshot
                    )
                }
            }
            Result.success(cleaned)
        } else {
            TranscriptionClient.transcribe(
                audioFile,
                transcriptionPrompt,
                null,
                sttPrompt = transcriptionPrompt,
                requestSnapshot = configuration.requestSnapshot,
                checkpoint = checkpoint,
                rawComplete = rawComplete
            )
        }
    }

    suspend fun buildPrompt(): String {
        val dictionary = appPreferences.dictionaryEntries.first().filter { it.isEnabled }
        val shortcuts = appPreferences.shortcuts.first().filter { it.isEnabled }
        val context = captureTranscriptionCleanupContext(
            dictionary = dictionary,
            shortcuts = shortcuts,
            formattingInstructions = emptyList(),
            appContext = null,
            languageContext = emptyList()
        )
        return TranscriptionCleanupPrompt.speechRecognitionHints(context).orEmpty()
    }

}

private fun containsWhitespace(value: String): Boolean = value.any(Char::isWhitespace)

internal fun captureTranscriptionCleanupContext(
    dictionary: List<DictionaryEntry>,
    shortcuts: List<Shortcut>,
    formattingInstructions: List<String>,
    appContext: String?,
    languageContext: List<String>
): CapturedTranscriptionCleanupContext {
    val vocabularyOnly = dictionary.filter { it.replacement.isNullOrBlank() }
    return CapturedTranscriptionCleanupContext(
        vocabulary = vocabularyOnly.map { it.trigger }.filterNot(::containsWhitespace),
        phrases = vocabularyOnly.map { it.trigger }.filter(::containsWhitespace),
        explicitReplacements = dictionary.mapNotNull { entry ->
            entry.replacement?.takeIf(String::isNotBlank)
                ?.let { CleanupReplacement(entry.trigger, it) }
        },
        shortcutExpansions = shortcuts.map { CleanupReplacement(it.voiceTrigger, it.expansion) },
        formattingInstructions = formattingInstructions,
        appContext = appContext?.takeIf(String::isNotBlank),
        languageContext = languageContext
    )
}
