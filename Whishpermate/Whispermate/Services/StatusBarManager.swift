import AppKit
import SwiftUI
import WhisperMateShared

// MARK: - Window Identifiers

enum WindowIdentifiers {
    static let main = NSUserInterfaceItemIdentifier("main")
    static let settings = NSUserInterfaceItemIdentifier("settings")
    static let history = NSUserInterfaceItemIdentifier("history")
    static let onboarding = NSUserInterfaceItemIdentifier("onboarding")
}

/// Finds the main settings window reliably across all lifecycle states
func findMainWindow() -> NSWindow? {
    // 1. Try by identifier (most reliable when set)
    if let window = NSApplication.shared.windows.first(where: { $0.identifier == WindowIdentifiers.main }) {
        DebugLog.info("findMainWindow: found by identifier", context: "WindowManagement")
        return window
    }
    // 2. Try via AppDelegate's cached strong reference
    if let appDelegate = NSApp.delegate as? AppDelegate, let window = appDelegate.mainWindow {
        DebugLog.info("findMainWindow: found via AppDelegate.mainWindow", context: "WindowManagement")
        return window
    }
    // 3. Try by title while SwiftUI is still attaching the identifier
    if let window = NSApplication.shared.windows.first(where: { $0.level == .normal && $0.title == "AIDictation" }) {
        DebugLog.info("findMainWindow: found by title", context: "WindowManagement")
        return window
    }
    // 4. Fallback: .normal level window excluding known non-main windows
    let fallback = NSApplication.shared.windows.first(where: {
        $0.level == .normal
            && $0.identifier != WindowIdentifiers.history
            && $0.identifier != WindowIdentifiers.onboarding
            && $0.title != "History"
            && !$0.title.hasPrefix("Welcome")
            && ($0.title.isEmpty || $0.title == "AIDictation")
    })
    if fallback != nil {
        DebugLog.info("findMainWindow: found by .normal level fallback", context: "WindowManagement")
    }
    return fallback
}

// MARK: - Notification Names

extension NSNotification.Name {
    static let showHistory = NSNotification.Name("ShowHistory")
    static let showSettings = NSNotification.Name("ShowSettings")
    static let showOnboarding = NSNotification.Name("ShowOnboarding")
    static let onboardingComplete = NSNotification.Name("OnboardingComplete")
    static let recordingStarted = NSNotification.Name("RecordingStarted")
    static let recordingCompleted = NSNotification.Name("RecordingCompleted")
    static let recordingReadyForTranscription = NSNotification.Name("RecordingReadyForTranscription")
    static let openAccountSettings = NSNotification.Name("OpenAccountSettings")
    static let menuBarIconVisibilityRequested = NSNotification.Name("MenuBarIconVisibilityRequested")
    static let menuBarIconVisibilityChanged = NSNotification.Name("MenuBarIconVisibilityChanged")
}

// MARK: - StatusBarManager

/// Manages the macOS menu bar icon and dropdown menu
class StatusBarManager: NSObject, NSMenuDelegate {
    // MARK: - Properties

