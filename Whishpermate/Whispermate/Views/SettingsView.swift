import ApplicationServices
import AVFoundation
import SwiftUI
import WhisperMateShared

// MARK: - Billing Period

enum BillingPeriod {
    case monthly
    case annual
    case lifetime
}

// MARK: - Settings Card Component

struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: DSCornerRadius.medium)
                    .fill(Color.quaternarySystemFill)
            )
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case account = "Account"
    case permissions = "Permissions"
    // case transcription = "Transcription" // Hidden for now
    case audio = "Audio"
    case language = "Language"
    case dictionary = "Dictionary"
    case contextRules = "Context Rules"
    case shortcuts = "Shortcuts"
    case history = "History"

    var id: String { rawValue }

    /// Sections visible in the sidebar list (Account is accessed via bottom status view)
    static var sidebarCases: [SettingsSection] {
        allCases.filter { $0 != .account }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .account: return "person.circle"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "lock.shield"
        // case .transcription: return "text.bubble"
        case .audio: return "waveform"
        case .language: return "globe"
        case .dictionary: return "book.closed"
        case .contextRules: return "text.badge.checkmark"
        case .shortcuts: return "text.word.spacing"
        }
    }

    var description: String {
        switch self {
        case .general: return "Hotkey, overlay, and startup settings"
        case .account: return "Subscription and account management"
        case .history: return "View and manage transcription history"
        case .permissions: return "Microphone, accessibility, and screen recording"
        // case .transcription: return "Transcription provider and model settings"
        case .audio: return "Input device and audio settings"
        case .language: return "Transcription language preferences"
        case .dictionary: return "Custom word replacements and corrections"
        case .contextRules: return "App-specific formatting rules"
        case .shortcuts: return "Voice-triggered text expansions"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var languageManager: LanguageManager
    @ObservedObject var transcriptionProviderManager: TranscriptionProviderManager
    @ObservedObject var llmProviderManager: LLMProviderManager
    @ObservedObject var dictionaryManager: DictionaryManager
    @ObservedObject var contextRulesManager: ContextRulesManager
    @ObservedObject var shortcutManager: ShortcutManager
    @ObservedObject var overlayManager = OverlayWindowManager.shared
    @ObservedObject var launchAtLoginManager = LaunchAtLoginManager.shared
    @ObservedObject var authManager = AuthManager.shared
    @ObservedObject var screenCaptureManager = ScreenCaptureManager.shared
    @ObservedObject var parakeetService = ParakeetTranscriptionService.shared
    @Binding var selectedSection: SettingsSection
    @State private var transcriptionApiKey = ""
    @State private var llmApiKey = ""
    @State private var customEndpoint = ""
    @State private var customModel = ""
    @State private var showingTranscriptionKeySaved = false
    @State private var showingLLMKeySaved = false
    @State private var audioDevices: [AudioDeviceManager.AudioDevice] = []
    @State private var selectedAudioDevice: AudioDeviceManager.AudioDevice?
    @State private var selectedBillingPeriod: BillingPeriod = .monthly
    @State private var isCheckingPayment = false
    @State private var paymentCheckTask: Task<Void, Never>?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsSection.sidebarCases, selection: $selectedSection) { section in
                    if section == .history {
                        Button(action: {
                            openWindow(id: "history")
                        }) {
                            HStack {
                                Label(section.rawValue, systemImage: section.icon)
                                Spacer()
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                // Account status at bottom of sidebar
                SidebarAccountStatusView(onTap: {
                    selectedSection = .account
                })
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedSection {
                    case .general:
                        generalSection
                    case .account:
                        accountSection
                    case .history:
                        // History opens in separate window, show placeholder
                        EmptyView()
                    case .permissions:
                        permissionsSection
                    // case .transcription:
                    //     transcriptionSection
                    case .audio:
                        audioSection
                    case .language:
                        languageSection
                    case .dictionary:
                        dictionarySection
                    case .contextRules:
                        contextRulesSection
                    case .shortcuts:
                        shortcutsSection
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            loadAudioDevices()
        }
        .onChange(of: selectedAudioDevice) { newValue in
            saveSelectedAudioDevice(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AudioDeviceListChanged"))) { _ in
            loadAudioDevices()
        }
        .onDisappear {
            stopPaymentConfirmationCheck()
        }
    }

    // MARK: - Account Section

    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Account Status Card
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    if authManager.isAuthenticated, let user = authManager.currentUser {
                        // Email
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Account")
                                    .dsFont(.body)
                                    .foregroundStyle(Color.dsForeground)
                                Text(user.email)
                                    .dsFont(.label)
                                    .foregroundStyle(Color.dsMutedForeground)
                            }
                            Spacer()
                            Button("Sign Out") {
                                Task {
                                    await AuthManager.shared.logout()
                                }
                            }
                            .controlSize(.small)
                        }

                        Divider()

                        // Subscription Status
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Subscription")
                                    .dsFont(.body)
                                    .foregroundStyle(Color.dsForeground)
                                Text(user.subscriptionTier == .pro ? "Pro" : "Free")
                                    .dsFont(.label)
                                    .foregroundStyle(user.subscriptionTier == .pro ? Color.dsSecondary : Color.dsMutedForeground)
                            }
                            Spacer()
                        }
                    } else {
                        // Not signed in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Account")
                                    .dsFont(.body)
                                    .foregroundStyle(Color.dsForeground)
                                Text("Sign up to upgrade to unlimited")
                                    .dsFont(.label)
                                    .foregroundStyle(Color.dsMutedForeground)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Upgrade") {
                                authManager.openSignUp()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            // Word Usage Card (for all free users - authenticated or not)
            if !isPro {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Word Usage")
                                    .dsFont(.body)
                                    .foregroundStyle(Color.dsForeground)

                                let (used, limit, _, _) = subscriptionManager.getUsageStatus()
                                let remaining = max(0, limit - used)

                                if remaining == 0 {
                                    Text("You've used all \(limit) free words this month")
                                        .dsFont(.label)
                                        .foregroundStyle(Color.orange)
                                } else {
                                    Text("\(used) of \(limit) words used this month")
                                        .dsFont(.label)
                                        .foregroundStyle(Color.dsMutedForeground)
                                }
                            }
                            Spacer()
                        }

                        // Progress bar
                        let (used, limit, percentage, _) = subscriptionManager.getUsageStatus()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 8)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(percentage >= 1.0 ? Color.orange : Color.accentColor)
                                    .frame(width: geo.size.width * min(percentage, 1.0), height: 8)
                            }
                        }
                        .frame(height: 8)

                        // Reset date
                        if let resetDate = getResetDate() {
                            Text("Resets \(resetDate)")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                    }
                }
            }

            // Upgrade Card (only for authenticated Free tier users)
            if authManager.isAuthenticated && !isPro {
                SettingsCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Upgrade to Pro")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            if isCheckingPayment {
                                Text("Checking for payment confirmation...")
                                    .dsFont(.label)
                                    .foregroundStyle(Color.dsMutedForeground)
                            } else {
                                Text("Unlimited transcriptions, priority support")
                                    .dsFont(.label)
                                    .foregroundStyle(Color.dsMutedForeground)
                            }
                        }
                        Spacer()
                        if isCheckingPayment {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Upgrade") {
                                openPaymentLink()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

        }
        .onAppear {
            resumePaymentCheckIfNeeded()
        }
    }

    private var isPro: Bool {
        authManager.isAuthenticated && authManager.currentUser?.subscriptionTier == .pro
    }

    private func getResetDate() -> String? {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        if authManager.isAuthenticated, let user = authManager.currentUser {
            if let resetAt = user.wordCountResetAt {
                return formatter.string(from: resetAt)
            }
        } else {
            if let resetAt = subscriptionManager.localWordCountResetAt {
                return formatter.string(from: resetAt)
            }
        }
        return nil
    }

    private func openPaymentLink() {
        if isCheckingPayment {
            return
        }

        if let user = authManager.currentUser, user.subscriptionTier == .pro {
            return
        }

        if let user = authManager.currentUser, user.stripeSubscriptionId != nil {
            DebugLog.info("Checkout blocked: existing subscription detected", context: "SettingsView")
            startPaymentConfirmationCheck(resuming: true)
            return
        }

        if hasPendingPaymentAttempt() {
            DebugLog.info("Checkout blocked: payment confirmation already in progress", context: "SettingsView")
            startPaymentConfirmationCheck(resuming: true)
            return
        }

        let paymentLinkKey: String
        switch selectedBillingPeriod {
        case .monthly:
            paymentLinkKey = "STRIPE_PAYMENT_LINK_MONTHLY"
        case .annual:
            paymentLinkKey = "STRIPE_PAYMENT_LINK_ANNUAL"
        case .lifetime:
            paymentLinkKey = "STRIPE_PAYMENT_LINK_LIFETIME"
        @unknown default:
            paymentLinkKey = "STRIPE_PAYMENT_LINK_MONTHLY"
        }

        guard let paymentLinkString = SecretsLoader.getValue(for: paymentLinkKey),
              var paymentURL = URL(string: paymentLinkString)
        else {
            DebugLog.error("Invalid payment link", context: "SettingsView")
            return
        }

        // Add user email as query parameter if authenticated
        if let email = authManager.currentUser?.email,
           let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        {
            var components = URLComponents(url: paymentURL, resolvingAgainstBaseURL: false)
            var queryItems = components?.queryItems ?? []
            queryItems.append(URLQueryItem(name: "prefilled_email", value: encodedEmail))
            components?.queryItems = queryItems
            if let urlWithEmail = components?.url {
                paymentURL = urlWithEmail
            }
        }

        #if canImport(AppKit)
            NSWorkspace.shared.open(paymentURL)
        #endif

        // Start checking for payment confirmation
        startPaymentConfirmationCheck(resuming: false)
    }

    private enum PaymentTracking {
        static let pendingKey = "paymentAttemptAt"
        static let pendingWindow: TimeInterval = 10 * 60
    }

    private func hasPendingPaymentAttempt() -> Bool {
        guard let lastAttempt = AppDefaults.shared.object(forKey: PaymentTracking.pendingKey) as? Date else {
            return false
        }
        return Date().timeIntervalSince(lastAttempt) < PaymentTracking.pendingWindow
    }

    private func markPaymentAttempt() {
        AppDefaults.shared.set(Date(), forKey: PaymentTracking.pendingKey)
    }

    private func clearPaymentAttempt() {
        AppDefaults.shared.removeObject(forKey: PaymentTracking.pendingKey)
    }

    private func resumePaymentCheckIfNeeded() {
        guard !isCheckingPayment, paymentCheckTask == nil else { return }
        guard authManager.isAuthenticated, !isPro else {
            clearPaymentAttempt()
            return
        }
        if hasPendingPaymentAttempt() {
            startPaymentConfirmationCheck(resuming: true)
        }
    }

    private func startPaymentConfirmationCheck(resuming: Bool) {
        guard !isCheckingPayment, paymentCheckTask == nil else { return }

        if !resuming {
            markPaymentAttempt()
        }

        isCheckingPayment = true
        DebugLog.info("Starting payment confirmation check", context: "SettingsView")

        paymentCheckTask = Task {
            var wasCancelled = false
            // Poll for up to 10 minutes (120 checks every 5 seconds)
            for _ in 0 ..< 120 {
                if Task.isCancelled {
                    wasCancelled = true
                    break
                }

                // Wait 5 seconds between checks
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    wasCancelled = true
                    break
                }

                // Refresh user data
                await authManager.refreshUser()

                // Check if subscription status changed to pro
                if authManager.currentUser?.subscriptionTier == .pro {
                    DebugLog.info("✅ Payment confirmed! User is now Pro", context: "SettingsView")
                    await MainActor.run {
                        isCheckingPayment = false
                    }
                    clearPaymentAttempt()
                    break
                }
            }

            // Stop checking after 10 minutes
            await MainActor.run {
                isCheckingPayment = false
                paymentCheckTask = nil
            }
            if !wasCancelled {
                clearPaymentAttempt()
            }
        }
    }

    private func stopPaymentConfirmationCheck() {
        paymentCheckTask?.cancel()
        paymentCheckTask = nil
        isCheckingPayment = false
    }


    // MARK: - General Section

    @Environment(\.openWindow) private var openWindow

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Recording Hotkey Settings Group
            SettingsCard {
                VStack(spacing: 0) {
                    // Dictation Hotkey
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dictation Hotkey")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Shortcut to start and stop dictation")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        HotkeyRecorderView(hotkeyManager: hotkeyManager, hotkeyType: .dictation)
                    }
                    .padding(.vertical, 2)

                    Divider()
                        .padding(.vertical, 6)

                    // Command Hotkey - Hidden for now
                    // HStack(spacing: 12) {
                    //     VStack(alignment: .leading, spacing: 2) {
                    //         Text("Command Hotkey")
                    //             .dsFont(.body)
                    //             .foregroundStyle(Color.dsForeground)
                    //         Text("Transform selected text with voice instructions")
                    //             .dsFont(.label)
                    //             .foregroundStyle(Color.dsMutedForeground)
                    //     }
                    //     Spacer()
                    //     HotkeyRecorderView(hotkeyManager: hotkeyManager, hotkeyType: .command)
                    // }
                    // .padding(.vertical, 2)

                    // Divider()
                    //     .padding(.vertical, 6)

                    // Push-to-Talk Toggle
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Push to Talk")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text(hotkeyManager.isPushToTalk ? "Hold to record, release to stop" : "Press to start, press again to stop")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        Toggle("", isOn: $hotkeyManager.isPushToTalk)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                    .padding(.vertical, 2)
                }
            }

            // Overlay Settings Group
            SettingsCard {
                VStack(spacing: 0) {
                    // Show Overlay When Idle
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Overlay When Idle")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Display the overlay even when not recording")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !overlayManager.hideIdleState },
                            set: { overlayManager.hideIdleState = !$0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)

                    Divider()
                        .padding(.vertical, 6)

                    // Overlay Position
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Overlay Position")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Where the recording indicator appears")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        Picker("", selection: $overlayManager.position) {
                            ForEach(OverlayPosition.allCases, id: \.self) { position in
                                Text(position.rawValue).tag(position)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    .padding(.vertical, 2)
                }
            }

            // Startup Group
            SettingsCard {
                VStack(spacing: 0) {
                    // Launch at Login
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Automatically start when you log in")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { launchAtLoginManager.isEnabled },
                            set: { _ in launchAtLoginManager.toggle() }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // All Permissions in one card
            SettingsCard {
                VStack(spacing: 0) {
                    // Microphone Permission
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(Color.dsMutedForeground)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Microphone")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Required to capture your voice for transcription")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.dsSecondary)
                        } else {
                            Button("Grant Access") {
                                Task {
                                    await AVCaptureDevice.requestAccess(for: .audio)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)

                    Divider()
                        .padding(.vertical, 6)

                    // Accessibility Permission
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(Color.dsMutedForeground)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Needed for global hotkeys and text insertion")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        if AXIsProcessTrusted() {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.dsSecondary)
                        } else {
                            Button("Open Settings") {
                                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
                                let _ = AXIsProcessTrustedWithOptions(options)
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)

                    Divider()
                        .padding(.vertical, 6)

                    // Screen Recording Permission
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.dashed.badge.record")
                            .foregroundStyle(Color.dsMutedForeground)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Recording")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Optional, enables context-aware transcription")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        if screenCaptureManager.hasScreenRecordingPermission {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.dsSecondary)
                        } else {
                            Button("Grant Access") {
                                screenCaptureManager.requestScreenRecordingPermission()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Transcription Section

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provider Selection
            SettingsCard {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transcription Provider")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Choose how your voice is transcribed")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { transcriptionProviderManager.selectedProvider },
                            set: { transcriptionProviderManager.setProvider($0) }
                        )) {
                            ForEach(TranscriptionProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    .padding(.vertical, 2)

                    // Provider description
                    HStack {
                        Text(transcriptionProviderManager.selectedProvider.description)
                            .dsFont(.label)
                            .foregroundStyle(Color.dsMutedForeground)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }

            // On-Device Model Settings (shown when Parakeet is selected)
            if transcriptionProviderManager.selectedProvider == .parakeet {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Model Status")
                                    .dsFont(.body)
                                    .foregroundStyle(Color.dsForeground)
                                Text(parakeetStatusText)
                                    .dsFont(.label)
                                    .foregroundStyle(parakeetStatusColor)
                            }
                            Spacer()

                            switch parakeetService.state {
                            case .notInitialized:
                                Button("Download Model (~500 MB)") {
                                    Task {
                                        try? await parakeetService.initialize()
                                    }
                                }
                                .controlSize(.small)
                            case .downloading, .initializing:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .opacity(0) // Placeholder to maintain layout
                            case .ready, .transcribing:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .error:
                                Button("Retry") {
                                    parakeetService.cleanup()
                                    Task {
                                        try? await parakeetService.initialize()
                                    }
                                }
                                .controlSize(.small)
                            }
                        }

                        Text("Multilingual model supporting 25 European languages")
                            .dsFont(.label)
                            .foregroundStyle(Color.dsMutedForeground)

                        // Progress bar for downloading/initializing states
                        if case .downloading = parakeetService.state {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                Text("Downloading model from Hugging Face...")
                                    .dsFont(.label)
                                    .foregroundStyle(Color.dsMutedForeground)
                            }
                        } else if case .initializing = parakeetService.state {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                Text("Loading model into memory...")
                                    .dsFont(.label)
                                    .foregroundStyle(Color.dsMutedForeground)
                            }
                        }
                    }
                }
            }

            // API Key (shown for cloud providers except Custom which uses Secrets.plist)
            if transcriptionProviderManager.selectedProvider.requiresAPIKey && transcriptionProviderManager.selectedProvider != .custom {
                SettingsCard {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("API Key")
                                    .dsFont(.body)
                                    .foregroundStyle(Color.dsForeground)
                                Text("Your \(transcriptionProviderManager.selectedProvider.displayName) API key")
                                    .dsFont(.label)
                                    .foregroundStyle(Color.dsMutedForeground)
                            }
                            Spacer()
                        }

                        HStack {
                            SecureField("Enter API key", text: $transcriptionApiKey)
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                KeychainHelper.save(
                                    key: transcriptionProviderManager.selectedProvider.apiKeyName,
                                    value: transcriptionApiKey
                                )
                                showingTranscriptionKeySaved = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    showingTranscriptionKeySaved = false
                                }
                            }
                            .controlSize(.small)

                            if showingTranscriptionKeySaved {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
                .onAppear {
                    transcriptionApiKey = KeychainHelper.get(
                        key: transcriptionProviderManager.selectedProvider.apiKeyName
                    ) ?? ""
                }
                .onChange(of: transcriptionProviderManager.selectedProvider) { _ in
                    transcriptionApiKey = KeychainHelper.get(
                        key: transcriptionProviderManager.selectedProvider.apiKeyName
                    ) ?? ""
                }
            }

            // LLM Post-Processing toggle (shown for all providers except Custom)
            if transcriptionProviderManager.selectedProvider != .custom {
                SettingsCard {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("LLM Post-Processing")
                                    .dsFont(.body)
                                    .foregroundStyle(Color.dsForeground)
                                Text("Apply dictionary, shortcuts, and context rules")
                                    .dsFont(.label)
                                    .foregroundStyle(Color.dsMutedForeground)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { transcriptionProviderManager.enableLLMPostProcessing },
                                set: { transcriptionProviderManager.setLLMPostProcessing($0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        }

                        if transcriptionProviderManager.enableLLMPostProcessing {
                            Divider()

                            // Post-processing provider picker
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Post-Processing")
                                        .dsFont(.body)
                                        .foregroundStyle(Color.dsForeground)
                                }
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { transcriptionProviderManager.postProcessingProvider },
                                    set: { transcriptionProviderManager.setPostProcessingProvider($0) }
                                )) {
                                    ForEach(PostProcessingProvider.allCases) { provider in
                                        Text(provider.displayName).tag(provider)
                                    }
                                }
                                .pickerStyle(.menu)
                                .fixedSize()
                            }

                            // Show LLM settings only when Custom LLM is selected
                            if transcriptionProviderManager.postProcessingProvider == .customLLM {
                                // LLM Provider picker
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("LLM Provider")
                                            .dsFont(.body)
                                            .foregroundStyle(Color.dsForeground)
                                    }
                                    Spacer()
                                    Picker("", selection: Binding(
                                        get: { llmProviderManager.selectedProvider },
                                        set: { llmProviderManager.setProvider($0) }
                                    )) {
                                        ForEach(LLMProvider.allCases) { provider in
                                            Text(provider.displayName).tag(provider)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .fixedSize()
                                }

                                // LLM API Key
                                HStack {
                                    SecureField("Enter LLM API key", text: $llmApiKey)
                                        .textFieldStyle(.roundedBorder)

                                    Button("Save") {
                                        KeychainHelper.save(
                                            key: llmProviderManager.selectedProvider.apiKeyName,
                                            value: llmApiKey
                                        )
                                        showingLLMKeySaved = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            showingLLMKeySaved = false
                                        }
                                    }
                                    .controlSize(.small)

                                    if showingLLMKeySaved {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            } // end if customLLM
                        }
                    }
                }
                .onAppear {
                    llmApiKey = KeychainHelper.get(
                        key: llmProviderManager.selectedProvider.apiKeyName
                    ) ?? ""
                }
                .onChange(of: llmProviderManager.selectedProvider) { _ in
                    llmApiKey = KeychainHelper.get(
                        key: llmProviderManager.selectedProvider.apiKeyName
                    ) ?? ""
                }
            }
        }
    }

    private var parakeetStatusText: String {
        switch parakeetService.state {
        case .notInitialized:
            return "Model not downloaded"
        case .downloading:
            return "Downloading model..."
        case .initializing:
            return "Loading model..."
        case .ready:
            return "Ready"
        case .transcribing:
            return "Transcribing..."
        case let .error(message):
            return "Error: \(message)"
        }
    }

    private var parakeetStatusColor: Color {
        switch parakeetService.state {
        case .ready, .transcribing:
            return .green
        case .error:
            return .red
        default:
            return Color.dsMutedForeground
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Audio Settings Group
            SettingsCard {
                VStack(spacing: 0) {
                    // Input Device
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input Device")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Select which microphone to use for recording")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        Picker("", selection: $selectedAudioDevice) {
                            ForEach(audioDevices) { device in
                                Text(device.localizedName).tag(device as AudioDeviceManager.AudioDevice?)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    .padding(.vertical, 2)

                    Divider()
                        .padding(.vertical, 6)

                    // Mute Other Audio
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mute Other Audio")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Pause system audio while recording")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { AppDefaults.shared.object(forKey: "muteAudioWhenRecording") as? Bool ?? true },
                            set: { AppDefaults.shared.set($0, forKey: "muteAudioWhenRecording") }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Language Section

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Transcription Language")
                                .dsFont(.body)
                                .foregroundStyle(Color.dsForeground)
                            Text("Select languages for transcription. Auto-detect works for all languages.")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }

                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 140)),
                    ], spacing: 8) {
                        ForEach(Language.allCases) { language in
                            Button(action: {
                                languageManager.toggleLanguage(language)
                            }) {
                                HStack(spacing: 8) {
                                    Text(language.flag)
                                        .dsFont(.body)

                                    Text(language.displayName)
                                        .dsFont(.body)
                                        .foregroundStyle(languageManager.isSelected(language) ? .white : Color.dsForeground)
                                        .lineLimit(1)

                                    Spacer()

                                    if languageManager.isSelected(language) {
                                        Image(systemName: "checkmark")
                                            .dsFont(.tinyBold)
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: DSCornerRadius.small)
                                        .fill(languageManager.isSelected(language) ? Color.dsPrimary : Color.dsCard)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: DSCornerRadius.small)
                                        .stroke(Color.dsBorder, lineWidth: languageManager.isSelected(language) ? 0 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Text Rules Section

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DictionaryTabView(manager: dictionaryManager)
        }
    }

    private var contextRulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContextRulesTabView(manager: contextRulesManager)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShortcutsTabView(manager: shortcutManager)
        }
    }

    // MARK: - Helper Functions

    private func loadAudioDevices() {
        // Get all available audio input devices using Core Audio
        audioDevices = AudioDeviceManager.shared.getInputDevices()

        // Select saved device or default
        if selectedAudioDevice == nil {
            if let savedDeviceID = AppDefaults.shared.string(forKey: "selectedAudioDeviceID"),
               let savedDevice = audioDevices.first(where: { $0.uniqueID == savedDeviceID })
            {
                selectedAudioDevice = savedDevice
            } else {
                selectedAudioDevice = AudioDeviceManager.shared.getDefaultInputDevice()
            }
        }
    }

    private func saveSelectedAudioDevice(_ device: AudioDeviceManager.AudioDevice?) {
        if let device = device {
            AppDefaults.shared.set(device.uniqueID, forKey: "selectedAudioDeviceID")
            DebugLog.info("Setting audio device: \(device.localizedName)", context: "SettingsView")

            // Set as system default so AVAudioEngine will use it
            let success = AudioDeviceManager.shared.setDefaultInputDevice(deviceID: device.id)
            if success {
                DebugLog.info("Successfully set default input device", context: "SettingsView")

                // Notify AudioRecorder about the change
                NotificationCenter.default.post(
                    name: NSNotification.Name("AudioInputDeviceChanged"),
                    object: device.uniqueID
                )
            } else {
                DebugLog.info("Failed to set default input device", context: "SettingsView")
            }
        }
    }

    private func setupDeviceNotifications() {
        // Listen for device list changes from Core Audio
        // Using .onReceive in SwiftUI instead of NotificationCenter for proper lifecycle management
    }

    private func removeDeviceNotifications() {
        // Handled by SwiftUI's .onReceive lifecycle
    }
}

