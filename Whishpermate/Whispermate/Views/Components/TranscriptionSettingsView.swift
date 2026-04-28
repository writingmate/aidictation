import SwiftUI
import WhisperMateShared

struct TranscriptionSettingsView: View {
    @ObservedObject var dictionaryManager: DictionaryManager
    @ObservedObject var contextRulesManager: ContextRulesManager
    @ObservedObject var shortcutManager: ShortcutManager

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Feature", selection: $selectedTab) {
                Text("Dictionary").tag(0)
                Text("Context Rules").tag(1)
                Text("Shortcuts").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 16)

            TabView(selection: $selectedTab) {
                DictionaryTabView(manager: dictionaryManager)
                    .tag(0)

                ContextRulesTabView(manager: contextRulesManager)
                    .tag(1)

                ShortcutsTabView(manager: shortcutManager)
                    .tag(2)
            }
            .tabViewStyle(.automatic)
        }
    }
}

// MARK: - Dictionary Tab

struct DictionaryTabView: View {
    @ObservedObject var manager: DictionaryManager
    @State private var newTrigger = ""
    @State private var newReplacement = ""

    var body: some View {
        VStack(spacing: 0) {
            // Existing entries
            ForEach(Array(manager.entries.enumerated()), id: \.element.id) { _, entry in
                DictionaryEntryRow(
                    entry: entry,
                    onToggle: { manager.toggleEntry(entry) },
                    onEdit: { trigger, replacement in
                        manager.updateEntry(entry, trigger: trigger, replacement: replacement)
                    },
                    onDelete: { manager.removeEntry(entry) }
                )
            }

            // Add new entry row
            HStack(spacing: 12) {
                TextField("Trigger word", text: $newTrigger)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Replacement (optional)", text: $newReplacement)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(newReplacement.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity)

                Button(action: {
                    if !newTrigger.isEmpty {
                        let replacement = newReplacement.isEmpty ? nil : newReplacement
                        manager.addEntry(trigger: newTrigger, replacement: replacement)
                        newTrigger = ""
                        newReplacement = ""
                    }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .opacity(newTrigger.isEmpty ? 0 : 1)

                // Placeholder for edit button alignment
                Color.clear
                    .frame(width: 16, height: 16)

                // Placeholder for toggle alignment
                Toggle("", isOn: .constant(true))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .hidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.quaternarySystemFill)
        }
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.medium))
    }
}

struct DictionaryEntryRow: View {
    let entry: DictionaryEntry
    let onToggle: () -> Void
    let onEdit: (String, String?) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editTrigger = ""
    @State private var editReplacement = ""

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                TextField("Trigger", text: $editTrigger)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                TextField("Replacement (optional)", text: $editReplacement)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: {
                    let replacement = editReplacement.isEmpty ? nil : editReplacement
                    onEdit(editTrigger, replacement)
                    isEditing = false
                }) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .disabled(editTrigger.isEmpty)

                Button(action: {
                    isEditing = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)

                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            } else {
                Text(entry.trigger)
                    .font(.body)
                    .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let replacement = entry.replacement {
                    Text(replacement)
                        .font(.body)
                        .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("(no replacement)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .compatibleItalic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: {
                    editTrigger = entry.trigger
                    editReplacement = entry.replacement ?? ""
                    isEditing = true
                }) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.body)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .opacity(isHovering ? 1 : 0)

                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .opacity(isHovering ? 1 : 0)

                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.quaternarySystemFill)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.horizontal, 16)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Context Rules Tab

struct ContextRulesTabView: View {
    @ObservedObject var manager: ContextRulesManager
    @State private var showingAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Existing rules
            ForEach(Array(manager.rules.enumerated()), id: \.element.id) { _, rule in
                ContextRuleRow(
                    rule: rule,
                    onToggle: { manager.toggleRule(rule) },
                    onEdit: { name, bundleIds, titlePatterns, instructions in
                        manager.updateRule(rule, name: name, appBundleIds: bundleIds, titlePatterns: titlePatterns, instructions: instructions)
                    },
                    onDelete: { manager.removeRule(rule) }
                )
            }

