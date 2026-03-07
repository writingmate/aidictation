import AVFoundation
import SwiftUI
import WhisperMateShared

struct ContentView: View {
    @StateObject private var historyManager = HistoryManager()
    @StateObject private var dictionaryManager = DictionaryManager.shared
    @StateObject private var toneStyleManager = ToneStyleManager.shared
    @StateObject private var shortcutManager = ShortcutManager.shared
    @StateObject private var languageManager = LanguageManager()
    @StateObject private var parakeetService = ParakeetTranscriptionService.shared
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @AppStorage("useOnDeviceTranscription", store: AppDefaults.shared) private var useOnDeviceTranscription = false
    @State private var selectedTab: Int = 0
    @State private var showRecordingSheet = false
    @State private var selectedRecording: Recording?
    @State private var showTextRules = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // Use iPhone layout for all devices (scales nicely on iPad)
        iPhoneLayout
    }

    // MARK: - iPad Layout

    private var iPadLayout: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {
                    // Large Record Button
                    recordButton
                        .padding(.top, 40)

                    // Text Rules Section
                    textRulesSection

                    // History Section
                    historySection

                    // Settings Section
                    settingsSection
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .navigationTitle("WhisperMate")
            .sheet(isPresented: $showRecordingSheet) {
                RecordingSheetView(historyManager: historyManager, dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager, languageManager: languageManager)
            }
            .sheet(item: $selectedRecording) { recording in
                RecordingSheetView(historyManager: historyManager, dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager, languageManager: languageManager, recording: recording)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - iPhone Layout

    private var iPhoneLayout: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                // History Tab
                historyView
                    .tabItem {
                        Label("History", systemImage: "clock.fill")
                    }
                    .tag(0)

                // Placeholder for center button
                Color.clear
                    .tabItem {
                        Text("")
                    }
                    .tag(1)

                // Settings Tab
                settingsView
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(2)
            }
            .onChange(of: selectedTab) { newTab in
                if newTab == 1 {
                    showRecordingSheet = true
                    // Reset to previous tab immediately
                    selectedTab = 0
                }
            }

            // Large center recording button overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: {
                        showRecordingSheet = true
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 64, height: 64)
                                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

                            Image(systemName: "mic.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    Spacer()
                }
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showRecordingSheet) {
            RecordingSheetView(historyManager: historyManager, dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager, languageManager: languageManager)
        }
    }

    // MARK: - iPad Components

    private var recordButton: some View {
        Button(action: {
            showRecordingSheet = true
        }) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 120, height: 120)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)

                    Image(systemName: "mic.fill")
                        .font(.system(size: 50, weight: .semibold))
                        .foregroundColor(.white)
                }

                Text("Tap to Record")
                    .font(.system(size: 20, weight: .medium, design: .default))
                    .foregroundColor(.primary)
            }
        }
    }

    private var textRulesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Transcription", systemImage: "text.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold, design: .default))
                Spacer()
            }

            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Dictionary")
                            .font(.body.weight(.medium))
                        Text("\(dictionaryManager.entries.filter { $0.isEnabled }.count) entries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(10)

                HStack {
                    VStack(alignment: .leading) {
                        Text("Tone & Style")
                            .font(.body.weight(.medium))
                        Text("\(toneStyleManager.styles.filter { $0.isEnabled }.count) styles")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(10)

                HStack {
                    VStack(alignment: .leading) {
                        Text("Shortcuts")
                            .font(.body.weight(.medium))
                        Text("\(shortcutManager.shortcuts.filter { $0.isEnabled }.count) shortcuts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(10)

                NavigationLink(destination: TranscriptionSettingsView(dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager)) {
                    HStack {
                        Text("Manage Settings")
                            .font(.body)
                            .foregroundColor(.blue)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(10)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Recent History", systemImage: "clock.fill")
                    .font(.system(size: 22, weight: .semibold, design: .default))
                Spacer()
            }

            if historyManager.recordings.isEmpty {
                Text("No recordings yet")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(10)
            } else {
                VStack(spacing: 12) {
                    ForEach(historyManager.recordings.prefix(5)) { recording in
                        Button(action: {
                            selectedRecording = recording
                        }) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(recording.transcription)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                Text(recording.formattedDate)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .cornerRadius(10)
                        }
                        .contextMenu {
                            Button(action: {
                                UIPasteboard.general.string = recording.transcription
                            }) {
                                Label("Copy", systemImage: "doc.on.doc")
                            }

                            Button(role: .destructive, action: {
                                historyManager.deleteRecording(recording)
                            }) {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Settings & Permissions", systemImage: "gear")
                    .font(.system(size: 22, weight: .semibold, design: .default))
                Spacer()
            }

            VStack(spacing: 12) {
                // Microphone Permission
                PermissionRow(
                    title: "Microphone Access",
                    icon: "mic.fill",
                    status: checkMicrophonePermission(),
                    action: openAppSettings
                )

                // Keyboard Permission
                PermissionRow(
                    title: "Keyboard Full Access",
                    icon: "keyboard",
                    status: .info,
                    statusText: "Enable in Settings → Keyboards",
                    action: openKeyboardSettings
                )

                Divider()
                    .padding(.vertical, 8)

                // App Info
                HStack {
                    Text("Version")
                        .font(.body)
                    Spacer()
                    Text("0.0.20")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(10)

                // Clear History
                Button(action: {
                    historyManager.clearAll()
                }) {
                    HStack {
                        Label("Clear All History", systemImage: "trash")
                            .foregroundColor(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(10)
                }
                .disabled(historyManager.recordings.isEmpty)
            }
        }
    }

    // MARK: - History View

    private var historyView: some View {
        NavigationView {
            List {
                ForEach(historyManager.recordings) { recording in
                    Button(action: {
                        selectedRecording = recording
                    }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(recording.transcription)
                                .font(.body)
                                .foregroundColor(.primary)
                            Text(recording.formattedDate)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            historyManager.deleteRecording(recording)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            UIPasteboard.general.string = recording.transcription
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .tint(.blue)

                        if recording.audioFileURL != nil {
                            Button {
                                selectedRecording = recording
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .sheet(item: $selectedRecording) { recording in
                RecordingSheetView(historyManager: historyManager, dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager, languageManager: languageManager, recording: recording)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Settings View (iPhone)

    private var settingsView: some View {
        NavigationView {
            Form {
                // Account Section
                Section("Account") {
                    if authManager.isAuthenticated, let user = authManager.currentUser {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.email)
                                    .font(.body)
                                Text(user.subscriptionTier.displayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Usage info
                        let usage = subscriptionManager.getUsageStatus()
                        if !usage.isPro {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Words used")
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(usage.used) / \(usage.limit)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                ProgressView(value: min(usage.percentage, 1.0))
                                    .tint(usage.percentage >= 0.9 ? .red : .blue)
                            }

                            Button(action: {
                                subscriptionManager.openUpgrade()
                            }) {
                                Label("Upgrade to Pro", systemImage: "star.fill")
                                    .foregroundColor(.orange)
                            }
                        }

                        Button("Sign Out", role: .destructive) {
                            Task {
                                await authManager.logout()
                            }
                        }
                    } else {
                        Button(action: {
                            authManager.openSignUp()
                        }) {
                            HStack {
                                Image(systemName: "person.circle")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sign In / Create Account")
                                        .font(.body)
                                    Text("Get \(UsageLimits.freeMonthlyWordLimit) free words/month")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                // Language Section
                Section("Language") {
                    NavigationLink(destination: LanguageSelectionView(languageManager: languageManager)) {
                        HStack {
                            Label("Transcription Language", systemImage: "globe")
                            Spacer()
                            Text(languageDisplayText)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                // Transcription Engine Section
                Section {
                    Toggle(isOn: $useOnDeviceTranscription) {
                        Label("On-Device (Parakeet)", systemImage: "iphone")
                    }
                    .onChange(of: useOnDeviceTranscription) { enabled in
                        if enabled {
                            Task {
                                try? await parakeetService.initialize()
                            }
                        }
                    }

                    switch parakeetService.state {
                    case .notInitialized:
                        if useOnDeviceTranscription {
                            HStack {
                                Text("Model not downloaded")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Download") {
                                    Task {
                                        try? await parakeetService.initialize()
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    case .downloading:
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading model...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .initializing:
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Initializing...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .ready:
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Model ready")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    case .transcribing:
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Transcribing...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .error(let message):
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Transcription Engine")
                } footer: {
                    Text(useOnDeviceTranscription
                        ? "Transcription runs privately on your device. No internet required."
                        : "Transcription uses cloud API. Requires internet connection.")
                }

                Section("Permissions") {
                    Button(action: openAppSettings) {
                        HStack {
                            Label("Microphone Access", systemImage: "mic.fill")
                            Spacer()
                            Image(systemName: checkMicrophonePermission() == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(checkMicrophonePermission() == .granted ? .green : .orange)
                        }
                    }

                    Button(action: openKeyboardSettings) {
                        HStack {
                            Label("Keyboard Settings", systemImage: "keyboard")
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Transcription") {
                    NavigationLink(destination: TranscriptionSettingsView(dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager)) {
                        Label("Dictionary & Shortcuts", systemImage: "text.badge.checkmark")
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Data") {
                    Button("Clear All History", role: .destructive) {
                        historyManager.clearAll()
                    }
                    .disabled(historyManager.recordings.isEmpty)
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Computed Properties

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
    }

    private var languageDisplayText: String {
        if languageManager.selectedLanguages.contains(.auto) {
            return "Auto-detect"
        }
        let names = languageManager.selectedLanguages.map { $0.displayName }
        return names.sorted().joined(separator: ", ")
    }

    // MARK: - Permission Helpers

    private func checkMicrophonePermission() -> PermissionStatus {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "App-prefs:root=General&path=Keyboard") {
            UIApplication.shared.open(url)
        }
        // Fallback to general settings if keyboard shortcut doesn't work
        openAppSettings()
    }
}

// MARK: - Permission Row Component

struct PermissionRow: View {
    let title: String
    let icon: String
    let status: PermissionStatus
    var statusText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.blue)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body)
                        .foregroundColor(.primary)

                    if let statusText = statusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(status.text)
                            .font(.caption)
                            .foregroundColor(status.color)
                    }
                }

                Spacer()

                Image(systemName: status.iconName)
                    .font(.title3)
                    .foregroundColor(status.color)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .cornerRadius(10)
        }
    }
}

enum PermissionStatus {
    case granted
    case denied
    case notDetermined
    case info

    var text: String {
        switch self {
        case .granted:
            return "Enabled"
        case .denied:
            return "Tap to enable in Settings"
        case .notDetermined:
            return "Tap to enable"
        case .info:
            return "Tap to open Settings"
        }
    }

    var color: Color {
        switch self {
        case .granted:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        case .info:
            return .secondary
        }
    }

    var iconName: String {
        switch self {
        case .granted:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.circle.fill"
        case .notDetermined:
            return "exclamationmark.triangle.fill"
        case .info:
            return "arrow.up.forward.square"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthManager.shared)
        .environmentObject(SubscriptionManager.shared)
}
