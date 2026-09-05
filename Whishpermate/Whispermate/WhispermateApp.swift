//
//  WhispermateApp.swift
//  Whishpermate
//
//  Created by Artsiom Vysotski on 10/16/25.
//

import CoreText
import SwiftUI
import WhisperMateShared

private enum AppWindowDefaults {
    static let mainFrameSize = NSSize(width: 900, height: 650)
    static let historyFrameSize = NSSize(width: 900, height: 600)
    static let onboardingFrameSize = NSSize(width: 1100, height: 724)

    static func setFrameSize(_ size: NSSize, for window: NSWindow) {
        let currentFrame = window.frame
        window.setFrame(
            NSRect(
                x: currentFrame.midX - size.width / 2,
                y: currentFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }
}

private func isAuthCallbackURL(_ url: URL) -> Bool {
    url.scheme == AuthManager.applicationURLScheme
        && (url.host == "auth-callback" || url.host == "auth")
}

private enum AuthCallbackGate {
    private static var lastProcessedURL: String?
    private static var lastProcessedTime: Date?
    private static let duplicateWindow: TimeInterval = 5.0

    static func shouldProcess(_ url: URL, context: String) -> Bool {
        let urlString = url.absoluteString
        let now = Date()

        if let lastURL = lastProcessedURL,
           let lastTime = lastProcessedTime,
           lastURL == urlString,
           now.timeIntervalSince(lastTime) < duplicateWindow
        {
            DebugLog.info("Ignoring duplicate auth callback", context: context)
            return false
        }

        lastProcessedURL = urlString
        lastProcessedTime = now
        return true
    }
}

private enum MainSettingsWindowOpenState {
    private static var isOpening = false
    private static var lastOpenRequest = Date.distantPast
    private static let creationTimeout: TimeInterval = 1.5

    static func shouldRequestCreation() -> Bool {
        let now = Date()
        if isOpening, now.timeIntervalSince(lastOpenRequest) < creationTimeout {
            return false
        }

        isOpening = true
        lastOpenRequest = now
        return true
    }

    static func resolve() {
        isOpening = false
    }
}

/// Emits a sanitized account-state snapshot only when the release workflow
/// explicitly enables it. This lets the hosted gate observe the signed app
/// after Launch Services delivers the real browser callback without exposing
/// account identifiers or auth tokens.
private final class ReleaseAuthVerificationReporter {
    static let shared = ReleaseAuthVerificationReporter()

    private var outputURL: URL?

    private init() {}

    func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AIDICTATION_RELEASE_AUTH_SMOKE"] == "1",
              let outputPath = environment["AIDICTATION_RELEASE_AUTH_RESULT"],
              !outputPath.isEmpty
        else {
            return
        }

        outputURL = URL(fileURLWithPath: outputPath)
    }

    func report(_ authManager: AuthManager, outcome: AuthCallbackOutcome) {
        guard let outputURL else { return }

        let user = authManager.currentUser
        let payload: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "authenticated": authManager.isAuthenticated,
            "profile_loaded": user != nil,
            "subscription_status": user?.subscriptionStatus ?? "missing",
            "subscription_tier": user?.subscriptionTier.rawValue ?? "missing",
            "has_reached_limit": user?.hasReachedLimit ?? true,
            "words_remaining_unlimited": user?.effectiveWordLimit == Int.max,
            "auth_error_present": authManager.error != nil,
            "callback_has_access_token": outcome.hasAccessToken,
            "callback_has_refresh_token": outcome.hasRefreshToken,
            "callback_has_token_type": outcome.hasTokenType,
            "callback_has_expires_in": outcome.hasExpiresIn,
            "callback_session_established": outcome.sessionEstablished,
            "profile_request_started": outcome.profileRequestStarted,
            "callback_failure_phase": outcome.failurePhase.rawValue,
            "callback_failure_category": outcome.failureCategory.rawValue,
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: outputURL, options: .atomic)
        } catch {
            DebugLog.error("Could not write the release authentication result", context: "ReleaseVerification")
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusBarManager = StatusBarManager()
    var mainWindow: NSWindow?

    // Keep references to managers
    private let appState = AppState.shared
    private let hotkeyManager = HotkeyManager.shared
    private let onboardingManager = OnboardingManager.shared
    private let authManager = AuthManager.shared
    private let subscriptionManager = SubscriptionManager.shared
    private let terminationReplyGuard = MacTerminationReplyGuard()

    func applicationDidFinishLaunching(_: Notification) {
        ReleaseAuthVerificationReporter.shared.startIfRequested()
        SentryTelemetry.start()
        DockIconManager.shared.applySavedPreference()
        statusBarManager.setupMenuBar()
        _ = UpdateManager.shared
        _ = MeetingNotesCoordinator.shared
        _ = MeetingDetectionMonitor.shared

        // Disable automatic window restoration for all windows except main
        AppDefaults.shared.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Set up hotkey callbacks once at app startup
        // This ensures they persist throughout the app lifecycle
        setupHotkeyCallbacks()
        AudioDeviceManager.shared.applyPreferredOrAutomaticDevice()

        // Listen for onboarding completion to close the onboarding window and show main.
        // This must be in AppDelegate because the main window's SwiftUI view may not be
        // active yet (the window is hidden at launch), so .onReceive won't fire there.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOnboardingComplete),
            name: .onboardingComplete,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bringOnboardingToFront),
            name: .bringOnboardingToFront,
            object: nil
        )