            // Add new rule button
            Button(action: { showingAddSheet = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    Text("Add Context Rule")
                        .font(.body)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.quaternarySystemFill)
        }
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.medium))
        .sheet(isPresented: $showingAddSheet) {
            AddContextRuleSheet(manager: manager, isPresented: $showingAddSheet)
        }
    }
}

// MARK: - App Token Field

struct AppTokenField: View {
    @Binding var selectedAppBundleIds: Set<String>
    let installedApps: [InstalledApp]

    @State private var searchText = ""
    @State private var isShowingDropdown = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Token field area with selected apps
            VStack(spacing: 0) {
                // Selected apps as tokens
                if !selectedApps.isEmpty {
                    TokenFlowLayout(spacing: 6) {
                        ForEach(selectedApps) { app in
                            AppToken(app: app) {
                                selectedAppBundleIds.remove(app.bundleID)
                            }
                        }
                    }
                    .padding(8)
                }

                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    TextField("Search apps to add...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .focused($isSearchFocused)
                        .onSubmit {
                            if let firstMatch = filteredApps.first {
                                selectedAppBundleIds.insert(firstMatch.bundleID)
                                searchText = ""
                            }
                        }
                }
                .padding(8)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSearchFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSearchFocused ? 2 : 1)
            )
            .onTapGesture {
                isSearchFocused = true
            }

            // Dropdown with filtered results
            if isSearchFocused && !searchText.isEmpty && !filteredApps.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredApps.prefix(10)) { app in
                            Button(action: {
                                selectedAppBundleIds.insert(app.bundleID)
                                searchText = ""
                            }) {
                                HStack(spacing: 8) {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 16, height: 16)
                                    }
                                    Text(app.name)
                                        .font(.callout)
                                    Spacer()
                                    if selectedAppBundleIds.contains(app.bundleID) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.secondary)
                                            .font(.caption2)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Color(nsColor: .controlBackgroundColor)
                                    .opacity(0.001)
                            )
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 200)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            }

            Text("Leave empty to apply to all apps • \(selectedAppBundleIds.count) selected")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedApps: [InstalledApp] {
        installedApps.filter { selectedAppBundleIds.contains($0.bundleID) }
    }

    private var filteredApps: [InstalledApp] {
        if searchText.isEmpty {
            return []
        }
        return installedApps.filter { app in
            !selectedAppBundleIds.contains(app.bundleID) &&
                (app.name.localizedCaseInsensitiveContains(searchText) ||
                    app.bundleID.localizedCaseInsensitiveContains(searchText))
        }
    }
}

struct AppToken: View {
    let app: InstalledApp
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            Text(app.name)
                .font(.caption)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .selectedControlColor).opacity(0.3))
        .cornerRadius(4)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Title Pattern Token Field

struct TitlePatternTokenField: View {
    @Binding var titlePatterns: [String]
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Tokens and input field
            if !titlePatterns.isEmpty {
                TokenFlowLayout(spacing: 6) {
                    ForEach(titlePatterns, id: \.self) { pattern in
                        TitlePatternToken(pattern: pattern) {
                            titlePatterns.removeAll { $0 == pattern }
                        }
                    }
                }
                .padding(8)
            }

            // Input field
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                TextField("Type pattern and press Enter (e.g., Gmail, *LinkedIn*)", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isInputFocused)
                    .onSubmit {
                        addPattern()
                    }
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isInputFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isInputFocused ? 2 : 1)
        )
        .onTapGesture {
            isInputFocused = true
        }
    }

    private func addPattern() {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !titlePatterns.contains(trimmed) else {
            inputText = ""
            return
        }
        titlePatterns.append(trimmed)
        inputText = ""
    }
}