    weak var appWindow: NSWindow?

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    private enum Keys {
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    static var isMenuBarIconVisible: Bool {
        get { AppDefaults.shared.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true }
        set { AppDefaults.shared.set(newValue, forKey: Keys.showMenuBarIcon) }
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMenuBarIconVisibilityRequest(_:)),
            name: .menuBarIconVisibilityRequested,
            object: nil
        )
    }

    // MARK: - Public API

    static func requestMenuBarIconVisibility(_ visible: Bool) {
        isMenuBarIconVisible = visible
        NotificationCenter.default.post(name: .menuBarIconVisibilityRequested, object: visible)
    }

    func setupMenuBar() {
        guard Self.isMenuBarIconVisible else {
            removeMenuBarIcon()
            return
        }

        guard statusItem == nil else {
            return
        }

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else {
            DebugLog.info("Failed to create status bar button", context: "StatusBarManager")
            return
        }

        // Use menu bar template icon
        if let menuBarIcon = NSImage(named: "MenuBarIcon") {
            menuBarIcon.isTemplate = true
            menuBarIcon.size = NSSize(width: 18, height: 18)
            button.image = menuBarIcon
        } else {
            // Fallback to SF Symbol
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "AIDictation")?.withSymbolConfiguration(config)
        }

        // Create menu
        menu = NSMenu()
        menu?.delegate = self

        // Show/Hide Window
        let showHideItem = NSMenuItem(
            title: "Show AIDictation",
            action: #selector(toggleWindow),
            keyEquivalent: ""
        )
        showHideItem.target = self
        menu?.addItem(showHideItem)

        menu?.addItem(NSMenuItem.separator())

        addMicrophoneMenu()
        addTranscriptionModeMenu()

        menu?.addItem(NSMenuItem.separator())

        // History
        let historyItem = NSMenuItem(
            title: "History",
            action: #selector(showHistory),
            keyEquivalent: "h"
        )
        historyItem.target = self
        menu?.addItem(historyItem)

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu?.addItem(settingsItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updatesItem.target = self
        menu?.addItem(updatesItem)

        menu?.addItem(NSMenuItem.separator())

        let hideMenuBarItem = NSMenuItem(
            title: "Hide Menu Bar Icon",
            action: #selector(hideMenuBarIcon),
            keyEquivalent: ""
        )
        hideMenuBarItem.target = self
        menu?.addItem(hideMenuBarItem)

        menu?.addItem(NSMenuItem.separator())

        // Onboarding
        let onboardingItem = NSMenuItem(
            title: "Show Onboarding",
            action: #selector(showOnboarding),
            keyEquivalent: ""
        )
        onboardingItem.target = self
        menu?.addItem(onboardingItem)

        menu?.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit AIDictation",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu?.addItem(quitItem)

        statusItem?.menu = menu

        DebugLog.info("Menu bar icon created successfully", context: "StatusBarManager")
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setMenuBarIconVisible(visible)
            }
            return
        }

        guard Self.isMenuBarIconVisible != visible || (visible && statusItem == nil) || (!visible && statusItem != nil) else {
            NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: visible)
            return
        }

        Self.isMenuBarIconVisible = visible

        if visible {
            setupMenuBar()
        } else {
            removeMenuBarIcon()
        }

        NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: visible)
    }

    func menuWillOpen(_: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Private Methods

    private func rebuildMenu() {
        menu?.removeAllItems()

        let showHideItem = NSMenuItem(
            title: "Show AIDictation",
            action: #selector(toggleWindow),
            keyEquivalent: ""
        )
        showHideItem.target = self
        menu?.addItem(showHideItem)

        menu?.addItem(NSMenuItem.separator())
        addMicrophoneMenu()
        addTranscriptionModeMenu()

        menu?.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem(title: "History", action: #selector(showHistory), keyEquivalent: "h")
        historyItem.target = self
        menu?.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu?.addItem(settingsItem)

        let updatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu?.addItem(updatesItem)

        menu?.addItem(NSMenuItem.separator())

        let hideMenuBarItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideMenuBarIcon), keyEquivalent: "")
        hideMenuBarItem.target = self
        menu?.addItem(hideMenuBarItem)

        menu?.addItem(NSMenuItem.separator())

        let onboardingItem = NSMenuItem(title: "Show Onboarding", action: #selector(showOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu?.addItem(onboardingItem)

        menu?.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit AIDictation", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu?.addItem(quitItem)
    }

    @objc private func handleMenuBarIconVisibilityRequest(_ notification: Notification) {
        guard let visible = notification.object as? Bool else {
            return
        }

        setMenuBarIconVisible(visible)
    }

    private func addMicrophoneMenu() {
        let manager = AudioDeviceManager.shared
        manager.refreshDevices()

        let parent = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let autoItem = NSMenuItem(title: "Auto Select", action: #selector(selectAutomaticMicrophone), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = manager.automaticallySelectDevice ? .on : .off
        submenu.addItem(autoItem)

        submenu.addItem(NSMenuItem.separator())

        for device in manager.inputDevices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = (!manager.automaticallySelectDevice && manager.selectedDevice?.uniqueID == device.uniqueID) ? .on : .off
            submenu.addItem(item)
        }

        if manager.inputDevices.isEmpty {
            let emptyItem = NSMenuItem(title: "No Input Devices", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        }

        parent.submenu = submenu
        menu?.addItem(parent)
    }

    private func addTranscriptionModeMenu() {
        let providerManager = AppState.shared.transcriptionProviderManager
        let parent = NSMenuItem(title: "Transcription Mode", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for mode in TranscriptionMode.availableCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectTranscriptionMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = providerManager.transcriptionMode == mode ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        menu?.addItem(parent)
    }

    @objc private func selectAutomaticMicrophone() {
        AudioDeviceManager.shared.setAutomaticSelection(true)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let uniqueID = sender.representedObject as? String else { return }
        let manager = AudioDeviceManager.shared
        manager.refreshDevices()
        guard let device = manager.inputDevices.first(where: { $0.uniqueID == uniqueID }) else { return }
        _ = manager.selectDevice(device)
    }

    @objc private func selectTranscriptionMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = TranscriptionMode(rawValue: rawValue)
        else { return }

        _ = AppState.shared.transcriptionProviderManager.requestTranscriptionMode(mode)
    }

    @objc private func toggleWindow() {
        // Don't show settings while onboarding is active
        if OnboardingManager.shared.showOnboarding {
            return
        }

        // Use stored window reference if available, otherwise find by identifier
        let window = appWindow ?? findMainWindow()

        if let window = window {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            showMainSettingsWindow()
        }
    }

    @objc private func showHistory() {
        showHistoryWindow()
    }

    @objc private func showSettings() {
        showMainSettingsWindow()
    }

    @objc private func checkForUpdates() {
        Task { @MainActor in
            UpdateManager.shared.checkForUpdates()
        }
    }

    @objc private func hideMenuBarIcon() {
        Self.requestMenuBarIconVisibility(false)
    }

    @objc private func showOnboarding() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .showOnboarding, object: nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func removeMenuBarIcon() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        menu = nil
        DebugLog.info("Menu bar icon removed", context: "StatusBarManager")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removeMenuBarIcon()
    }
}
