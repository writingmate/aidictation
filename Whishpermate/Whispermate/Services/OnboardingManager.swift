import Foundation
internal import Combine
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import WhisperMateShared

enum OnboardingStep: Int, CaseIterable {
    case microphone = 0
    case accessibility = 1
    case language = 2
    case hotkey = 3

    var title: String {
        switch self {
        case .microphone: return "Enable Microphone"
        case .accessibility: return "Enable Accessibility"
        case .language: return "Select Your Languages"
        case .hotkey: return "Set Your Hotkey"
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic.circle.fill"
        case .accessibility: return "hand.tap.fill"
        case .language: return "globe"
        case .hotkey: return "keyboard.fill"
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            return "AIDictation needs access to your microphone to record your voice for transcription."
        case .accessibility:
            return "AIDictation needs accessibility permissions to automatically paste transcriptions into your apps."
        case .language:
            return "Select the languages you speak. You can choose multiple languages or use auto-detect."
        case .hotkey:
            return "Choose your preferred hotkey to control recording. Press and hold to record, or double-tap to start/stop long recording."
        }
    }

    var isOptional: Bool {
        return false
    }
}

/// Manages the onboarding flow and permission states
class OnboardingManager: ObservableObject {
    static let shared = OnboardingManager()

    // MARK: - Published Properties

    @Published var showOnboarding: Bool = false
    @Published var currentStep: OnboardingStep = .microphone {
        didSet {
            // Persist the current step so we can resume after app restart
            AppDefaults.shared.set(currentStep.rawValue, forKey: Keys.currentOnboardingStep)
        }
    }

    @Published var accessibilityGranted: Bool = false
    @Published var microphoneGranted: Bool = false
    @Published var microphoneDenied: Bool = false

    // MARK: - Private Properties

    private enum Keys {
        static let onboardingCompleted = "has_completed_onboarding"
        static let currentOnboardingStep = "current_onboarding_step"
        static let hotkeyKeycode = "hotkey_keycode"
        static let hotkeyModifiers = "hotkey_modifiers"
    }

    // MARK: - Initialization

    private init() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Public API

    func updateAccessibilityStatus() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func updateMicrophoneStatus() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func checkOnboardingStatus() {
        DebugLog.info("Checking onboarding status", context: "OnboardingManager")

        // Check if user has completed onboarding before
        let hasCompleted = AppDefaults.shared.bool(forKey: Keys.onboardingCompleted)

        if !hasCompleted {
            // Onboarding not completed - show it
            DebugLog.info("Onboarding not completed - showing onboarding", context: "OnboardingManager")
            showOnboarding = true

            // Restore the saved step, or find the first incomplete step
            if let savedStepRaw = AppDefaults.shared.value(forKey: Keys.currentOnboardingStep) as? Int,
               let savedStep = OnboardingStep(rawValue: savedStepRaw)
            {
                // Resume from saved step, but verify previous steps are still complete
                currentStep = findFirstIncompleteStepUpTo(savedStep)
                DebugLog.info("Resuming onboarding at step: \(currentStep)", context: "OnboardingManager")
            } else {
                currentStep = .microphone
                DebugLog.info("Starting onboarding from beginning", context: "OnboardingManager")
            }
        } else {
            // User has completed onboarding before
            // Check if all permissions are still granted
            let allGranted = checkAllPermissions()
            showOnboarding = !allGranted

            if !allGranted {
                DebugLog.info("Permissions revoked, showing onboarding again", context: "OnboardingManager")
                // Find first non-granted permission
                currentStep = findFirstIncompleteStep()
            } else {
                DebugLog.info("All permissions granted, skipping onboarding", context: "OnboardingManager")
            }
        }
    }

    /// Find the first incomplete step, but don't go past maxStep
    private func findFirstIncompleteStepUpTo(_ maxStep: OnboardingStep) -> OnboardingStep {
        for step in OnboardingStep.allCases {
            if !isStepComplete(step) {
                return step
            }
            if step == maxStep {
                return maxStep
            }
        }
        return maxStep
    }

