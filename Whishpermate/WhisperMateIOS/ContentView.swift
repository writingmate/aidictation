import AVFoundation
#if canImport(ActivityKit)
    import ActivityKit
#endif
import Combine
import MediaPlayer
import SwiftUI
import WhisperMateShared

private enum CloudConsentAction {
    case startInlineRecording
    case switchToCloud
}

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
    @State private var showAccountLoginSheet = false
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
    @State private var activeKeyboardDictationSessionID: String?
    @State private var showKeyboardReturnScreen = false
    @State private var keyboardBridgeAliveUntil: Date?
    @State private var selectedRecordingMode: TranscriptionOutputMode = .dictation
    @State private var showCloudTranscriptionConsent = false
    @State private var pendingCloudConsentAction: CloudConsentAction?
    @State private var keyboardCommandPollTask: Task<Void, Never>?
    @State private var showDeleteAccountConfirmation = false
    @State private var showDeleteAccountResult = false
    @State private var deleteAccountResultTitle = ""
    @State private var deleteAccountResultMessage = ""
    @State private var isDeletingAccount = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // Use iPhone layout for all devices (scales nicely on iPad)
        iPhoneLayout
            .onAppear {
                DebugLog.info("ContentView appeared; starting keyboard command polling", context: "KEYBOARD_DIAG")
                drainKeyboardDiagnostics()
                startKeyboardCommandPolling()
                consumePendingKeyboardCommandIfNeeded()
                #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-showAccountLoginForValidation") {
                        showAccountLoginSheet = true
                    }
                #endif
            }
            .onDisappear {
                stopKeyboardCommandPolling()
            }
            .onChange(of: scenePhase) { phase in
                DebugLog.info("scenePhase=\(String(describing: phase))", context: "KEYBOARD_DIAG")
                if phase == .active {
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
                let sessionID = notification.object as? String ?? KeyboardDictationHandoff.activeSessionID()
                startKeyboardDictation(sessionID: sessionID)
            }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardDictationHandoff.stopAppNotification)) { notification in
                let sessionID = notification.object as? String ?? KeyboardDictationHandoff.activeSessionID()
                stopKeyboardDictation(sessionID: sessionID)
            }
            .alert("Login Unavailable", isPresented: $showLoginConfigurationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loginConfigurationMessage)
            }
            .sheet(isPresented: $showAccountLoginSheet) {
                AccountLoginView(authManager: authManager)
            }
            .alert("Delete Account?", isPresented: $showDeleteAccountConfirmation) {
                Button("Delete Account", role: .destructive) {
                    deleteAccount()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your account, usage, and invite data, then signs you out. If you have an active paid plan, cancel it from your billing receipt or payment provider to stop future charges.")
            }
            .alert(deleteAccountResultTitle, isPresented: $showDeleteAccountResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteAccountResultMessage)
            }
            .alert("Offline Model", isPresented: $showOfflineModelAlert) {
                if canDownloadOfflineModelFromAlert {
                    Button("Download") {
                        prepareOfflineModel()
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
                    let action = pendingCloudConsentAction
                    pendingCloudConsentAction = nil

                    switch action {
                    case .startInlineRecording:
                        handleInlineRecordingTap()
                    case .switchToCloud:
                        transcriptionProviderManager.setTranscriptionMode(.cloud)
                    case .none:
                        break
                    }
                }
                Button("Use Offline Mode") {
                    pendingCloudConsentAction = nil
                    useOfflineModeFromCloudConsent()
                }
                Button("Not Now", role: .cancel) {
                    pendingCloudConsentAction = nil
                }
            } message: {
                Text(CloudTranscriptionConsent.disclosureMessage)
            }
    }

    private func openRecordingSheet() {
        recordingSheetID = UUID()
        showRecordingSheet = true
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

            if inlineRecording.isPanelVisible {
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
                            selectedRecording = recording
                        }) {
                            VStack(alignment: .leading, spacing: 8) {
                                if recording.outputMode == .notes {
                                    Label("Notes", systemImage: "note.text")
                                        .font(.caption.weight(.medium))
                                        .foregroundColor(.secondary)
                                }
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
	                                recordingToShare = recording
	                            }) {
	                                Label("Share", systemImage: "square.and.arrow.up")
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
                selectedRecording = recording
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    if recording.outputMode == .notes {
                        Label("Notes", systemImage: "note.text")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                    }
                    Text(recording.transcription)
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
                    historyManager.deleteRecording(recording)
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    recordingToShare = recording
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

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
                        .disabled(isDeletingAccount)

                        Button(role: .destructive) {
                            showDeleteAccountConfirmation = true
                        } label: {
                            if isDeletingAccount {
                                HStack {
                                    ProgressView()
                                    Text("Deleting Account")
                                }
                            } else {
                                Label("Delete Account", systemImage: "trash")
                            }
                        }
                        .disabled(isDeletingAccount)
                    } else {
                        Button(action: openLogin) {
                            HStack {
                                Label("Log In to Get More", systemImage: "person.crop.circle.badge.plus")
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Get More Words") {
                    ReferralInviteView(
                        user: authManager.currentUser,
                        isAuthenticated: authManager.isAuthenticated,
                        isLoading: isPreparingReferral,
                        isRedeeming: isRedeemingReferral,
                        codeToRedeem: $referralCodeToRedeem,
                        error: referralError,
                        onInvite: prepareReferralInvite,
                        onRedeem: redeemReferralCode,
                        onLogin: openLogin
                    )
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

                Section("Cloud Privacy") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(CloudTranscriptionConsent.disclosureMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(CloudTranscriptionConsent.isGranted ? "Cloud transcription is allowed." : "Cloud transcription is not allowed yet.")
                            .font(.footnote.weight(.medium))
                            .foregroundColor(CloudTranscriptionConsent.isGranted ? .secondary : .orange)
                    }
                    .padding(.vertical, 4)

                    if CloudTranscriptionConsent.isGranted {
                        Button("Turn Off Cloud Permission", role: .destructive) {
                            CloudTranscriptionConsent.revoke()
                        }
                    } else {
                        Button("Allow Cloud Transcription") {
                            CloudTranscriptionConsent.grant()
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
                        historyManager.clearAll()
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
        .sheet(isPresented: $showAccountLoginSheet) {
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
            pendingCloudConsentAction = .switchToCloud
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
                    offlineModelMessage = error.localizedDescription
                    showOfflineModelAlert = true
                }
            }
        }
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
        showAccountLoginSheet = true
    }

    private func deleteAccount() {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true

        Task {
            do {
                try await authManager.deleteAccount()
                deleteAccountResultTitle = "Account Deleted"
                deleteAccountResultMessage = "Your account has been deleted and you have been signed out."
            } catch {
                deleteAccountResultTitle = "Account Not Deleted"
                deleteAccountResultMessage = "We couldn't delete your account. Please try again."
            }

            isDeletingAccount = false
            showDeleteAccountResult = true
        }
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
            guard ensureCloudTranscriptionAllowedForRecording() else { return }
            guard ensureOfflineModelReadyForRecording() else { return }
        }

        inlineRecording.handlePrimaryAction(
            historyManager: historyManager,
            dictionaryManager: dictionaryManager,
            toneStyleManager: toneStyleManager,
            shortcutManager: shortcutManager,
            selectedPreset: recordingPreset(for: selectedRecordingMode, manager: toneStyleManager),
            keepAudioBridgeAliveAfterStop: activeKeyboardDictationSessionID != nil
        ) { recording in
            if let activeKeyboardDictationSessionID {
                DebugLog.info("publishing keyboard text sessionID=\(activeKeyboardDictationSessionID) length=\(recording.transcription.count)", context: "KEYBOARD_DIAG")
                KeyboardDictationHandoff.publish(
                    text: recording.transcription,
                    sessionID: activeKeyboardDictationSessionID
                )
                self.activeKeyboardDictationSessionID = nil
                self.showKeyboardReturnScreen = false
                self.inlineRecording.setKeyboardMeterSessionID(nil)
                self.keepKeyboardBridgeAlive()
            }
            markRecordingAsNew(recording)
        }
    }

    private func ensureCloudTranscriptionAllowedForRecording() -> Bool {
        guard needsCloudTranscriptionConsentForRecording else {
            return true
        }

        pendingCloudConsentAction = .startInlineRecording
        showCloudTranscriptionConsent = true
        return false
    }

    private var needsCloudTranscriptionConsentForRecording: Bool {
        !transcriptionProviderManager.shouldUseOnDeviceTranscription && !CloudTranscriptionConsent.isGranted
    }

    private func startKeyboardDictation(sessionID: String?) {
        let resolvedSessionID = sessionID ?? KeyboardDictationHandoff.beginSession()
        DebugLog.info("startKeyboardDictation sessionID=\(resolvedSessionID) inlineState=\(inlineRecording.state)", context: "KEYBOARD_DIAG")
        activeKeyboardDictationSessionID = resolvedSessionID
        keepKeyboardBridgeAlive()
        showKeyboardReturnScreen = true
        inlineRecording.setKeyboardMeterSessionID(resolvedSessionID)
        if inlineRecording.state == .idle {
            handleInlineRecordingTap()
        }
    }

    private func stopKeyboardDictation(sessionID: String?) {
        let resolvedSessionID = sessionID ?? activeKeyboardDictationSessionID ?? KeyboardDictationHandoff.activeSessionID()
        DebugLog.info("stopKeyboardDictation sessionID=\(resolvedSessionID ?? "nil") inlineState=\(inlineRecording.state)", context: "KEYBOARD_DIAG")
        activeKeyboardDictationSessionID = resolvedSessionID
        keepKeyboardBridgeAlive()
        showKeyboardReturnScreen = true
        inlineRecording.setKeyboardMeterSessionID(resolvedSessionID)
        if inlineRecording.state == .recording || inlineRecording.state == .paused {
            handleInlineRecordingTap()
        }
    }

    private func consumePendingKeyboardCommandIfNeeded() {
        drainKeyboardDiagnostics()
        guard let pending = KeyboardDictationHandoff.consumePendingCommand() else {
            return
        }

        DebugLog.info("app consumed command=\(pending.command.rawValue) sessionID=\(pending.sessionID ?? "nil")", context: "KEYBOARD_DIAG")
        switch pending.command {
        case .start:
            startKeyboardDictation(sessionID: pending.sessionID)
        case .stop:
            stopKeyboardDictation(sessionID: pending.sessionID)
        case .shutdown:
            shutdownKeyboardDictation(sessionID: pending.sessionID)
        @unknown default:
            DebugLog.info("unknown keyboard command=\(pending.command.rawValue)", context: "KEYBOARD_DIAG")
        }
    }

    private func shutdownKeyboardDictation(sessionID: String?) {
        DebugLog.info("shutdownKeyboardDictation sessionID=\(sessionID ?? "nil") inlineState=\(inlineRecording.state)", context: "KEYBOARD_DIAG")
        activeKeyboardDictationSessionID = nil
        showKeyboardReturnScreen = false
        keyboardBridgeAliveUntil = nil
        inlineRecording.setKeyboardMeterSessionID(nil)
        inlineRecording.stopListening()
        KeyboardDictationHandoff.clearActiveSession()
    }

    private var shouldKeepKeyboardCommandPolling: Bool {
        let hasActiveKeyboardRecording = activeKeyboardDictationSessionID != nil
            && (inlineRecording.state == .recording || inlineRecording.state == .paused || inlineRecording.state == .processing)
        let hasLiveKeyboardBridge = keyboardBridgeAliveUntil.map { $0 > Date() } ?? false
        return hasActiveKeyboardRecording || hasLiveKeyboardBridge
    }

    private func startKeyboardCommandPolling() {
        guard keyboardCommandPollTask == nil else { return }

        DebugLog.info("start command polling", context: "KEYBOARD_DIAG")
        keyboardCommandPollTask = Task { @MainActor in
            while !Task.isCancelled {
                KeyboardDictationHandoff.publishAppReady()
                drainKeyboardDiagnostics()
                consumePendingKeyboardCommandIfNeeded()
                try? await Task.sleep(nanoseconds: 250_000_000)
                if scenePhase != .active, !shouldKeepKeyboardCommandPolling {
                    keyboardCommandPollTask = nil
                    break
                }
            }
        }
    }

    private func keepKeyboardBridgeAlive() {
        keyboardBridgeAliveUntil = Date().addingTimeInterval(120)
        KeyboardDictationHandoff.publishAppReady()
        startKeyboardCommandPolling()
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
            return "Go back to the keyboard. Your text will appear there when it is ready."
        default:
            return "Swipe back to the keyboard. Microphone access is active now."
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

                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                    Text("Return to the keyboard")
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.secondary)
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

private final class RecordingNowPlayingStatus {
    private enum LiveActivityPhase {
        case listening
        case processing
    }

    private var isActive = false
    private var startedAt = Date()
    private var liveActivitySessionID: String?

    #if canImport(ActivityKit)
        @available(iOS 16.2, *)
        private var liveActivity: Activity<KeyboardDictationActivityAttributes>? {
            Activity<KeyboardDictationActivityAttributes>.activities.first
        }
    #endif

    func start() {
        isActive = true
        startedAt = Date()

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
        startOrUpdateLiveActivity(phase: .listening)
        DebugLog.info("recording now playing status started", context: "KEYBOARD_DIAG")
    }

    func processing() {
        guard isActive else { return }
        startOrUpdateLiveActivity(phase: .processing)
    }

    func stop() {
        guard isActive || MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else {
            return
        }

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

            Task {
                let sessionID = KeyboardDictationHandoff.activeSessionID() ?? UUID().uuidString
                let activityPhase: KeyboardDictationActivityAttributes.Phase = phase == .processing ? .processing : .listening
                let state = KeyboardDictationActivityAttributes.ContentState(phase: activityPhase, startedAt: startedAt)

                if let liveActivity {
                    await liveActivity.update(ActivityContent(state: state, staleDate: nil))
                    liveActivitySessionID = liveActivity.attributes.sessionID
                    return
                }

                do {
                    let attributes = KeyboardDictationActivityAttributes(sessionID: sessionID)
                    let activity = try Activity.request(
                        attributes: attributes,
                        content: ActivityContent(state: state, staleDate: nil),
                        pushType: nil
                    )
                    liveActivitySessionID = activity.attributes.sessionID
                    DebugLog.info("live activity started sessionID=\(sessionID)", context: "KEYBOARD_DIAG")
                } catch {
                    DebugLog.info("failed to start live activity: \(error)", context: "KEYBOARD_DIAG")
                }
            }
        #endif
    }

    private func endLiveActivity() {
        #if canImport(ActivityKit)
            guard #available(iOS 17.0, *) else { return }

            Task {
                for activity in Activity<KeyboardDictationActivityAttributes>.activities {
                    let state = KeyboardDictationActivityAttributes.ContentState(phase: .processing, startedAt: startedAt)
                    await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
                }
                liveActivitySessionID = nil
            }
        #endif
    }
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
    }
}

