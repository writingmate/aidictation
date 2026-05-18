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
        val multilingual = appPreferences.multilingualEnabled.first()
        val postProcess = appPreferences.postProcessingEnabled.first()
        val onDeviceTranscription = appPreferences.onDeviceTranscriptionEnabled.first()
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
        val forcedLanguages = apiLanguagesFor(multilingual, languages)
        if (provider == ApiProvider.WRITINGMATE) {
            if (forcedLanguages.size > 1) {
                val candidates = TranscriptionClient.transcribeForLanguages(
                    audioFile = audioFile,
                    languages = forcedLanguages,
                    prompt = prompt,
                    sttPrompt = prompt,
                    postProcessingPrompt = if (postProcess) {
                        buildPostProcessingPrompt(prompt, contextRules)
                    } else {
                        null
                    }
                )
                val namedCandidates = candidates.withLanguageNames()
                val languageNames = forcedLanguages.mapNotNull { WhisperLanguages.getName(it) }
                return Result.success(LanguagePostProcessClient.postProcess(namedCandidates, languageNames, contextRules))
            }
            return TranscriptionClient.transcribe(
                audioFile = audioFile,
                prompt = prompt,
                language = language,
                sttPrompt = prompt,
                postProcessingPrompt = if (postProcess) {
                    buildPostProcessingPrompt(prompt, contextRules)
                } else {
                    null
                }
            )
        }

        return if (forcedLanguages.size > 1) {
            val candidates = TranscriptionClient.transcribeForLanguages(audioFile, forcedLanguages, prompt)
            val namedCandidates = candidates.withLanguageNames()
            val languageNames = forcedLanguages.mapNotNull { WhisperLanguages.getName(it) }
            Result.success(LanguagePostProcessClient.postProcess(namedCandidates, languageNames, contextRules))
        } else if (postProcess) {
            val raw = TranscriptionClient.transcribe(audioFile, prompt, language)
                .getOrElse { return Result.failure(it) }
            val languageNames = languages.mapNotNull { WhisperLanguages.getName(it) }
                .takeIf { multilingual && it.isNotEmpty() }
                ?: listOf("auto")
            Result.success(LanguagePostProcessClient.postProcess(mapOf("auto" to raw), languageNames, contextRules))
        } else {
            TranscriptionClient.transcribe(audioFile, prompt, language)
        }
    }

    private fun apiLanguageFor(multilingual: Boolean, languages: List<String>): String? {
        if (!multilingual) return null
        val validLanguages = languages.filter { WhisperLanguages.getLanguage(it) != null }
        return validLanguages.singleOrNull()
    }

    private fun apiLanguagesFor(multilingual: Boolean, languages: List<String>): List<String> {
        if (!multilingual) return emptyList()
        return languages.filter { WhisperLanguages.getLanguage(it) != null }.distinct()
    }

    private fun Map<String, String>.withLanguageNames(): Map<String, String> =
        mapKeys { (code, _) -> WhisperLanguages.getName(code) ?: code }

    suspend fun buildPrompt(): String {
        val dictionary = appPreferences.dictionaryEntries.first()
            .filter { it.isEnabled }
            .map { it.trigger }

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

    suspend fun applyPostProcessing(text: String): String {
        if (appPreferences.onDeviceTranscriptionEnabled.first()) {
            return applyLocalTextExpansions(text)
        }

        val provider = ApiConfigManager.instance?.getTranscriptionConfig()?.provider ?: ApiProvider.WRITINGMATE
        if (provider == ApiProvider.WRITINGMATE) return text

        return applyLocalTextExpansions(text)
    }

    private suspend fun applyLocalTextExpansions(text: String): String {
        var result = text
        val dictionary = appPreferences.dictionaryEntries.first()
            .filter { it.isEnabled && it.replacement != null }
            .sortedByDescending { it.trigger.length }

        for (entry in dictionary) {
            result = result.replace(entry.trigger, entry.replacement!!, ignoreCase = true)
        }

        val shortcuts = appPreferences.shortcuts.first()
            .filter { it.isEnabled }
            .sortedByDescending { it.voiceTrigger.length }

        for (shortcut in shortcuts) {
            result = result.replace(shortcut.voiceTrigger, shortcut.expansion, ignoreCase = true)
        }

        return result
    }
}
