import AVFoundation
#if canImport(ActivityKit)
    import ActivityKit
#endif
import Combine
import MediaPlayer
import SwiftUI
import WhisperMateShared

@MainActor
private enum KeyboardHostLaunchRecoveryGate {
    static var attempted = false
    static var ready = false
}

@MainActor
private let mobileAudioHostLaunchRecoveryGate = HostLaunchRecoveryGate()

struct ContentView: View {
    @StateObject private var historyManager = HistoryManager()
    @StateObject private var dictionaryManager = DictionaryManager.shared
    @StateObject private var toneStyleManager = ToneStyleManager.shared
    @StateObject private var shortcutManager = ShortcutManager.shared
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var transcriptionProviderManager = TranscriptionProviderManager()
    @StateObject private var parakeetService = SharedParakeetTranscriptionService.shared
    @StateObject private var inlineRecording = InlineRecordingCoordinator()
    @State private var showRecordingSheet = false
    @State private var showSettings = false
    @State private var recordingSheetID = UUID()
    @State private var selectedRecording: Recording?
    @State private var showTextRules = false
    @State private var showLoginSheet = false
    @State private var showLoginConfigurationAlert = false
    @State private var loginConfigurationMessage = ""
    @State private var showOfflineModelAlert = false
    @State private var offlineModelMessage = ""
    @State private var newlyInsertedRecordingID: UUID?
    @State private var historySearchText = ""
    @State private var recordingToShare: Recording?
    @State private var referralShareItem: ReferralShareItem?
    @State private var isPreparingReferral = false
    @State private var isRedeemingReferral = false
    @State private var referralCodeToRedeem = ""
    @State private var referralError: String?
    @State private var activeKeyboardDictationIdentity: KeyboardDictationHandoff.AttemptIdentity?
    @State private var showKeyboardReturnScreen = false
    @State private var keyboardBridgeAliveUntil: Date?
    @State private var selectedRecordingMode: TranscriptionOutputMode = .dictation
    @State private var showCloudTranscriptionConsent = false
    @State private var keyboardCommandPollTask: Task<Void, Never>?
    @State private var keyboardHostLaunchReady = false
    @State private var mobileAudioRecoveryReady = false
    @State private var historyActionMessage: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // Use iPhone layout for all devices (scales nicely on iPad)
        iPhoneLayout
            .onAppear {
                Task { @MainActor in
                    await recoverMobileAudioProcessingIfNeeded()
                    guard mobileAudioRecoveryReady else { return }
                    recoverKeyboardHostLaunchIfNeeded()
                }
                #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-showAccountLoginForValidation") {
                        // The login sheet now lives inside the settings sheet,
                        // matching the path real users take to reach it.
                        showSettings = true
                        showLoginSheet = true
                    }
                #endif
            }
            .onDisappear {
                stopKeyboardCommandPolling()
            }
            .onChange(of: scenePhase) { phase in
                DebugLog.info("scenePhase=\(String(describing: phase))", context: "KEYBOARD_DIAG")
                if phase == .active {
                    guard keyboardHostLaunchReady else { return }
                    drainKeyboardDiagnostics()
                    startKeyboardCommandPolling()
                    consumePendingKeyboardCommandIfNeeded()
                } else if shouldKeepKeyboardCommandPolling {
                    startKeyboardCommandPolling()
                } else {
                    stopKeyboardCommandPolling()
                }
            }
            .onChange(of: selectedRecordingMode) { _ in
                prepareOfflineRuntimeForSelectedModeIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardDictationHandoff.openAppNotification)) { notification in
                _ = notification
                consumePendingKeyboardCommandIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardDictationHandoff.stopAppNotification)) { notification in
                _ = notification
                consumePendingKeyboardCommandIfNeeded()
            }
            .alert("Login Unavailable", isPresented: $showLoginConfigurationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loginConfigurationMessage)
            }
            .alert("Offline Model", isPresented: $showOfflineModelAlert) {
                if canDownloadOfflineModelFromAlert {
                    Button("Try Again") {
                        prepareOfflineModelWithRetry()
                    }
                }
                if canSwitchToCloudFromOfflineModelAlert {
                    Button("Use Cloud") {
                        switchToCloudTranscription()
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(offlineModelMessage)
            }
            .alert(CloudTranscriptionConsent.alertTitle, isPresented: $showCloudTranscriptionConsent) {
                Button("Allow Cloud Transcription") {
                    CloudTranscriptionConsent.grant()
                    handleInlineRecordingTap()
                }
                Button("Use Offline Mode") {
                    useOfflineModeFromCloudConsent()
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text(CloudTranscriptionConsent.disclosureMessage)
            }
            .alert("History", isPresented: Binding(
                get: { historyActionMessage != nil },
                set: { if !$0 { historyActionMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(historyActionMessage ?? "")
            }
    }

    private func openRecordingSheet() {
        guard !showKeyboardReturnScreen else { return }
        guard requireMobileAudioRecoveryReady() else { return }
        recordingSheetID = UUID()
        showRecordingSheet = true
    }

    private func openSavedRecording(_ recording: Recording) {
        guard !showKeyboardReturnScreen else { return }
        guard requireMobileAudioRecoveryReady() else { return }
        selectedRecording = recording
    }

    private var displayedHistoryRecordings: [Recording] {
        let query = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return historyManager.recordings
        }
        return historyManager.filteredRecordings(searchText: query)
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
            .navigationTitle("AI Dictation")
            .sheet(isPresented: $showRecordingSheet) {
                RecordingSheetView(historyManager: historyManager, dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager)
                    .id(recordingSheetID)
            }
            .sheet(item: $selectedRecording) { recording in
                RecordingSheetView(historyManager: historyManager, dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager, recording: recording)
            }
            .sheet(item: $recordingToShare) { recording in
                ShareSheet(activityItems: [recording.transcription])
            }
            .sheet(item: $referralShareItem) { item in
                ShareSheet(activityItems: [item.text])
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - iPhone Layout

    private var iPhoneLayout: some View {
        ZStack {
            historyView

            if inlineRecording.isPanelVisible, !showKeyboardReturnScreen {
                GeometryReader { proxy in
                    let sheetBaseHeight = max(proxy.size.height, UIScreen.main.bounds.height)
                    let isCompleting = inlineRecording.state == .completing
                    let completionOffset = sheetBaseHeight * 0.4
                    let recordingSheetHeight = sheetBaseHeight * 0.9
                    let recordingSheetTop = max(0, proxy.size.height - recordingSheetHeight)
                    VStack {
                        Spacer()
                        InlineRecordingPanel(
                            recorder: inlineRecording,
                            dismissErrorAction: inlineRecording.dismissError
                        )
                        .frame(height: isCompleting ? 92 : sheetBaseHeight * 0.9)
                        .padding(.horizontal, isCompleting ? 24 : 0)
                        .offset(y: isCompleting ? -completionOffset : 0)
                    }
                    .ignoresSafeArea(edges: .bottom)

                    if !isCompleting, inlineRecording.errorMessage == nil {
                        RecordingPresetMenu(
                            manager: toneStyleManager,
                            selectedMode: $selectedRecordingMode,
                            isOnDarkSurface: true
                        )
                        .position(x: proxy.size.width / 2, y: recordingSheetTop + 74)
                        .zIndex(4)

                        if let inlineModelCueText {
                            InlineModelStatusBar(
                                text: inlineModelCueText,
                                iconName: inlineModelCueIconName,
                                showsProgress: inlineModelCueShowsProgress
                            )
                            .position(x: proxy.size.width / 2, y: recordingSheetTop + 118)
                            .zIndex(4)
                        }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

            if showKeyboardReturnScreen {
                KeyboardDictationReturnView(state: inlineRecording.state)
                    .transition(.opacity)
                    .zIndex(3)
            }

            if !showKeyboardReturnScreen {
                VStack {
                    Spacer()
                    Button(action: handleInlineRecordingTap) {
                        AIDictationMicButtonVisual(
                            state: inlineRecording.visualState,
                            audioLevel: inlineRecording.audioLevel,
                            frequencyBands: inlineRecording.frequencyBands,
                            size: 64
                        )
                        .shadow(color: .black.opacity(inlineRecording.isActive ? 0.28 : 0.2), radius: inlineRecording.isActive ? 10 : 4, x: 0, y: inlineRecording.isActive ? 5 : 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(inlineRecording.state == .processing || inlineRecording.state == .completing)
                    .opacity(inlineRecording.state == .processing || inlineRecording.state == .completing ? 0 : 1)
                    .scaleEffect(inlineRecording.state == .processing || inlineRecording.state == .completing ? 0.82 : 1)
                    .accessibilityLabel(inlineRecording.isActive ? "Stop recording" : "Start recording")
                    .padding(.bottom, 28)
                }
                .zIndex(2)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.08), value: inlineRecording.state)
        .animation(.easeInOut(duration: 0.2), value: inlineRecording.errorMessage)
    }

    // MARK: - iPad Components

    private var recordButton: some View {
        Button(action: {
            openRecordingSheet()
        }) {
            VStack(spacing: 16) {
                AIDictationMicButtonVisual(state: .idle, size: 120)
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)

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
                        Text("Mode")
                            .font(.body.weight(.medium))
                        Text("\(toneStyleManager.styles.filter { $0.isEnabled }.count) active")
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
                            .foregroundColor(.primary)
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
                            openSavedRecording(recording)
                        }) {
                            VStack(alignment: .leading, spacing: 8) {
                                if recording.outputMode == .notes {
                                    Label("Notes", systemImage: "note.text")
                                        .font(.caption.weight(.medium))
                                        .foregroundColor(.secondary)
                                }
                                Text(historyDisplayText(for: recording))
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
	                                recordingToShare = recording
	                            }) {
	                                Label("Share", systemImage: "square.and.arrow.up")
	                            }
	                            .disabled(recording.transcription.isEmpty)

                            Button(role: .destructive, action: {
                                deleteRecordingSafely(recording)
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

                // Clear History
                Button(action: {
                    clearHistorySafely()
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

                // App Info
                HStack {
                    Text("Version")
                        .font(.body)
                    Spacer()
                    Text(appVersionText)
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(10)
            }
        }
    }

    // MARK: - History View

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                historySearchField

                Button {
                    guard !showKeyboardReturnScreen else { return }
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if displayedHistoryRecordings.isEmpty {
                Text(historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No recordings yet" : "No matching recordings")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.bottom, 96)
            } else {
                List {
                    historyRows
                }
                .listStyle(.plain)
                .animation(.spring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.06), value: displayedHistoryRecordings.map(\.id))
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            settingsView
        }
        .sheet(item: $selectedRecording) { recording in
            RecordingSheetView(historyManager: historyManager, dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager, recording: recording)
        }
        .sheet(item: $recordingToShare) { recording in
            ShareSheet(activityItems: [recording.transcription])
        }
        .sheet(item: $referralShareItem) { item in
            ShareSheet(activityItems: [item.text])
        }
    }

    @ViewBuilder
    private var historyRows: some View {
        ForEach(displayedHistoryRecordings) { recording in
            let isNewRecording = newlyInsertedRecordingID == recording.id

            Button(action: {
                openSavedRecording(recording)
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    if recording.outputMode == .notes {
                        Label("Notes", systemImage: "note.text")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                    }
                    Text(historyDisplayText(for: recording))
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(recording.formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.dsPrimary.opacity(isNewRecording ? 0.14 : 0))
                )
                .scaleEffect(isNewRecording ? 1.025 : 1, anchor: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .listRowBackground(Color.clear)
            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            .animation(.spring(response: 0.34, dampingFraction: 0.72, blendDuration: 0.04), value: isNewRecording)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteRecordingSafely(recording)
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    recordingToShare = recording
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(recording.transcription.isEmpty)

                Button {
                    openSavedRecording(recording)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .tint(.green)
            }
        }
    }

    private var historySearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)

            TextField("Search history", text: $historySearchText)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if !historySearchText.isEmpty {
                Button {
                    historySearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - Settings View (iPhone)

    private var settingsView: some View {
        NavigationView {
            Form {
                Section("Account") {
                    UsageSummaryView(
                        usage: subscriptionManager.getUsageStatus(),
                        isAuthenticated: authManager.isAuthenticated,
                        email: authManager.currentUser?.email,
                        subscriptionTier: authManager.currentUser?.subscriptionTier
                    )

                    if authManager.isAuthenticated {
                        Button(role: .destructive) {
                            Task {
                                await authManager.logout()
                            }
                        } label: {
                            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        Button(action: openLogin) {
                            Label("Log In to Get More", systemImage: "person.crop.circle.badge.plus")
                                .foregroundColor(.primary)
                        }
                    }
                }

                Section("Permissions") {
                    Button(action: openAppSettings) {
                        HStack {
                            Label("Microphone Access", systemImage: "mic.fill")
                            Spacer()
	                            Image(systemName: checkMicrophonePermission() == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
	                                .foregroundColor(checkMicrophonePermission() == .granted ? .green : .orange)
	                        }
	                        .foregroundColor(.primary)
	                    }

	                    Button(action: openKeyboardSettings) {
	                        HStack {
	                            Label("Keyboard Settings", systemImage: "keyboard")
                            Spacer()
	                            Image(systemName: "arrow.up.forward.square")
	                                .foregroundColor(.secondary)
	                        }
	                        .foregroundColor(.primary)
	                    }
	                }

                Section("Dictation Mode") {
                    NavigationLink {
                        TranscriptionModeSelectionView(
                            transcriptionProviderManager: transcriptionProviderManager,
                            parakeetService: parakeetService,
                            offlineModelStatusText: offlineModelStatusText,
                            offlineModelStatusIcon: offlineModelStatusIcon,
                            offlineModelTrailingIcon: offlineModelTrailingIcon,
                            offlineModelStatusColor: offlineModelStatusColor,
                            offlineModelIsBusy: offlineModelIsBusy,
                            prepareOfflineModel: prepareOfflineModel
                        )
                    } label: {
                        HStack {
                            Label("Model", systemImage: "waveform.badge.magnifyingglass")
                            Spacer()
                            Text(transcriptionProviderManager.transcriptionMode.displayName)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Transcription") {
                    NavigationLink {
                        DictionaryView(manager: dictionaryManager)
                            .navigationTitle("Dictionary")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Dictionary", systemImage: "text.badge.checkmark")
                            .foregroundColor(.primary)
                    }

                    NavigationLink {
                        ToneStyleView(manager: toneStyleManager)
                            .navigationTitle("Mode")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Mode", systemImage: "wand.and.stars")
                            .foregroundColor(.primary)
                    }

                    NavigationLink {
                        ShortcutsView(manager: shortcutManager)
                            .navigationTitle("Shortcuts")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Shortcuts", systemImage: "text.append")
                            .foregroundColor(.primary)
                    }
                }

                Section("Data") {
                    Button("Clear All History", role: .destructive) {
                        clearHistorySafely()
                    }
                    .disabled(historyManager.recordings.isEmpty)
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionText)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(StackNavigationViewStyle())
        // Present from inside the settings sheet: a sheet attached to the root
        // view cannot present while this sheet is already showing.
        .sheet(isPresented: $showLoginSheet) {
            AccountLoginView(authManager: authManager)
        }
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

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)):
            return "\(version) (\(build))"
        case let (.some(version), .none):
            return version
        case let (.none, .some(build)):
            return build
        case (.none, .none):
            return "Unknown"
        }
    }

    private var offlineModelStatusIcon: String {
        guard SharedParakeetTranscriptionService.isRuntimeSupported else {
            return "exclamationmark.triangle.fill"
        }
	        switch parakeetService.state {
	        case .downloading:
	            return "arrow.down.circle"
	        case .initializing:
	            return "arrow.down.circle"
        case .ready, .transcribing:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .notInitialized:
            return parakeetService.isModelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle"
        @unknown default:
            return "arrow.down.circle"
        }
    }

    private var offlineModelTrailingIcon: String {
        guard SharedParakeetTranscriptionService.isRuntimeSupported else {
            return "exclamationmark.triangle.fill"
        }
        return parakeetService.isModelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle"
    }

    private var offlineModelStatusColor: Color {
        guard SharedParakeetTranscriptionService.isRuntimeSupported else {
            return .orange
        }
        switch parakeetService.state {
        case .ready, .transcribing:
            return .green
        case .error:
            return .orange
        default:
            return parakeetService.isModelDownloaded ? .green : .secondary
        }
    }

    private var offlineModelStatusText: String {
        guard SharedParakeetTranscriptionService.isRuntimeSupported else {
            return SharedParakeetTranscriptionService.unavailableMessage
        }
        switch parakeetService.state {
        case .downloading:
            return "Downloading offline model"
        case .initializing:
            return "Preparing offline model"
        case .ready, .transcribing:
            return "Offline model ready"
        case .error(let message):
            return message.isEmpty ? "Download offline model" : message
        case .notInitialized:
            return parakeetService.isModelDownloaded ? "Offline model ready" : "Download offline model"
        @unknown default:
            return "Download offline model"
        }
    }

    private var offlineModelIsBusy: Bool {
        switch parakeetService.state {
        case .downloading, .initializing:
            return true
        default:
            return false
        }
    }

    private var selectedModeNeedsOfflineRuntime: Bool {
        transcriptionProviderManager.shouldUseOnDeviceTranscription || selectedRecordingMode == .meetings
    }

    private var inlineModelCueText: String? {
        guard selectedModeNeedsOfflineRuntime else {
            return nil
        }

        guard SharedParakeetTranscriptionService.isRuntimeSupported else {
            return SharedParakeetTranscriptionService.unavailableMessage
        }

        switch parakeetService.state {
        case .downloading:
            return selectedRecordingMode == .meetings ? "Downloading speaker detection" : "Downloading offline model"
        case .initializing:
            return selectedRecordingMode == .meetings ? "Preparing speaker detection" : "Preparing offline model"
        case .ready, .transcribing:
            return selectedRecordingMode == .meetings ? "Speaker detection ready" : "Offline mode ready"
        case .error(let message):
            return message.isEmpty ? "Model setup failed" : message
        case .notInitialized:
            return parakeetService.isModelDownloaded
                ? (selectedRecordingMode == .meetings ? "Speaker detection ready" : "Offline mode ready")
                : (selectedRecordingMode == .meetings ? "Speaker detection needs download" : "Offline model needs download")
        @unknown default:
            return selectedRecordingMode == .meetings ? "Speaker detection needs download" : "Offline model needs download"
        }
    }

    private var inlineModelCueShowsProgress: Bool {
        switch parakeetService.state {
        case .downloading, .initializing:
            return true
        default:
            return false
        }
    }

    private var inlineModelCueIconName: String {
        if parakeetService.isModelDownloaded {
            return "checkmark.circle.fill"
        }

        switch parakeetService.state {
        case .downloading, .initializing:
            return "arrow.down.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    private var canDownloadOfflineModelFromAlert: Bool {
        SharedParakeetTranscriptionService.isRuntimeSupported && !offlineModelIsBusy && !parakeetService.isModelDownloaded
    }

    private var canSwitchToCloudFromOfflineModelAlert: Bool {
        transcriptionProviderManager.transcriptionMode != .cloud
    }

    private func switchToCloudTranscription() {
        guard CloudTranscriptionConsent.isGranted else {
            showCloudTranscriptionConsent = true
            return
        }

        transcriptionProviderManager.setTranscriptionMode(.cloud)
    }

    private func useOfflineModeFromCloudConsent() {
        guard TranscriptionMode.offline.isAvailable else {
            offlineModelMessage = SharedParakeetTranscriptionService.unavailableMessage
            showOfflineModelAlert = true
            return
        }

        transcriptionProviderManager.setTranscriptionMode(.offline)
        prepareOfflineModel()
    }

    private func prepareOfflineModel() {
        Task {
            do {
                try await parakeetService.initialize()
            } catch {
                await MainActor.run {
                    offlineModelMessage = "Couldn't download the offline model. Try again."
                    showOfflineModelAlert = true
                }
            }
        }
    }

    private func prepareOfflineModelWithRetry() {
        parakeetService.clearModelCacheAndReset()
        prepareOfflineModel()
    }

    private func prepareOfflineRuntimeForSelectedModeIfNeeded() {
        guard selectedModeNeedsOfflineRuntime,
              SharedParakeetTranscriptionService.isRuntimeSupported,
              !offlineModelIsBusy,
              !parakeetService.isModelDownloaded
        else { return }

        prepareOfflineModel()
    }

    private func ensureOfflineModelReadyForRecording() -> Bool {
        guard selectedModeNeedsOfflineRuntime else {
            return true
        }

        guard SharedParakeetTranscriptionService.isRuntimeSupported else {
            offlineModelMessage = SharedParakeetTranscriptionService.unavailableMessage
            showOfflineModelAlert = true
            return false
        }

        guard !parakeetService.isModelDownloaded else {
            return true
        }

        if offlineModelIsBusy {
            offlineModelMessage = selectedRecordingMode == .meetings
                ? "Speaker detection is still downloading. Please wait until it is ready before recording."
                : "The offline model is still downloading. Please wait until it is ready before recording."
        } else {
            offlineModelMessage = selectedRecordingMode == .meetings
                ? "Download speaker detection before recording in Meetings mode."
                : "Download the offline model before recording in offline mode."
        }
        showOfflineModelAlert = true
        return false
    }

    private func openLogin() {
        showLoginSheet = true
    }

    private func prepareReferralInvite() {
        guard authManager.isAuthenticated else {
            openLogin()
            return
        }

        Task { @MainActor in
            await MainActor.run {
                isPreparingReferral = true
                referralError = nil
            }

            do {
                let user = try await authManager.ensureReferralCode()
                guard let code = user.referralCode, !code.isEmpty else {
                    throw NSError(domain: "Referral", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Your invite link is not ready yet. Please try again.",
                    ])
                }

                await MainActor.run {
                    referralShareItem = ReferralShareItem(text: ReferralProgram.inviteText(code: code))
                    isPreparingReferral = false
                }
            } catch {
                await MainActor.run {
                    referralError = "Could not create your invite link. Please try again."
                    isPreparingReferral = false
                }
                DebugLog.warning("Referral invite failed: \(error.localizedDescription)", context: "Referral")
            }
        }
    }

    private func redeemReferralCode() {
        guard authManager.isAuthenticated else {
            openLogin()
            return
        }

        let code = referralCodeToRedeem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            referralError = "Enter an invite code."
            return
        }

        Task {
            await MainActor.run {
                isRedeemingReferral = true
                referralError = nil
            }

            do {
                _ = try await authManager.redeemReferralCode(code)
                await MainActor.run {
                    referralCodeToRedeem = ""
                    referralError = "Invite applied. Extra words added."
                    isRedeemingReferral = false
                }
            } catch {
                await MainActor.run {
                    referralError = "Could not apply that invite code."
                    isRedeemingReferral = false
                }
                DebugLog.warning("Referral redeem failed: \(error.localizedDescription)", context: "Referral")
            }
        }
    }

    private func handleInlineRecordingTap() {
        DebugLog.info("inline primary action state=\(inlineRecording.state) selectedMode=\(selectedRecordingMode.displayName)", context: "KEYBOARD_DIAG")
        if inlineRecording.state == .idle {
            guard requireMobileAudioRecoveryReady() else { return }
            guard ensureCloudTranscriptionAllowedForRecording() else { return }
            guard ensureOfflineModelReadyForRecording() else { return }
        }

        inlineRecording.handlePrimaryAction(
            historyManager: historyManager,
            dictionaryManager: dictionaryManager,
            toneStyleManager: toneStyleManager,
            shortcutManager: shortcutManager,
            selectedPreset: recordingPreset(for: selectedRecordingMode, manager: toneStyleManager),
            keyboardIdentity: activeKeyboardDictationIdentity,
            keepAudioBridgeAliveAfterStop: activeKeyboardDictationIdentity != nil
        ) { recording in
            if let activeKeyboardDictationIdentity {
                DebugLog.info("completed keyboard attemptID=\(activeKeyboardDictationIdentity.attemptID) length=\(recording.transcription.count)", context: "KEYBOARD_DIAG")
                self.activeKeyboardDictationIdentity = nil
                self.showKeyboardReturnScreen = false
                self.keyboardBridgeAliveUntil = nil
                self.inlineRecording.setKeyboardAttemptIdentity(nil)
                self.inlineRecording.stopListening()
            }
            markRecordingAsNew(recording)
        }
    }

    private func ensureCloudTranscriptionAllowedForRecording() -> Bool {
        guard needsCloudTranscriptionConsentForRecording else {
            return true
        }

        showCloudTranscriptionConsent = true
        return false
    }

    private var needsCloudTranscriptionConsentForRecording: Bool {
        !transcriptionProviderManager.shouldUseOnDeviceTranscription && !CloudTranscriptionConsent.isGranted
    }

    private func startKeyboardDictation(identity: KeyboardDictationHandoff.AttemptIdentity) {
        guard mobileAudioRecoveryReady else {
            _ = KeyboardDictationHandoff.publishHostFailure(
                identity: identity,
                userMessage: "Saved recordings are still being checked. Try again in a moment."
            )
            Task { @MainActor in await recoverMobileAudioProcessingIfNeeded() }
            return
        }
        guard let snapshot = loadKeyboardSnapshot(identity: identity) else { return }
        guard snapshot.phase == .preparing else {
            if snapshot.phase == .finalizing {
                _ = KeyboardDictationHandoff.publishHostFailure(
                    identity: identity,
                    userMessage: "Recording stopped before it started."
                )
            }
            return
        }
        DebugLog.info("startKeyboardDictation attemptID=\(identity.attemptID) inlineState=\(inlineRecording.state)", context: "KEYBOARD_DIAG")

        guard inlineRecording.state == .idle else {
            _ = KeyboardDictationHandoff.publishHostFailure(
                identity: identity,
                userMessage: "Another recording is already active."
            )
            return
        }
        guard ensureCloudTranscriptionAllowedForRecording(), ensureOfflineModelReadyForRecording() else {
            _ = KeyboardDictationHandoff.publishHostFailure(
                identity: identity,
                userMessage: "Open AI Dictation and finish choosing your transcription mode."
            )
            return
        }

        activeKeyboardDictationIdentity = identity
        keepKeyboardBridgeAlive()
        dismissAllSheetsForKeyboardDictation()
        showKeyboardReturnScreen = true
        inlineRecording.setKeyboardAttemptIdentity(identity)
        handleInlineRecordingTap()
    }

    private func dismissAllSheetsForKeyboardDictation() {
        showSettings = false
        showRecordingSheet = false
        selectedRecording = nil
        recordingToShare = nil
        referralShareItem = nil
        showLoginSheet = false
    }

    private func stopKeyboardDictation(identity: KeyboardDictationHandoff.AttemptIdentity) {
        guard let snapshot = loadKeyboardSnapshot(identity: identity),
              snapshot.phase == .finalizing,
              activeKeyboardDictationIdentity == identity
        else {
            return
        }
        DebugLog.info("stopKeyboardDictation attemptID=\(identity.attemptID) inlineState=\(inlineRecording.state)", context: "KEYBOARD_DIAG")
        keepKeyboardBridgeAlive()
        dismissAllSheetsForKeyboardDictation()
        showKeyboardReturnScreen = true
        inlineRecording.setKeyboardAttemptIdentity(identity)
        if inlineRecording.state == .recording || inlineRecording.state == .paused || inlineRecording.state == .processing {
            handleInlineRecordingTap()
        } else {
            _ = KeyboardDictationHandoff.publishHostFailure(
                identity: identity,
                userMessage: "Recording was not active."
            )
        }
    }

    private func consumePendingKeyboardCommandIfNeeded() {
        guard keyboardHostLaunchReady else { return }
        reconcileActiveKeyboardAttemptIfNeeded()
        drainKeyboardDiagnostics()
        let pending: KeyboardDictationHandoff.CommandEnvelope
        do {
            guard let persisted = try KeyboardDictationHandoff.consumePendingCommandEnvelopePersisted() else {
                return
            }
            pending = persisted
        } catch {
            cancelActiveKeyboardHostWork()
            keyboardHostLaunchReady = false
            KeyboardHostLaunchRecoveryGate.ready = false
            keyboardCommandPollTask?.cancel()
            keyboardCommandPollTask = nil
            historyActionMessage = "Keyboard dictation is temporarily unavailable. Restart the app and try again."
            return
        }

        DebugLog.info("app consumed command=\(pending.command.rawValue) attemptID=\(pending.identity.attemptID)", context: "KEYBOARD_DIAG")
        switch pending.command {
        case .start:
            startKeyboardDictation(identity: pending.identity)
        case .stop:
            stopKeyboardDictation(identity: pending.identity)
        case .cancel, .shutdown:
            shutdownKeyboardDictation(identity: pending.identity)
        @unknown default:
            DebugLog.info("unknown keyboard command=\(pending.command.rawValue)", context: "KEYBOARD_DIAG")
        }
        reconcileActiveKeyboardAttemptIfNeeded()
    }

    /// The persisted snapshot is authoritative even when a cancel command aged out while the
    /// host was suspended. Reconcile it on every poll so abandoned native work cannot continue.
    private func reconcileActiveKeyboardAttemptIfNeeded() {
        guard let identity = activeKeyboardDictationIdentity else { return }
        let snapshot = loadKeyboardSnapshot(identity: identity)
        guard activeKeyboardDictationIdentity == identity else { return }
        switch KeyboardDictationHandoff.hostReconciliationAction(
            activeIdentity: identity,
            snapshot: snapshot
        ) {
        case .cancel:
            shutdownKeyboardDictation(identity: identity)
        case .stop:
            stopKeyboardDictation(identity: identity)
        case .none:
            return
        }
    }

    private func shutdownKeyboardDictation(identity: KeyboardDictationHandoff.AttemptIdentity) {
        DebugLog.info("shutdownKeyboardDictation attemptID=\(identity.attemptID) inlineState=\(inlineRecording.state)", context: "KEYBOARD_DIAG")
        guard activeKeyboardDictationIdentity == identity
                || loadKeyboardSnapshot(identity: identity)?.phase == .cancelled
        else { return }
        _ = KeyboardDictationHandoff.cancelAttempt(identity: identity)
        cancelActiveKeyboardHostWork()
    }

    /// Fails closed without touching the handoff journal. This is used when persistence itself
    /// cannot be read or written, so native work is retired while its managed source is retained.
    private func cancelActiveKeyboardHostWork() {
        guard activeKeyboardDictationIdentity != nil else { return }
        activeKeyboardDictationIdentity = nil
        showKeyboardReturnScreen = false
        keyboardBridgeAliveUntil = nil
        let reconciliation = inlineRecording.cancelAndReconcile(historyManager: historyManager)
        inlineRecording.setKeyboardAttemptIdentity(nil)
        if let reconciliation {
            Task { @MainActor in
                if let recovered = await reconciliation.value {
                    markRecordingAsNew(recovered)
                }
            }
        }
    }

    private var shouldKeepKeyboardCommandPolling: Bool {
        let hasActiveKeyboardRecording = activeKeyboardDictationIdentity != nil
            && (inlineRecording.state == .recording || inlineRecording.state == .paused || inlineRecording.state == .processing)
        let hasLiveKeyboardBridge = keyboardBridgeAliveUntil.map { $0 > Date() } ?? false
        return hasActiveKeyboardRecording || hasLiveKeyboardBridge
    }

    private func startKeyboardCommandPolling() {
        guard keyboardHostLaunchReady, keyboardCommandPollTask == nil else { return }

        DebugLog.info("start command polling", context: "KEYBOARD_DIAG")
        armQuickDictation()
        keyboardCommandPollTask = Task { @MainActor in
            while !Task.isCancelled {
                KeyboardDictationHandoff.publishAppReady()
                refreshQuickDictationHeartbeat()
                drainKeyboardDiagnostics()
                consumePendingKeyboardCommandIfNeeded()
                tearDownExpiredKeyboardBridge()
                try? await Task.sleep(nanoseconds: 250_000_000)

                // Check if we should keep polling
                let isQuickDictationActive = inlineRecording.audioRecorder.isStandbyActive
                let hasActiveKeyboardWork = shouldKeepKeyboardCommandPolling

                if scenePhase != .active, !hasActiveKeyboardWork, !isQuickDictationActive {
                    // App is in background, no active keyboard work, and no Quick Dictation standby
                    // Stop polling and let iOS suspend the app
                    DebugLog.info("stopping command polling (background, no standby)", context: "KEYBOARD_DIAG")
                    clearQuickDictation()
                    keyboardCommandPollTask = nil
                    break
                }

                // If Quick Dictation is active, check if it has expired
                if isQuickDictationActive {
                    if let availability = KeyboardDictationHandoff.loadQuickDictationAvailability(),
                       availability.expiresAt <= Date() {
                        // Quick Dictation window expired - stop standby
                        DebugLog.info("Quick Dictation window expired; stopping standby", context: "KEYBOARD_DIAG")
                        clearQuickDictation()
                        if scenePhase != .active, !hasActiveKeyboardWork {
                            keyboardCommandPollTask = nil
                            break
                        }
                    }
                }
            }
        }
    }

    /// Arms Quick Dictation with a 10-minute window using audio standby mode.
    /// The audio standby keeps iOS from suspending the app, enabling in-place dictation.
    private func armQuickDictation() {
        guard !inlineRecording.audioRecorder.isStandbyActive else {
            // Already in standby - just refresh the availability
            refreshQuickDictationHeartbeat()
            return
        }

        do {
            try inlineRecording.audioRecorder.startStandby()
            let availability = KeyboardDictationHandoff.QuickDictationAvailability()
            KeyboardDictationHandoff.saveQuickDictationAvailability(availability)
            DebugLog.info("armed Quick Dictation with audio standby until \(availability.expiresAt)", context: "KEYBOARD_DIAG")
        } catch {
            DebugLog.info("failed to arm Quick Dictation: \(error)", context: "KEYBOARD_DIAG")
            // Fall back to non-standby mode - the heartbeat will expire quickly
            let availability = KeyboardDictationHandoff.QuickDictationAvailability()
            KeyboardDictationHandoff.saveQuickDictationAvailability(availability)
        }
    }

    /// Refreshes the Quick Dictation heartbeat to indicate the app is still actively listening.
    private func refreshQuickDictationHeartbeat() {
        guard let current = KeyboardDictationHandoff.loadQuickDictationAvailability(),
              current.expiresAt > Date()
        else { return }
        let refreshed = current.refreshingHeartbeat()
        KeyboardDictationHandoff.saveQuickDictationAvailability(refreshed)
    }

    /// Clears Quick Dictation and stops audio standby.
    private func clearQuickDictation() {
        inlineRecording.audioRecorder.stopStandby(deactivateAudioSession: true)
        KeyboardDictationHandoff.clearQuickDictationAvailability()
        DebugLog.info("cleared Quick Dictation", context: "KEYBOARD_DIAG")
    }

    /// The keyboard refreshes the bridge while it is in use; once it has been
    /// quiet past the deadline, release the mic, Now Playing entry, and Live
    /// Activity instead of letting them linger until iOS kills the app.
    private func tearDownExpiredKeyboardBridge() {
        guard let expiry = keyboardBridgeAliveUntil, expiry <= Date() else { return }
        guard inlineRecording.state == .idle else { return }

        DebugLog.info("keyboard bridge expired; shutting down dictation session", context: "KEYBOARD_DIAG")
        guard let identity = activeKeyboardDictationIdentity else {
            keyboardBridgeAliveUntil = nil
            showKeyboardReturnScreen = false
            return
        }
        shutdownKeyboardDictation(identity: identity)
    }

    private func keepKeyboardBridgeAlive() {
        keyboardBridgeAliveUntil = Date().addingTimeInterval(120)
        guard keyboardHostLaunchReady else { return }
        KeyboardDictationHandoff.publishAppReady()
        refreshQuickDictationHeartbeat()
        startKeyboardCommandPolling()
    }

    private func recoverKeyboardHostLaunchIfNeeded() {
        guard !KeyboardHostLaunchRecoveryGate.attempted else {
            keyboardHostLaunchReady = KeyboardHostLaunchRecoveryGate.ready
            if keyboardHostLaunchReady {
                drainKeyboardDiagnostics()
                startKeyboardCommandPolling()
                consumePendingKeyboardCommandIfNeeded()
            }
            return
        }
        KeyboardHostLaunchRecoveryGate.attempted = true

        // Clear any stale Quick Dictation availability from a previous process.
        // A new app launch means we need to re-arm Quick Dictation fresh.
        KeyboardDictationHandoff.clearQuickDictationAvailability()

        do {
            if let abandonedIdentity = try KeyboardDictationHandoff.normalizeAfterHostLaunch() {
                if activeKeyboardDictationIdentity == abandonedIdentity {
                    activeKeyboardDictationIdentity = nil
                }
                showKeyboardReturnScreen = false
                keyboardBridgeAliveUntil = nil
            }
            // True process startup always closes stale/nonmatching Live Activities before a
            // fresh queued command is consumed.
            inlineRecording.setKeyboardAttemptIdentity(nil)
            inlineRecording.stopListening()
            KeyboardHostLaunchRecoveryGate.ready = true
            keyboardHostLaunchReady = true
            DebugLog.info("ContentView appeared; starting keyboard command polling", context: "KEYBOARD_DIAG")
            drainKeyboardDiagnostics()
            startKeyboardCommandPolling()
            consumePendingKeyboardCommandIfNeeded()
        } catch {
            cancelActiveKeyboardHostWork()
            KeyboardHostLaunchRecoveryGate.ready = false
            keyboardHostLaunchReady = false
            historyActionMessage = "Keyboard dictation is temporarily unavailable. Restart the app and try again."
        }
    }

    private func loadKeyboardSnapshot(
        identity: KeyboardDictationHandoff.AttemptIdentity
    ) -> KeyboardDictationHandoff.Snapshot? {
        do {
            return try KeyboardDictationHandoff.loadSnapshot(for: identity)
        } catch {
            cancelActiveKeyboardHostWork()
            KeyboardHostLaunchRecoveryGate.ready = false
            keyboardHostLaunchReady = false
            keyboardCommandPollTask?.cancel()
            keyboardCommandPollTask = nil
            historyActionMessage = "Keyboard dictation is temporarily unavailable. Restart the app and try again."
            return nil
        }
    }

    private func drainKeyboardDiagnostics() {
        for entry in KeyboardDictationHandoff.consumeDiagnostics() {
            DebugLog.info(entry, context: "KEYBOARD_DIAG_SHARED")
        }
    }

    private func stopKeyboardCommandPolling() {
        DebugLog.info("stop command polling", context: "KEYBOARD_DIAG")
        keyboardCommandPollTask?.cancel()
        keyboardCommandPollTask = nil
        clearQuickDictation()
    }

    private func markRecordingAsNew(_ recording: Recording) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72, blendDuration: 0.04)) {
            newlyInsertedRecordingID = recording.id
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard newlyInsertedRecordingID == recording.id else { return }
            withAnimation(.easeOut(duration: 0.24)) {
                newlyInsertedRecordingID = nil
            }
        }
    }

    private func historyDisplayText(for recording: Recording) -> String {
        recording.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Recording needs attention"
            : recording.transcription
    }

    private func deleteRecordingSafely(_ recording: Recording) {
        guard requireMobileAudioRecoveryReady() else { return }
        Task { @MainActor in
            do {
                try await MobileAudioProcessingStore.shared.tombstone(recordingID: recording.id)
                try historyManager.removeAudioFileIfPresent(for: recording)
                try await historyManager.deleteRecording(recording)
            } catch {
                historyActionMessage = "This recording could not be deleted. Please try again."
            }
        }
    }

    private func clearHistorySafely() {
        guard requireMobileAudioRecoveryReady() else { return }
        let recordings = historyManager.recordings

        if inlineRecording.isActive {
            inlineRecording.stopListening()
            if let activeKeyboardDictationIdentity {
                _ = KeyboardDictationHandoff.cancelAttempt(
                    identity: activeKeyboardDictationIdentity,
                    reason: "History cleared."
                )
            }
            activeKeyboardDictationIdentity = nil
            showKeyboardReturnScreen = false
        }

        Task { @MainActor in
            do {
                try await MobileAudioProcessingStore.shared.clearAll(
                    recordingIDs: recordings.map(\.id)
                )
                for recording in recordings {
                    try historyManager.removeAudioFileIfPresent(for: recording)
                }
                try await historyManager.clearAll(recordingIDs: recordings.map(\.id))
            } catch {
                historyActionMessage = "History could not be cleared. Please try again."
            }
        }
    }

    private func requireMobileAudioRecoveryReady() -> Bool {
        guard mobileAudioRecoveryReady else {
            historyActionMessage = "Saved recordings are still being checked. Try again in a moment."
            // Only the in-flight first pass can still block. Kick it so the next
            // tap proceeds after that pass finishes — success or failure.
            Task { @MainActor in await recoverMobileAudioProcessingIfNeeded() }
            return false
        }
        return true
    }

    private func recoverMobileAudioProcessingIfNeeded() async {
        let historyManager = historyManager
        let succeeded = await mobileAudioHostLaunchRecoveryGate.ensureReady {
            let usageRecordingIDs: [UUID]
            do {
                usageRecordingIDs = try await Self.performMobileAudioRecovery(
                    historyManager: historyManager
                )
            } catch {
                DebugLog.warning(
                    "Mobile audio recovery failed: \(error.localizedDescription)",
                    context: "ContentView"
                )
                throw error
            }
            // Recovery readiness must never wait on a usage-network request. Claims happen in
            // this follow-up task; once claimed, a request is deliberately never replayed.
            Task { @MainActor in
                for recordingID in usageRecordingIDs {
                    await MobileAudioUsageAccounting.flush(
                        recordingID: recordingID,
                        historyManager: historyManager
                    )
                }
            }
        }

        // A completed pass must never brick recording, history, or delete.
        // Offline model download is a separate path and must not keep this false.
        mobileAudioRecoveryReady = true
        if !succeeded {
            historyActionMessage = "Saved recordings need attention. Try again in a moment."
        }
    }

    @MainActor
    private static func performMobileAudioRecovery(
        historyManager: HistoryManager
    ) async throws -> [UUID] {
        try await historyManager.reload()
        _ = try await MobileAudioProcessingStore.shared.normalizeInterruptedAttempts()
        let snapshots = try await MobileAudioProcessingStore.shared.allSnapshots()
        let usageRecordingIDs = snapshots.compactMap { snapshot -> UUID? in
            guard snapshot.stage == .succeeded,
                  snapshot.usageAccountingState != .acknowledged
            else { return nil }
            return snapshot.recordingID
        }
        for snapshot in snapshots where snapshot.stage == .deleted {
            if let recording = historyManager.recordings.first(where: { $0.id == snapshot.recordingID }) {
                try historyManager.removeAudioFileIfPresent(for: recording)
                try await historyManager.deleteRecording(recording)
            }
        }

        for snapshot in snapshots
        where snapshot.stage == .succeeded
            || snapshot.stage == .failed
            || snapshot.stage == .cancelled
        {
            guard FileManager.default.fileExists(atPath: snapshot.sourcePath) else { continue }
            let text = try await MobileAudioProcessingStore.shared.recognizedText(
                for: snapshot.recordingID
            )
            if snapshot.stage == .succeeded,
               text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            {
                continue
            }
            let outputMode = snapshot.outputModeRaw.flatMap(TranscriptionOutputMode.init(rawValue:))
                ?? .dictation
            let transcriptionOptions = snapshot.transcriptionOptions
                ?? (outputMode == .meetings ? TranscriptionOptions(diarization: true) : .default)
            if let existing = historyManager.recordings.first(where: { $0.id == snapshot.recordingID }) {
                if snapshot.stage == .succeeded,
                   let text,
                   existing.transcription != text
                {
                    try await historyManager.upsertRecording(Recording(
                        id: existing.id,
                        timestamp: existing.timestamp,
                        transcription: text,
                        duration: snapshot.duration ?? existing.duration,
                        audioFileURL: snapshot.sourceURL,
                        outputMode: outputMode,
                        transcriptionOptions: snapshot.transcriptionOptions ?? existing.transcriptionOptions
                    ))
                }
            } else {
                try await historyManager.upsertRecording(Recording(
                    id: snapshot.recordingID,
                    timestamp: snapshot.createdAt,
                    transcription: text ?? "",
                    duration: snapshot.duration,
                    audioFileURL: snapshot.sourceURL,
                    outputMode: outputMode,
                    transcriptionOptions: transcriptionOptions
                ))
            }

        }
        return usageRecordingIDs
    }
}

private struct ReferralShareItem: Identifiable {
    let id = UUID()
    let text: String
}

private struct KeyboardDictationReturnView: View {
    let state: InlineRecordingState

    private var title: String {
        switch state {
        case .processing, .completing:
            return "Finishing dictation"
        default:
            return "Recording is ready"
        }
    }

    private var message: String {
        switch state {
        case .processing, .completing:
            return "Your text will appear in the keyboard when it is ready."
        default:
            return "Microphone access is active now."
        }
    }

    private var iconName: String {
        switch state {
        case .processing, .completing:
            return "text.badge.checkmark"
        default:
            return "keyboard"
        }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: iconName)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Color.dsPrimary)
                    .frame(width: 88, height: 88)
                    .background(Circle().fill(Color.dsPrimary.opacity(0.12)))

                VStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        Text("Tap the back button in the top-left corner to return to the app you were typing in.")
                    } icon: {
                        Image(systemName: "arrow.up.left.circle.fill")
                            .foregroundStyle(Color.dsPrimary)
                    }

                    Label {
                        Text("The Live Activity keeps the microphone ready for the keyboard and ends on its own shortly after you finish dictating.")
                    } icon: {
                        Image(systemName: "waveform.circle.fill")
                            .foregroundStyle(Color.dsPrimary)
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.secondary)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UsageSummaryView: View {
    let usage: (used: Int, limit: Int, percentage: Double, isPro: Bool)
    let isAuthenticated: Bool
    let email: String?
    let subscriptionTier: SubscriptionTier?

    private var remainingText: String {
        if usage.isPro {
            return "Unlimited words"
        }

        let remaining = max(0, usage.limit - usage.used)
        return "\(remaining.formatted()) words remaining"
    }

    private var planLabel: String {
        subscriptionTier?.displayName ?? (usage.isPro ? "Pro" : "Free")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Words This Month", systemImage: "text.word.spacing")
                    .font(.body.weight(.medium))
                Spacer()
	                Text(planLabel)
	                    .font(.caption.weight(.semibold))
	                    .foregroundColor(.secondary)
	                    .padding(.horizontal, 8)
	                    .padding(.vertical, 4)
	                    .background(Color(uiColor: .tertiarySystemFill))
	                    .clipShape(Capsule())
            }

            if let email {
                Text(email)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if !isAuthenticated {
                Text("Log in when you need more words.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .lastTextBaseline) {
                Text(usage.used.formatted())
                    .font(.title2.weight(.bold))
                Text(usage.isPro ? "used" : "of \(usage.limit.formatted())")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(remainingText)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.secondary)
            }

	            if !usage.isPro {
	                ProgressView(value: min(max(usage.percentage, 0), 1))
	                    .tint(.secondary)
	            }
        }
        .padding(.vertical, 6)
    }
}

private struct AccountLoginView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Log In"
        case createAccount = "Create Account"

        var id: String { rawValue }
    }

    @ObservedObject var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    @State private var isWorking = false

    private enum Field {
        case email
        case password
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedEmail.isEmpty && password.count >= 6 && !isWorking
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Account action", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .password
                        }

                    SecureField("Password", text: $password)
                        .textContentType(mode == .createAccount ? .newPassword : .password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.done)
                        .onSubmit(submit)
                } footer: {
                    Text(mode == .createAccount ? "Use at least 6 characters." : "Use the email and password for your account.")
                }

                if let message {
                    Section {
                        Text(message)
                            .foregroundColor(message == successMessage ? .secondary : .orange)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                            } else {
                                Text(mode.rawValue)
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle(mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                focusedField = .email
            }
            .onChange(of: authManager.isAuthenticated) { isAuthenticated in
                if isAuthenticated {
                    dismiss()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var successMessage: String {
        "Check your email to finish creating your account."
    }

    private func submit() {
        guard canSubmit else { return }

        isWorking = true
        message = nil

        Task {
            do {
                switch mode {
                case .signIn:
                    try await authManager.signIn(email: trimmedEmail, password: password)
                case .createAccount:
                    try await authManager.createAccount(email: trimmedEmail, password: password)
                    if !authManager.isAuthenticated {
                        message = successMessage
                    }
                }

                if authManager.isAuthenticated {
                    dismiss()
                }
            } catch {
                message = error.localizedDescription
            }

            isWorking = false
        }
    }
}

private struct ReferralInviteView: View {
    let user: User?
    let isAuthenticated: Bool
    let isLoading: Bool
    let isRedeeming: Bool
    @Binding var codeToRedeem: String
    let error: String?
    let onInvite: () -> Void
    let onRedeem: () -> Void
    let onLogin: () -> Void

    private var bonusText: String {
        guard let user, user.bonusWords > 0 else {
            return "Invite a friend and get \(ReferralProgram.bonusWordsPerReferral.formatted()) extra words when they join."
        }
        return "\(user.bonusWords.formatted()) extra words earned from invites."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Invite friends for more words", systemImage: "gift")
                .font(.body.weight(.medium))

            Text(bonusText)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                isAuthenticated ? onInvite() : onLogin()
            } label: {
                HStack {
                    if isLoading {
                        ProgressView()
                    }
                    Text(isAuthenticated ? "Share Invite" : "Log In to Invite")
                }
            }
            .disabled(isLoading)

            if isAuthenticated {
                HStack(spacing: 8) {
                    TextField("Invite code", text: $codeToRedeem)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Apply") {
                        onRedeem()
                    }
                    .disabled(isRedeeming || codeToRedeem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TranscriptionModeSelectionView: View {
    @ObservedObject var transcriptionProviderManager: TranscriptionProviderManager
    @ObservedObject var parakeetService: SharedParakeetTranscriptionService
    @State private var showCloudTranscriptionConsent = false
    let offlineModelStatusText: String
    let offlineModelStatusIcon: String
    let offlineModelTrailingIcon: String
    let offlineModelStatusColor: Color
    let offlineModelIsBusy: Bool
    let prepareOfflineModel: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(TranscriptionMode.availableCases) { mode in
                    modeButton(for: mode)
                }
            } footer: {
                Text("Cloud mode sends your voice recording and transcript to AIDictation's cloud transcription service after you allow cloud transcription. Offline mode keeps transcription on this device.")
            }

            if transcriptionProviderManager.transcriptionMode != .cloud {
                Section("Offline Model") {
                    Button(action: prepareOfflineModel) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                if offlineModelIsBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: offlineModelStatusIcon)
                                        .foregroundColor(offlineModelStatusColor)
                                }

                                Text(offlineModelStatusText)
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: 12)

                                if !offlineModelIsBusy {
                                    Image(systemName: offlineModelTrailingIcon)
                                        .foregroundColor(offlineModelStatusColor)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!SharedParakeetTranscriptionService.isRuntimeSupported)
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .alert(CloudTranscriptionConsent.alertTitle, isPresented: $showCloudTranscriptionConsent) {
            Button("Allow Cloud Transcription") {
                CloudTranscriptionConsent.grant()
                transcriptionProviderManager.setTranscriptionMode(.cloud)
            }
            Button("Use Offline Mode") {
                transcriptionProviderManager.setTranscriptionMode(.offline)
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(CloudTranscriptionConsent.disclosureMessage)
        }
    }

    private func modeButton(for mode: TranscriptionMode) -> some View {
        let isSelected = transcriptionProviderManager.transcriptionMode == mode
        let rating = modeRating(for: mode)

        return Button {
            selectMode(mode)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .primary : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.displayName)
                        .font(.body.weight(.medium))
                        .foregroundColor(.primary)

                    Text(mode.description)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                modeStars(speed: rating.speed, accuracy: rating.accuracy)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectMode(_ mode: TranscriptionMode) {
        guard mode != .cloud || CloudTranscriptionConsent.isGranted else {
            showCloudTranscriptionConsent = true
            return
        }

        transcriptionProviderManager.setTranscriptionMode(mode)
    }

    private func modeStars(speed: Int, accuracy: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ratingRow(title: "Speed", value: speed)
            ratingRow(title: "Accuracy", value: accuracy)
        }
    }

    private func ratingRow(title: String, value: Int) -> some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)

            ForEach(0 ..< 4, id: \.self) { index in
                Image(systemName: index < value ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundColor(index < value ? .primary : .secondary.opacity(0.45))
            }
        }
    }

    private func modeRating(for mode: TranscriptionMode) -> (speed: Int, accuracy: Int) {
        switch mode {
        case .cloud: return (speed: 3, accuracy: 4)
        case .offline: return (speed: 4, accuracy: 3)
        case .automatic: return (speed: 4, accuracy: 4)
        @unknown default: return (speed: 3, accuracy: 3)
        }
    }
}

// MARK: - Inline Recording

private enum InlineRecordingState: Equatable {
    case idle
    case recording
    case paused
    case processing
    case completing
}

@MainActor
private final class RecordingNowPlayingStatus {
    private enum LiveActivityPhase {
        case listening
        case processing
    }

    private var isActive = false
    private var startedAt = Date()
    private var liveActivityIdentity: KeyboardDictationHandoff.AttemptIdentity?
    private var liveActivityOperationToken = UUID()
    private var liveActivityOperationTask: Task<Void, Never>?

    func start(identity: KeyboardDictationHandoff.AttemptIdentity? = nil) {
        isActive = true
        startedAt = Date()
        liveActivityIdentity = identity

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "AI Dictation",
            MPMediaItemPropertyArtist: "Recording",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
        ]

        if #available(iOS 10.0, *) {
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        UIApplication.shared.beginReceivingRemoteControlEvents()
        if identity == nil {
            endLiveActivity()
        } else {
            startOrUpdateLiveActivity(phase: .listening)
        }
        DebugLog.info("recording now playing status started", context: "KEYBOARD_DIAG")
    }

    func processing() {
        guard isActive else { return }
        startOrUpdateLiveActivity(phase: .processing)
    }

    func stop() {
        isActive = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
        endLiveActivity()
        DebugLog.info("recording now playing status stopped", context: "KEYBOARD_DIAG")
    }

    private func startOrUpdateLiveActivity(phase: LiveActivityPhase) {
        #if canImport(ActivityKit)
            guard #available(iOS 17.0, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
                return
            }

            guard let identity = liveActivityIdentity else {
                endLiveActivity()
                return
            }
            let operationStartedAt = startedAt
            enqueueLiveActivityOperation { [weak self] token in
                guard let self, self.liveActivityOperationToken == token,
                      self.liveActivityIdentity == identity
                else { return }
                let activityPhase: KeyboardDictationActivityAttributes.Phase = phase == .processing ? .processing : .listening
                let state = KeyboardDictationActivityAttributes.ContentState(
                    phase: activityPhase,
                    startedAt: operationStartedAt
                )
                let activities = Activity<KeyboardDictationActivityAttributes>.activities
                let exactActivities = activities.filter { self.activity($0, matches: identity) }
                let activityToKeep = exactActivities.first

                for activity in activities where activity.id != activityToKeep?.id {
                    await activity.end(
                        ActivityContent(state: state, staleDate: nil),
                        dismissalPolicy: .immediate
                    )
                    guard self.liveActivityOperationToken == token,
                          self.liveActivityIdentity == identity
                    else { return }
                }

                if let activityToKeep {
                    await activityToKeep.update(ActivityContent(state: state, staleDate: nil))
                    return
                }
                guard self.liveActivityOperationToken == token,
                      self.liveActivityIdentity == identity
                else { return }
                do {
                    let attributes = KeyboardDictationActivityAttributes(identity: identity)
                    _ = try Activity.request(
                        attributes: attributes,
                        content: ActivityContent(state: state, staleDate: nil),
                        pushType: nil
                    )
                    DebugLog.info("live activity started attemptID=\(identity.attemptID)", context: "KEYBOARD_DIAG")
                } catch {
                    DebugLog.info("failed to start live activity: \(error)", context: "KEYBOARD_DIAG")
                }
            }
        #endif
    }

    private func endLiveActivity() {
        #if canImport(ActivityKit)
            guard #available(iOS 17.0, *) else { return }

            liveActivityIdentity = nil
            let operationStartedAt = startedAt
            enqueueLiveActivityOperation { [weak self] token in
                guard let self, self.liveActivityOperationToken == token else { return }
                let state = KeyboardDictationActivityAttributes.ContentState(
                    phase: .processing,
                    startedAt: operationStartedAt
                )
                for activity in Activity<KeyboardDictationActivityAttributes>.activities {
                    await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
                    guard self.liveActivityOperationToken == token else { return }
                }
            }
        #endif
    }

    #if canImport(ActivityKit)
        @available(iOS 17.0, *)
        private func activity(
            _ activity: Activity<KeyboardDictationActivityAttributes>,
            matches identity: KeyboardDictationHandoff.AttemptIdentity
        ) -> Bool {
            activity.attributes.sessionID == identity.sessionID
                && activity.attributes.attemptID == identity.attemptID
                && activity.attributes.generation == identity.generation
        }

        @available(iOS 17.0, *)
        private func enqueueLiveActivityOperation(
            _ operation: @escaping @MainActor @Sendable (UUID) async -> Void
        ) {
            let precedingTask = liveActivityOperationTask
            let token = UUID()
            liveActivityOperationToken = token
            liveActivityOperationTask = Task { @MainActor in
                if let precedingTask { await precedingTask.value }
                guard self.liveActivityOperationToken == token else { return }
                await operation(token)
                if self.liveActivityOperationToken == token {
                    self.liveActivityOperationTask = nil
                }
            }
        }
    #endif
}

struct RecordingPresetMenu: View {
    @ObservedObject var manager: ToneStyleManager
    @Binding var selectedMode: TranscriptionOutputMode
    var isEnabled = true
    var isOnDarkSurface = false

    private var title: String {
        selectedMode.displayName
    }

    var body: some View {
        Menu {
            ForEach(TranscriptionOutputMode.allCases) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    Label(mode.displayName, systemImage: selectedMode == mode ? "checkmark" : iconName(for: mode))
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: selectedMode))
                    .foregroundStyle(Color.dsPrimary)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .foregroundStyle(isOnDarkSurface ? Color.white : Color.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isOnDarkSurface ? Color.white.opacity(0.78) : Color.dsPrimary)
            }
            .font(.subheadline.weight(.medium))
            .frame(minWidth: 142)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(isOnDarkSurface ? Color.black.opacity(0.38) : Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(isOnDarkSurface ? Color.white.opacity(0.18) : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.72)
    }

    private func iconName(for mode: TranscriptionOutputMode) -> String {
        switch mode {
        case .dictation:
            return "text.cursor"
        case .notes:
            return "note.text"
        case .meetings:
            return "person.2.fill"
        @unknown default:
            return "text.cursor"
        }
    }
}

func recordingPreset(for mode: TranscriptionOutputMode, manager: ToneStyleManager) -> ContextRule? {
    switch mode {
    case .dictation:
        return nil
    case .notes:
        return manager.recordingPresets.first { $0.isNotesModeRule } ?? ContextRule(
            name: ContextRulesManager.notesRuleName,
            appBundleIds: [],
            instructions: TranscriptionOutputMode.notesPostProcessingInstruction,
            isEnabled: false
        )
    case .meetings:
        return manager.recordingPresets.first { $0.isMeetingsModeRule } ?? ContextRule(
            name: ContextRulesManager.meetingsRuleName,
            appBundleIds: [],
            instructions: ContextRulesManager.meetingsPostProcessingInstruction,
            isEnabled: false,
            transcriptionOptions: TranscriptionOptions(diarization: true)
        )
    @unknown default:
        return nil
    }
}

@MainActor
private final class InlineRecordingCoordinator: ObservableObject {
    @Published var state: InlineRecordingState = .idle
    @Published var audioLevel: Float = 0.0
    @Published var frequencyBands: [Float] = Array(repeating: 0.0, count: 10)
    @Published var errorMessage: String?
    @Published var completionText: String?

    private let audioRecorderSlot = IOSRetirableResourceSlot(factory: AudioRecorder.init)
    /// Public accessor for the audio recorder, needed for Quick Dictation standby mode.
    var audioRecorder: AudioRecorder { audioRecorderSlot.current }
    private let processingStore = MobileAudioProcessingStore.shared
    private let recordingStatus = RecordingNowPlayingStatus()
    private let subscriptionManager = SubscriptionManager.shared
    private var recordingStartTime: Date?
    private var activeAttempt: MobileAudioProcessingStore.Lease?
    private var activeAttemptTask: Task<Void, Never>?
    private var captureDeadlineTask: Task<Void, Never>?
    private var activeTranscriptionRequest: SharedTranscriptionService.RequestSnapshot?
    private var activeOutputMode: TranscriptionOutputMode?
    private var activeTranscriptionOptions: TranscriptionOptions?
    private var keyboardAttemptIdentity: KeyboardDictationHandoff.AttemptIdentity?
    private var stopRequestedWhilePreparing = false
    private var pendingAttemptID: UUID?
    private weak var pendingAttemptRecorder: AudioRecorder?
    private var cancelledPendingAttemptID: UUID?
    private var cancellationReconciliationAttemptID: UUID?
    private var recorderCancellables = Set<AnyCancellable>()

    private let minimumRecordingDuration: TimeInterval = 0.35
    private let minimumAudioFileBytes: Int64 = 1000
    private let recordingStartDeadline: TimeInterval = 5
    private let minimumFinalizationDeadline: TimeInterval = 15
    private let maximumFinalizationDeadline: TimeInterval = 120
    private let maximumRecordingDuration: TimeInterval = 4 * 60 * 60
    private let terminalCommitDeadline: TimeInterval = 3
    private let cleanupDeadline: TimeInterval = 50

    var isActive: Bool {
        state == .recording || state == .paused || state == .processing
    }

    var visualState: AIDictationRecordingState {
        switch state {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .paused:
            return .paused
        case .processing, .completing:
            return .processing
        }
    }

    var isPanelVisible: Bool {
        state != .idle || errorMessage != nil
    }

    init() {
        bindAudioRecorder(audioRecorder)
    }

    private func bindAudioRecorder(_ recorder: AudioRecorder) {
        recorder.$isRecording
            .dropFirst()
            .sink { [weak self] isRecording in
                Task { @MainActor in
                    self?.updateRecordingState(isRecording)
                }
            }
            .store(in: &recorderCancellables)

        recorder.$audioLevel
            .sink { [weak self] level in
                Task { @MainActor in
                    guard self?.state == .recording else { return }
                    self?.audioLevel = level
                    self?.publishKeyboardMeter()
                }
            }
            .store(in: &recorderCancellables)

        recorder.$frequencyBands
            .sink { [weak self] bands in
                Task { @MainActor in
                    guard self?.state == .recording else { return }
                    self?.frequencyBands = bands
                    self?.publishKeyboardMeter()
                }
            }
            .store(in: &recorderCancellables)

        recorder.$managedAttemptFailure
            .compactMap { $0 }
            .sink { [weak self] failure in
                Task { @MainActor in
                    self?.handleCaptureFailure(failure)
                }
            }
            .store(in: &recorderCancellables)
    }

    private func retireAudioRecorderIfCurrent(_ recorder: AudioRecorder) {
        let replacement = audioRecorderSlot.retire(ifCurrent: recorder)
        guard replacement !== recorder else { return }
        recorderCancellables.removeAll()
        bindAudioRecorder(replacement)
    }

    func handlePrimaryAction(
        historyManager: HistoryManager,
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager,
        selectedPreset: ContextRule?,
        keyboardIdentity: KeyboardDictationHandoff.AttemptIdentity? = nil,
        keepAudioBridgeAliveAfterStop: Bool = false,
        onCompleted: @escaping (Recording) -> Void
    ) {
        switch state {
        case .idle:
            startRecording(
                historyManager: historyManager,
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
                selectedPreset: selectedPreset,
                keyboardIdentity: keyboardIdentity,
                keepAudioBridgeAliveAfterStop: keepAudioBridgeAliveAfterStop,
                onCompleted: onCompleted
            )
        case .recording, .paused:
            stopRecording(
                historyManager: historyManager,
                keepAudioBridgeAliveAfterStop: keepAudioBridgeAliveAfterStop,
                onCompleted: onCompleted
            )
        case .processing:
            if activeAttempt != nil {
                stopRequestedWhilePreparing = true
            }
        case .completing:
            break
        }
    }

    func togglePauseRecording() {
        switch state {
        case .recording:
            audioRecorder.pauseRecording()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                state = .paused
                audioLevel = 0
                frequencyBands = Array(repeating: 0.0, count: 10)
            }
        case .paused:
            audioRecorder.resumeRecording()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                state = .recording
            }
        case .idle, .processing, .completing:
            break
        }
    }

    func setKeyboardAttemptIdentity(_ identity: KeyboardDictationHandoff.AttemptIdentity?) {
        keyboardAttemptIdentity = identity
        DebugLog.info(
            "set keyboard meter attemptID=\(identity?.attemptID ?? "nil")",
            context: "KEYBOARD_DIAG"
        )
        if identity == nil {
            KeyboardDictationHandoff.clearMeter()
        }
    }

    private func publishKeyboardMeter() {
        guard let identity = keyboardAttemptIdentity else { return }
        if audioLevel > 0.02 {
            DebugLog.info("app meter attemptID=\(identity.attemptID) level=\(String(format: "%.3f", audioLevel)) bands=\(frequencyBands.count)", context: "KEYBOARD_DIAG")
        }
        KeyboardDictationHandoff.publishMeter(
            audioLevel: audioLevel,
            frequencyBands: frequencyBands,
            identity: identity
        )
    }

    private func handleCaptureFailure(_ failure: ManagedAudioRecordingFailure) {
        guard let lease = activeAttempt,
              lease.attemptID == failure.attemptID,
              state == .recording || state == .paused
        else { return }

        activeAttemptTask?.cancel()
        captureDeadlineTask?.cancel()
        let abandonedRecorder = audioRecorder
        retireAudioRecorderIfCurrent(abandonedRecorder)
        let identity = keyboardAttemptIdentity
        activeAttemptTask = Task { @MainActor in
            let terminalResult = await processingStore.commitTerminalState(
                .failed(
                    message: failure.error.localizedDescription,
                    integrity: .knownIncomplete
                ),
                lease: lease,
                timeout: terminalCommitDeadline
            )
            Task {
                await abandonedRecorder.abandonRecording(
                    attemptID: lease.attemptID,
                    deactivateAudioSession: false
                )
                try? await processingStore.purgePayloadsIfDeleted(recordingID: lease.recordingID)
            }
            guard activeAttempt == lease else { return }
            let message = terminalDisplayMessage(
                for: terminalResult,
                fallback: failure.error.localizedDescription
            )
            if case .superseded = terminalResult {
                activeAttempt = nil
                activeAttemptTask = nil
                reset(keepAudioBridgeAlive: false)
                return
            }
            if let identity, keyboardAttemptIdentity == identity {
                _ = KeyboardDictationHandoff.publishHostFailure(
                    identity: identity,
                    recordingID: lease.recordingID.uuidString,
                    userMessage: message ?? failure.error.localizedDescription
                )
            }
            activeAttempt = nil
            activeAttemptTask = nil
            showError(message ?? failure.error.localizedDescription)
        }
    }

    func dismissError() {
        withAnimation(.easeInOut(duration: 0.2)) {
            errorMessage = nil
        }
    }

    func stopListening() {
        activeAttemptTask?.cancel()
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        if let pendingAttemptID {
            cancelledPendingAttemptID = pendingAttemptID
            self.pendingAttemptID = nil
            if let pendingAttemptRecorder {
                retireAudioRecorderIfCurrent(pendingAttemptRecorder)
            }
            pendingAttemptRecorder = nil
        }
        guard let activeAttempt else {
            audioRecorder.stopMonitoring()
            recordingStatus.stop()
            recordingStartTime = nil
            activeAttemptTask = nil
            activeTranscriptionRequest = nil
            activeOutputMode = nil
            activeTranscriptionOptions = nil
            keyboardAttemptIdentity = nil
            stopRequestedWhilePreparing = false
            state = .idle
            audioLevel = 0
            frequencyBands = Array(repeating: 0.0, count: 10)
            completionText = nil
            errorMessage = nil
            return
        }

        let recorder = audioRecorder
        retireAudioRecorderIfCurrent(recorder)
        let identity = keyboardAttemptIdentity
        cancellationReconciliationAttemptID = activeAttempt.attemptID
        activeAttemptTask = Task { @MainActor in
            let terminalResult = await processingStore.commitTerminalState(
                .cancelled(message: "Processing cancelled."),
                lease: activeAttempt,
                timeout: terminalCommitDeadline
            )
            Task {
                await recorder.abandonRecording(
                    attemptID: activeAttempt.attemptID,
                    deactivateAudioSession: false
                )
                try? await processingStore.purgePayloadsIfDeleted(
                    recordingID: activeAttempt.recordingID
                )
            }
            guard self.activeAttempt == activeAttempt else { return }

            var persistenceWarning: String?
            switch terminalResult {
            case .committed(let snapshot) where snapshot.stage == .succeeded:
                do {
                    let store = processingStore
                    let recoveredText = try await IOSAudioProcessingDeadline.run(
                        seconds: terminalCommitDeadline
                    ) {
                        try await store.recognizedText(
                            for: activeAttempt.recordingID
                        )
                    }
                    guard let recoveredText,
                          !recoveredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { throw MobileAudioProcessingStore.StoreError.emptyResult }
                    if let identity {
                        _ = KeyboardDictationHandoff.publishHostResult(
                            text: recoveredText,
                            identity: identity,
                            recordingID: activeAttempt.recordingID.uuidString
                        )
                    }
                } catch {
                    persistenceWarning = MobileAudioProcessingStore.terminalPersistenceWarning
                }
            case .committed:
                if let identity {
                    _ = KeyboardDictationHandoff.cancelAttempt(identity: identity)
                }
            case .persistenceUnavailable:
                persistenceWarning = MobileAudioProcessingStore.terminalPersistenceWarning
                if let identity {
                    _ = KeyboardDictationHandoff.publishHostFailure(
                        identity: identity,
                        recordingID: activeAttempt.recordingID.uuidString,
                        userMessage: MobileAudioProcessingStore.terminalPersistenceWarning
                    )
                }
            case .superseded:
                break
            @unknown default:
                persistenceWarning = MobileAudioProcessingStore.terminalPersistenceWarning
            }

            self.activeAttempt = nil
            activeAttemptTask = nil
            cancellationReconciliationAttemptID = nil
            keyboardAttemptIdentity = nil
            if let persistenceWarning {
                showError(persistenceWarning)
            } else {
                errorMessage = nil
                reset(keepAudioBridgeAlive: false)
            }
        }
    }

    /// Cancels the active native work immediately, then reconciles any complete raw transcript
    /// that won the race with cancellation into the same durable completion side effects.
    func cancelAndReconcile(
        historyManager: HistoryManager
    ) -> Task<Recording?, Never>? {
        guard let lease = activeAttempt else {
            stopListening()
            return nil
        }

        activeAttemptTask?.cancel()
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        let recorder = audioRecorder
        let outputMode = activeOutputMode ?? .dictation
        let transcriptionOptions = activeTranscriptionOptions ?? .default
        let fallbackDuration = max(0, Date().timeIntervalSince(recordingStartTime ?? Date()))

        retireAudioRecorderIfCurrent(recorder)
        cancellationReconciliationAttemptID = lease.attemptID

        return Task { @MainActor in
            let terminalResult = await processingStore.commitTerminalState(
                .cancelled(message: "Processing cancelled."),
                lease: lease,
                timeout: terminalCommitDeadline
            )
            Task {
                await recorder.abandonRecording(
                    attemptID: lease.attemptID,
                    deactivateAudioSession: false
                )
                try? await processingStore.purgePayloadsIfDeleted(recordingID: lease.recordingID)
            }
            guard activeAttempt == lease else { return nil }

            guard case .committed(let snapshot) = terminalResult,
                  snapshot.stage == .succeeded
            else {
                activeAttempt = nil
                activeAttemptTask = nil
                cancellationReconciliationAttemptID = nil
                if terminalResult == .persistenceUnavailable {
                    showError(MobileAudioProcessingStore.terminalPersistenceWarning)
                } else {
                    errorMessage = nil
                    reset(keepAudioBridgeAlive: false)
                }
                return nil
            }

            let recoveredText: String?
            do {
                let store = processingStore
                recoveredText = try await IOSAudioProcessingDeadline.run(
                    seconds: terminalCommitDeadline
                ) {
                    try await store.recognizedText(for: lease.recordingID)
                }
            } catch {
                activeAttempt = nil
                activeAttemptTask = nil
                cancellationReconciliationAttemptID = nil
                showError(MobileAudioProcessingStore.terminalPersistenceWarning)
                return nil
            }
            guard let recoveredText,
                  !recoveredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                activeAttempt = nil
                activeAttemptTask = nil
                cancellationReconciliationAttemptID = nil
                showError(MobileAudioProcessingStore.terminalPersistenceWarning)
                return nil
            }

            let recording = Recording(
                id: lease.recordingID,
                transcription: recoveredText,
                duration: snapshot.duration ?? fallbackDuration,
                audioFileURL: snapshot.sourceURL,
                outputMode: outputMode,
                transcriptionOptions: snapshot.transcriptionOptions ?? transcriptionOptions
            )
            do {
                try await IOSAudioProcessingDeadline.runOnMainActor(
                    seconds: terminalCommitDeadline
                ) {
                    guard self.activeAttempt == lease, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    try await self.replaceHistoryRecording(recording, in: historyManager)
                }
            } catch {
                activeAttempt = nil
                activeAttemptTask = nil
                cancellationReconciliationAttemptID = nil
                showError(MobileAudioProcessingStore.terminalPersistenceWarning)
                return nil
            }
            activeAttempt = nil
            activeAttemptTask = nil
            cancellationReconciliationAttemptID = nil
            errorMessage = nil
            reset(keepAudioBridgeAlive: false)
            await MobileAudioUsageAccounting.flush(
                recordingID: lease.recordingID,
                historyManager: historyManager,
                store: processingStore,
                subscriptionManager: subscriptionManager
            )
            return recording
        }
    }

    private func startRecording(
        historyManager: HistoryManager,
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager,
        selectedPreset: ContextRule?,
        keyboardIdentity: KeyboardDictationHandoff.AttemptIdentity?,
        keepAudioBridgeAliveAfterStop: Bool,
        onCompleted: @escaping (Recording) -> Void
    ) {
        dismissError()
        DebugLog.info("inline startRecording permission=\(AVAudioSession.sharedInstance().recordPermission.rawValue)", context: "KEYBOARD_DIAG")

        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            DebugLog.info("inline start blocked by subscription reason=\(access.reason ?? "nil")", context: "KEYBOARD_DIAG")
            let message = access.reason ?? "Log in to continue transcribing."
            publishKeyboardStartFailure(identity: keyboardIdentity, message: message)
            showError(message)
            return
        }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            beginRecording(
                historyManager: historyManager,
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
                selectedPreset: selectedPreset,
                keyboardIdentity: keyboardIdentity,
                keepAudioBridgeAliveAfterStop: keepAudioBridgeAliveAfterStop,
                onCompleted: onCompleted
            )
        case .denied:
            let message = "Microphone permission denied. Please enable it in Settings."
            publishKeyboardStartFailure(identity: keyboardIdentity, message: message)
            showError(message)
        case .undetermined:
            DebugLog.info("requesting microphone permission", context: "KEYBOARD_DIAG")
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    DebugLog.info("microphone permission response granted=\(granted)", context: "KEYBOARD_DIAG")
                    if granted {
                        self?.beginRecording(
                            historyManager: historyManager,
                            dictionaryManager: dictionaryManager,
                            toneStyleManager: toneStyleManager,
                            shortcutManager: shortcutManager,
                            selectedPreset: selectedPreset,
                            keyboardIdentity: keyboardIdentity,
                            keepAudioBridgeAliveAfterStop: keepAudioBridgeAliveAfterStop,
                            onCompleted: onCompleted
                        )
                    } else {
                        let message = "Microphone permission denied. Please enable it in Settings."
                        self?.publishKeyboardStartFailure(identity: keyboardIdentity, message: message)
                        self?.showError(message)
                    }
                }
            }
        @unknown default:
            let message = "Unable to check microphone permission."
            publishKeyboardStartFailure(identity: keyboardIdentity, message: message)
            showError(message)
        }
    }

    private func beginRecording(
        historyManager: HistoryManager,
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager,
        selectedPreset: ContextRule?,
        keyboardIdentity: KeyboardDictationHandoff.AttemptIdentity?,
        keepAudioBridgeAliveAfterStop: Bool,
        onCompleted: @escaping (Recording) -> Void
    ) {
        DebugLog.info("inline beginRecording", context: "KEYBOARD_DIAG")
        let startOutputMode = recordingOutputMode(for: selectedPreset)
        let startOptions = selectedPreset?.transcriptionOptions ?? .default
        let request: SharedTranscriptionService.RequestSnapshot
        do {
            request = try SharedTranscriptionService.RequestSnapshot.capture(
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
                outputMode: startOutputMode,
                transcriptionOptions: startOptions,
                selectedPreset: selectedPreset
            )
        } catch {
            let message = userMessage(for: error)
            publishKeyboardStartFailure(identity: keyboardIdentity, message: message)
            showError(message)
            return
        }

        recordingStartTime = nil
        activeOutputMode = startOutputMode
        activeTranscriptionOptions = startOptions
        activeTranscriptionRequest = request
        self.keyboardAttemptIdentity = keyboardIdentity
        stopRequestedWhilePreparing = false
        cancellationReconciliationAttemptID = nil
        errorMessage = nil
        audioLevel = 0
        frequencyBands = Array(repeating: 0.0, count: 10)

        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            state = .processing
        }

        let recordingID = UUID()
        let attemptID = UUID()
        let recorder = audioRecorder
        pendingAttemptID = attemptID
        pendingAttemptRecorder = recorder
        activeAttemptTask?.cancel()
        activeAttemptTask = Task { @MainActor in
            var lease: MobileAudioProcessingStore.Lease?
            do {
                let prepared = try await processingStore.beginNewAttempt(
                    recordingID: recordingID,
                    attemptID: attemptID,
                    outputModeRaw: startOutputMode.rawValue,
                    transcriptionOptions: startOptions,
                    deadlineAt: Date().addingTimeInterval(recordingStartDeadline)
                )
                lease = prepared
                guard pendingAttemptID == attemptID,
                      cancelledPendingAttemptID != attemptID,
                      !Task.isCancelled
                else { throw CancellationError() }
                pendingAttemptID = nil
                pendingAttemptRecorder = nil
                activeAttempt = prepared
                if let keyboardIdentity {
                    guard KeyboardDictationHandoff.snapshot(for: keyboardIdentity)?.phase == .preparing else {
                        throw CancellationError()
                    }
                    guard KeyboardDictationHandoff.publishHostPhase(
                        .recording,
                        identity: keyboardIdentity,
                        recordingID: prepared.recordingID.uuidString
                    ) else {
                        throw CancellationError()
                    }
                }

                _ = try await IOSAudioProcessingDeadline.run(seconds: recordingStartDeadline) {
                    try await recorder.startRecording(
                        at: prepared.sourceURL,
                        attemptID: prepared.attemptID
                    )
                }
                let captureDeadline = Date().addingTimeInterval(maximumRecordingDuration)
                try await processingStore.captureBecameReady(
                    prepared,
                    deadlineAt: captureDeadline
                )
                guard activeAttempt == prepared, !Task.isCancelled else {
                    throw CancellationError()
                }

                recordingStartTime = Date()
                recordingStatus.start(identity: keyboardIdentity)
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    state = .recording
                }
                activeAttemptTask = nil
                scheduleCaptureDeadline(
                    for: prepared,
                    deadlineAt: captureDeadline,
                    historyManager: historyManager,
                    keepAudioBridgeAliveAfterStop: keepAudioBridgeAliveAfterStop,
                    onCompleted: onCompleted
                )

                if stopRequestedWhilePreparing {
                    stopRequestedWhilePreparing = false
                    stopRecording(
                        historyManager: historyManager,
                        keepAudioBridgeAliveAfterStop: keepAudioBridgeAliveAfterStop,
                        onCompleted: onCompleted
                    )
                }
            } catch {
                var terminalResult: MobileAudioProcessingStore.TerminalCommitResult?
                if let lease {
                    retireAudioRecorderIfCurrent(recorder)
                    terminalResult = await persistTerminalState(
                        lease: lease,
                        error: error,
                        integrity: .unfinalized
                    )
                    Task {
                        await recorder.abandonRecording(
                            attemptID: lease.attemptID,
                            deactivateAudioSession: false
                        )
                        try? await processingStore.purgePayloadsIfDeleted(recordingID: lease.recordingID)
                    }
                }
                let terminalMessage = terminalDisplayMessage(
                    for: terminalResult,
                    fallback: error is CancellationError
                        ? "Recording cancelled."
                        : userMessage(for: error)
                )
                if let keyboardIdentity,
                   !(error is CancellationError),
                   terminalResult != .superseded
                {
                    _ = KeyboardDictationHandoff.publishHostFailure(
                        identity: keyboardIdentity,
                        recordingID: lease?.recordingID.uuidString,
                        userMessage: terminalMessage ?? userMessage(for: error)
                    )
                }
                let stillOwnsSurface = pendingAttemptID == attemptID
                    || activeAttempt?.attemptID == attemptID
                if pendingAttemptID == attemptID {
                    pendingAttemptID = nil
                    pendingAttemptRecorder = nil
                }
                let cancellationWon = cancelledPendingAttemptID == attemptID
                if cancellationWon {
                    cancelledPendingAttemptID = nil
                }
                guard !cancellationWon, stillOwnsSurface else { return }
                guard activeAttempt?.attemptID == attemptID || activeAttempt == nil else { return }
                activeAttempt = nil
                activeAttemptTask = nil
                if let terminalMessage {
                    showError(terminalMessage)
                } else {
                    reset(keepAudioBridgeAlive: false)
                }
            }
        }
    }

    private func scheduleCaptureDeadline(
        for lease: MobileAudioProcessingStore.Lease,
        deadlineAt: Date,
        historyManager: HistoryManager,
        keepAudioBridgeAliveAfterStop: Bool,
        onCompleted: @escaping (Recording) -> Void
    ) {
        captureDeadlineTask?.cancel()
        captureDeadlineTask = Task { @MainActor in
            let remaining = max(0, deadlineAt.timeIntervalSinceNow)
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return
            }
            guard activeAttempt == lease,
                  state == .recording || state == .paused
            else { return }
            stopRecording(
                historyManager: historyManager,
                keepAudioBridgeAliveAfterStop: keepAudioBridgeAliveAfterStop,
                onCompleted: onCompleted
            )
        }
    }

    private func stopRecording(
        historyManager: HistoryManager,
        keepAudioBridgeAliveAfterStop: Bool,
        onCompleted: @escaping (Recording) -> Void
    ) {
        guard let activeAttempt,
              let request = activeTranscriptionRequest,
              let outputMode = activeOutputMode,
              let transcriptionOptions = activeTranscriptionOptions
        else {
            showError("Recording could not be finished. Please try again.")
            return
        }
        DebugLog.info("inline stopRecording state=\(state) mode=\(outputMode.rawValue)", context: "KEYBOARD_DIAG")
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        if !keepAudioBridgeAliveAfterStop {
            recordingStatus.stop()
        } else {
            recordingStatus.processing()
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            state = .processing
            audioLevel = 0
            frequencyBands = Array(repeating: 0.0, count: 10)
        }

        let recorder = audioRecorder
        let capturedDuration = max(0, Date().timeIntervalSince(recordingStartTime ?? Date()))
        let finalizationSeconds = max(
            minimumFinalizationDeadline,
            min(maximumFinalizationDeadline, 10 + (capturedDuration * 0.05))
        )
        let finalizationDeadlineAt = Date().addingTimeInterval(finalizationSeconds)
        activeAttemptTask?.cancel()
        activeAttemptTask = Task { @MainActor in
            var recorderClosed = false
            do {
                try await processingStore.beginFinalization(
                    activeAttempt,
                    deadlineAt: finalizationDeadlineAt
                )
                if let keyboardAttemptIdentity {
                    guard KeyboardDictationHandoff.publishHostPhase(
                        .finalizing,
                        identity: keyboardAttemptIdentity,
                        recordingID: activeAttempt.recordingID.uuidString,
                        deadlineAt: finalizationDeadlineAt
                    ) else {
                        throw CancellationError()
                    }
                }

                let partialURL = try await IOSAudioProcessingDeadline.run(
                    seconds: finalizationSeconds
                ) {
                    try await recorder.stopRecording(
                        attemptID: activeAttempt.attemptID,
                        deactivateAudioSession: !keepAudioBridgeAliveAfterStop
                    )
                }
                recorderClosed = true
                guard self.activeAttempt == activeAttempt, !Task.isCancelled else {
                    throw CancellationError()
                }

                if keepAudioBridgeAliveAfterStop {
                    audioRecorder.startMonitoring()
                    recordingStatus.start(identity: keyboardAttemptIdentity)
                }

                guard partialURL == activeAttempt.sourceURL else {
                    throw MobileAudioProcessingStore.StoreError.sourceConflict
                }
                let proof = try await processingStore.proveFinalizedSource(
                    activeAttempt,
                    minimumBytes: minimumAudioFileBytes,
                    minimumDuration: minimumRecordingDuration
                )
                try await processingStore.checkpointFinalizedSourceProof(
                    activeAttempt,
                    proof: proof
                )
                let finalized = try await processingStore.acceptFinalizedSource(
                    activeAttempt,
                    proof: proof
                )
                guard self.activeAttempt == activeAttempt, !Task.isCancelled else {
                    throw CancellationError()
                }

                if let keyboardAttemptIdentity {
                    guard KeyboardDictationHandoff.publishHostPhase(
                        .processing,
                        identity: keyboardAttemptIdentity,
                        recordingID: activeAttempt.recordingID.uuidString
                    ) else {
                        throw CancellationError()
                    }
                }

                await transcribeAudio(
                    audioURL: finalized.url,
                    lease: activeAttempt,
                    duration: finalized.duration,
                    historyManager: historyManager,
                    outputMode: outputMode,
                    transcriptionOptions: transcriptionOptions,
                    request: request,
                    keepAudioBridgeAlive: keepAudioBridgeAliveAfterStop,
                    onCompleted: onCompleted
                )
            } catch {
                if !recorderClosed {
                    retireAudioRecorderIfCurrent(recorder)
                }
                let integrity: MobileAudioProcessingStore.SourceIntegrity =
                    recorderClosed
                        || (error as? MobileAudioProcessingStore.StoreError) == .sourceIncomplete
                    ? .knownIncomplete
                    : .unfinalized
                let terminalResult = await persistTerminalState(
                    lease: activeAttempt,
                    error: error,
                    integrity: integrity
                )
                Task {
                    await recorder.abandonRecording(
                        attemptID: activeAttempt.attemptID,
                        deactivateAudioSession: false
                    )
                    try? await processingStore.purgePayloadsIfDeleted(
                        recordingID: activeAttempt.recordingID
                    )
                }
                guard self.activeAttempt == activeAttempt else { return }
                let fallbackMessage = error is CancellationError
                    ? "Processing cancelled."
                    : userMessage(for: error)
                if recorderClosed {
                    await finishTerminalRecording(
                        lease: activeAttempt,
                        audioURL: activeAttempt.sourceURL,
                        duration: capturedDuration,
                        historyManager: historyManager,
                        outputMode: outputMode,
                        transcriptionOptions: transcriptionOptions,
                        fallbackMessage: fallbackMessage,
                        terminalResult: terminalResult,
                        keepAudioBridgeAlive: keepAudioBridgeAliveAfterStop,
                        onCompleted: onCompleted
                    )
                    return
                }
                if let keyboardAttemptIdentity,
                   terminalResult != .superseded
                {
                    _ = KeyboardDictationHandoff.publishHostFailure(
                        identity: keyboardAttemptIdentity,
                        recordingID: activeAttempt.recordingID.uuidString,
                        userMessage: terminalDisplayMessage(
                            for: terminalResult,
                            fallback: fallbackMessage
                        ) ?? fallbackMessage
                    )
                }
                self.activeAttempt = nil
                activeAttemptTask = nil
                if let message = terminalDisplayMessage(
                    for: terminalResult,
                    fallback: fallbackMessage
                ) {
                    showError(message)
                } else {
                    reset(keepAudioBridgeAlive: false)
                }
            }
        }
    }

    private func transcribeAudio(
        audioURL: URL,
        lease: MobileAudioProcessingStore.Lease,
        duration: TimeInterval,
        historyManager: HistoryManager,
        outputMode: TranscriptionOutputMode,
        transcriptionOptions: TranscriptionOptions,
        request: SharedTranscriptionService.RequestSnapshot,
        keepAudioBridgeAlive: Bool = false,
        onCompleted: @escaping (Recording) -> Void
    ) async {
        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            let message = access.reason ?? "Log in to continue transcribing."
            let terminalResult = await processingStore.commitTerminalState(
                .failed(message: message, integrity: .complete),
                lease: lease,
                timeout: terminalCommitDeadline
            )
            guard activeAttempt == lease else { return }
            await finishTerminalRecording(
                lease: lease,
                audioURL: audioURL,
                duration: duration,
                historyManager: historyManager,
                outputMode: outputMode,
                transcriptionOptions: transcriptionOptions,
                fallbackMessage: message,
                terminalResult: terminalResult,
                keepAudioBridgeAlive: keepAudioBridgeAlive,
                onCompleted: onCompleted
            )
            return
        }

        do {
            let deadline = max(90, min(600, (duration * 2) + 60))
            let recognitionURL = try await processingStore.beginRecognition(
                lease,
                deadlineAt: Date().addingTimeInterval(deadline)
            )
            let chunkWorkspace = try await processingStore.makeChunkWorkspace(for: lease)
            defer { chunkWorkspace.cleanupAll() }
            let cleanupStageDeadline = cleanupDeadline
            let processedResult = try await MobileAudioStageDeadline.run(
                recognitionSeconds: deadline,
                cleanupSeconds: cleanupStageDeadline
            ) { cleanupDidStart in
                try await SharedTranscriptionService.transcribe(
                    audioURL: recognitionURL,
                    request: request,
                    chunkWorkspace: chunkWorkspace,
                    onRecognitionCheckpoint: { checkpoint in
                        try await self.processingStore.checkpointRecognitionPartial(checkpoint, lease: lease)
                    },
                    onRawTranscript: { raw in
                        try await self.processingStore.checkpointRawTranscript(raw, lease: lease)
                    },
                    onCleanupStarted: {
                        try await self.processingStore.cleanupStarted(
                            lease,
                            deadlineAt: Date().addingTimeInterval(cleanupStageDeadline)
                        )
                        cleanupDidStart()
                    }
                )
            }
            guard activeAttempt == lease, !Task.isCancelled else { throw CancellationError() }
            let successPersistenceDeadline = Date().addingTimeInterval(terminalCommitDeadline)
            let terminalResult = await processingStore.commitTerminalState(
                .succeeded(text: processedResult),
                lease: lease,
                timeout: terminalCommitDeadline
            )
            guard activeAttempt == lease, !Task.isCancelled else { return }
            guard case .committed(let successSnapshot) = terminalResult,
                  successSnapshot.stage == .succeeded
            else {
                await finishTerminalRecording(
                    lease: lease,
                    audioURL: audioURL,
                    duration: duration,
                    historyManager: historyManager,
                    outputMode: outputMode,
                    transcriptionOptions: transcriptionOptions,
                    fallbackMessage: MobileAudioProcessingStore.terminalPersistenceWarning,
                    terminalResult: terminalResult,
                    keepAudioBridgeAlive: keepAudioBridgeAlive,
                    onCompleted: onCompleted
                )
                return
            }

            let remainingPersistenceTime =
                successPersistenceDeadline.timeIntervalSinceNow
            guard remainingPersistenceTime > 0 else {
                activeAttempt = nil
                activeAttemptTask = nil
                if let keyboardAttemptIdentity {
                    _ = KeyboardDictationHandoff.publishHostFailure(
                        identity: keyboardAttemptIdentity,
                        recordingID: lease.recordingID.uuidString,
                        userMessage: MobileAudioProcessingStore.terminalPersistenceWarning
                    )
                }
                showError(MobileAudioProcessingStore.terminalPersistenceWarning)
                return
            }
            let durableResult: String
            do {
                durableResult = try await IOSAudioProcessingDeadline.runOnMainActor(
                    seconds: remainingPersistenceTime
                ) {
                    guard self.activeAttempt == lease, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    guard let storedText = try await self.processingStore.recognizedText(
                        for: lease.recordingID
                    ),
                    !storedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { throw MobileAudioProcessingStore.StoreError.emptyResult }
                    let recording = Recording(
                        id: lease.recordingID,
                        transcription: storedText,
                        duration: duration,
                        audioFileURL: audioURL,
                        outputMode: outputMode,
                        transcriptionOptions: transcriptionOptions
                    )
                    try await self.replaceHistoryRecording(recording, in: historyManager)
                    guard self.activeAttempt == lease, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    return storedText
                }
            } catch {
                activeAttempt = nil
                activeAttemptTask = nil
                if let keyboardAttemptIdentity {
                    _ = KeyboardDictationHandoff.publishHostFailure(
                        identity: keyboardAttemptIdentity,
                        recordingID: lease.recordingID.uuidString,
                        userMessage: MobileAudioProcessingStore.terminalPersistenceWarning
                    )
                }
                showError(MobileAudioProcessingStore.terminalPersistenceWarning)
                return
            }
            let recording = Recording(
                id: lease.recordingID,
                transcription: durableResult,
                duration: duration,
                audioFileURL: audioURL,
                outputMode: outputMode,
                transcriptionOptions: transcriptionOptions
            )
            let keyboardDeliverySucceeded: Bool
            if let keyboardAttemptIdentity {
                keyboardDeliverySucceeded = KeyboardDictationHandoff.publishHostResult(
                    text: durableResult,
                    identity: keyboardAttemptIdentity,
                    recordingID: lease.recordingID.uuidString
                )
            } else {
                keyboardDeliverySucceeded = true
            }

            withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) {
                activeAttempt = nil
                activeAttemptTask = nil
                reset(keepAudioBridgeAlive: false)
            }

            onCompleted(recording)
            if !keyboardDeliverySucceeded {
                showError("Your transcription was saved in History, but it could not be sent to the keyboard.")
            }
            // Completion is already durable and the UI is idle; keep usage
            // accounting structured so app suspension cannot silently drop it.
            await MobileAudioUsageAccounting.flush(
                recordingID: lease.recordingID,
                historyManager: historyManager,
                store: processingStore,
                subscriptionManager: subscriptionManager
            )
        } catch {
            let terminalResult = await persistTerminalState(
                lease: lease,
                error: error,
                integrity: .complete
            )
            guard cancellationReconciliationAttemptID != lease.attemptID else { return }
            guard activeAttempt == lease else { return }
            await finishTerminalRecording(
                lease: lease,
                audioURL: audioURL,
                duration: duration,
                historyManager: historyManager,
                outputMode: outputMode,
                transcriptionOptions: transcriptionOptions,
                fallbackMessage: error is CancellationError
                    ? "Processing cancelled."
                    : userMessage(for: error),
                terminalResult: terminalResult,
                keepAudioBridgeAlive: keepAudioBridgeAlive,
                onCompleted: onCompleted
            )
        }
    }

    private func finishTerminalRecording(
        lease: MobileAudioProcessingStore.Lease,
        audioURL: URL,
        duration: TimeInterval,
        historyManager: HistoryManager,
        outputMode: TranscriptionOutputMode,
        transcriptionOptions: TranscriptionOptions,
        fallbackMessage: String,
        terminalResult: MobileAudioProcessingStore.TerminalCommitResult,
        keepAudioBridgeAlive: Bool,
        onCompleted: @escaping (Recording) -> Void
    ) async {
        guard activeAttempt == lease else { return }
        guard case .committed(let snapshot) = terminalResult else {
            let message = terminalDisplayMessage(for: terminalResult, fallback: fallbackMessage)
            if terminalResult != .superseded, let keyboardAttemptIdentity {
                _ = KeyboardDictationHandoff.publishHostFailure(
                    identity: keyboardAttemptIdentity,
                    recordingID: lease.recordingID.uuidString,
                    userMessage: message ?? fallbackMessage
                )
            }
            activeAttempt = nil
            activeAttemptTask = nil
            if let message {
                showError(message)
            } else {
                reset(keepAudioBridgeAlive: false)
            }
            return
        }
        let recoveredText: String?
        do {
            recoveredText = try await IOSAudioProcessingDeadline.runOnMainActor(
                seconds: terminalCommitDeadline
            ) {
                guard self.activeAttempt == lease, !Task.isCancelled else {
                    throw CancellationError()
                }
                let text = try await self.processingStore.recognizedText(for: lease.recordingID)
                let recording = Recording(
                    id: lease.recordingID,
                    transcription: text ?? "",
                    duration: snapshot.duration ?? duration,
                    audioFileURL: snapshot.sourceURL,
                    outputMode: outputMode,
                    transcriptionOptions: transcriptionOptions
                )
                try await self.replaceHistoryRecording(recording, in: historyManager)
                guard self.activeAttempt == lease, !Task.isCancelled else {
                    throw CancellationError()
                }
                return text
            }
        } catch {
            let message = MobileAudioProcessingStore.terminalPersistenceWarning
            if let keyboardAttemptIdentity {
                _ = KeyboardDictationHandoff.publishHostFailure(
                    identity: keyboardAttemptIdentity,
                    recordingID: lease.recordingID.uuidString,
                    userMessage: message
                )
            }
            activeAttempt = nil
            activeAttemptTask = nil
            showError(message)
            return
        }
        let succeeded = snapshot.stage == .succeeded
        let message = snapshot.userMessage ?? fallbackMessage
        let recording = Recording(
            id: lease.recordingID,
            transcription: recoveredText ?? "",
            duration: snapshot.duration ?? duration,
            audioFileURL: snapshot.sourceURL,
            outputMode: outputMode,
            transcriptionOptions: transcriptionOptions
        )
        var keyboardDeliverySucceeded = true
        if let keyboardAttemptIdentity {
            if succeeded, let recoveredText, !recoveredText.isEmpty {
                keyboardDeliverySucceeded = KeyboardDictationHandoff.publishHostResult(
                    text: recoveredText,
                    identity: keyboardAttemptIdentity,
                    recordingID: lease.recordingID.uuidString
                )
            } else {
                keyboardDeliverySucceeded = KeyboardDictationHandoff.publishHostFailure(
                    identity: keyboardAttemptIdentity,
                    recordingID: lease.recordingID.uuidString,
                    userMessage: message
                )
            }
        }

        activeAttempt = nil
        activeAttemptTask = nil
        if succeeded {
            reset(keepAudioBridgeAlive: false)
            onCompleted(recording)
            if !keyboardDeliverySucceeded {
                showError("Your transcription was saved in History, but it could not be sent to the keyboard.")
            }
            await MobileAudioUsageAccounting.flush(
                recordingID: lease.recordingID,
                historyManager: historyManager,
                store: processingStore,
                subscriptionManager: subscriptionManager
            )
        } else {
            showError(message)
        }
    }

    private func replaceHistoryRecording(
        _ recording: Recording,
        in historyManager: HistoryManager
    ) async throws {
        try await historyManager.upsertRecording(recording)
    }

    private func persistTerminalState(
        lease: MobileAudioProcessingStore.Lease,
        error: Error,
        integrity: MobileAudioProcessingStore.SourceIntegrity
    ) async -> MobileAudioProcessingStore.TerminalCommitResult {
        let intent: MobileAudioProcessingStore.TerminalIntent
        if error is CancellationError
            || error as? IOSAudioProcessingDeadlineError == .cancelled
        {
            intent = .cancelled(message: "Processing cancelled.")
        } else {
            intent = .failed(message: userMessage(for: error), integrity: integrity)
        }
        return await processingStore.commitTerminalState(
            intent,
            lease: lease,
            timeout: terminalCommitDeadline
        )
    }

    private func terminalDisplayMessage(
        for result: MobileAudioProcessingStore.TerminalCommitResult?,
        fallback: String
    ) -> String? {
        guard let result else { return fallback }
        switch result {
        case .committed(let snapshot):
            return snapshot.stage == .succeeded ? nil : (snapshot.userMessage ?? fallback)
        case .persistenceUnavailable:
            return MobileAudioProcessingStore.terminalPersistenceWarning
        case .superseded:
            return nil
        @unknown default:
            return MobileAudioProcessingStore.terminalPersistenceWarning
        }
    }

    private func recordingOutputMode(for preset: ContextRule?) -> TranscriptionOutputMode {
        if preset?.isMeetingsModeRule == true {
            return .meetings
        }
        if preset?.isNotesModeRule == true {
            return .notes
        }
        return .dictation
    }

    private func updateRecordingState(_ isRecording: Bool) {
        // Durable attempt tasks own the state machine. A native publication is deliberately not
        // allowed to revive or reset an attempt after its deadline/cancellation won.
        guard activeAttempt != nil, isRecording, state == .recording else { return }
    }

    private func reset(keepAudioBridgeAlive: Bool = false) {
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        if keepAudioBridgeAlive {
            recordingStatus.start(identity: keyboardAttemptIdentity)
        } else {
            recordingStatus.stop()
            #if os(iOS)
                audioRecorder.stopMonitoring()
            #endif
        }
        recordingStartTime = nil
        activeTranscriptionRequest = nil
        activeOutputMode = nil
        activeTranscriptionOptions = nil
        stopRequestedWhilePreparing = false
        state = .idle
        audioLevel = 0
        frequencyBands = Array(repeating: 0.0, count: 10)
        completionText = nil
    }

    private func showError(_ message: String) {
        captureDeadlineTask?.cancel()
        captureDeadlineTask = nil
        recordingStatus.stop()
        audioRecorder.stopMonitoring()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            state = .idle
            errorMessage = message
            completionText = nil
            stopRequestedWhilePreparing = false
            recordingStartTime = nil
            activeTranscriptionRequest = nil
            activeOutputMode = nil
            activeTranscriptionOptions = nil
            audioLevel = 0
            frequencyBands = Array(repeating: 0.0, count: 10)
        }
    }

    private func userMessage(for error: Error) -> String {
        if let deadlineError = error as? IOSAudioProcessingDeadlineError {
            return deadlineError.localizedDescription
        }
        if let recorderError = error as? ManagedAudioRecordingError {
            return recorderError.localizedDescription
        }
        if let storeError = error as? MobileAudioProcessingStore.StoreError {
            return storeError.localizedDescription
        }
        if let openAIError = error as? OpenAIError {
            return openAIError.localizedDescription
        }
        if let httpFailure = error as? AppleAudioHTTPRecovery.Failure {
            return httpFailure.localizedDescription
        }
        if let historyError = error as? HistoryPersistenceError {
            return historyError.localizedDescription
        }
        return "Transcription failed. Your recording was kept. Please try again."
    }

    private func publishKeyboardStartFailure(
        identity: KeyboardDictationHandoff.AttemptIdentity?,
        message: String
    ) {
        guard let identity else { return }
        _ = KeyboardDictationHandoff.publishHostFailure(
            identity: identity,
            userMessage: message
        )
    }
}

