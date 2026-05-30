import SwiftUI
import WhisperMateShared

struct TranscriptionSettingsView: View {
    @ObservedObject var dictionaryManager: DictionaryManager
    @ObservedObject var toneStyleManager: ToneStyleManager
    @ObservedObject var shortcutManager: ShortcutManager

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Feature", selection: $selectedTab) {
                Text("Dictionary").tag(0)
                Text("Mode").tag(1)
                Text("Shortcuts").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            TabView(selection: $selectedTab) {
                DictionaryView(manager: dictionaryManager)
                    .tag(0)

                ToneStyleView(manager: toneStyleManager)
                    .tag(1)

                ShortcutsView(manager: shortcutManager)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("Transcription Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Dictionary View

struct DictionaryView: View {
    @ObservedObject var manager: DictionaryManager
    @State private var newTrigger = ""
    @State private var editingEntry: DictionaryEntry?

    var body: some View {
        List {
            Section(header: Text(""), footer: Text("")) {
                ForEach(manager.entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.trigger)
                                .font(.body)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { entry.isEnabled },
                            set: { _ in manager.toggleEntry(entry) }
                        ))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingEntry = entry
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let entry = manager.entries[index]
                        manager.removeEntry(entry)
                    }
                }
            }

            Section(header: Text("Add New Entry"), footer: Text("Dictionary entries help recognize and format specific words correctly")) {
                VStack(spacing: 12) {
                    TextField("Word or phrase", text: $newTrigger)

                    if !newTrigger.isEmpty {
                        Button(action: addEntry) {
                            Label("Add Entry", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            EditDictionaryEntrySheet(manager: manager, entry: entry)
        }
    }

    private func addEntry() {
        guard !newTrigger.isEmpty else { return }
        manager.addEntry(trigger: newTrigger, replacement: nil)
        newTrigger = ""
    }
}

struct EditDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: DictionaryManager
    let entry: DictionaryEntry

    @State private var trigger: String

    init(manager: DictionaryManager, entry: DictionaryEntry) {
        self.manager = manager
        self.entry = entry
        _trigger = State(initialValue: entry.trigger)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Entry") {
                    TextField("Word or phrase", text: $trigger)
                }
            }
            .navigationTitle("Edit Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        manager.updateEntry(
                            entry,
                            trigger: trigger,
                            replacement: nil
                        )
                        dismiss()
                    }
                    .disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Tone & Style View

struct ToneStyleView: View {
    @ObservedObject var manager: ToneStyleManager
    @State private var showingAddSheet = false
    @State private var editingStyle: ContextRule?

    var body: some View {
        List {
            Section(header: Text(""), footer: Text("")) {
                ForEach(manager.styles) { style in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(style.name)
                                .font(.body.weight(.medium))

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { style.isEnabled },
                                set: { _ in manager.toggleStyle(style) }
                            ))
                        }

                        Text(style.instructions)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if !style.appBundleIds.isEmpty {
                            Text("Apps: \(style.appBundleIds.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingStyle = style
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let style = manager.styles[index]
                        manager.removeStyle(style)
                    }
                }
            }

            Section(header: Text(""), footer: Text("Tone & style rules adjust language formality and structure for different apps")) {
                Button(action: { showingAddSheet = true }) {
                    Label("Add Tone/Style", systemImage: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddToneStyleSheet(manager: manager, isPresented: $showingAddSheet)
        }
        .sheet(item: $editingStyle) { style in
            EditToneStyleSheet(manager: manager, style: style)
        }
    }
}

struct AddToneStyleSheet: View {
    @ObservedObject var manager: ToneStyleManager
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var appBundleIds = ""
    @State private var instructions = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Name"), footer: Text("")) {
                    TextField("e.g., Slack - Professional", text: $name)
                }

                Section(header: Text("App Bundle IDs"), footer: Text("Comma-separated list of app bundle IDs. Leave empty to apply to all apps.")) {
                    TextField("e.g., com.tinyspeck.chatlyio", text: $appBundleIds)
                }

                Section(header: Text("Instructions"), footer: Text("Describe the tone, style, and formatting for this app")) {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("Add Tone/Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addStyle()
                    }
                    .disabled(name.isEmpty || instructions.isEmpty)
                }
            }
        }
    }

    private func addStyle() {
        let bundleIds = appBundleIds
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        manager.addStyle(name: name, appBundleIds: bundleIds, instructions: instructions)
        isPresented = false
    }
}

