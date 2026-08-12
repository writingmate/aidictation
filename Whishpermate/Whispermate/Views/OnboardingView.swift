import SwiftUI
import WhisperMateShared

struct OnboardingView: View {
    @ObservedObject var onboardingManager: OnboardingManager
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var languageManager: LanguageManager
    @ObservedObject var promptRulesManager: PromptRulesManager
    @ObservedObject var llmProviderManager: LLMProviderManager

    @State private var isCheckingAccessibility = false
    @State private var isCheckingMicrophone = false
    @State private var showChangeHotkey = false
    @State private var showModelDownloadAlert = false
    @State private var pendingMode: TranscriptionMode?
    @State private var fnKeyMonitor: FnKeyMonitor?
    @State private var fnKeyDetected = false
    @State private var fnKeyEverDetected = false
    @ObservedObject var transcriptionProviderManager: TranscriptionProviderManager
    @ObservedObject var parakeetService = ParakeetTranscriptionService.shared
    @ObservedObject var overlayManager = OverlayWindowManager.shared
    @ObservedObject private var authManager = AuthManager.shared

    @State private var currentUIStep: OnboardingUIStep = .permissions
    @State private var selectedOnboardingMode: TranscriptionMode = .cloud
    @State private var firstRecordingText = ""
    @FocusState private var isTestFieldFocused: Bool

    enum OnboardingUIStep: Int, CaseIterable {
        case permissions = 0
        case languages = 1
        case transcriptionMode = 2
        case overlayColor = 3
        case hotkeyTest = 4
        case firstRecording = 5
        case account = 6
        case complete = 7
    }

    private func stepName(_ step: OnboardingUIStep) -> String {
        switch step {
        case .permissions: return "permissions"
        case .languages: return "languages"
        case .transcriptionMode: return "transcription_mode"
        case .overlayColor: return "overlay_color"
        case .hotkeyTest: return showChangeHotkey ? "hotkey_change" : "hotkey_test"
        case .firstRecording: return "first_recording"
        case .account: return "account"
        case .complete: return "complete"
        }
    }

    // Gradient colors
    private let gradientStart = Color(red: 1.0, green: 0.494, blue: 0.78) // #FF7EC7
    private let gradientEnd = Color(red: 1.0, green: 0.929, blue: 0.275) // #FFED46

    private let accentColor = Color(red: 0.945, green: 0.431, blue: 0.0) // #F16E00
    private var isAccountSignedIn: Bool {
        authManager.isAuthenticated && authManager.currentUser != nil
    }

    var body: some View {
        Group {
            if currentUIStep == .complete {
                completeScreen
            } else {
                splitLayoutScreen
            }
        }
        .padding(12)
        .frame(width: 1100, height: 724)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .onAppear {
            // Reset to first step when onboarding is shown fresh
            currentUIStep = .permissions
            firstRecordingText = ""
            fnKeyDetected = false
            fnKeyEverDetected = false
            showChangeHotkey = false
            hotkeyManager.setDeferRegistration(true)
            // Immediately refresh permission status before starting periodic checks
            onboardingManager.updateMicrophoneStatus()
            onboardingManager.updateAccessibilityStatus()
            recordOnboardingStep("step_shown")
            startPermissionChecks()
        }
        .onDisappear {
            hotkeyManager.setDeferRegistration(false)
            stopAllChecks()
        }
        .alert("Download the offline model?", isPresented: $showModelDownloadAlert) {
            Button("Download Model") {
                if let mode = pendingMode {
                    selectedOnboardingMode = mode
                    recordOnboardingStep(
                        "setting_selected",
                        data: ["selected_setting": "transcription_mode", "model_download": "accepted"]
                    )
                }
                let service = parakeetService
                Task {
                    if case .error = await MainActor.run(body: { service.state }) {
                        await MainActor.run { service.cleanup() }
                    }
                    try? await service.initialize()
                }
                pendingMode = nil
            }
            Button("Not Now", role: .cancel) {
                recordOnboardingStep(
                    "setting_selected",
                    data: ["selected_setting": "transcription_mode", "model_download": "declined"]
                )
                pendingMode = nil
            }
        } message: {
            Text("Local and Auto need a one-time download of about 200 MB.")
        }
    }

