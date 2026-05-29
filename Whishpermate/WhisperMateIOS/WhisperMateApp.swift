import Combine
import SwiftUI
import UIKit
import WhisperMateShared

@main
struct WhisperMateApp: App {
    @StateObject private var onboardingManager = OnboardingManager()

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
        }
    }

    private func handleAppURL(_ url: URL) -> Bool {
        guard url.scheme == "aidictation" else {
            return false
        }

        guard url.host == "microphone-settings" else {
            return false
        }

        DispatchQueue.main.async {
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            UIApplication.shared.open(settingsURL)
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
