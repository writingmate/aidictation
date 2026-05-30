import Combine
import AVFoundation
import SwiftUI
import UIKit
import WhisperMateShared

@main
struct WhisperMateApp: App {
    @StateObject private var onboardingManager = OnboardingManager()
    @State private var showKeyboardAudioSetup = false

    init() {}

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingManager.hasCompletedOnboarding {
                    ContentView()
                } else {
                    OnboardingView(onboardingManager: onboardingManager)
                }
            }
            .onOpenURL { url in
                if handleAppURL(url) {
                    return
                }

                Task {
                    await AuthManager.shared.handleAuthCallback(url: url)
                }
            }
            .sheet(isPresented: $showKeyboardAudioSetup) {
                OnboardingView(
                    onboardingManager: onboardingManager,
                    initialStep: AVAudioSession.sharedInstance().recordPermission == .granted ? .keyboardSetup : .microphone
                )
            }
        }
    }

    private func handleAppURL(_ url: URL) -> Bool {
        guard url.scheme == "aidictation" else {
            return false
        }

        if url.host == "keyboard-dictation" {
            let sessionID = KeyboardDictationHandoff.sessionID(from: url)
            KeyboardDictationHandoff.publish(command: .start, sessionID: sessionID)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: KeyboardDictationHandoff.openAppNotification,
                    object: sessionID
                )
            }
            return true
        }

        if url.host == "keyboard-dictation-stop" {
            let sessionID = KeyboardDictationHandoff.sessionID(from: url)
            KeyboardDictationHandoff.publish(command: .stop, sessionID: sessionID)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: KeyboardDictationHandoff.stopAppNotification,
                    object: sessionID
                )
            }
            return true
        }

        guard url.host == "microphone-settings" || url.host == "keyboard-audio-access" else {
            return false
        }

        DispatchQueue.main.async {
            showKeyboardAudioSetup = true
        }

        return true
    }
}

// MARK: - Onboarding Manager

class OnboardingManager: ObservableObject {
    @Published var hasCompletedOnboarding: Bool

    private let onboardingKey = "has_completed_onboarding"

    init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: onboardingKey)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: onboardingKey)
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: onboardingKey)
    }
}