    // MARK: - Split Layout Screen

    private var splitLayoutScreen: some View {
        HStack(spacing: 0) {
            leftContentArea
                .frame(width: 620)
                .background(.background)

            rightGradientArea
                .frame(width: 456)
        }
    }

    // MARK: - Left Content Area

    private var leftContentArea: some View {
        VStack(spacing: 0) {
            // Step indicators
            HStack(spacing: 8) {
                ForEach(0 ..< OnboardingUIStep.complete.rawValue, id: \.self) { index in
                    Circle()
                        .fill(index <= currentUIStep.rawValue ? accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()
                .frame(height: 40)

            // Title
            Text(stepTitle)
                .font(.largeTitle)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Subtitle (if applicable)
            if let subtitle = stepSubtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }

            Spacer()
                .frame(height: 40)

            // Step content
            stepContent

            Spacer()

            // Navigation buttons at bottom
            navigationButtons
        }
        .padding(.top, 40)
        .padding(.bottom, 40)
        .padding(.horizontal, 60)
    }

    // MARK: - Right Gradient Area

    private var rightGradientArea: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [gradientEnd, gradientStart]),
                    startPoint: .top,
                    endPoint: .bottom
                )

                ZStack {
                    decorativeImage
                        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
                }
                .id(currentUIStep)
                .offset(y: (currentUIStep == .languages || currentUIStep == .transcriptionMode || currentUIStep == .overlayColor || currentUIStep == .hotkeyTest || currentUIStep == .account) ? 0 : -geo.size.height * 0.1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .compatibleContentOpacityTransition()
        .animation(.easeInOut(duration: 0.3), value: currentUIStep)
    }

    @ViewBuilder
    private var decorativeImage: some View {
        switch currentUIStep {
        case .permissions:
            // Show mic permission dialog if mic not granted, otherwise accessibility dialog
            // Images are 2x resolution: Mic 840x828 -> 420x414, Accessibility 942x478 -> 471x239
            if onboardingManager.isMicrophoneGranted() {
                Image("OnboardingAccessibilityPermission")
                    .resizable()
                    .frame(width: 471, height: 239)
                    .padding(40)
            } else {
                Image("OnboardingMicPermission")
                    .resizable()
                    .frame(width: 420, height: 414)
                    .padding(40)
            }

        case .languages:
            // 2x: 782x852 -> 391x426
            Image("OnboardingLanguages")
                .resizable()
                .frame(width: 391, height: 426)
                .padding(40)

        case .transcriptionMode:
            Image(systemName: "waveform.badge.mic")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .foregroundStyle(.white.opacity(0.5))
                .padding(40)

        case .overlayColor:
            OnboardingOverlayColorDecorativeView(theme: overlayManager.colorTheme)
                .padding(40)

        case .hotkeyTest:
            // 2x: Keyboard 796x988 -> 398x494, KeyboardPlain 772x896 -> 386x448
            if showChangeHotkey {
                Image("OnboardingKeyboardPlain")
                    .resizable()
                    .frame(width: 386, height: 448)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 0)
                    .padding(.vertical, 40)
            } else {
                Image("OnboardingKeyboard")
                    .resizable()
                    .frame(width: 398, height: 494)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 0)
                    .padding(.vertical, 40)
            }

        case .firstRecording:
            // 2x: 786x740 -> 393x370
            Image("OnboardingDictation")
                .resizable()
                .frame(width: 393, height: 370)
                .padding(40)