@MainActor
private final class InlineRecordingCoordinator: ObservableObject {
    @Published var state: InlineRecordingState = .idle
    @Published var audioLevel: Float = 0.0
    @Published var frequencyBands: [Float] = Array(repeating: 0.0, count: 10)
    @Published var errorMessage: String?
    @Published var completionText: String?

    private let audioRecorder = AudioRecorder()
    private let recordingStatus = RecordingNowPlayingStatus()
    private let subscriptionManager = SubscriptionManager.shared
    private var recordingStartTime: Date?
    private var recorderHasStarted = false
    private var keyboardMeterSessionID: String?
    private var cancellables = Set<AnyCancellable>()

    private let minimumRecordingDuration: TimeInterval = 0.35
    private let minimumAudioFileBytes: Int64 = 1000
    private let recordingStartTimeout: UInt64 = 1_200_000_000

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
        audioRecorder.$isRecording
            .dropFirst()
            .sink { [weak self] isRecording in
                Task { @MainActor in
                    self?.updateRecordingState(isRecording)
                }
            }
            .store(in: &cancellables)

        audioRecorder.$audioLevel
            .sink { [weak self] level in
                Task { @MainActor in
                    guard self?.state == .recording else { return }
                    self?.audioLevel = level
                    self?.publishKeyboardMeter()
                }
            }
            .store(in: &cancellables)

