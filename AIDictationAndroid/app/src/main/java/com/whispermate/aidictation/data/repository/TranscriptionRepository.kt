package com.whispermate.aidictation.data.repository

import com.whispermate.aidictation.data.local.ParakeetTranscriber
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import com.whispermate.aidictation.data.preferences.ApiProvider
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.remote.LanguagePostProcessClient
import com.whispermate.aidictation.data.remote.TranscriptionClient
import com.whispermate.aidictation.domain.model.WhisperLanguages
import kotlinx.coroutines.flow.first
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TranscriptionRepository @Inject constructor(
    private val appPreferences: AppPreferences,
    private val parakeetTranscriber: ParakeetTranscriber
) {
    suspend fun prewarmOnDeviceIfEnabled(): Result<Unit> {
        val onDeviceTranscription = appPreferences.onDeviceTranscriptionEnabled.first()
        val transcriptionConfig = ApiConfigManager.instance?.getTranscriptionConfig()
        val provider = transcriptionConfig?.provider ?: ApiProvider.WRITINGMATE

        if (!onDeviceTranscription && provider != ApiProvider.PARAKEET) {
            return Result.success(Unit)
        }

        return parakeetTranscriber.prewarm()
    }

    suspend fun transcribe(
        audioFile: File,
        prompt: String? = null,
        contextRules: String? = null
    ): Result<String> {
        val languages = appPreferences.selectedLanguages.first()
        val multilingual = true
        val onDeviceTranscription = appPreferences.onDeviceTranscriptionEnabled.first()
        val postProcess = !onDeviceTranscription
        val requiresCloud = languages.any { WhisperLanguages.requiresCloudTranscription(it) }
        if (requiresCloud) {
            appPreferences.setOnDeviceTranscriptionEnabled(false)
            ApiConfigManager.instance?.switchTranscriptionToCloud()
        }
        val transcriptionConfig = ApiConfigManager.instance?.getTranscriptionConfig()
        val provider = transcriptionConfig?.provider ?: ApiProvider.WRITINGMATE

        if (!requiresCloud && (onDeviceTranscription || provider == ApiProvider.PARAKEET)) {
            val raw = parakeetTranscriber.transcribe(audioFile)
                .getOrElse { return Result.failure(it) }
            return if (postProcess) {
                val languageNames = languages
                    .filter { WhisperLanguages.isReliableOffline(it) }
                    .mapNotNull { WhisperLanguages.getName(it) }
                    .takeIf { it.isNotEmpty() }
                    ?: listOf("English")
                Result.success(LanguagePostProcessClient.postProcess(mapOf("auto" to raw), languageNames, contextRules))
            } else {
                Result.success(raw)
            }
        }

        val language = apiLanguageFor(multilingual, languages)
        val languageNames = languages.mapNotNull { WhisperLanguages.getName(it) }
        val transcriptionPrompt = buildLanguageAwarePrompt(prompt, languageNames)
        val postProcessingPrompt = if (postProcess) {
            buildPostProcessingPrompt(transcriptionPrompt, contextRules)
        } else {
            null
        }
        if (provider == ApiProvider.WRITINGMATE) {
            return TranscriptionClient.transcribe(
                audioFile = audioFile,
                prompt = transcriptionPrompt,
                language = language,
                sttPrompt = transcriptionPrompt,
                postProcessingPrompt = postProcessingPrompt
            )
        }

        return if (postProcess) {
            val raw = TranscriptionClient.transcribe(audioFile, transcriptionPrompt, language, sttPrompt = transcriptionPrompt)
                .getOrElse { return Result.failure(it) }
            val postProcessLanguageNames = languageNames.takeIf { multilingual && it.isNotEmpty() } ?: listOf("auto")
            Result.success(LanguagePostProcessClient.postProcess(mapOf("auto" to raw), postProcessLanguageNames, contextRules))
        } else {
            TranscriptionClient.transcribe(audioFile, transcriptionPrompt, language, sttPrompt = transcriptionPrompt)
        }
    }

    private fun apiLanguageFor(multilingual: Boolean, languages: List<String>): String? {
        if (!multilingual) return null
        val validLanguages = languages.filter { WhisperLanguages.getLanguage(it) != null }
        return validLanguages.singleOrNull()
    }

    suspend fun buildPrompt(): String {
        val dictionary = appPreferences.dictionaryEntries.first()
            .filter { it.isEnabled }
            .map { it.replacement?.takeIf { replacement -> replacement.isNotBlank() } ?: it.trigger }

        val shortcuts = appPreferences.shortcuts.first()
            .filter { it.isEnabled }
            .map { it.voiceTrigger }

        val parts = mutableListOf<String>()

        if (dictionary.isNotEmpty()) {
            parts.add("Vocabulary: ${dictionary.joinToString(", ")}")
        }

        if (shortcuts.isNotEmpty()) {
            parts.add("Phrases: ${shortcuts.joinToString(", ")}")
        }

        return parts.joinToString(". ")
    }

    private fun buildPostProcessingPrompt(prompt: String?, contextRules: String?): String? {
        return listOfNotNull(
            prompt?.takeIf { it.isNotBlank() },
            contextRules?.takeIf { it.isNotBlank() }
        ).joinToString("\n").ifBlank { null }
    }

    private fun buildLanguageAwarePrompt(prompt: String?, languageNames: List<String>): String? {
        val languageHint = languageNames
            .takeIf { it.size > 1 }
            ?.joinToString(", ")
            ?.let { "The speaker will use one of these selected languages: $it. Detect the spoken language from the audio and transcribe it in that same language." }

        return listOfNotNull(
            languageHint,
            prompt?.takeIf { it.isNotBlank() }
        ).joinToString("\n").ifBlank { null }
    }

    suspend fun applyPostProcessing(text: String): String {
        return applyLocalTextExpansions(text)
    }

    private suspend fun applyLocalTextExpansions(text: String): String {
        var result = text
        val shortcuts = appPreferences.shortcuts.first()
            .filter { it.isEnabled }
            .sortedByDescending { it.voiceTrigger.length }

        for (shortcut in shortcuts) {
            result = result.replace(shortcut.voiceTrigger, shortcut.expansion, ignoreCase = true)
        }

        return result
    }
}
