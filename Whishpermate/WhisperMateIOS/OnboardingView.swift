import AVFoundation
import SwiftUI
import WhisperMateShared

struct OnboardingView: View {
    @ObservedObject var onboardingManager: OnboardingManager
    @StateObject private var languageManager = LanguageManager()
    @State private var currentStep: OnboardingStep = .welcome
    @State private var isCheckingMicrophone = false
    @State private var refreshTrigger = false

    enum OnboardingStep {
        case welcome
        case microphone
        case language
        case keyboardSetup
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Spacer()

                switch currentStep {
                case .welcome:
                    welcomeStep
                case .microphone:
                    microphoneStep
                case .language:
                    languageStep
                case .keyboardSetup:
                    keyboardSetupStep
                }

                Spacer()

                // Bottom button
                bottomButton
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
            }
            .padding()
            .navigationTitle("WhisperMate Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // Load API key from Secrets.plist into keychain on first launch
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

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .frame(width: 100, height: 100)
                .foregroundColor(.blue)

            Text("Welcome to WhisperMate")
                .font(.title)
                .fontWeight(.bold)

            Text("Voice-to-text keyboard for iOS")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "mic.fill", text: "Speak naturally")
                FeatureRow(icon: "bolt.fill", text: "Fast transcription")
                FeatureRow(icon: "lock.fill", text: "Secure & private")
            }
            .frame(maxWidth: 250)
            .padding()
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(.blue)

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.bold)

            Text("WhisperMate needs microphone access to transcribe your voice.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            if isMicrophoneGranted() {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)

                    Text("Permission granted")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.green)
                }
                .padding(.vertical, 20)
            }
        }
    }

    private var languageStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(.blue)

            Text("Select Languages")
                .font(.title2)
                .fontWeight(.bold)

            Text("Choose the languages you'll be speaking. You can change this later in Settings.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Language.allCases) { language in
                        Button(action: {
                            languageManager.toggleLanguage(language)
                        }) {
                            HStack {
                                Text(language.flag)
                                    .font(.title3)
                                Text(language.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if languageManager.isSelected(language) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(languageManager.isSelected(language) ? Color.blue.opacity(0.1) : Color(uiColor: .secondarySystemGroupedBackground))
                            )
                        }
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxHeight: 300)
        }
    }

    private var keyboardSetupStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundColor(.blue)

            Text("Enable Keyboard")
                .font(.title2)
                .fontWeight(.bold)

            Text("To use WhisperMate, you need to enable the keyboard in Settings.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 16) {
                InstructionRow(number: 1, text: "Go to Settings > General > Keyboard > Keyboards")
                InstructionRow(number: 2, text: "Tap 'Add New Keyboard'")
                InstructionRow(number: 3, text: "Select 'WhisperMate'")
                InstructionRow(number: 4, text: "Enable 'Allow Full Access' for voice features")
            }
            .padding()

            Button("Open Settings") {
                openKeyboardSettings()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Bottom Button

    @ViewBuilder
    private var bottomButton: some View {
        switch currentStep {
        case .welcome:
            Button(action: {
                currentStep = .microphone
            }) {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Capsule()
                            .fill(Color.blue)
                    )
            }

        case .microphone:
            Button(action: {
                if isMicrophoneGranted() {
                    currentStep = .language
                } else {
                    requestMicrophonePermission()
                }
            }) {
                Text(isMicrophoneGranted() ? "Continue" : "Enable Microphone")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Capsule()
                            .fill(Color.blue)
                    )
            }

        case .language:
            Button(action: {
                currentStep = .keyboardSetup
            }) {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Capsule()
                            .fill(Color.blue)
                    )
            }

        case .keyboardSetup:
            Button(action: {
                onboardingManager.completeOnboarding()
            }) {
                Text("Get Started")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Capsule()
                            .fill(Color.blue)
                    )
            }
        }
    }

    // MARK: - Helpers

    private func isMicrophoneGranted() -> Bool {
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    private func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { _ in
            // Permission dialog will appear, polling will detect the change
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

        // Check if permission was granted
        if isMicrophoneGranted() {
            // Auto-advance to next step
            isCheckingMicrophone = false
            currentStep = .language
            return
        }

        // Toggle state to trigger view refresh
        refreshTrigger.toggle()

        // Check again in 0.5 seconds
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

// MARK: - Supporting Views

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24, height: 24)
            Text(text)
                .foregroundColor(.primary)
        }
    }
}

struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Color.blue)
                .clipShape(Circle())
            Text(text)
                .foregroundColor(.primary)
            Spacer()
        }
    }
}
