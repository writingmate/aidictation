package com.whispermate.aidictation.data.preferences

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.squareup.moshi.Moshi
import com.squareup.moshi.Types
import com.whispermate.aidictation.R
import com.whispermate.aidictation.domain.model.Command
import com.whispermate.aidictation.domain.model.ContextRule
import com.whispermate.aidictation.domain.model.DictionaryEntry
import com.whispermate.aidictation.domain.model.FREE_MONTHLY_WORD_LIMIT
import com.whispermate.aidictation.domain.model.Shortcut
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.Calendar
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "settings")

@Singleton
class AppPreferences @Inject constructor(
    @ApplicationContext private val context: Context,
    private val moshi: Moshi
) {
    private object Keys {
        val HAS_COMPLETED_ONBOARDING = booleanPreferencesKey("has_completed_onboarding")
        val DICTIONARY_ENTRIES = stringPreferencesKey("dictionary_entries")
        val TONE_STYLES = stringPreferencesKey("tone_styles")
        val CONTEXT_RULES = stringPreferencesKey("context_rules")
        val SHORTCUTS = stringPreferencesKey("shortcuts")
        val COMMANDS = stringPreferencesKey("commands")
        val API_KEY = stringPreferencesKey("api_key")
        val SELECTED_LANGUAGES = stringPreferencesKey("selected_languages")
        val MULTILINGUAL_ENABLED = booleanPreferencesKey("multilingual_enabled")
        val POST_PROCESSING_ENABLED = booleanPreferencesKey("post_processing_enabled")
        val LOCAL_MONTHLY_WORD_COUNT = intPreferencesKey("local_monthly_word_count")
        val LOCAL_WORD_COUNT_RESET_AT = longPreferencesKey("local_word_count_reset_at")
    }

    data class LocalUsage(
        val wordCount: Int,
        val resetAtMillis: Long
    )

    // Selected Languages
    private val stringListType = Types.newParameterizedType(List::class.java, String::class.java)
    private val stringListAdapter = moshi.adapter<List<String>>(stringListType)

    val selectedLanguages: Flow<List<String>> = context.dataStore.data.map { preferences ->
        val json = preferences[Keys.SELECTED_LANGUAGES]
        if (json.isNullOrEmpty()) {
            emptyList()
        } else {
            stringListAdapter.fromJson(json) ?: emptyList()
        }
    }

    suspend fun saveSelectedLanguages(languages: List<String>) {
        context.dataStore.edit { preferences ->
            preferences[Keys.SELECTED_LANGUAGES] = stringListAdapter.toJson(languages)
        }
    }

    val multilingualEnabled: Flow<Boolean> = context.dataStore.data.map { preferences ->
        preferences[Keys.MULTILINGUAL_ENABLED] ?: true
    }

    suspend fun setMultilingualEnabled(enabled: Boolean) {
        context.dataStore.edit { preferences ->
            preferences[Keys.MULTILINGUAL_ENABLED] = enabled
        }
    }

    val postProcessingEnabled: Flow<Boolean> = context.dataStore.data.map { preferences ->
        preferences[Keys.POST_PROCESSING_ENABLED] ?: true
    }

    suspend fun setPostProcessingEnabled(enabled: Boolean) {
        context.dataStore.edit { preferences ->
            preferences[Keys.POST_PROCESSING_ENABLED] = enabled
        }
    }

    val localUsage: Flow<LocalUsage> = context.dataStore.data.map { preferences ->
        LocalUsage(
            wordCount = preferences[Keys.LOCAL_MONTHLY_WORD_COUNT] ?: 0,
            resetAtMillis = preferences[Keys.LOCAL_WORD_COUNT_RESET_AT] ?: nextMonthStartMillis()
        )
    }

    suspend fun checkAndResetLocalUsageIfNeeded() {
        context.dataStore.edit { preferences ->
            val resetAt = preferences[Keys.LOCAL_WORD_COUNT_RESET_AT] ?: nextMonthStartMillis()
            if (System.currentTimeMillis() >= resetAt) {
                preferences[Keys.LOCAL_MONTHLY_WORD_COUNT] = 0
                preferences[Keys.LOCAL_WORD_COUNT_RESET_AT] = nextMonthStartMillis()
            } else if (preferences[Keys.LOCAL_WORD_COUNT_RESET_AT] == null) {
                preferences[Keys.LOCAL_WORD_COUNT_RESET_AT] = resetAt
            }
        }
    }

    suspend fun getLocalWordCount(): Int {
        checkAndResetLocalUsageIfNeeded()
        return localUsage.first().wordCount
    }

    suspend fun addLocalWords(count: Int) {
        if (count <= 0) return
        checkAndResetLocalUsageIfNeeded()
        context.dataStore.edit { preferences ->
            val current = preferences[Keys.LOCAL_MONTHLY_WORD_COUNT] ?: 0
            preferences[Keys.LOCAL_MONTHLY_WORD_COUNT] = (current + count).coerceAtLeast(0)
            if (preferences[Keys.LOCAL_WORD_COUNT_RESET_AT] == null) {
                preferences[Keys.LOCAL_WORD_COUNT_RESET_AT] = nextMonthStartMillis()
            }
        }
    }

    suspend fun hasReachedLocalFreeLimit(): Boolean {
        return getLocalWordCount() >= FREE_MONTHLY_WORD_LIMIT
    }

    // Onboarding
    val hasCompletedOnboarding: Flow<Boolean> = context.dataStore.data.map { preferences ->
        preferences[Keys.HAS_COMPLETED_ONBOARDING] ?: false
    }

    suspend fun setOnboardingCompleted(completed: Boolean) {
        context.dataStore.edit { preferences ->
            preferences[Keys.HAS_COMPLETED_ONBOARDING] = completed
        }
    }

    // Dictionary Entries
    private val dictionaryEntryListType = Types.newParameterizedType(List::class.java, DictionaryEntry::class.java)
    private val dictionaryEntryAdapter = moshi.adapter<List<DictionaryEntry>>(dictionaryEntryListType)

    val dictionaryEntries: Flow<List<DictionaryEntry>> = context.dataStore.data.map { preferences ->
        val json = preferences[Keys.DICTIONARY_ENTRIES]
        if (json.isNullOrEmpty()) {
            defaultDictionaryEntries
        } else {
            dictionaryEntryAdapter.fromJson(json) ?: defaultDictionaryEntries
        }
    }

    suspend fun saveDictionaryEntries(entries: List<DictionaryEntry>) {
        context.dataStore.edit { preferences ->
            preferences[Keys.DICTIONARY_ENTRIES] = dictionaryEntryAdapter.toJson(entries)
        }
    }

    // Context Rules (previously called ToneStyles)
    private val contextRuleListType = Types.newParameterizedType(List::class.java, ContextRule::class.java)
    private val contextRuleAdapter = moshi.adapter<List<ContextRule>>(contextRuleListType)

    val contextRules: Flow<List<ContextRule>> = context.dataStore.data.map { preferences ->
        // Try new key first, then fall back to old key for migration
        val json = preferences[Keys.CONTEXT_RULES] ?: preferences[Keys.TONE_STYLES]
        if (json.isNullOrEmpty()) {
            defaultContextRules
        } else {
            contextRuleAdapter.fromJson(json) ?: defaultContextRules
        }
    }

    suspend fun saveContextRules(rules: List<ContextRule>) {
        context.dataStore.edit { preferences ->
            preferences[Keys.CONTEXT_RULES] = contextRuleAdapter.toJson(rules)
        }
    }

    // Backward compatibility aliases
    val toneStyles: Flow<List<ContextRule>> get() = contextRules

    suspend fun saveToneStyles(styles: List<ContextRule>) = saveContextRules(styles)

    /**
     * Get combined instructions for a specific app package.
     * Returns instructions from all matching enabled rules:
     * - Rules with empty appPackageNames (apply to all apps)
     * - Rules that match the current app's package name
     */
    suspend fun getInstructionsForApp(packageName: String?): String? {
        val rules = contextRules.first()

        val matchingRules = rules.filter { rule ->
            if (!rule.isEnabled) return@filter false

            // If no app restrictions, apply to all
            if (rule.appPackageNames.isEmpty()) return@filter true

            // Check if current app matches
            packageName != null && rule.appPackageNames.contains(packageName)
        }

        if (matchingRules.isEmpty()) return null

        return matchingRules.joinToString(". ") { it.instructions }
    }

    // Shortcuts
    private val shortcutListType = Types.newParameterizedType(List::class.java, Shortcut::class.java)
    private val shortcutAdapter = moshi.adapter<List<Shortcut>>(shortcutListType)

    val shortcuts: Flow<List<Shortcut>> = context.dataStore.data.map { preferences ->
        val json = preferences[Keys.SHORTCUTS]
        if (json.isNullOrEmpty()) {
            defaultShortcuts
        } else {
            shortcutAdapter.fromJson(json) ?: defaultShortcuts
        }
    }

    suspend fun saveShortcuts(shortcuts: List<Shortcut>) {
        context.dataStore.edit { preferences ->
            preferences[Keys.SHORTCUTS] = shortcutAdapter.toJson(shortcuts)
        }
    }

    // Commands
    private val commandListType = Types.newParameterizedType(List::class.java, Command::class.java)
    private val commandAdapter = moshi.adapter<List<Command>>(commandListType)

    val commands: Flow<List<Command>> = context.dataStore.data.map { preferences ->
        val json = preferences[Keys.COMMANDS]
        if (json.isNullOrEmpty()) {
            defaultCommands
        } else {
            mergeDefaultBuiltInCommands(commandAdapter.fromJson(json) ?: defaultCommands)
        }
    }

    suspend fun saveCommands(commands: List<Command>) {
        context.dataStore.edit { preferences ->
            preferences[Keys.COMMANDS] = commandAdapter.toJson(commands)
        }
    }

    /**
     * Get all enabled commands for voice detection.
     */
    suspend fun getEnabledCommands(): List<Command> {
        return commands.first().filter { it.isEnabled }
    }

    /**
     * Get commands that have toolbar buttons.
     */
    suspend fun getToolbarCommands(): List<Command> {
        return commands.first().filter { it.isEnabled && it.iconRes != null }
    }

    companion object {
        val defaultDictionaryEntries = listOf(
            DictionaryEntry(trigger = "AI dictation", replacement = "AIDictation", isEnabled = false),
            DictionaryEntry(trigger = "open AI", replacement = "OpenAI", isEnabled = false),
            DictionaryEntry(trigger = "chat GPT", replacement = "ChatGPT", isEnabled = false),
            DictionaryEntry(trigger = "API", replacement = null, isEnabled = false),
            DictionaryEntry(trigger = "iOS", replacement = null, isEnabled = false),
            DictionaryEntry(trigger = "JSON", replacement = null, isEnabled = false),
        )

        val defaultShortcuts = listOf(
            Shortcut(voiceTrigger = "my email", expansion = "your.email@example.com", isEnabled = false),
            Shortcut(voiceTrigger = "my phone", expansion = "+1 (555) 123-4567", isEnabled = false),
            Shortcut(voiceTrigger = "my address", expansion = "123 Main Street, City, State 12345", isEnabled = false),
        )

        val defaultContextRules = listOf(
            // Speech cleanup rules (global, apply to all apps)
            ContextRule(
                name = "Remove filler words",
                appPackageNames = emptyList(),
                instructions = "Remove filler words like 'um', 'uh', 'like', 'you know', 'basically', 'actually'.",
                isEnabled = false
            ),
            ContextRule(
                name = "Clean up repetitions",
                appPackageNames = emptyList(),
                instructions = "Clean up stutters and repeated words or phrases.",
                isEnabled = false
            ),
            ContextRule(
                name = "Fix self-corrections",
                appPackageNames = emptyList(),
                instructions = "When someone corrects themselves mid-sentence ('no actually', 'I mean', 'wait'), keep only the final corrected version.",
                isEnabled = false
            ),
            ContextRule(
                name = "Remove hedging",
                appPackageNames = emptyList(),
                instructions = "Remove hedging language like 'I think', 'maybe', 'sort of', 'kind of'.",
                isEnabled = false
            ),
            ContextRule(
                name = "Remove weak phrases",
                appPackageNames = emptyList(),
                instructions = "Remove weak phrases like 'I mean', talking in circles, unnecessary qualifiers.",
                isEnabled = false
            ),
            ContextRule(
                name = "Reduce adverbs",
                appPackageNames = emptyList(),
                instructions = "Reduce overused adverbs like 'really', 'very', 'literally'.",
                isEnabled = false
            ),
        )

        val defaultCommands = listOf(
            Command(
                id = "cleanup",
                name = "Cleanup",
                voiceTriggers = listOf("clean this up", "clean up", "fix grammar", "fix this"),
                systemPrompt = "Clean up the text. Fix grammar, spelling, and punctuation errors. Remove filler words and make it read naturally. Preserve the original meaning and tone.",
                iconRes = R.drawable.ic_cleanup,
                isBuiltIn = true,
                isEnabled = true
            ),
            Command(
                id = "rewrite",
                name = "Rewrite",
                voiceTriggers = listOf("rewrite this", "rewrite it", "rephrase this"),
                systemPrompt = "Rewrite the text to be clearer and more concise while preserving the original meaning.",
                iconRes = null,
                isBuiltIn = true,
                isEnabled = true
            ),
            Command(
                id = "shorten",
                name = "Shorten",
                voiceTriggers = listOf("make it shorter", "shorten this", "shorter"),
                systemPrompt = "Make the text shorter while keeping the key points and meaning intact.",
                iconRes = null,
                isBuiltIn = true,
                isEnabled = true
            ),
            Command(
                id = "expand",
                name = "Expand",
                voiceTriggers = listOf("expand this", "make it longer", "expand"),
                systemPrompt = "Expand the text with more detail while maintaining the same tone and style.",
                iconRes = null,
                isBuiltIn = true,
                isEnabled = true
            ),
            Command(
                id = "bullet_list",
                name = "Bullet list",
                voiceTriggers = listOf("make this a bullet list", "format as bullets", "bullet list", "bullets"),
                systemPrompt = "Format the text as a concise bullet list. Preserve the original meaning and do not add facts.",
                iconRes = null,
                isBuiltIn = true,
                isEnabled = true
            ),
            Command(
                id = "numbered_list",
                name = "Numbered list",
                voiceTriggers = listOf("make this a numbered list", "format as a numbered list", "numbered list"),
                systemPrompt = "Format the text as a concise numbered list. Preserve the original meaning and do not add facts.",
                iconRes = null,
                isBuiltIn = true,
                isEnabled = true
            ),
        )
    }

    private fun mergeDefaultBuiltInCommands(commands: List<Command>): List<Command> {
        val existingIds = commands.map { it.id }.toSet()
        val missingDefaults = defaultCommands.filter { it.id !in existingIds }
        return commands + missingDefaults
    }

    private fun nextMonthStartMillis(): Long {
        val calendar = Calendar.getInstance()
        calendar.set(Calendar.DAY_OF_MONTH, 1)
        calendar.set(Calendar.HOUR_OF_DAY, 0)
        calendar.set(Calendar.MINUTE, 0)
        calendar.set(Calendar.SECOND, 0)
        calendar.set(Calendar.MILLISECOND, 0)
        calendar.add(Calendar.MONTH, 1)
        return calendar.timeInMillis
    }
}
