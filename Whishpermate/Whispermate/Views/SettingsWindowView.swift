import SwiftUI
import WhisperMateShared

struct SettingsWindowView: View {
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared
    @ObservedObject private var transcriptionProviderManager = TranscriptionProviderManager.shared
    @ObservedObject private var llmProviderManager = LLMProviderManager.shared
    @ObservedObject private var dictionaryManager = DictionaryManager.shared
    @ObservedObject private var contextRulesManager = ContextRulesManager.shared
    @ObservedObject private var shortcutManager = ShortcutManager.shared
    @ObservedObject private var onboardingManager = OnboardingManager.shared
    @State private var selectedSection: SettingsSection = .general
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SettingsView(
            hotkeyManager: hotkeyManager,
            languageManager: languageManager,
            transcriptionProviderManager: transcriptionProviderManager,
            llmProviderManager: llmProviderManager,
            dictionaryManager: dictionaryManager,
            contextRulesManager: contextRulesManager,
            shortcutManager: shortcutManager,
            selectedSection: $selectedSection
        )
        .navigationTitle(selectedSection.rawValue)
        .onReceive(NotificationCenter.default.publisher(for: .showMeetingNotes)) { _ in
            selectedSection = .notes
        }
        .onReceive(NotificationCenter.default.publisher(for: .showMeetingSettings)) { _ in
            selectedSection = .meetingSettings
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            // Close existing onboarding window if open
            if let window = NSApplication.shared.windows.first(where: { $0.identifier == WindowIdentifiers.onboarding }) {
                window.close()
            }
            // Reset onboarding state and open fresh onboarding window
            onboardingManager.resetOnboarding()
            WindowBridge.openWindow?("onboarding")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAccountSettings)) { _ in
            // Navigate to Account section and show window
            selectedSection = .account
            showMainSettingsWindow()
        }
    }
}
