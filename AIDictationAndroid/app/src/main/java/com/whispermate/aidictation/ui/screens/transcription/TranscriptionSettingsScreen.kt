package com.whispermate.aidictation.ui.screens.transcription

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.whispermate.aidictation.R
import com.whispermate.aidictation.domain.model.DictionaryEntry
import com.whispermate.aidictation.domain.model.Shortcut
import com.whispermate.aidictation.domain.model.ToneStyle
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TranscriptionSettingsScreen(
    onNavigateBack: () -> Unit,
    viewModel: TranscriptionSettingsViewModel = hiltViewModel()
) {
    val scope = rememberCoroutineScope()
    val pagerState = rememberPagerState(pageCount = { 3 })

    val dictionaryEntries by viewModel.dictionaryEntries.collectAsState()
    val toneStyles by viewModel.toneStyles.collectAsState()
    val shortcuts by viewModel.shortcuts.collectAsState()

    val tabs = listOf(
        stringResource(R.string.transcription_dictionary),
        stringResource(R.string.transcription_tone_style),
        stringResource(R.string.transcription_shortcuts)
    )

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_post_processing_settings)) },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back"
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
            TabRow(
                selectedTabIndex = pagerState.currentPage
            ) {
                tabs.forEachIndexed { index, title ->
                    Tab(
                        selected = pagerState.currentPage == index,
                        onClick = {
                            scope.launch {
                                pagerState.animateScrollToPage(index)
                            }
                        },
                        text = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    )
                }
            }

            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxSize()
            ) { page ->
                when (page) {
                    0 -> DictionaryTab(
                        entries = dictionaryEntries,
                        onAdd = { trigger, replacement ->
                            viewModel.addDictionaryEntry(trigger, replacement.ifEmpty { null })
                        },
                        onToggle = { viewModel.toggleDictionaryEntry(it) },
                        onDelete = { viewModel.deleteDictionaryEntry(it) },
                        onRestoreDefaults = { viewModel.restoreDefaultDictionaryEntries() }
                    )
                    1 -> ToneStyleTab(
                        styles = toneStyles,
                        onAdd = { name, packages, instructions ->
                            viewModel.addToneStyle(name, packages, instructions)
                        },
                        onToggle = { viewModel.toggleToneStyle(it) },
                        onDelete = { viewModel.deleteToneStyle(it) },
                        onRestoreDefaults = { viewModel.restoreDefaultToneStyles() }
                    )
                    2 -> ShortcutsTab(
                        shortcuts = shortcuts,
                        onAdd = { trigger, expansion ->
                            viewModel.addShortcut(trigger, expansion)
                        },
                        onToggle = { viewModel.toggleShortcut(it) },
                        onDelete = { viewModel.deleteShortcut(it) },
                        onRestoreDefaults = { viewModel.restoreDefaultShortcuts() }
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DictionaryTab(
    entries: List<DictionaryEntry>,
    onAdd: (String, String) -> Unit,
    onToggle: (DictionaryEntry) -> Unit,
    onDelete: (DictionaryEntry) -> Unit,
    onRestoreDefaults: () -> Unit
) {
    var trigger by remember { mutableStateOf("") }
    var replacement by remember { mutableStateOf("") }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // Add new entry section
        item {
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            ) {
                Column(
                    modifier = Modifier.padding(16.dp)
                ) {
                    OutlinedTextField(
                        value = trigger,
                        onValueChange = { trigger = it },
                        label = { Text(stringResource(R.string.dictionary_trigger)) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    OutlinedTextField(
                        value = replacement,
                        onValueChange = { replacement = it },
                        label = { Text(stringResource(R.string.dictionary_replacement)) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    Button(
                        onClick = {
                            if (trigger.isNotEmpty()) {
                                onAdd(trigger, replacement)
                                trigger = ""
                                replacement = ""
                            }
                        },
                        enabled = trigger.isNotEmpty(),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.Add, contentDescription = null)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(stringResource(R.string.dictionary_add))
                    }
                }
            }
        }

        item {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 4.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = stringResource(R.string.dictionary_footer),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                Button(onClick = onRestoreDefaults) {
                    Text(stringResource(R.string.restore_defaults))
                }
            }
        }

        items(entries, key = { it.id }) { entry ->
            DictionaryEntryItem(
                entry = entry,
                onToggle = { onToggle(entry) },
                onDelete = { onDelete(entry) }
            )
        }
    }
}

@Composable
private fun DictionaryEntryItem(
    entry: DictionaryEntry,
    onToggle: () -> Unit,
    onDelete: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = entry.trigger,
                    style = MaterialTheme.typography.bodyLarge
                )
                entry.replacement?.let {
                    Text(
                        text = "→ $it",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            Switch(
                checked = entry.isEnabled,
                onCheckedChange = { onToggle() }
            )
            IconButton(onClick = onDelete) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = stringResource(R.string.delete_entry)
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ToneStyleTab(
    styles: List<ToneStyle>,
    onAdd: (String, List<String>, String) -> Unit,
    onToggle: (ToneStyle) -> Unit,
    onDelete: (ToneStyle) -> Unit,
    onRestoreDefaults: () -> Unit
) {
    var showAddSheet by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState()

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(
                    onClick = { showAddSheet = true },
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Default.Add, contentDescription = null)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(stringResource(R.string.tone_add))
                }
                Button(onClick = onRestoreDefaults) {
                    Text(stringResource(R.string.restore_defaults))
                }
            }
        }

        items(styles, key = { it.id }) { style ->
            ToneStyleItem(
                style = style,
                onToggle = { onToggle(style) },
                onDelete = { onDelete(style) }
            )
        }
    }

    if (showAddSheet) {
        ModalBottomSheet(
            onDismissRequest = { showAddSheet = false },
            sheetState = sheetState
        ) {
            AddToneStyleSheet(
                onAdd = { name, packages, instructions ->
                    onAdd(name, packages, instructions)
                    showAddSheet = false
                },
                onCancel = { showAddSheet = false }
            )
        }
    }
}

@Composable
private fun AddToneStyleSheet(
    onAdd: (String, List<String>, String) -> Unit,
    onCancel: () -> Unit
) {
    var name by remember { mutableStateOf("") }
    var packageNames by remember { mutableStateOf("") }
    var instructions by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)
    ) {
        Text(
            text = stringResource(R.string.tone_add),
            style = MaterialTheme.typography.titleLarge
        )
        Spacer(modifier = Modifier.height(16.dp))

        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text(stringResource(R.string.tone_name)) },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )
        Spacer(modifier = Modifier.height(8.dp))

        OutlinedTextField(
            value = packageNames,
            onValueChange = { packageNames = it },
            label = { Text(stringResource(R.string.tone_app_ids)) },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )
        Spacer(modifier = Modifier.height(8.dp))

        OutlinedTextField(
            value = instructions,
            onValueChange = { instructions = it },
            label = { Text(stringResource(R.string.tone_instructions)) },
            modifier = Modifier
                .fillMaxWidth()
                .height(120.dp),
            maxLines = 5
        )
        Spacer(modifier = Modifier.height(16.dp))

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End
        ) {
            Button(
                onClick = onCancel,
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant,
                    contentColor = MaterialTheme.colorScheme.onSurfaceVariant
                )
            ) {
                Text(stringResource(R.string.cancel))
            }
            Spacer(modifier = Modifier.width(8.dp))
            Button(
                onClick = {
                    val packages = packageNames.split(",")
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                    onAdd(name, packages, instructions)
                },
                enabled = name.isNotEmpty() && instructions.isNotEmpty()
            ) {
                Text(stringResource(R.string.dictionary_add))
            }
        }
        Spacer(modifier = Modifier.height(32.dp))
    }
}