        // Check if onboarding is needed and open window if necessary
        checkAndShowOnboarding()

        // Show overlay on app launch (if not hidden by user preference)
        if !OverlayWindowManager.shared.hideIdleState {
            OverlayWindowManager.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Don't show settings window during onboarding or recording/transcription/pasting
        if onboardingManager.showOnboarding {
            return false
        }
        let state = AppState.shared
        if state.recordingState != .idle || state.isProcessing {
            return false
        }
        showMainSettingsWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let token = terminationReplyGuard.begin() else {
            // One terminate-later reply already owns the handoff. Repeated Quit
            // cannot consume native-close proof or create a second AppKit reply.
            return .terminateLater
        }
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let canTerminate = await appState.prepareForTermination()
            guard terminationReplyGuard.resolve(token), let sender else { return }
            sender.reply(toApplicationShouldTerminate: canTerminate)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_: Notification) {
        // Ensure window is always properly configured when app becomes active
        if mainWindow == nil {
            configureMainWindow(preservingVisibility: true)
        }
        // Don't let macOS auto-restore the settings window during onboarding or recording/transcription
        if onboardingManager.showOnboarding {
            mainWindow?.orderOut(nil)
            return
        }
        // Activation can be the direct result of the user choosing Settings.
        // Never hide an explicitly presented window merely because a recording
        // is finishing in the background.
    }

    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let dockMenu = NSMenu()

        // Settings menu item
        let settingsItem = NSMenuItem(
            title: "AIDictation Settings",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        dockMenu.addItem(settingsItem)

        return dockMenu
    }

    // MARK: - URL Handling