        audioRecorder.$frequencyBands
            .sink { [weak self] bands in
                Task { @MainActor in
                    guard self?.state == .recording else { return }
                    self?.frequencyBands = bands
                    self?.publishKeyboardMeter()
                }
            }
            .store(in: &cancellables)
    }

    func handlePrimaryAction(
        historyManager: HistoryManager,
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager,
        selectedPreset: ContextRule?,
        keepAudioBridgeAliveAfterStop: Bool = false,
        onCompleted: @escaping (Recording) -> Void
    ) {
        switch state {
        case .idle:
            startRecording()
        case .recording, .paused:
            stopRecording(
                historyManager: historyManager,
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
                selectedPreset: selectedPreset,
                keepAudioBridgeAliveAfterStop: keepAudioBridgeAliveAfterStop,
                onCompleted: onCompleted
            )
        case .processing:
            break
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

    func setKeyboardMeterSessionID(_ sessionID: String?) {
        keyboardMeterSessionID = sessionID
        DebugLog.info("set keyboard meter sessionID=\(sessionID ?? "nil")", context: "KEYBOARD_DIAG")
        if sessionID == nil {
            KeyboardDictationHandoff.clearMeter()
        }
    }

    private func publishKeyboardMeter() {
        guard let sessionID = keyboardMeterSessionID ?? KeyboardDictationHandoff.activeSessionID() else { return }
        if audioLevel > 0.02 {
            DebugLog.info("app meter sessionID=\(sessionID) level=\(String(format: "%.3f", audioLevel)) bands=\(frequencyBands.count)", context: "KEYBOARD_DIAG")
        }
        KeyboardDictationHandoff.publishMeter(
            audioLevel: audioLevel,
            frequencyBands: frequencyBands,
            sessionID: sessionID
        )
    }

    func dismissError() {
        withAnimation(.easeInOut(duration: 0.2)) {
            errorMessage = nil
        }
    }

    func stopListening() {
        _ = audioRecorder.stopRecording(deactivateAudioSession: true)
        recordingStatus.stop()
        recordingStartTime = nil
        recorderHasStarted = false
        state = .idle
        audioLevel = 0
        frequencyBands = Array(repeating: 0.0, count: 10)
        completionText = nil
        errorMessage = nil
    }

    private func startRecording() {
        dismissError()
        DebugLog.info("inline startRecording permission=\(AVAudioSession.sharedInstance().recordPermission.rawValue)", context: "KEYBOARD_DIAG")

        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            DebugLog.info("inline start blocked by subscription reason=\(access.reason ?? "nil")", context: "KEYBOARD_DIAG")
            showError(access.reason ?? "Log in to continue transcribing.")
            return
        }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            showError("Microphone permission denied. Please enable it in Settings.")
        case .undetermined:
            DebugLog.info("requesting microphone permission", context: "KEYBOARD_DIAG")
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    DebugLog.info("microphone permission response granted=\(granted)", context: "KEYBOARD_DIAG")
                    if granted {
                        self?.beginRecording()
                    } else {
                        self?.showError("Microphone permission denied. Please enable it in Settings.")
                    }
                }
            }
        @unknown default:
            showError("Unable to check microphone permission.")
        }
    }

    private func beginRecording() {
        DebugLog.info("inline beginRecording", context: "KEYBOARD_DIAG")
        recordingStartTime = Date()
        recordingStatus.start()
        recorderHasStarted = false
        errorMessage = nil
        audioLevel = 0
        frequencyBands = Array(repeating: 0.0, count: 10)

        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            state = .recording
        }

        audioRecorder.startRecording()
        verifyRecordingDidStart()
    }

    private func verifyRecordingDidStart() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: recordingStartTimeout)
            guard state == .recording, !recorderHasStarted else {
                return
            }

            DebugLog.info("inline recording start timeout isRecording=\(audioRecorder.isRecording)", context: "KEYBOARD_DIAG")
            showError("Recording could not start. Please try again.")
        }
    }

    private func stopRecording(
        historyManager: HistoryManager,
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager,
        selectedPreset: ContextRule?,
        keepAudioBridgeAliveAfterStop: Bool,
        onCompleted: @escaping (Recording) -> Void
    ) {
        let recordingStartedAt = recordingStartTime

        DebugLog.info("inline stopRecording state=\(state) preset=\(selectedPreset?.name ?? "dictation")", context: "KEYBOARD_DIAG")
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

        Task {
            guard let audioURL = await audioRecorder.stopRecordingAsync(deactivateAudioSession: false) else {
                DebugLog.info("inline stop returned nil audioURL", context: "KEYBOARD_DIAG")
                reset(keepAudioBridgeAlive: keepAudioBridgeAliveAfterStop)
                return
            }

            if keepAudioBridgeAliveAfterStop {
                audioRecorder.startMonitoring()
                recordingStatus.start()
            }

            DebugLog.info("inline stop returned url=\(audioURL.path)", context: "KEYBOARD_DIAG")
            guard validateRecordingForTranscription(audioURL, recordingStartTime: recordingStartedAt) else {
                try? FileManager.default.removeItem(at: audioURL)
                reset(keepAudioBridgeAlive: keepAudioBridgeAliveAfterStop)
                return
            }

            await transcribeAudio(
                audioURL: audioURL,
                historyManager: historyManager,
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
                selectedPreset: selectedPreset,
                keepAudioBridgeAlive: keepAudioBridgeAliveAfterStop,
                onCompleted: onCompleted
            )
        }
    }

    private func transcribeAudio(
        audioURL: URL,
        historyManager: HistoryManager,
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager,
        selectedPreset: ContextRule?,
        keepAudioBridgeAlive: Bool = false,
        onCompleted: @escaping (Recording) -> Void
    ) async {
        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            try? FileManager.default.removeItem(at: audioURL)
            showError(access.reason ?? "Log in to continue transcribing.")
            return
        }

        do {
            let outputMode = recordingOutputMode(for: selectedPreset)
            let transcriptionOptions = selectedPreset?.transcriptionOptions ?? .default
            let processedResult = try await SharedTranscriptionService.transcribe(
                audioURL: audioURL,
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
                outputMode: outputMode,
                transcriptionOptions: transcriptionOptions,
                selectedPreset: selectedPreset
            )

            guard !processedResult.isEmpty else {
                DebugLog.info("Inline transcription was empty after sanitization; skipping history item", context: "ContentView")
                try? FileManager.default.removeItem(at: audioURL)
                reset(keepAudioBridgeAlive: keepAudioBridgeAlive)
                return
            }

            let wordCount = subscriptionManager.wordCount(for: processedResult)
            await subscriptionManager.recordWords(wordCount)

            let duration = recordingStartTime.map { Date().timeIntervalSince($0) }
            let recordingID = UUID()
            let permanentAudioURL = historyManager.saveAudioFile(from: audioURL, for: recordingID)
            let recording = Recording(
                id: recordingID,
                transcription: processedResult,
                duration: duration,
                audioFileURL: permanentAudioURL,
                outputMode: outputMode,
                transcriptionOptions: transcriptionOptions
            )

            try? FileManager.default.removeItem(at: audioURL)

            withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) {
                historyManager.addRecording(recording)
                reset(keepAudioBridgeAlive: keepAudioBridgeAlive)
            }

            onCompleted(recording)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            showError("Transcription failed. Please try again.")
        }
    }

    private func validateRecordingForTranscription(_ audioURL: URL, recordingStartTime: Date?) -> Bool {
        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

        let fileSize: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            fileSize = attributes[.size] as? Int64 ?? 0
        } catch {
            DebugLog.info("Failed to verify inline recording file: \(error)", context: "ContentView")
            return false
        }

        let audioDuration = audioFileDuration(audioURL)
        DebugLog.info("inline recording validation elapsed=\(String(format: "%.2f", elapsed)) duration=\(audioDuration.map { String(format: "%.2f", $0) } ?? "nil") fileSize=\(fileSize)", context: "KEYBOARD_DIAG")
        if elapsed < minimumRecordingDuration || (audioDuration ?? elapsed) < minimumRecordingDuration {
            DebugLog.info("Inline recording too short; skipping transcription", context: "ContentView")
            return false
        }

        if fileSize < minimumAudioFileBytes {
            DebugLog.info("Inline recording has no audio payload; skipping transcription", context: "ContentView")
            return false
        }

        return true
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

    private func audioFileDuration(_ audioURL: URL) -> TimeInterval? {
        do {
            let file = try AVAudioFile(forReading: audioURL)
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0 else { return nil }
            return Double(file.length) / sampleRate
        } catch {
            DebugLog.info("Failed to read inline recording duration: \(error)", context: "ContentView")
            return nil
        }
    }

    private func updateRecordingState(_ isRecording: Bool) {
        if state == .processing || state == .paused || state == .completing {
            return
        }

        if isRecording {
            recorderHasStarted = true
            return
        }

        if state == .recording, !isRecording {
            guard recorderHasStarted else {
                return
            }
            reset()
        }
    }

    private func reset(keepAudioBridgeAlive: Bool = false) {
        if keepAudioBridgeAlive {
            recordingStatus.start()
        } else {
            recordingStatus.stop()
            #if os(iOS)
                audioRecorder.stopMonitoring()
            #endif
        }
        recordingStartTime = nil
        recorderHasStarted = false
        state = .idle
        audioLevel = 0
        frequencyBands = Array(repeating: 0.0, count: 10)
        completionText = nil
    }

    private func showError(_ message: String) {
        recordingStatus.stop()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            state = .idle
            errorMessage = message
            completionText = nil
            recorderHasStarted = false
            audioLevel = 0
            frequencyBands = Array(repeating: 0.0, count: 10)
        }
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