struct TitlePatternToken: View {
    let pattern: String
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.alignleft")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(pattern)
                .font(.caption)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .selectedControlColor).opacity(0.3))
        .cornerRadius(4)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// Flow layout for tokens
struct TokenFlowLayout<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 13.0, *) {
            FlowLayout(spacing: spacing) {
                content
            }
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
        }
    }
}

@available(macOS 13.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX, y: bounds.minY + result.frames[index].minY), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var frames: [CGRect] = []
        var size: CGSize = .zero

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth, x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

struct ContextRuleRow: View {
    let rule: ContextRule
    let onToggle: () -> Void
    let onEdit: (String, [String], [String], String) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var showingEditSheet = false
    @State private var appIcons: [InstalledApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.name)
                        .font(.headline)
                        .foregroundStyle(rule.isEnabled ? .primary : .secondary)

                    Text(rule.instructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if rule.appBundleIds.isEmpty {
                        Text("Applies to all apps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .compatibleItalic()
                    } else if !appIcons.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(appIcons.prefix(8)) { app in
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                }
                            }
                            if appIcons.count > 8 {
                                Text("+\(appIcons.count - 8)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Spacer()

                Button(action: { showingEditSheet = true }) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.body)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .opacity(isHovering ? 1 : 0)

                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .opacity(isHovering ? 1 : 0)

                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.quaternarySystemFill)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.horizontal, 16)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onAppear {
            loadAppIcons()
        }
        .onChange(of: rule.appBundleIds) { _ in
            loadAppIcons()
        }
        .sheet(isPresented: $showingEditSheet) {
            EditContextRuleSheet(
                rule: rule,
                onSave: onEdit,
                isPresented: $showingEditSheet
            )
        }
    }

    private func loadAppIcons() {
        let installedApps = AppDiscoveryManager.shared.getInstalledApps()
        appIcons = installedApps.filter { app in
            rule.appBundleIds.contains(app.bundleID)
        }
    }
}

struct EditContextRuleSheet: View {
    let rule: ContextRule
    let onSave: (String, [String], [String], String) -> Void
    @Binding var isPresented: Bool

    @State private var name: String
    @State private var selectedAppBundleIds: Set<String>
    @State private var titlePatterns: [String] // Array of window title patterns
    @State private var instructions: String
    @State private var installedApps: [InstalledApp] = []

    init(rule: ContextRule, onSave: @escaping (String, [String], [String], String) -> Void, isPresented: Binding<Bool>) {
        self.rule = rule
        self.onSave = onSave
        _isPresented = isPresented
        _name = State(initialValue: rule.name)
        _selectedAppBundleIds = State(initialValue: Set(rule.appBundleIds))
        _titlePatterns = State(initialValue: rule.titlePatterns)
        _instructions = State(initialValue: rule.instructions)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Context Rule")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.subheadline)
                TextField("e.g., Professional Work Chat", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Apps")
                    .font(.subheadline)

                AppTokenField(selectedAppBundleIds: $selectedAppBundleIds, installedApps: installedApps)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Window Title Patterns")
                    .font(.subheadline)

                TitlePatternTokenField(titlePatterns: $titlePatterns)

                Text("Leave empty to match all window titles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions")
                    .font(.subheadline)
                TextEditor(text: $instructions)
                    .font(.callout)
                    .frame(height: 80)
                    .border(Color(nsColor: .separatorColor))
                Text("Describe the formatting rules for this context")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveRule()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || instructions.isEmpty)
            }
        }
        .padding()
        .frame(width: 450)
        .onAppear {
            installedApps = AppDiscoveryManager.shared.getInstalledApps()
        }
    }

    private func saveRule() {
        onSave(name, Array(selectedAppBundleIds), titlePatterns, instructions)
        isPresented = false
    }
}

