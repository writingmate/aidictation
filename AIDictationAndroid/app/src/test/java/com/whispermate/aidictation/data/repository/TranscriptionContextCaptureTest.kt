package com.whispermate.aidictation.data.repository

import com.whispermate.aidictation.data.remote.CleanupReplacement
import com.whispermate.aidictation.data.remote.TranscriptionCleanupPrompt
import com.whispermate.aidictation.domain.model.DictionaryEntry
import com.whispermate.aidictation.domain.model.Shortcut
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TranscriptionContextCaptureTest {
    @Test
    fun vocabularyPhrasesReplacementsExpansionsAndAppRulesReachCleanup() {
        val context = captureTranscriptionCleanupContext(
            dictionary = listOf(
                DictionaryEntry(trigger = "NovaFlow"),
                DictionaryEntry(trigger = "Kestrel Works"),
                DictionaryEntry(trigger = "nova flow", replacement = "NovaFlow")
            ),
            shortcuts = listOf(
                Shortcut(voiceTrigger = "q b r", expansion = "quarterly business review")
            ),
            formattingInstructions = listOf("Use short paragraphs."),
            appContext = "Mail compose field",
            languageContext = listOf("British English")
        )

        assertEquals(listOf("NovaFlow"), context.vocabulary)
        assertEquals(listOf("Kestrel Works"), context.phrases)
        assertEquals(
            listOf(CleanupReplacement("nova flow", "NovaFlow")),
            context.explicitReplacements
        )
        assertEquals(
            listOf(CleanupReplacement("q b r", "quarterly business review")),
            context.shortcutExpansions
        )
        assertEquals(listOf("Use short paragraphs."), context.formattingInstructions)
        assertEquals("Mail compose field", context.appContext)
        assertEquals(listOf("British English"), context.languageContext)

        val prompt = TranscriptionCleanupPrompt.systemPrompt(context)
        listOf(
            "NovaFlow",
            "Kestrel Works",
            "nova flow → NovaFlow",
            "q b r → quarterly business review",
            "Use short paragraphs.",
            "Mail compose field",
            "British English"
        ).forEach { assertTrue("cleanup prompt lost $it", prompt.contains(it)) }
    }
}