// MARK: - Rule Row Component

struct RuleRow: View {
    let rule: PromptRule
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Rule text
            Text(rule.text)
                .font(.body)
                .foregroundStyle(rule.isEnabled ? .primary : .secondary)

            Spacer()

            // Delete button (visible on hover) - always present to prevent height changes
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.body)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .frame(width: 16, height: 16)
            .opacity(isHovering ? 1 : 0)

            // Toggle switch
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(nsColor: .separatorColor)),
            alignment: .bottom
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Sidebar Account Status View

struct SidebarAccountStatusView: View {
    @ObservedObject private var authManager = AuthManager.shared
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    var onTap: () -> Void

    var body: some View {
        let (used, limit, percentage, isPro) = subscriptionManager.getUsageStatus()

        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                // Plan badge
                HStack(spacing: 4) {
                    Image(systemName: isPro ? "star.fill" : "person.fill")
                        .font(.caption2)
                    Text(isPro ? "Pro" : "Free")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(isPro ? .orange : .secondary)

                if isPro {
                    Text("Unlimited transcriptions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    // Usage bar
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 4)

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(percentage >= 0.9 ? Color.orange : Color.accentColor)
                                    .frame(width: geo.size.width * min(percentage, 1.0), height: 4)
                            }
                        }
                        .frame(height: 4)

                        Text("\(limit - used) words left")
                            .font(.caption2)
                            .foregroundStyle(percentage >= 0.9 ? .orange : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var selectedSection: SettingsSection = .general

        var body: some View {
            SettingsView(
                hotkeyManager: HotkeyManager.shared,
                languageManager: LanguageManager.shared,
                transcriptionProviderManager: TranscriptionProviderManager(),
                llmProviderManager: LLMProviderManager.shared,
                dictionaryManager: DictionaryManager.shared,
                contextRulesManager: ContextRulesManager.shared,
                shortcutManager: ShortcutManager.shared,
                selectedSection: $selectedSection
            )
        }
    }

    return PreviewWrapper()
}
