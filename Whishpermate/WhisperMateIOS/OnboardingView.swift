import AVFoundation
import SwiftUI
import WhisperMateShared

struct OnboardingView: View {
    @ObservedObject var onboardingManager: OnboardingManager
    @State private var currentStep: OnboardingStep = OnboardingStep.initialStep
    @State private var isCheckingMicrophone = false
    @State private var refreshTrigger = false

    enum OnboardingStep {
        case welcome
        case microphone
        case keyboardSetup

        static var initialStep: OnboardingStep {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-AIDictationShowKeyboardOnboarding") {
                    return .keyboardSetup
                }
            #endif
            return .welcome
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomButton
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .navigationTitle("AI Dictation Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .tint(Color.dsPrimary)
        .onAppear {
            if KeychainHelper.get(key: "custom_transcription_api_key") == nil,
               let apiKey = SecretsLoader.transcriptionKey(for: .custom)
            {
                KeychainHelper.save(key: "custom_transcription_api_key", value: apiKey)
            }

            if currentStep == .microphone {
                startMicrophoneCheck()
            }
        }
        .onChange(of: currentStep) { newStep in
            if newStep == .microphone {
                startMicrophoneCheck()
            } else {
                stopMicrophoneCheck()
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .microphone:
            microphoneStep
        case .keyboardSetup:
            keyboardSetupStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)

            OnboardingHeroIcon(systemName: "waveform", iconSize: 44)

            VStack(spacing: 8) {
                Text("Welcome to AI Dictation")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("Voice-to-text keyboard for iOS")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                FeatureRow(icon: "mic.fill", text: "Speak naturally")
                FeatureRow(icon: "bolt.fill", text: "Fast transcription")
                FeatureRow(icon: "lock.fill", text: "Secure and private")
            }
            .padding(.top, 8)

            Spacer(minLength: 20)
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)

            OnboardingHeroIcon(systemName: "mic.fill", iconSize: 40)

            VStack(spacing: 10) {
                Text("Microphone Access")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("AI Dictation needs microphone access to transcribe your voice.")
                    .font(.system(size: 16))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }

            if isMicrophoneGranted() {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Permission granted")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.green)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(
                    Capsule()
                        .fill(Color.green.opacity(0.12))
                )
                .padding(.top, 8)
            } else if isMicrophoneDenied() {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Turn it back on in Settings")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.12))
                )
                .padding(.top, 8)
            }

            Spacer(minLength: 20)
        }
    }

    private var keyboardSetupStep: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)

            OnboardingHeroIcon(systemName: "keyboard", iconSize: 38)

            VStack(spacing: 8) {
                Text("Enable the Keyboard")
                    .font(.system(size: 27, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("Add AI Dictation in Settings, then allow full access for voice input.")
                    .font(.system(size: 15))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                InstructionRow(number: 1, text: "Open Settings > General > Keyboard")
                InstructionRow(number: 2, text: "Tap Keyboards, then Add New Keyboard")
                InstructionRow(number: 3, text: "Choose AI Dictation")
                InstructionRow(number: 4, text: "Turn on Allow Full Access")
            }
            .padding(.top, 2)

            Button(action: openKeyboardSettings) {
                Label("Open Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.dsPrimary)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(
                        Capsule()
                            .fill(Color(uiColor: .systemBackground))
                            .shadow(color: Color.black.opacity(0.06), radius: 10, y: 4)
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.dsPrimary.opacity(0.28), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)
        }
    }

    @ViewBuilder
    private var bottomButton: some View {
        switch currentStep {
        case .welcome:
            Button(action: { currentStep = .microphone }) {
                PrimaryOnboardingButtonTitle("Continue")
            }
        case .microphone:
            Button(action: {
                if isMicrophoneGranted() {
                    currentStep = .keyboardSetup
                } else if isMicrophoneDenied() {
                    openKeyboardSettings()
                } else {
                    requestMicrophonePermission()
                }
            }) {
                PrimaryOnboardingButtonTitle(microphoneButtonTitle)
            }
        case .keyboardSetup:
            Button(action: { onboardingManager.completeOnboarding() }) {
                PrimaryOnboardingButtonTitle("Get Started")
            }
        }
    }

    private func isMicrophoneGranted() -> Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    private func isMicrophoneDenied() -> Bool {
        AVAudioSession.sharedInstance().recordPermission == .denied
    }

    private var microphoneButtonTitle: String {
        if isMicrophoneGranted() {
            return "Continue"
        }

        if isMicrophoneDenied() {
            return "Open Settings"
        }

        return "Enable Microphone"
    }

    private func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { _ in
            // Permission dialog appears; polling detects the change.
        }
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

        if isMicrophoneGranted() {
            isCheckingMicrophone = false
            currentStep = .keyboardSetup
            return
        }

        refreshTrigger.toggle()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.checkMicrophonePeriodically()
        }
    }

    private func openKeyboardSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private struct OnboardingHeroIcon: View {
    let systemName: String
    let iconSize: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.dsPrimary.opacity(0.18),
                            Color.dsPrimary.opacity(0.07),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.dsPrimary.opacity(0.22), lineWidth: 1)
                )

            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(Color.dsPrimary)
        }
        .frame(width: 94, height: 94)
    }
}

private struct PrimaryOnboardingButtonTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                Capsule()
                    .fill(Color.dsPrimary)
                    .shadow(color: Color.dsPrimary.opacity(0.25), radius: 12, y: 6)
            )
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color.dsPrimary)
                .frame(width: 26)

            Text(text)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.primary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 260)
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.dsPrimary)
                )

            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: Color.black.opacity(0.055), radius: 12, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}