    func checkAllPermissions() -> Bool {
        return isMicrophoneGranted() && isAccessibilityGranted() && isHotkeyConfigured()
    }

    func isMicrophoneGranted() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func isAccessibilityGranted() -> Bool {
        return AXIsProcessTrusted()
    }

    func isHotkeyConfigured() -> Bool {
        // Check the same keys that HotkeyManager uses
        return AppDefaults.shared.value(forKey: Keys.hotkeyKeycode) != nil &&
            AppDefaults.shared.value(forKey: Keys.hotkeyModifiers) != nil
    }

    func isStepComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .microphone: return isMicrophoneGranted()
        case .accessibility: return isAccessibilityGranted()
        case .language: return true // Always allow continuing from language step
        case .hotkey: return isHotkeyConfigured()
        }
    }

    func findFirstIncompleteStep() -> OnboardingStep {
        for step in OnboardingStep.allCases {
            if !isStepComplete(step) {
                return step
            }
        }
        return .microphone // Default fallback
    }

    func moveToNextStep() {
        DebugLog.info("Moving to next step from \(currentStep)", context: "OnboardingManager")

        let allSteps = OnboardingStep.allCases
        guard let currentIndex = allSteps.firstIndex(of: currentStep) else { return }

        // Move to the next step in sequence
        let nextIndex = currentIndex + 1
        if nextIndex < allSteps.count {
            currentStep = allSteps[nextIndex]
            DebugLog.info("Moving to next step: \(currentStep)", context: "OnboardingManager")
        } else {
            // All steps complete!
            completeOnboarding()
        }
    }

    func completeOnboarding() {
        DebugLog.info("✅ Onboarding complete!", context: "OnboardingManager")
        AppDefaults.shared.set(true, forKey: Keys.onboardingCompleted)
        AppDefaults.shared.removeObject(forKey: Keys.currentOnboardingStep)
        showOnboarding = false

        // Post notification to close onboarding window and show main window
        NotificationCenter.default.post(name: .onboardingComplete, object: nil)
    }

    func requestMicrophonePermission() {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch currentStatus {
        case .notDetermined:
            // First time - show system dialog
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    DebugLog.info("Microphone permission: \(granted)", context: "OnboardingManager")
                    if granted {
                        OverlayWindowManager.shared.initializeAudioObservers()
                        self?.moveToNextStep()
                    } else {
                        self?.microphoneDenied = true
                    }
                }
            }
        case .denied, .restricted:
            // Already denied - open System Settings
            DebugLog.info("Microphone already denied, opening System Settings", context: "OnboardingManager")
            microphoneDenied = true
            openMicrophoneSettings()
        case .authorized:
            // Already granted
            OverlayWindowManager.shared.initializeAudioObservers()
            moveToNextStep()
        @unknown default:
            break
        }
    }

    func openMicrophoneSettings() {
        PrivacyPermissionFlowManager.shared.open(.microphone)
    }

    func requestAccessibilityPermission() {
        DebugLog.info("Triggering accessibility permission request", context: "OnboardingManager")
        PrivacyPermissionFlowManager.shared.open(
            .accessibility,
            permissionGranted: { AXIsProcessTrusted() }
        )
        DebugLog.info("Permission dialog triggered", context: "OnboardingManager")
    }

    func reopenOnboarding() {
        DebugLog.info("Reopening onboarding", context: "OnboardingManager")
        currentStep = .microphone
        showOnboarding = true
    }

    func resetOnboarding() {
        DebugLog.info("Resetting onboarding status", context: "OnboardingManager")
        AppDefaults.shared.removeObject(forKey: Keys.onboardingCompleted)
        AppDefaults.shared.removeObject(forKey: Keys.currentOnboardingStep)
        currentStep = .microphone
        showOnboarding = true
    }
}