    func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        if GoogleCalendarClient.shared.handle(url) { return }
        // Handle authentication callback (aidictation://auth-callback)
        if isAuthCallbackURL(url) {
            DebugLog.info("AppDelegate received authentication callback", context: "AppDelegate")
            guard AuthCallbackGate.shouldProcess(url, context: "AppDelegate") else {
                return
            }

            // Bring app to foreground and show main window
            NSApplication.shared.activate(ignoringOtherApps: true)
            showMainSettingsWindow()

            DebugLog.info("Processing auth callback...", context: "AppDelegate")
            Task {
                let outcome = await authManager.handleAuthCallback(url: url)
                await MainActor.run {
                    ReleaseAuthVerificationReporter.shared.report(authManager, outcome: outcome)
                }
            }
        }
        // Handle payment success callback
        else if url.scheme == AuthManager.applicationURLScheme,
                url.host == "payment",
                url.path == "/success"
        {
            Task {
                await subscriptionManager.handlePaymentSuccess()
            }
        }
        // Handle payment cancel callback
        else if url.scheme == AuthManager.applicationURLScheme,
                url.host == "payment",
                url.path == "/cancel"
        {
            subscriptionManager.handlePaymentCancel()
        }
    }

    @objc private func openSettings() {
        showMainSettingsWindow()
    }

    func configureMainWindow(preservingVisibility: Bool = false) {
        guard let window = findMainWindow()
            ?? mainSettingsWindowCandidates().first else {
            return
        }

        // Only configure once
        if let mainWindow {
            deduplicateMainSettingsWindows(keeping: mainWindow)
            return
        }
        let keepVisible = preservingVisibility && window.isVisible

        // Minimal configuration; keep the native title bar controls visible.
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        applyWindowChrome(window)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.hasShadow = true
        window.isOpaque = true
        AppWindowDefaults.setFrameSize(AppWindowDefaults.mainFrameSize, for: window)

        // Use the system's corner radius for Tahoe/Sequoia
        if #available(macOS 13.0, *) {
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = 12.0
            window.contentView?.layer?.masksToBounds = true
        }

        // Prevent window from being released when closed
        window.isReleasedWhenClosed = false

        // Set window identifier for identification
        window.identifier = WindowIdentifiers.main

        mainWindow = window
        statusBarManager.appWindow = window

        // Set delegate to customize traffic light button behavior
        window.delegate = self

        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        customizeTrafficLightButtons(window: window)

        // Center window before hiding it - prevents jump when showing onboarding
        window.center()

        // Hide window on launch - app starts in menu bar only mode
        if !keepVisible { window.setIsVisible(false) }
        deduplicateMainSettingsWindows(keeping: window)

        DebugLog.info("Main window configured, centered, with native traffic lights and hidden on launch", context: "AppDelegate")
    }

    // MARK: - Traffic Light Customization

    private func customizeTrafficLightButtons(window: NSWindow) {
        // Get traffic light buttons
        guard let closeButton = window.standardWindowButton(.closeButton),
              let miniaturizeButton = window.standardWindowButton(.miniaturizeButton)
        else {
            DebugLog.info("Could not get traffic light buttons", context: "AppDelegate")
            return
        }

        // Red button: Hide window to menu bar
        closeButton.target = self
        closeButton.action = #selector(closeButtonClicked)

        // Yellow button: Contract to overlay
        miniaturizeButton.target = self
        miniaturizeButton.action = #selector(yellowButtonClicked)

        // Green button: Keep standard zoom behavior (don't customize)

        DebugLog.info("Traffic light buttons customized", context: "AppDelegate")
    }

    @objc private func closeButtonClicked() {
        DebugLog.info("Red button clicked - hiding window to menu bar", context: "AppDelegate")
        mainWindow?.setIsVisible(false)
        if !OverlayWindowManager.shared.hideIdleState {
            OverlayWindowManager.shared.show()
        }
    }

    @objc private func yellowButtonClicked() {
        DebugLog.info("Yellow button clicked - contracting to overlay", context: "AppDelegate")
        OverlayWindowManager.shared.contractToOverlay()
    }

    // MARK: - Window Delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Prevent actual close, just hide instead
        if sender === mainWindow {
            sender.setIsVisible(false)
            return false
        }
        return true
    }

    // MARK: - Onboarding

    @objc private func handleOnboardingComplete() {
        DebugLog.info("Handling onboarding complete notification", context: "AppDelegate")

        // Close onboarding window
        if let window = NSApplication.shared.windows.first(where: { $0.identifier == WindowIdentifiers.onboarding }) {
            window.close()
        }

        showMainSettingsWindow()
    }

    @objc private func bringOnboardingToFront() {
        DebugLog.info("Bringing onboarding window to front", context: "AppDelegate")
        NSApplication.shared.activate(ignoringOtherApps: true)
        WindowBridge.openWindow?("onboarding")
    }

    private func checkAndShowOnboarding() {
        // Delay slightly to ensure views are loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            // Check if onboarding needs to be shown
            self.onboardingManager.checkOnboardingStatus()

            DebugLog.info("Onboarding check complete. showOnboarding = \(self.onboardingManager.showOnboarding)", context: "AppDelegate")

            // If onboarding is needed, open it directly
            if self.onboardingManager.showOnboarding {
                WindowBridge.openWindow?("onboarding")
            }
        }
    }

    // MARK: - Hotkey Setup

    private func setupHotkeyCallbacks() {
        DebugLog.info("========================================", context: "AppDelegate")
        DebugLog.info("Setting up hotkey callbacks", context: "AppDelegate")
        DebugLog.info("========================================", context: "AppDelegate")

        // Dictation hotkey callbacks
        hotkeyManager.onHotkeyPressed = { [weak self] in
            DebugLog.info("🎯 Dictation hotkey pressed", context: "AppDelegate")
            self?.appState.startRecording()
        }

        hotkeyManager.onHotkeyReleased = { [weak self] in
            DebugLog.info("🎯 Dictation hotkey released", context: "AppDelegate")
            self?.appState.stopRecording()
        }

        hotkeyManager.onDoubleTap = { [weak self] in
            DebugLog.info("🎯🎯 Double-tap", context: "AppDelegate")
            self?.appState.toggleContinuousRecording()
        }

        // Command hotkey callbacks
        hotkeyManager.onCommandHotkeyPressed = { [weak self] in
            DebugLog.info("🎯 Command hotkey pressed", context: "AppDelegate")
            self?.appState.startCommandRecording()
        }

        hotkeyManager.onCommandHotkeyReleased = { [weak self] in
            DebugLog.info("🎯 Command hotkey released", context: "AppDelegate")
            self?.appState.stopRecording()
        }

        DebugLog.info("Hotkey callbacks configured!", context: "AppDelegate")

        // Build the overlay window now so the first Fn press only has to show
        // it. Creating it lazily put ~1s of NSWindow + SwiftUI setup between
        // the key press and the bubble appearing.
        OverlayWindowManager.shared.prewarmWindow()

        // Same reasoning as the overlay: build the audio engine before the first
        // hotkey rather than after it. ~400ms of CoreAudio setup measured.
        AudioRecorder.shared.prewarmEngine()
        SoundEffectManager.shared.prepare()
    }
}