@Composable
private fun ToneStyleItem(
    style: ToneStyle,
    onToggle: () -> Unit,
    onDelete: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = style.name,
                    style = MaterialTheme.typography.bodyLarge
                )
                Text(
                    text = style.instructions,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                if (style.appPackageNames.isNotEmpty()) {
                    Text(
                        text = style.appPackageNames.joinToString(", "),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            Switch(
                checked = style.isEnabled,
                onCheckedChange = { onToggle() }
            )
            IconButton(onClick = onDelete) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = stringResource(R.string.delete_rule)
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShortcutsTab(
    shortcuts: List<Shortcut>,
    onAdd: (String, String) -> Unit,
    onToggle: (Shortcut) -> Unit,
    onDelete: (Shortcut) -> Unit,
    onRestoreDefaults: () -> Unit
) {
    var trigger by remember { mutableStateOf("") }
    var expansion by remember { mutableStateOf("") }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        item {
            Button(
                onClick = onRestoreDefaults,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(stringResource(R.string.restore_defaults))
            }
        }

        item {
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            ) {
                Column(
                    modifier = Modifier.padding(16.dp)
                ) {
                    OutlinedTextField(
                        value = trigger,
                        onValueChange = { trigger = it },
                        label = { Text(stringResource(R.string.shortcut_trigger)) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    OutlinedTextField(
                        value = expansion,
                        onValueChange = { expansion = it },
                        label = { Text(stringResource(R.string.shortcut_expansion)) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    Button(
                        onClick = {
                            if (trigger.isNotEmpty() && expansion.isNotEmpty()) {
                                onAdd(trigger, expansion)
                                trigger = ""
                                expansion = ""
                            }
                        },
                        enabled = trigger.isNotEmpty() && expansion.isNotEmpty(),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.Add, contentDescription = null)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(stringResource(R.string.shortcut_add))
                    }
                }
            }
        }

        items(shortcuts, key = { it.id }) { shortcut ->
            ShortcutItem(
                shortcut = shortcut,
                onToggle = { onToggle(shortcut) },
                onDelete = { onDelete(shortcut) }
            )
        }
    }
}

@Composable
private fun ShortcutItem(
    shortcut: Shortcut,
    onToggle: () -> Unit,
    onDelete: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = shortcut.voiceTrigger,
                    style = MaterialTheme.typography.bodyLarge
                )
                Text(
                    text = "→ ${shortcut.expansion}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Switch(
                checked = shortcut.isEnabled,
                onCheckedChange = { onToggle() }
            )
            IconButton(onClick = onDelete) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = stringResource(R.string.delete_shortcut)
                )
            }
        }
    }
}