        case .account:
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 210, height: 210)

                Circle()
                    .fill(Color.white.opacity(0.34))
                    .frame(width: 150, height: 150)

                Image(systemName: isAccountSignedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.plus")
                    .font(.system(size: 92, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .padding(40)

        case .complete:
            EmptyView()
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentUIStep {
        case .permissions:
            permissionsContent

        case .languages:
            languageContent

        case .transcriptionMode:
            transcriptionModeContent

        case .overlayColor:
            overlayColorContent

        case .hotkeyTest:
            if showChangeHotkey {
                changeHotkeyContent
            } else {
                hotkeyTestContent
            }

        case .firstRecording:
            firstRecordingContent

        case .account:
            accountContent

        case .complete:
            EmptyView()
        }
    }

    // MARK: - Permissions Content

    private var permissionsContent: some View {
        VStack(spacing: 16) {
            PermissionRow(
                title: "Use your microphone",
                subtitle: "AIDictation listens only while you are recording.",
                isGranted: onboardingManager.isMicrophoneGranted(),
                accentColor: accentColor,
                onAllow: {
                    onboardingManager.requestMicrophonePermission()
                }
            )

            PermissionRow(
                title: "Type the result for you",
                subtitle: "This lets AIDictation paste text wherever your cursor is.",
                isGranted: onboardingManager.isAccessibilityGranted(),
                accentColor: accentColor,
                onAllow: {
                    onboardingManager.requestAccessibilityPermission()
                }
            )
        }
    }

    // MARK: - Language Content

    private var languageContent: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 10) {
                ForEach(Language.allCases) { language in
                    languageButton(
                        flag: language.flag,
                        name: language.displayName,
                        isSelected: languageManager.isSelected(language),
                        action: {
                            languageManager.toggleLanguage(language)
                            recordOnboardingStep("setting_selected", data: ["selected_setting": "languages"])
                        }
                    )
                }
            }
        }
        .frame(maxHeight: 350)
    }

    private func languageButton(flag: String, name: String, isSelected: Bool, action: (() -> Void)? = nil) -> some View {
        Button(action: { action?() }) {
            HStack(spacing: 8) {
                Text(flag)

                Text(name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? accentColor : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcription Mode Content

    private var isParakeetReady: Bool {
        if case .ready = parakeetService.state { return true }
        return false
    }

    private var isParakeetDownloading: Bool {
        switch parakeetService.state {
        case .downloading, .initializing: return true
        default: return false
        }
    }

    private func modeStars(speed: Int, quality: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                ForEach(0 ..< 4, id: \.self) { i in
                    Image(systemName: i < speed ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundStyle(i < speed ? accentColor : .secondary.opacity(0.4))
                }
            }
            HStack(spacing: 2) {
                Text("Quality")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                ForEach(0 ..< 4, id: \.self) { i in
                    Image(systemName: i < quality ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundStyle(i < quality ? accentColor : .secondary.opacity(0.4))
                }
            }
        }
    }

    private func modeRating(for mode: TranscriptionMode) -> (speed: Int, quality: Int) {
        switch mode {
        case .cloud: return (speed: 3, quality: 4)
        case .local: return (speed: 4, quality: 3)
        case .auto: return (speed: 4, quality: 4)
        }
    }

    private var transcriptionModeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(TranscriptionMode.allCases, id: \.self) { mode in
                let isSelected = selectedOnboardingMode == mode
                let needsModel = mode != .cloud
                let isAvailable = mode.isAvailable
                let rating = modeRating(for: mode)

                Button {
                    guard isAvailable else { return }

                    if needsModel && !isParakeetReady && !isParakeetDownloading {
                        pendingMode = mode
                        recordOnboardingStep(
                            "setting_selected",
                            data: ["selected_setting": "transcription_mode", "pending_download_mode": mode.rawValue]
                        )
                        showModelDownloadAlert = true
                    } else {
                        selectedOnboardingMode = mode
                        recordOnboardingStep("setting_selected", data: ["selected_setting": "transcription_mode"])
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Text(mode.description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .opacity(isAvailable ? 1 : 0.65)
                        }

                        Spacer()

                        modeStars(speed: rating.speed, quality: rating.quality)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isSelected ? accentColor.opacity(0.08) : Color(nsColor: .windowBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? accentColor : Color.secondary.opacity(0.2), lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable)
            }

            // Model download status (only shown when actively downloading or ready)
            switch parakeetService.state {
            case .downloading:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading offline model…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            case .initializing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Initializing model…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            case .ready, .transcribing:
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Offline model ready")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            case .error(let message):
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Failed: \(message)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Retry") {
                        parakeetService.cleanup()
                        Task { try? await parakeetService.initialize() }
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Overlay Color Content

    private var overlayColorContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            overlayColorPreview

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 10) {
                ForEach(OverlayColorTheme.allCases, id: \.self) { theme in
                    overlayColorButton(theme)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: overlayManager.colorTheme)
    }

    private var overlayColorPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.06))

            HStack(spacing: 7) {
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(overlayManager.colorTheme.onboardingColor)
                    )

                ForEach(0 ..< 10, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 4, height: CGFloat([5, 12, 17, 12, 19, 17, 21, 20, 12, 5][index]))
                }

                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 20, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(overlayManager.colorTheme.onboardingColor)
                            .frame(width: 8, height: 8)
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(overlayManager.colorTheme.onboardingColor)
                    .shadow(color: overlayManager.colorTheme.onboardingColor.opacity(0.28), radius: 14, x: 0, y: 8)
            )
        }
        .frame(height: 110)
    }

    private func overlayColorButton(_ theme: OverlayColorTheme) -> some View {
        let color = theme.onboardingColor
        let isSelected = overlayManager.colorTheme == theme

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                overlayManager.setColorTheme(theme)
            }
            recordOnboardingStep("setting_selected", data: ["selected_setting": "overlay_color"])
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: 28, height: 28)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                Text(theme.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? color.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hotkey Test Content

    private var hotkeyTestContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Title with Fn key inline
            HStack(spacing: 12) {
                Text("Press Fn now")
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text("Fn")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundStyle(fnKeyDetected ? accentColor : .primary)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(fnKeyDetected ? accentColor.opacity(0.1) : Color(nsColor: .windowBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(fnKeyDetected ? accentColor : Color.secondary.opacity(0.3), lineWidth: 2)
                    )
            }

            // "or" with pick other hotkey button
            HStack(spacing: 8) {
                Text("or")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Button("choose another hotkey") {
                    showChangeHotkey = true
                    stopFnKeyMonitoring()
                }
                .buttonStyle(.plain)
                .font(.body)
                .foregroundStyle(accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            startFnKeyMonitoring()
        }
        .onDisappear {
            stopFnKeyMonitoring()
        }
    }

    // MARK: - Change Hotkey Content

    private var changeHotkeyContent: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Text("Choose a shortcut that feels natural.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                HotkeyRecorderView(hotkeyManager: hotkeyManager, showsConflictHelp: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }

    // MARK: - First Recording Content

    private var firstRecordingContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Text field for testing - first so user focuses here
            firstRecordingTextField
                .textFieldStyle(.plain)
                .font(.body)
                .padding(12)
                .frame(minHeight: 100, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .focused($isTestFieldFocused)

            // Instructions below
            VStack(alignment: .leading, spacing: 12) {
                Text("Hold \(hotkeyManager.currentHotkey?.displayString ?? "the hotkey")")
                    .font(.body)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text("Say:")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("This is my first recording.")
                        .font(.body)
                        .italic()
                        .foregroundStyle(.secondary)
                }

                Text("Release when you are done")
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Enable hotkey registration for testing
            DebugLog.info("FirstRecording onAppear - enabling hotkey registration, currentHotkey=\(hotkeyManager.currentHotkey?.displayString ?? "nil")", context: "OnboardingView")
            hotkeyManager.setDeferRegistration(false)
            // Auto-focus the text field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTestFieldFocused = true
            }
        }
        .onDisappear {
            // Re-defer if going back
            DebugLog.info("FirstRecording onDisappear - currentUIStep=\(currentUIStep)", context: "OnboardingView")
            if currentUIStep != .complete {
                hotkeyManager.setDeferRegistration(true)
            }
        }
    }

    // MARK: - Account Content

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if authManager.isAuthenticated, let user = authManager.currentUser {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signed in")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(user.email)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.35), lineWidth: 1)
                )
            } else {
                Button(action: goNext) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use AIDictation now, sign in anytime")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Sign in to keep your account and billing in one place.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(AccountCardButtonStyle())
                .accessibilityLabel("Sign in")
                .accessibilityHint("Opens sign-in in your browser")

                if authManager.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking session...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = authManager.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var firstRecordingTextField: some View {
        let prompt = "Press \(hotkeyManager.currentHotkey?.displayString ?? "hotkey") and speak..."
        if #available(macOS 13.0, *) {
            TextField(prompt, text: $firstRecordingText, axis: .vertical)
        } else {
            TextField(prompt, text: $firstRecordingText)
        }
    }

    // MARK: - Complete Screen

    @State private var completeAnimationPhase = 0 // 0: start, 1: expanded, 2: card, 3: checkmark, 4: button

    private var completeScreen: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [gradientEnd, gradientStart]),
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if completeAnimationPhase >= 2 {
                VStack(spacing: 24) {
                    // Success checkmark with animation
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 80, height: 80)
                            .scaleEffect(completeAnimationPhase >= 3 ? 1 : 0)

                        Image(systemName: "checkmark")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(.white)
                            .scaleEffect(completeAnimationPhase >= 3 ? 1 : 0)
                    }

                    VStack(spacing: 12) {
                        Text("You're ready")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)

                        Text("Dictate into any app on your Mac.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .opacity(completeAnimationPhase >= 3 ? 1 : 0)

                    if completeAnimationPhase >= 4 {
                        Button("Let's Go!") {
                            onboardingManager.completeOnboarding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accentColor)
                        .compatibleExtraLargeControlSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(48)
                .frame(maxWidth: 400)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.15), radius: 30, x: 0, y: 15)
                )
                .scaleEffect(completeAnimationPhase >= 2 ? 1 : 0.8)
                .opacity(completeAnimationPhase >= 2 ? 1 : 0)
            }
        }
        .frame(width: completeAnimationPhase >= 1 ? 1076 : 456, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: completeAnimationPhase)
        .onAppear {
            startCompleteAnimation()
        }
    }

    private func startCompleteAnimation() {
        completeAnimationPhase = 0

        // Phase 1: Expand sidebar (0.1s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                completeAnimationPhase = 1
            }
        }

        // Phase 2: Show card (0.4s after expand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                completeAnimationPhase = 2
            }
        }

        // Phase 3: Show checkmark with bounce (0.3s after card)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                completeAnimationPhase = 3
            }
        }

        // Phase 4: Show button (0.3s after checkmark)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.3)) {
                completeAnimationPhase = 4
            }
        }
    }

    // MARK: - Navigation Buttons

    @ViewBuilder
    private var navigationButtons: some View {
        let canProceed: Bool = {
            switch currentUIStep {
            case .permissions:
                return onboardingManager.isMicrophoneGranted() && onboardingManager.isAccessibilityGranted()
            case .languages:
                return true
            case .transcriptionMode:
                if selectedOnboardingMode == .cloud { return true }
                if case .ready = parakeetService.state { return true }
                return false
            case .overlayColor:
                return true
            case .hotkeyTest:
                return showChangeHotkey ? hotkeyManager.currentHotkey != nil : fnKeyEverDetected
            case .firstRecording:
                return true
            case .account:
                return true
            case .complete:
                return true
            }
        }()

        HStack(spacing: 12) {
            // Back button (not shown on first step)
            if currentUIStep != .permissions {
                Button("Back", action: goBack)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }

            if currentUIStep == .account {
                Button("Skip", action: skipAccountStep)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                Button(isAccountSignedIn ? "Finish" : "Sign In", action: goNext)
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .controlSize(.regular)
                    .disabled(authManager.isLoading || authManager.isAuthenticationSessionActive)
            } else {
                // Next button
                Button("Next", action: goNext)
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .controlSize(.regular)
                    .disabled(!canProceed)
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private func recordOnboardingStep(_ event: String, step: OnboardingUIStep? = nil, data: [String: Any] = [:]) {
        let targetStep = step ?? currentUIStep
        var payload = onboardingTelemetryData(for: targetStep)
        for (key, value) in data {
            payload[key] = value
        }
        SentryTelemetry.recordOnboardingStep(event, step: stepName(targetStep), data: payload)
    }

    private func onboardingTelemetryData(for step: OnboardingUIStep) -> [String: Any] {
        let selectedLanguages = languageManager.selectedLanguages
            .map(\.rawValue)
            .sorted()
        let selectedLanguageValue = selectedLanguages.joined(separator: ",")
        let selectedHotkeyValue = hotkeyManager.currentHotkey?.displayString
        let selectedAccountValue = authManager.currentUser?.email ?? "not_signed_in"

        var data: [String: Any] = [
            "microphone_granted": onboardingManager.isMicrophoneGranted(),
            "accessibility_granted": onboardingManager.isAccessibilityGranted(),
            "language_count": selectedLanguages.count,
            "languages": selectedLanguages,
            "selected_languages": selectedLanguages,
            "transcription_mode": selectedOnboardingMode.rawValue,
            "selected_transcription_mode": selectedOnboardingMode.rawValue,
            "transcription_mode_available": selectedOnboardingMode.isAvailable,
            "overlay_color": overlayManager.colorTheme.rawValue,
            "selected_color": overlayManager.colorTheme.rawValue,
            "hotkey_configured": hotkeyManager.currentHotkey != nil,
            "fn_detected": fnKeyEverDetected,
            "account_signed_in": isAccountSignedIn,
        ]

        if let selectedHotkeyValue {
            data["hotkey"] = selectedHotkeyValue
            data["selected_hotkey"] = selectedHotkeyValue
        }

        if let user = authManager.currentUser {
            data["account_email"] = user.email
            data["selected_email"] = user.email
            data["account_user_id"] = user.userId.uuidString
            data["account_subscription_status"] = user.subscriptionStatus
            data["account_subscription_tier"] = user.subscriptionTier.displayName
        }

        switch parakeetService.state {
        case .notInitialized:
            data["local_model_state"] = "not_initialized"
        case .downloading:
            data["local_model_state"] = "downloading"
        case .initializing:
            data["local_model_state"] = "initializing"
        case .ready:
            data["local_model_state"] = "ready"
        case .transcribing:
            data["local_model_state"] = "transcribing"
        case .error:
            data["local_model_state"] = "error"
        }

        switch step {
        case .permissions:
            data["selected_setting"] = "permissions"
            data["selected_setting_value"] = [
                "microphone:\(onboardingManager.isMicrophoneGranted())",
                "accessibility:\(onboardingManager.isAccessibilityGranted())",
            ].joined(separator: ",")
        case .languages:
            data["selected_setting"] = "languages"
            data["selected_setting_value"] = selectedLanguageValue
        case .transcriptionMode:
            data["selected_setting"] = "transcription_mode"
            data["selected_setting_value"] = selectedOnboardingMode.rawValue
        case .overlayColor:
            data["selected_setting"] = "overlay_color"
            data["selected_setting_value"] = overlayManager.colorTheme.rawValue
        case .hotkeyTest:
            data["selected_setting"] = showChangeHotkey ? "custom_hotkey" : "fn_hotkey"
            data["selected_setting_value"] = selectedHotkeyValue ?? (fnKeyEverDetected ? "fn" : "not_configured")
        case .firstRecording:
            data["selected_setting"] = "first_recording"
            data["selected_setting_value"] = firstRecordingText.isEmpty ? "empty" : "recorded"
            data["first_recording_text_length"] = firstRecordingText.count
        case .account:
            data["selected_setting"] = isAccountSignedIn ? "signed_in" : "not_signed_in"
            data["selected_setting_value"] = selectedAccountValue
        case .complete:
            data["selected_setting"] = "complete"
            data["selected_setting_value"] = "complete"
        }

        return data
    }

    private func setOnboardingStep(_ nextStep: OnboardingUIStep) {
        currentUIStep = nextStep
        recordOnboardingStep("step_shown", step: nextStep)
    }

    private var stepTitle: String {
        switch currentUIStep {
        case .permissions:
            return "Let's get AIDictation ready"
        case .languages:
            return "What languages do you use?"
        case .transcriptionMode:
            return "How should transcription run?"
        case .overlayColor:
            return "Pick your overlay color"
        case .hotkeyTest:
            return showChangeHotkey ? "Change your hotkey" : "Try your dictation hotkey"
        case .firstRecording:
            return "Try one quick recording"
        case .account:
            return "Sign in?"
        case .complete:
            return ""
        }
    }

    private var stepSubtitle: String? {
        switch currentUIStep {
        case .languages:
            return "Choose the languages you speak. Auto-detect works well if you switch often."
        case .transcriptionMode:
            return "Use cloud for best accuracy, local for offline speed, or auto to let AIDictation choose."
        case .overlayColor:
            return "This changes the recording pill at the bottom of your screen."
        case .hotkeyTest:
            if showChangeHotkey {
                return "Pick the key or shortcut you want to use when dictating."
            } else {
                return "Press Fn now. You can choose another shortcut if Fn does not feel right."
            }
        case .account:
            return "This is optional. You can skip and start dictating now."
        default:
            return nil
        }
    }

    private func goBack() {
        recordOnboardingStep("step_back")

        if showChangeHotkey {
            showChangeHotkey = false
            startFnKeyMonitoring()
            recordOnboardingStep("step_shown")
            return
        }

        if let prevIndex = OnboardingUIStep(rawValue: currentUIStep.rawValue - 1) {
            setOnboardingStep(prevIndex)
            if prevIndex == .hotkeyTest {
                startFnKeyMonitoring()
            }
        }
    }

    private func goNext() {
        recordOnboardingStep("step_completed")

        switch currentUIStep {
        case .permissions:
            setOnboardingStep(.languages)
        case .languages:
            setOnboardingStep(.transcriptionMode)
        case .transcriptionMode:
            if !selectedOnboardingMode.isAvailable {
                selectedOnboardingMode = .cloud
            }
            transcriptionProviderManager.setTranscriptionMode(selectedOnboardingMode)
            recordOnboardingStep("setting_applied", data: ["selected_setting": "transcription_mode"])
            setOnboardingStep(.overlayColor)
        case .overlayColor:
            setOnboardingStep(.hotkeyTest)
            startFnKeyMonitoring()
        case .hotkeyTest:
            if showChangeHotkey {
                if hotkeyManager.currentHotkey != nil {
                    setOnboardingStep(.firstRecording)
                }
            } else if fnKeyEverDetected {
                hotkeyManager.setHotkey(Hotkey(keyCode: 63, modifiers: .function))
                recordOnboardingStep("setting_applied", data: ["selected_setting": "fn_hotkey"])
                setOnboardingStep(.firstRecording)
            }
        case .firstRecording:
            setOnboardingStep(.account)
        case .account:
            if isAccountSignedIn {
                showCompleteScreen()
            } else {
                recordOnboardingStep("account_sign_in_started")
                authManager.openLogin()
            }
        case .complete:
            recordOnboardingStep("onboarding_completed")
            onboardingManager.completeOnboarding()
        }
    }

    private func skipAccountStep() {
        recordOnboardingStep("account_skipped")
        showCompleteScreen()
    }

    private func showCompleteScreen() {
        // Ensure hotkey stays enabled for complete screen
        hotkeyManager.setDeferRegistration(false)
        setOnboardingStep(.complete)
    }

    // MARK: - Permission Checking

    private func startPermissionChecks() {
        startMicrophoneCheck()
        startAccessibilityCheck()
    }

    private func stopAllChecks() {
        stopMicrophoneCheck()
        stopAccessibilityCheck()
        stopFnKeyMonitoring()
    }

    private func startMicrophoneCheck() {
        isCheckingMicrophone = true
        checkMicrophonePeriodically()
    }

    private func stopMicrophoneCheck() {
        isCheckingMicrophone = false
    }

    private func checkMicrophonePeriodically() {
        guard isCheckingMicrophone else { return }
        onboardingManager.updateMicrophoneStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.checkMicrophonePeriodically()
        }
    }

    private func startAccessibilityCheck() {
        isCheckingAccessibility = true
        checkAccessibilityPeriodically()
    }

    private func stopAccessibilityCheck() {
        isCheckingAccessibility = false
    }

    private func checkAccessibilityPeriodically() {
        guard isCheckingAccessibility else { return }
        onboardingManager.updateAccessibilityStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.checkAccessibilityPeriodically()
        }
    }

    private func startFnKeyMonitoring() {
        DebugLog.info("Starting Fn key monitoring", context: "OnboardingView")
        fnKeyMonitor = FnKeyMonitor()
        fnKeyMonitor?.onFnPressed = {
            DebugLog.info("Fn key pressed", context: "OnboardingView")
            fnKeyDetected = true
            fnKeyEverDetected = true
            recordOnboardingStep("setting_selected", data: ["selected_setting": "fn_hotkey"])
        }
        fnKeyMonitor?.onFnReleased = {
            DebugLog.info("Fn key released", context: "OnboardingView")
            fnKeyDetected = false
        }
        fnKeyMonitor?.startMonitoring(consumePureFnEvents: onboardingManager.isAccessibilityGranted())
    }

    private func stopFnKeyMonitoring() {
        DebugLog.info("Stopping Fn key monitoring", context: "OnboardingView")
        fnKeyMonitor?.stopMonitoring()
        fnKeyMonitor = nil
        fnKeyDetected = false
    }
}