struct AddContextRuleSheet: View {
    @ObservedObject var manager: ContextRulesManager
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var selectedAppBundleIds: Set<String> = []
    @State private var titlePatterns: [String] = [] // Array of window title patterns
    @State private var instructions = ""
    @State private var installedApps: [InstalledApp] = []

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Context Rule")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.subheadline)
                TextField("e.g., Professional Work Chat", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Apps")
                    .font(.subheadline)

                AppTokenField(selectedAppBundleIds: $selectedAppBundleIds, installedApps: installedApps)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Window Title Patterns")
                    .font(.subheadline)

                TitlePatternTokenField(titlePatterns: $titlePatterns)

                Text("Leave empty to match all window titles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions")
                    .font(.subheadline)
                TextEditor(text: $instructions)
                    .font(.callout)
                    .frame(height: 80)
                    .border(Color(nsColor: .separatorColor))
                Text("Describe the formatting rules for this context")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    addRule()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || instructions.isEmpty)
            }
        }
        .padding()
        .frame(width: 450)
        .onAppear {
            installedApps = AppDiscoveryManager.shared.getInstalledApps()
        }
    }

    private func addRule() {
        manager.addRule(name: name, appBundleIds: Array(selectedAppBundleIds), titlePatterns: titlePatterns, instructions: instructions)
        isPresented = false
    }
}

// MARK: - Shortcuts Tab

struct ShortcutsTabView: View {
    @ObservedObject var manager: ShortcutManager
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        VStack(spacing: 0) {
            // Existing shortcuts
            ForEach(Array(manager.shortcuts.enumerated()), id: \.element.id) { _, shortcut in
                ShortcutRow(
                    shortcut: shortcut,
                    onToggle: { manager.toggleShortcut(shortcut) },
                    onEdit: { voiceTrigger, expansion in
                        manager.updateShortcut(shortcut, voiceTrigger: voiceTrigger, expansion: expansion)
                    },
                    onDelete: { manager.removeShortcut(shortcut) }
                )
            }

            // Add new shortcut row
            HStack(spacing: 12) {
                TextField("Voice trigger (e.g., 'my email')", text: $newTrigger)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Expansion text", text: $newExpansion)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(maxWidth: .infinity)

                Button(action: {
                    if !newTrigger.isEmpty, !newExpansion.isEmpty {
                        manager.addShortcut(voiceTrigger: newTrigger, expansion: newExpansion)
                        newTrigger = ""
                        newExpansion = ""
                    }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .opacity(newTrigger.isEmpty || newExpansion.isEmpty ? 0 : 1)

                // Placeholder for edit button alignment
                Color.clear
                    .frame(width: 16, height: 16)

                // Placeholder for toggle alignment
                Toggle("", isOn: .constant(true))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .hidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.quaternarySystemFill)
        }
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.medium))
    }
}

struct ShortcutRow: View {
    let shortcut: Shortcut
    let onToggle: () -> Void
    let onEdit: (String, String) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editTrigger = ""
    @State private var editExpansion = ""

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                TextField("Voice trigger", text: $editTrigger)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                TextField("Expansion", text: $editExpansion)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: {
                    onEdit(editTrigger, editExpansion)
                    isEditing = false
                }) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .disabled(editTrigger.isEmpty || editExpansion.isEmpty)

                Button(action: {
                    isEditing = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)

                Toggle("", isOn: Binding(
                    get: { shortcut.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            } else {
                Text(shortcut.voiceTrigger)
                    .font(.body)
                    .foregroundStyle(shortcut.isEnabled ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(shortcut.expansion)
                    .font(.body)
                    .foregroundStyle(shortcut.isEnabled ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)

                Button(action: {
                    editTrigger = shortcut.voiceTrigger
                    editExpansion = shortcut.expansion
                    isEditing = true
                }) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.body)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .opacity(isHovering ? 1 : 0)

                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .opacity(isHovering ? 1 : 0)

                Toggle("", isOn: Binding(
                    get: { shortcut.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.quaternarySystemFill)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.horizontal, 16)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func compatibleItalic() -> some View {
        if #available(macOS 13.0, *) {
            italic()
        } else {
            self
        }
    }
}