private func isMainSettingsWindowCandidate(_ window: NSWindow) -> Bool {
    guard window.level == .normal else { return false }

    if window.identifier == WindowIdentifiers.history || window.identifier == WindowIdentifiers.onboarding {
        return false
    }

    if window.identifier == WindowIdentifiers.authPresentation {
        return false
    }

    if window.identifier == WindowIdentifiers.main || window.identifier == WindowIdentifiers.settings {
        return true
    }

    return window.title == AppNaming.displayName
}

private func mainSettingsWindowCandidates() -> [NSWindow] {
    NSApplication.shared.windows.filter(isMainSettingsWindowCandidate)
}

private func presentMainSettingsWindow(_ window: NSWindow) {
    window.setIsVisible(true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    // Cooperative activation (macOS 14+) can land after the ordering above,
    // leaving the window behind the previously active app. Re-assert once
    // the activation has had a chance to complete.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak window] in
        guard let window else { return }
        if !NSApp.isActive {
            activateAppForcefully()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// Activation that works even when triggered from a non-activating panel
/// (the overlay), where plain NSApp.activate is ignored on macOS 14+.
func activateAppForcefully() {
    if #available(macOS 14.0, *) {
        NSApp.activate()
    }
    NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
}

private func deduplicateMainSettingsWindows(keeping keepWindow: NSWindow) {
    let duplicates = mainSettingsWindowCandidates().filter { $0 !== keepWindow }
    guard !duplicates.isEmpty else { return }

    for window in duplicates {
        DebugLog.info("Closing duplicate Settings window: \(window.title)", context: "WindowManagement")
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }
}

private func applyWindowChrome(_ window: NSWindow) {
    window.titlebarSeparatorStyle = .none
    window.toolbar?.showsBaselineSeparator = false

    DispatchQueue.main.async {
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
    }
}

// MARK: - Window Identifier Modifier

struct WindowIdentifierModifier: ViewModifier {
    let identifier: NSUserInterfaceItemIdentifier

    func body(content: Content) -> some View {
        content.background(WindowAccessor(identifier: identifier))
    }
}

struct WindowAccessor: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.identifier = identifier
            if let window = view.window {
                applyWindowChrome(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        nsView.window?.identifier = identifier
        if let window = nsView.window {
            applyWindowChrome(window)
        }
    }
}

extension View {
    func windowIdentifier(_ identifier: NSUserInterfaceItemIdentifier) -> some View {
        modifier(WindowIdentifierModifier(identifier: identifier))
    }
}

/// Global function to show main window - can be called from anywhere
func showMainSettingsWindow(retryCount: Int = 0) {
    precondition(Thread.isMainThread)
    DebugLog.info(
        "showMainSettingsWindow requested attempt=\(retryCount)",
        context: "WindowManagement"
    )

    // Don't show settings while onboarding is active
    if OnboardingManager.shared.showOnboarding {
        DebugLog.info(
            "Settings requested during onboarding; presenting onboarding",
            context: "WindowManagement"
        )
        activateAppForcefully()
        WindowBridge.openLegacyWindow(id: "onboarding")
        return
    }

    activateAppForcefully()

    // Find the main window and show it
    if let window = findMainWindow() {
        MainSettingsWindowOpenState.resolve()
        // Ensure window is configured
        if let appDelegate = NSApp.delegate as? AppDelegate, appDelegate.mainWindow == nil {
            appDelegate.configureMainWindow()
        }
        deduplicateMainSettingsWindows(keeping: window)
        presentMainSettingsWindow(window)
        return
    }

    // Also try by title (window may exist but identifier not yet set)
    if let window = mainSettingsWindowCandidates().first {
        MainSettingsWindowOpenState.resolve()
        if let appDelegate = NSApp.delegate as? AppDelegate, appDelegate.mainWindow == nil {
            appDelegate.configureMainWindow()
        }
        deduplicateMainSettingsWindows(keeping: window)
        presentMainSettingsWindow(window)
        return
    }

    // SwiftUI's openWindow action is not guaranteed to have materialized its
    // scene while a menu-bar-only app is inactive. Create the same hosted view
    // synchronously through AppKit so a Settings request always has an actual
    // window to raise.
    MainSettingsWindowOpenState.resolve()
    DebugLog.info(
        "showMainSettingsWindow: creating synchronous AppKit fallback",
        context: "WindowManagement"
    )
    WindowBridge.openLegacyWindow(id: "main")
}

/// Global function to show history window - can be called from anywhere
func showHistoryWindow() {
    NSApplication.shared.activate(ignoringOtherApps: true)

    // First try to find existing history window
    for window in NSApplication.shared.windows {
        if window.identifier == WindowIdentifiers.history || window.title == "History" {
            window.setIsVisible(true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
    }

    // Window doesn't exist yet - ask SwiftUI to create it
    WindowBridge.openWindow?("history")
}

/// Bridges SwiftUI's openWindow action to AppKit code
enum WindowBridge {
    static var openWindow: ((String) -> Void)?
    static var openNoteWindow: ((UUID) -> Void)?
    private static var retainedWindows: [String: NSWindow] = [:]

    static func openLegacyWindow(id: String) {
        if id == "main" {
            let window = retainedWindows[id]
                ?? findMainWindow()
                ?? NSApplication.shared.windows.first(where: { $0.title == AppNaming.displayName })
                ?? makeMainSettingsWindow()

            retainedWindows[id] = window
            configureMainSettingsWindowIfNeeded()
            presentMainSettingsWindow(window)
            return
        }

        if let window = retainedWindows[id] ?? NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == id }) {
            window.setIsVisible(true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let window: NSWindow
        switch id {
        case "history":
            window = makeWindow(
                id: WindowIdentifiers.history,
                title: "History",
                size: AppWindowDefaults.historyFrameSize,
                rootView: AnyView(HistoryMasterDetailView())
            )
        case "onboarding":
            window = makeWindow(
                id: WindowIdentifiers.onboarding,
                title: "Welcome to AIDictation",
                size: AppWindowDefaults.onboardingFrameSize,
                rootView: AnyView(OnboardingView(
                    onboardingManager: OnboardingManager.shared,
                    hotkeyManager: HotkeyManager.shared,
                    languageManager: LanguageManager.shared,
                    promptRulesManager: PromptRulesManager.shared,
                    llmProviderManager: LLMProviderManager.shared,
                    transcriptionProviderManager: AppState.shared.transcriptionProviderManager
                ))
            )
        default:
            return
        }

        retainedWindows[id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func makeWindow(id: NSUserInterfaceItemIdentifier, title: String, size: NSSize, rootView: AnyView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = id
        window.title = title
        applyWindowChrome(window)
        window.contentViewController = NSHostingController(rootView: rootView)
        AppWindowDefaults.setFrameSize(size, for: window)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func makeMainSettingsWindow() -> NSWindow {
        DebugLog.info("openLegacyWindow: creating main Settings window on demand", context: "WindowManagement")
        return makeWindow(
            id: WindowIdentifiers.main,
            title: AppNaming.displayName,
            size: AppWindowDefaults.mainFrameSize,
            rootView: AnyView(SettingsWindowView())
        )
    }

    private static func configureMainSettingsWindowIfNeeded() {
        guard let appDelegate = NSApp.delegate as? AppDelegate, appDelegate.mainWindow == nil else {
            return
        }

        appDelegate.configureMainWindow()
    }
}

@main
struct WhishpermateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        ModernAppScenes()
    }
}

private struct ModernAppScenes: Scene {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Store openWindow action globally so AppKit code can open SwiftUI windows
        let _ = {
            WindowBridge.openWindow = { [openWindow] id in openWindow(id: id) }
            WindowBridge.openNoteWindow = { [openWindow] id in openWindow(value: id) }
        }()

        // Main window is now Settings
        Window(AppNaming.displayName, id: "main") {
            SettingsWindowView()
                .windowIdentifier(WindowIdentifiers.main)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .defaultPosition(.center)
        .defaultSize(width: AppWindowDefaults.mainFrameSize.width, height: AppWindowDefaults.mainFrameSize.height)
        .commands {
            // Remove File > New Window command since we only want one main window
            CommandGroup(replacing: .newItem) {
                Button("New meeting note") {
                    if let id = MeetingNotesCoordinator.shared.create() { MeetingNoteWindowController.open(id) }
                }.keyboardShortcut("n", modifiers: .command)
                Button("Notetaker") {
                    showMainSettingsWindow()
                    NotificationCenter.default.post(name: .showMeetingNotes, object: nil)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("AIDictation Settings") {
                    showMainSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdateManager.shared.checkForUpdates()
                }
            }
        }

        WindowGroup("Meeting note", for: UUID.self) { $noteID in
            if let noteID {
                NavigationStack { MeetingNoteEditor(noteID: noteID) }
            }
        }
        .defaultSize(width: 700, height: 700)
        .commandsRemoved()

        // History window - opens from Settings
        Window("History", id: "history") {
            HistoryMasterDetailView()
                .windowIdentifier(WindowIdentifiers.history)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .defaultPosition(.center)
        .defaultSize(width: 900, height: 600)
        .commandsRemoved()

        // Onboarding window
        Window("Welcome to Whispermate", id: "onboarding") {
            OnboardingView(
                onboardingManager: OnboardingManager.shared,
                hotkeyManager: HotkeyManager.shared,
                languageManager: LanguageManager.shared,
                promptRulesManager: PromptRulesManager.shared,
                llmProviderManager: LLMProviderManager.shared,
                transcriptionProviderManager: AppState.shared.transcriptionProviderManager
            )
            .windowIdentifier(WindowIdentifiers.onboarding)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(width: 1100, height: 724)
        .commandsRemoved()
    }
}

private struct LegacyAppScenes: Scene {
    var body: some Scene {
        let _ = { WindowBridge.openWindow = { id in WindowBridge.openLegacyWindow(id: id) } }()

        WindowGroup(AppNaming.displayName) {
            SettingsWindowView()
                .windowIdentifier(WindowIdentifiers.main)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("AIDictation Settings") {
                    showMainSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdateManager.shared.checkForUpdates()
                }
            }
        }
    }
}
