package com.whispermate.aidictation.ui.screens.transcription

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.domain.model.DictionaryEntry
import com.whispermate.aidictation.domain.model.Shortcut
import com.whispermate.aidictation.domain.model.ToneStyle
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class TranscriptionSettingsViewModel @Inject constructor(
    private val appPreferences: AppPreferences
) : ViewModel() {

    val dictionaryEntries: StateFlow<List<DictionaryEntry>> = appPreferences.dictionaryEntries
        .stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

    val toneStyles: StateFlow<List<ToneStyle>> = appPreferences.toneStyles
        .stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

    val shortcuts: StateFlow<List<Shortcut>> = appPreferences.shortcuts
        .stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

    // Dictionary operations
    fun addDictionaryEntry(trigger: String, replacement: String?) {
        viewModelScope.launch {
            val current = appPreferences.dictionaryEntries.first().toMutableList()
            current.add(0, DictionaryEntry(trigger = trigger, replacement = replacement))
            appPreferences.saveDictionaryEntries(current)
        }
    }

    fun toggleDictionaryEntry(entry: DictionaryEntry) {
        viewModelScope.launch {
            val current = appPreferences.dictionaryEntries.first().toMutableList()
            val index = current.indexOfFirst { it.id == entry.id }
            if (index != -1) {
                current[index] = current[index].copy(isEnabled = !current[index].isEnabled)
                appPreferences.saveDictionaryEntries(current)
            }
        }
    }

    fun deleteDictionaryEntry(entry: DictionaryEntry) {
        viewModelScope.launch {
            val current = appPreferences.dictionaryEntries.first().toMutableList()
            current.removeAll { it.id == entry.id }
            appPreferences.saveDictionaryEntries(current)
        }
    }

    fun restoreDefaultDictionaryEntries() {
        viewModelScope.launch {
            val current = appPreferences.dictionaryEntries.first().toMutableList()
            AppPreferences.defaultDictionaryEntries
                .filterNot { default ->
                    current.any {
                        it.trigger == default.trigger &&
                            it.replacement == default.replacement
                    }
                }
                .forEach { current.add(it) }
            appPreferences.saveDictionaryEntries(current)
        }
    }

    // Tone Style operations
    fun addToneStyle(name: String, appPackageNames: List<String>, instructions: String) {
        viewModelScope.launch {
            val current = appPreferences.toneStyles.first().toMutableList()
            current.add(0, ToneStyle(name = name, appPackageNames = appPackageNames, instructions = instructions))
            appPreferences.saveToneStyles(current)
        }
    }

    fun toggleToneStyle(style: ToneStyle) {
        viewModelScope.launch {
            val current = appPreferences.toneStyles.first().toMutableList()
            val index = current.indexOfFirst { it.id == style.id }
            if (index != -1) {
                current[index] = current[index].copy(isEnabled = !current[index].isEnabled)
                appPreferences.saveToneStyles(current)
            }
        }
    }

    fun deleteToneStyle(style: ToneStyle) {
        viewModelScope.launch {
            val current = appPreferences.toneStyles.first().toMutableList()
            current.removeAll { it.id == style.id }
            appPreferences.saveToneStyles(current)
        }
    }

    fun restoreDefaultToneStyles() {
        viewModelScope.launch {
            val current = appPreferences.toneStyles.first().toMutableList()
            AppPreferences.defaultContextRules
                .filterNot { default ->
                    current.any {
                        it.name == default.name &&
                            it.instructions == default.instructions
                    }
                }
                .forEach { current.add(it) }
            appPreferences.saveToneStyles(current)
        }
    }

    // Shortcut operations
    fun addShortcut(voiceTrigger: String, expansion: String) {
        viewModelScope.launch {
            val current = appPreferences.shortcuts.first().toMutableList()
            current.add(0, Shortcut(voiceTrigger = voiceTrigger, expansion = expansion))
            appPreferences.saveShortcuts(current)
        }
    }

    fun toggleShortcut(shortcut: Shortcut) {
        viewModelScope.launch {
            val current = appPreferences.shortcuts.first().toMutableList()
            val index = current.indexOfFirst { it.id == shortcut.id }
            if (index != -1) {
                current[index] = current[index].copy(isEnabled = !current[index].isEnabled)
                appPreferences.saveShortcuts(current)
            }
        }
    }

    fun deleteShortcut(shortcut: Shortcut) {
        viewModelScope.launch {
            val current = appPreferences.shortcuts.first().toMutableList()
            current.removeAll { it.id == shortcut.id }
            appPreferences.saveShortcuts(current)
        }
    }

    fun restoreDefaultShortcuts() {
        viewModelScope.launch {
            val current = appPreferences.shortcuts.first().toMutableList()
            AppPreferences.defaultShortcuts
                .filterNot { default ->
                    current.any {
                        it.voiceTrigger == default.voiceTrigger &&
                            it.expansion == default.expansion
                    }
                }
                .forEach { current.add(it) }
            appPreferences.saveShortcuts(current)
        }
    }
}