private struct InlineRecordingPanel: View {
    @ObservedObject var recorder: InlineRecordingCoordinator
    let dismissErrorAction: () -> Void
    private let sheetColor = Color(red: 0.10, green: 0.10, blue: 0.10)

    private var fillColor: Color {
        #if canImport(UIKit)
            recorder.state == .completing ? Color(uiColor: .secondarySystemGroupedBackground) : sheetColor
        #else
            sheetColor
        #endif
    }

    var body: some View {
        ZStack {
            if recorder.state == .completing {
                completionContent
            } else if let errorMessage = recorder.errorMessage {
                errorContent(errorMessage)
            } else {
                activeContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(fillColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .padding(.bottom, recorder.state == .completing ? 0 : -34)
        .animation(.spring(response: 0.46, dampingFraction: 0.9, blendDuration: 0.08), value: recorder.state)
    }

    private var activeContent: some View {
        GeometryReader { proxy in
            ZStack {
                AIDictationActiveRecordingVisual(
                    state: recorder.visualState,
                    audioLevel: recorder.audioLevel,
                    frequencyBands: recorder.frequencyBands,
                    color: .white
                )
                .frame(width: 190, height: 82)
                .position(
                    x: proxy.size.width / 2,
                    y: proxy.size.height / 2
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var completionContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(recorder.completionText ?? "")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text("Just now")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(Color.dsPrimary)

            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button("Dismiss", action: dismissErrorAction)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.dsPrimary)
        }
    }
}

private struct InlineModelStatusBar: View {
    let text: String
    let iconName: String
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))

            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(.white)

            if showsProgress {
                IndeterminateCapsuleProgressBar()
                    .frame(width: 72, height: 4)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.58))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .contentShape(Capsule(style: .continuous))
    }
}

struct IndeterminateCapsuleProgressBar: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { proxy in
                let width = proxy.size.width
                let progress = movingProgress(at: timeline.date)
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.82))
                            .frame(width: width * 0.36)
                            .offset(x: max(0, width * 0.64) * progress)
                    }
                    .clipShape(Capsule())
            }
        }
    }

    private func movingProgress(at date: Date) -> Double {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.25) / 1.25
        return 0.5 - 0.5 * cos(cycle * 2 * .pi)
    }
}

private struct InlineRecordingPauseButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.86))
                        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 6)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
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
                    .foregroundColor(Color.dsPrimary)
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
}
