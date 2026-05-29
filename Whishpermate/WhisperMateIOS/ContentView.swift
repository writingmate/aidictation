import AVFoundation
import Combine
import SwiftUI
import WhisperMateShared

struct ContentView: View {
    @StateObject private var historyManager = HistoryManager()
    @StateObject private var dictionaryManager = DictionaryManager.shared
    @StateObject private var toneStyleManager = ToneStyleManager.shared
    @StateObject private var shortcutManager = ShortcutManager.shared
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var transcriptionProviderManager = TranscriptionProviderManager()
    @StateObject private var inlineRecording = InlineRecordingCoordinator()
    @State private var showRecordingSheet = false
    @State private var showSettings = false
    @State private var recordingSheetID = UUID()
    @State private var selectedRecording: Recording?
    @State private var showTextRules = false
    @State private var showLoginConfigurationAlert = false
    @State private var loginConfigurationMessage = ""
    @State private var newlyInsertedRecordingID: UUID?
    @State private var historySearchText = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // Use iPhone layout for all devices (scales nicely on iPad)
        iPhoneLayout
            .tint(Color.dsPrimary)
            .alert("Login Unavailable", isPresented: $showLoginConfigurationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loginConfigurationMessage)
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
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }

            VStack {
                Spacer()
                Button(action: handleInlineRecordingTap) {
                    ZStack {
                        Circle()
                            .fill(Color.dsPrimary)
                            .frame(width: 64, height: 64)
                            .shadow(color: .black.opacity(inlineRecording.isActive ? 0.28 : 0.2), radius: inlineRecording.isActive ? 10 : 4, x: 0, y: inlineRecording.isActive ? 5 : 2)

                        InlineRecordingPrimaryIcon(isActive: inlineRecording.isActive)
                            .id(inlineRecording.isActive ? "stop" : "mic")
                            .transition(.opacity.combined(with: .scale(scale: 0.76)))
                    }
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
                ZStack {
                    Circle()
                        .fill(Color.dsPrimary)
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
                            .foregroundColor(Color.dsPrimary)
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
            VStack(alignment: .leading, spacing: 14) {
                historySearchField
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                List {
                    if displayedHistoryRecordings.isEmpty {
                        Text(historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No recordings yet" : "No matching recordings")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                            .listRowSeparator(.hidden)
                    }

                    ForEach(displayedHistoryRecordings) { recording in
                        let isNewRecording = newlyInsertedRecordingID == recording.id

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
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        .animation(.spring(response: 0.34, dampingFraction: 0.72, blendDuration: 0.04), value: isNewRecording)
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
                            .tint(Color.dsPrimary)

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
                .listStyle(.insetGrouped)
                .animation(.spring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.06), value: displayedHistoryRecordings.map(\.id))
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                settingsView
            }
            .sheet(item: $selectedRecording) { recording in
                RecordingSheetView(historyManager: historyManager, dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager, recording: recording)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var historySearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.secondary)

            TextField("Search history", text: $historySearchText)
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
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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

                Section("Dictation Mode") {
                    Picker("Mode", selection: Binding(
                        get: { transcriptionProviderManager.transcriptionMode },
                        set: { transcriptionProviderManager.setTranscriptionMode($0) }
                    )) {
                        ForEach(TranscriptionMode.availableCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Text(transcriptionProviderManager.transcriptionMode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if transcriptionProviderManager.transcriptionMode != .cloud {
                        Button(action: prepareOfflineModel) {
                            HStack {
                                Label("Offline Model", systemImage: "square.and.arrow.down")
                                Spacer()
                                Image(systemName: offlineModelStatusIcon)
                                    .foregroundColor(offlineModelStatusColor)
                            }
                        }
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.0.20")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Transcription") {
                    NavigationLink(destination: TranscriptionSettingsView(dictionaryManager: dictionaryManager, toneStyleManager: toneStyleManager, shortcutManager: shortcutManager)) {
                        Label("Transcription Settings", systemImage: "text.badge.checkmark")
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

    private var offlineModelStatusIcon: String {
        guard SharedParakeetTranscriptionService.isRuntimeSupported else {
            return "exclamationmark.triangle.fill"
        }
        return SharedParakeetTranscriptionService.shared.isModelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle"
    }

    private var offlineModelStatusColor: Color {
        guard SharedParakeetTranscriptionService.isRuntimeSupported else {
            return .orange
        }
        return SharedParakeetTranscriptionService.shared.isModelDownloaded ? .green : .secondary
    }

    private func prepareOfflineModel() {
        Task {
            try? await SharedParakeetTranscriptionService.shared.initialize()
        }
    }

    private func openLogin() {
        guard let url = authManager.loginURL() else {
            loginConfigurationMessage = authManager.error ?? "Login is not configured in this build."
            showLoginConfigurationAlert = true
            return
        }
        UIApplication.shared.open(url)
    }

    private func handleInlineRecordingTap() {
        inlineRecording.handlePrimaryAction(
            historyManager: historyManager,
            dictionaryManager: dictionaryManager,
            toneStyleManager: toneStyleManager,
            shortcutManager: shortcutManager
        ) { recording in
            markRecordingAsNew(recording)
        }
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
                    .foregroundColor(Color.dsPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.dsPrimary.opacity(0.12))
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
                    .tint(Color.dsPrimary)
            }
        }
        .padding(.vertical, 6)
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
private final class InlineRecordingCoordinator: ObservableObject {
    @Published var state: InlineRecordingState = .idle
    @Published var audioLevel: Float = 0.0
    @Published var frequencyBands: [Float] = Array(repeating: 0.0, count: 10)
    @Published var errorMessage: String?
    @Published var completionText: String?

    private let audioRecorder = AudioRecorder()
    private let subscriptionManager = SubscriptionManager.shared
    private var recordingStartTime: Date?
    private var cancellables = Set<AnyCancellable>()

    private let minimumRecordingDuration: TimeInterval = 0.35
    private let minimumAudioFileBytes: Int64 = 1000

    var isActive: Bool {
        state == .recording || state == .paused || state == .processing
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
                }
            }
            .store(in: &cancellables)

        audioRecorder.$frequencyBands
            .sink { [weak self] bands in
                Task { @MainActor in
                    guard self?.state == .recording else { return }
                    self?.frequencyBands = bands
                }
            }
            .store(in: &cancellables)
    }

    func handlePrimaryAction(
        historyManager: HistoryManager,
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager,
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

    func dismissError() {
        withAnimation(.easeInOut(duration: 0.2)) {
            errorMessage = nil
        }
    }

    private func startRecording() {
        dismissError()

        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            showError(access.reason ?? "Log in to continue transcribing.")
            return
        }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            showError("Microphone permission denied. Please enable it in Settings.")
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
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
        recordingStartTime = Date()
        errorMessage = nil
        audioLevel = 0
        frequencyBands = Array(repeating: 0.0, count: 10)

        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            state = .recording
        }

        audioRecorder.startRecording()
    }

    private func stopRecording(
        historyManager: HistoryManager,
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager,
        onCompleted: @escaping (Recording) -> Void
    ) {
        let recordingStartedAt = recordingStartTime

        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            state = .processing
            audioLevel = 0
            frequencyBands = Array(repeating: 0.0, count: 10)
        }

        Task {
            guard let audioURL = await audioRecorder.stopRecordingAsync(deactivateAudioSession: false) else {
                reset()
                return
            }

            guard validateRecordingForTranscription(audioURL, recordingStartTime: recordingStartedAt) else {
                try? FileManager.default.removeItem(at: audioURL)
                reset()
                return
            }

            await transcribeAudio(
                audioURL: audioURL,
                historyManager: historyManager,
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
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
        onCompleted: @escaping (Recording) -> Void
    ) async {
        let access = subscriptionManager.checkCanTranscribe()
        guard access.canTranscribe else {
            try? FileManager.default.removeItem(at: audioURL)
            showError(access.reason ?? "Log in to continue transcribing.")
            return
        }

        do {
            let processedResult = try await SharedTranscriptionService.transcribe(
                audioURL: audioURL,
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager
            )

            guard !processedResult.isEmpty else {
                DebugLog.info("Inline transcription was empty after sanitization; skipping history item", context: "ContentView")
                try? FileManager.default.removeItem(at: audioURL)
                reset()
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
                audioFileURL: permanentAudioURL
            )

            try? FileManager.default.removeItem(at: audioURL)

            withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) {
                historyManager.addRecording(recording)
                reset()
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

        if state == .recording, !isRecording {
            reset()
        }
    }

    private func reset() {
        recordingStartTime = nil
        state = .idle
        audioLevel = 0
        frequencyBands = Array(repeating: 0.0, count: 10)
        completionText = nil
    }

    private func showError(_ message: String) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            state = .idle
            errorMessage = message
            completionText = nil
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
        ZStack {
            AudioVisualizationView(
                audioLevel: recorder.audioLevel,
                color: .white,
                frequencyBands: recorder.frequencyBands
            )
            .opacity(recorder.state == .recording || recorder.state == .paused ? 1 : 0)

            ProcessingWaveView(color: .white)
                .opacity(recorder.state == .processing ? 1 : 0)
        }
        .frame(width: 190, height: 82)
        .padding(.horizontal, 28)
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

private struct InlineRecordingPrimaryIcon: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
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
