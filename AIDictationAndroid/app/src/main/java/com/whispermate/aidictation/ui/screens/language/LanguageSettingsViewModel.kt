package com.whispermate.aidictation.ui.screens.language

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import com.whispermate.aidictation.data.preferences.ApiProvider
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.domain.model.WhisperLanguage
import com.whispermate.aidictation.domain.model.WhisperLanguages
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

data class LanguageItem(
    val language: WhisperLanguage,
    val isSelected: Boolean,
    val localModeReason: LocalModeReason
)

enum class LocalModeReason {
    Available,
    CloudRecommended,
    CloudOnly
}

@HiltViewModel
class LanguageSettingsViewModel @Inject constructor(
    private val appPreferences: AppPreferences
) : ViewModel() {

    val searchQuery = MutableStateFlow("")

    private val initialOrdering = MutableStateFlow<Set<String>?>(null)
    private val isParakeetMode: Boolean
        get() = ApiConfigManager.instance?.getTranscriptionConfig()?.provider == ApiProvider.PARAKEET
    init {
        viewModelScope.launch {
            val selected = appPreferences.selectedLanguages.first()
            initialOrdering.value = selected.toSet()
        }
    }

    val languages: StateFlow<List<LanguageItem>> = combine(
        appPreferences.selectedLanguages,
        searchQuery,
        initialOrdering
    ) { selected, query, initial ->
        val selectedSet = selected.toSet()
        val orderingSet = initial ?: selectedSet
        WhisperLanguages.all
            .filter { lang ->
                if (query.isBlank()) true
                else lang.englishName.contains(query, ignoreCase = true) ||
                    lang.nativeName.contains(query, ignoreCase = true)
            }
            .sortedWith(compareByDescending { it.code in orderingSet })
            .map { lang ->
                LanguageItem(
                    language = lang,
                    isSelected = lang.code in selectedSet,
                    localModeReason = if (!isParakeetMode) {
                        LocalModeReason.Available
                    } else if (!lang.supportsParakeet) {
                        LocalModeReason.CloudOnly
                    } else if (WhisperLanguages.requiresCloudTranscription(lang.code)) {
                        LocalModeReason.CloudRecommended
                    } else {
                        LocalModeReason.Available
                    }
                )
            }
    }.stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

    fun toggleLanguage(code: String) {
        viewModelScope.launch {
            if (isParakeetMode && !WhisperLanguages.isReliableOffline(code)) {
                appPreferences.setOnDeviceTranscriptionEnabled(false)
                ApiConfigManager.instance?.switchTranscriptionToCloud()
            }
            val current = appPreferences.selectedLanguages.first().toMutableList()
            if (current.contains(code)) {
                current.remove(code)
            } else {
                current.add(code)
            }
            appPreferences.saveSelectedLanguages(current)
        }
    }

    fun setSearchQuery(query: String) {
        searchQuery.value = query
    }
}