struct EditToneStyleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ToneStyleManager
    let style: ContextRule

    @State private var name: String
    @State private var appBundleIds: String
    @State private var instructions: String

    init(manager: ToneStyleManager, style: ContextRule) {
        self.manager = manager
        self.style = style
        _name = State(initialValue: style.name)
        _appBundleIds = State(initialValue: style.appBundleIds.joined(separator: ", "))
        _instructions = State(initialValue: style.instructions)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Name") {
                    TextField("e.g., Slack - Professional", text: $name)
                }

                Section(header: Text("App Bundle IDs"), footer: Text("Comma-separated list of app bundle IDs. Leave empty to apply to all apps.")) {
                    TextField("e.g., com.tinyspeck.chatlyio", text: $appBundleIds)
                }

                Section(header: Text("Instructions"), footer: Text("Describe the tone, style, and formatting for this app")) {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("Edit Tone/Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let bundleIds = appBundleIds
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }

                        manager.updateStyle(style, name: name, appBundleIds: bundleIds, instructions: instructions)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Shortcuts View

struct ShortcutsView: View {
    @ObservedObject var manager: ShortcutManager
    @State private var newTrigger = ""
    @State private var newExpansion = ""
    @State private var editingShortcut: Shortcut?

    var body: some View {
        List {
            Section(header: Text(""), footer: Text("")) {
                ForEach(manager.shortcuts) { shortcut in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shortcut.voiceTrigger)
                                .font(.body)
                            Text("→ \(shortcut.expansion)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { shortcut.isEnabled },
                            set: { _ in manager.toggleShortcut(shortcut) }
                        ))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingShortcut = shortcut
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let shortcut = manager.shortcuts[index]
                        manager.removeShortcut(shortcut)
                    }
                }
            }

            Section(header: Text("Add New Shortcut"), footer: Text("Shortcuts let you say a phrase and have it expand to longer text")) {
                VStack(spacing: 12) {
                    TextField("Voice trigger (e.g., 'my email')", text: $newTrigger)
                    TextField("Expansion text", text: $newExpansion)

                    if !newTrigger.isEmpty && !newExpansion.isEmpty {
                        Button(action: addShortcut) {
                            Label("Add Shortcut", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .sheet(item: $editingShortcut) { shortcut in
            EditShortcutSheet(manager: manager, shortcut: shortcut)
        }
    }

    private func addShortcut() {
        guard !newTrigger.isEmpty, !newExpansion.isEmpty else { return }
        manager.addShortcut(voiceTrigger: newTrigger, expansion: newExpansion)
        newTrigger = ""
        newExpansion = ""
    }
}

struct EditShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ShortcutManager
    let shortcut: Shortcut

    @State private var voiceTrigger: String
    @State private var expansion: String

    init(manager: ShortcutManager, shortcut: Shortcut) {
        self.manager = manager
        self.shortcut = shortcut
        _voiceTrigger = State(initialValue: shortcut.voiceTrigger)
        _expansion = State(initialValue: shortcut.expansion)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Shortcut") {
                    TextField("Voice trigger", text: $voiceTrigger)
                    TextField("Expansion text", text: $expansion)
                }
            }
            .navigationTitle("Edit Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        manager.updateShortcut(shortcut, voiceTrigger: voiceTrigger, expansion: expansion)
                        dismiss()
                    }
                    .disabled(voiceTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