// MARK: - Account Card Button Style

/// Card-shaped button for the onboarding account step: it reads as a resting
/// container until pointed at, so the sign-in affordance is discoverable
/// without competing with the footer's primary action.
private struct AccountCardButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(configuration.isPressed ? 0.14 : (isHovering ? 0.1 : 0.06)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(isHovering ? 0.35 : 0.2), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Permission Row Component

struct PermissionRow: View {
    let title: String
    let subtitle: String
    let isGranted: Bool
    let accentColor: Color
    let onAllow: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Group {
                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                } else {
                    Button("Allow", action: onAllow)
                        .buttonStyle(.borderedProminent)
                        .tint(accentColor)
                        .controlSize(.regular)
                }
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Scaled Image Helper

struct ScaledImage: View {
    let name: String
    let scale: CGFloat

    var body: some View {
        Image(name)
            .scaleEffect(scale)
            .frame(
                width: (NSImage(named: name)?.size.width ?? 0) * scale,
                height: (NSImage(named: name)?.size.height ?? 0) * scale
            )
    }
}

private struct OnboardingOverlayColorDecorativeView: View {
    let theme: OverlayColorTheme

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 260, height: 260)

                Circle()
                    .stroke(Color.white.opacity(0.28), lineWidth: 2)
                    .frame(width: 210, height: 210)

                VStack(spacing: 16) {
                    overlayPill(scale: 1.25)

                    HStack(spacing: 10) {
                        ForEach(OverlayColorTheme.allCases, id: \.self) { option in
                            Circle()
                                .fill(option.onboardingColor)
                                .frame(width: option == theme ? 22 : 16, height: option == theme ? 22 : 16)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(option == theme ? 0.9 : 0.35), lineWidth: option == theme ? 3 : 1)
                                )
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: theme)
    }

    private func overlayPill(scale: CGFloat) -> some View {
        HStack(spacing: 7 * scale) {
            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 20 * scale, height: 20 * scale)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundStyle(theme.onboardingColor)
                )

            ForEach(0 ..< 10, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 4 * scale, height: CGFloat([5, 12, 17, 12, 19, 17, 21, 20, 12, 5][index]) * scale)
            }

            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 20 * scale, height: 20 * scale)
                .overlay(
                    RoundedRectangle(cornerRadius: 2 * scale)
                        .fill(theme.onboardingColor)
                        .frame(width: 8 * scale, height: 8 * scale)
                )
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 9 * scale)
        .background(
            Capsule()
                .fill(theme.onboardingColor)
                .shadow(color: theme.onboardingColor.opacity(0.28), radius: 18, x: 0, y: 8)
        )
    }
}

private extension OverlayColorTheme {
    var onboardingColor: Color {
        color
    }
}

private extension View {
    @ViewBuilder
    func compatibleContentOpacityTransition() -> some View {
        if #available(macOS 13.0, *) {
            contentTransition(.opacity)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleExtraLargeControlSize() -> some View {
        if #available(macOS 14.0, *) {
            controlSize(.extraLarge)
        } else {
            controlSize(.large)
        }
    }
}
