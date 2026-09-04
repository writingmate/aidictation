package com.whispermate.aidictation.ui.screens.language

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.TextButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.whispermate.aidictation.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LanguageSettingsScreen(
    onNavigateBack: () -> Unit,
    viewModel: LanguageSettingsViewModel = hiltViewModel()
) {
    val languages by viewModel.languages.collectAsState()
    val searchQuery by viewModel.searchQuery.collectAsState()
    var pendingCloudLanguage by remember { mutableStateOf<LanguageItem?>(null) }

    pendingCloudLanguage?.let { item ->
        val isCloudRecommended = item.localModeReason == LocalModeReason.CloudRecommended
        AlertDialog(
            onDismissRequest = { pendingCloudLanguage = null },
            title = { Text("Switch to cloud transcription?") },
            text = {
                Text(
                    if (isCloudRecommended) {
                        "${item.language.englishName} has lower offline accuracy. AI Dictation will switch transcription to cloud mode and then select ${item.language.englishName}."
                    } else {
                        "${item.language.englishName} is not available in offline mode. AI Dictation will switch transcription to cloud mode and then select ${item.language.englishName}."
                    }
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.toggleLanguage(item.language.code)
                        pendingCloudLanguage = null
                    }
                ) {
                    Text("Switch to Cloud")
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingCloudLanguage = null }) {
                    Text("Cancel")
                }
            }
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_languages)) },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back)
                        )
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { viewModel.setSearchQuery(it) },
                placeholder = { Text(stringResource(R.string.language_search_hint)) },
                leadingIcon = {
                    Icon(
                        imageVector = Icons.Default.Search,
                        contentDescription = null
                    )
                },
                singleLine = true,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
            )

            Text(
                text = stringResource(R.string.language_selection_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
            )

            Spacer(modifier = Modifier.height(4.dp))

            if (languages.isEmpty()) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = stringResource(R.string.language_no_results),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else {
                LazyColumn {
                    items(languages, key = { it.language.code }) { item ->
                        LanguageRow(
                            englishName = item.language.englishName,
                            nativeName = item.language.nativeName,
                            isSelected = item.isSelected,
                            localModeReason = item.localModeReason,
                            onClick = {
                                if (item.localModeReason != LocalModeReason.Available) {
                                    pendingCloudLanguage = item
                                } else {
                                    viewModel.toggleLanguage(item.language.code)
                                }
                            }
                        )
                        HorizontalDivider(modifier = Modifier.padding(start = 72.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun LanguageRow(
    englishName: String,
    nativeName: String,
    isSelected: Boolean,
    localModeReason: LocalModeReason,
    onClick: () -> Unit
) {
    val switchesToCloud = localModeReason != LocalModeReason.Available
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .alpha(if (switchesToCloud && !isSelected) 0.72f else 1f)
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(
                checked = isSelected,
                onCheckedChange = { onClick() }
            )
            Spacer(modifier = Modifier.width(8.dp))
            Column {
                Text(
                    text = englishName,
                    style = MaterialTheme.typography.bodyLarge
                )
                if (nativeName != englishName) {
                    Text(
                        text = nativeName,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                if (switchesToCloud && !isSelected) {
                    Text(
                        text = if (localModeReason == LocalModeReason.CloudRecommended) {
                            "Cloud recommended"
                        } else {
                            "Cloud only"
                        },
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}
