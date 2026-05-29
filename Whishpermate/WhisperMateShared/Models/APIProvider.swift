import Foundation
public import Combine

// MARK: - Transcription Provider

public enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case onDevice
    case groq
    case openai
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: return "Offline Mode"
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .custom: return "Custom"
        }
    }

    public var description: String {
        switch self {
        case .onDevice: return "Private, works without internet"
        case .groq: return "Whisper Large V3"
        case .openai: return "Whisper API"
        case .custom: return "Enhanced Whisper + LLM"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .onDevice: return ""
        case .groq: return "https://api.groq.com/openai/v1/audio/transcriptions"
        case .openai: return "https://api.openai.com/v1/audio/transcriptions"
        case .custom: return "https://writingmate.ai/api/openai/v1/audio/transcriptions"
        }
    }

    public var defaultModel: String {
        switch self {
        case .onDevice: return "apple-on-device"
        case .groq: return "whisper-large-v3-turbo"
        case .openai: return "whisper-1"
        case .custom: return "groq/whisper-large-v3-turbo"
        }
    }

    public var apiKeyName: String {
        return "\(rawValue)_transcription_api_key"
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .groq, .openai:
            return true
        case .onDevice, .custom:
            return false
        }
    }

    public var isOnDevice: Bool {
        self == .onDevice
    }

    public static var availableProviders: [TranscriptionProvider] {
        allCases.filter { provider in
            provider != .onDevice || SharedParakeetTranscriptionService.isRuntimeSupported
        }
    }
}

public enum TranscriptionMode: String, CaseIterable, Identifiable {
    case cloud
    case offline
    case automatic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloud: return "Cloud Mode"
        case .offline: return "Offline Mode"
        case .automatic: return "Automatic"
        }
    }

    public var description: String {
        switch self {
        case .cloud: return "Sends recordings to the cloud for transcription."
        case .offline: return "Transcribes on this device without sending audio out."
        case .automatic: return "Uses cloud mode when available and offline mode when needed."
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .cloud:
            return true
        case .offline, .automatic:
            return SharedParakeetTranscriptionService.isRuntimeSupported
        }
    }

    public static var availableCases: [TranscriptionMode] {
        allCases.filter(\.isAvailable)
    }
}

public class TranscriptionProviderManager: ObservableObject {
    @Published public var selectedProvider: TranscriptionProvider = .custom
    @Published public var transcriptionMode: TranscriptionMode = .cloud
    @Published public var customEndpoint: String = ""
    @Published public var customModel: String = ""

    private let providerKey = "selected_transcription_provider"
    private let modeKey = "selected_transcription_mode"
    private let endpointKey = "transcription_custom_endpoint"
    private let modelKey = "transcription_custom_model"

    public init() {
        loadSettings()
    }

    public func loadSettings() {
        if let savedProvider = AppDefaults.shared.string(forKey: providerKey),
           let provider = TranscriptionProvider(rawValue: savedProvider)
        {
            selectedProvider = provider
        } else {
            // Default to custom provider if no saved preference
            selectedProvider = .custom
        }

        if let savedMode = AppDefaults.shared.string(forKey: modeKey),
           let mode = TranscriptionMode(rawValue: savedMode),
           mode.isAvailable
        {
            transcriptionMode = mode
        } else if selectedProvider == .onDevice, TranscriptionMode.offline.isAvailable {
            transcriptionMode = .offline
        } else {
            transcriptionMode = .cloud
        }

        if selectedProvider == .onDevice && !SharedParakeetTranscriptionService.isRuntimeSupported {
            selectedProvider = .custom
            AppDefaults.shared.set(selectedProvider.rawValue, forKey: providerKey)
            transcriptionMode = .cloud
            AppDefaults.shared.set(transcriptionMode.rawValue, forKey: modeKey)
        }

        customEndpoint = AppDefaults.shared.string(forKey: endpointKey) ?? ""
        customModel = AppDefaults.shared.string(forKey: modelKey) ?? ""
        DebugLog.info("Loaded: \(selectedProvider.displayName)", context: "TranscriptionProviderManager")
    }

    public func setProvider(_ provider: TranscriptionProvider) {
        guard provider != .onDevice || SharedParakeetTranscriptionService.isRuntimeSupported else {
            setTranscriptionMode(.cloud)
            return
        }

        selectedProvider = provider
        AppDefaults.shared.set(provider.rawValue, forKey: providerKey)
        transcriptionMode = provider == .onDevice ? .offline : .cloud
        AppDefaults.shared.set(transcriptionMode.rawValue, forKey: modeKey)
        DebugLog.info("Set provider: \(provider.displayName)", context: "TranscriptionProviderManager")
    }

    public func setTranscriptionMode(_ mode: TranscriptionMode) {
        guard mode.isAvailable else {
            transcriptionMode = .cloud
            selectedProvider = .custom
            AppDefaults.shared.set(transcriptionMode.rawValue, forKey: modeKey)
            AppDefaults.shared.set(selectedProvider.rawValue, forKey: providerKey)
            return
        }

        transcriptionMode = mode
        AppDefaults.shared.set(mode.rawValue, forKey: modeKey)

        switch mode {
        case .offline:
            selectedProvider = .onDevice
        case .cloud, .automatic:
            if selectedProvider == .onDevice {
                selectedProvider = .custom
            }
        }
        AppDefaults.shared.set(selectedProvider.rawValue, forKey: providerKey)
    }

    public var shouldUseOnDeviceTranscription: Bool {
        switch transcriptionMode {
        case .offline:
            return SharedParakeetTranscriptionService.isRuntimeSupported
        case .automatic:
            return SharedParakeetTranscriptionService.isRuntimeSupported && !hasCloudCredentials
        case .cloud:
            return false
        }
    }

    public func saveCustomSettings(endpoint: String, model: String) {
        customEndpoint = endpoint
        customModel = model
        AppDefaults.shared.set(endpoint, forKey: endpointKey)
        AppDefaults.shared.set(model, forKey: modelKey)
    }

    public var effectiveEndpoint: String {
        if selectedProvider == .onDevice {
            return ""
        }

        // For custom provider, check Secrets.plist first
        if selectedProvider == .custom {
            if let secretEndpoint = SecretsLoader.customTranscriptionEndpoint(), !secretEndpoint.isEmpty {
                return secretEndpoint
            }
        }

        if !customEndpoint.isEmpty {
            return customEndpoint
        }
        return selectedProvider.defaultEndpoint
    }

    public var effectiveModel: String {
        if selectedProvider == .onDevice {
            return selectedProvider.defaultModel
        }

        // For custom provider, check Secrets.plist first
        if selectedProvider == .custom {
            if let secretModel = SecretsLoader.customTranscriptionModel(), !secretModel.isEmpty {
                return secretModel
            }
        }

        if !customModel.isEmpty {
            return customModel
        }
        return selectedProvider.defaultModel
    }

    private var hasCloudCredentials: Bool {
        let cloudProvider = selectedProvider == .onDevice ? TranscriptionProvider.custom : selectedProvider
        return KeychainHelper.get(key: cloudProvider.apiKeyName) != nil || SecretsLoader.transcriptionKey(for: cloudProvider) != nil
    }
}

// MARK: - LLM Provider

public enum LLMProvider: String, CaseIterable, Identifiable {
    case groq
    case openai
    case anthropic
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .custom: return "Custom"
        }
    }

    public var description: String {
        switch self {
        case .groq: return "Fast LLM (GPT-OSS-20B)"
        case .openai: return "GPT-4o"
        case .anthropic: return "Claude"
        case .custom: return "OpenAI-compatible API"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1/chat/completions"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .custom: return ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .groq: return "openai/gpt-oss-120b"
        case .openai: return "gpt-4o"
        case .anthropic: return "claude-3-5-sonnet-20241022"
        case .custom: return ""
        }
    }

    public var apiKeyName: String {
        return "\(rawValue)_llm_api_key"
    }
}

public class LLMProviderManager: ObservableObject {
    @Published var selectedProvider: LLMProvider = .groq
    @Published var customEndpoint: String = ""
    @Published var customModel: String = ""

    private let providerKey = "selected_llm_provider"
    private let endpointKey = "llm_custom_endpoint"
    private let modelKey = "llm_custom_model"

    init() {
        loadSettings()
    }

    public func loadSettings() {
        if let savedProvider = AppDefaults.shared.string(forKey: providerKey),
           let provider = LLMProvider(rawValue: savedProvider)
        {
            selectedProvider = provider
        }
        customEndpoint = AppDefaults.shared.string(forKey: endpointKey) ?? ""
        customModel = AppDefaults.shared.string(forKey: modelKey) ?? ""
        DebugLog.info("Loaded: \(selectedProvider.displayName)", context: "LLMProviderManager")
    }

    public func setProvider(_ provider: LLMProvider) {
        selectedProvider = provider
        AppDefaults.shared.set(provider.rawValue, forKey: providerKey)
        DebugLog.info("Set provider: \(provider.displayName)", context: "LLMProviderManager")
    }

    public func saveCustomSettings(endpoint: String, model: String) {
        customEndpoint = endpoint
        customModel = model
        AppDefaults.shared.set(endpoint, forKey: endpointKey)
        AppDefaults.shared.set(model, forKey: modelKey)
    }

    public var effectiveEndpoint: String {
        if !customEndpoint.isEmpty {
            return customEndpoint
        }
        return selectedProvider.defaultEndpoint
    }

    public var effectiveModel: String {
        if !customModel.isEmpty {
            return customModel
        }
        return selectedProvider.defaultModel
    }
}

// MARK: - Legacy API Provider (for backwards compatibility during migration)

public class APIProviderManager: ObservableObject {
    @Published var selectedProvider: TranscriptionProvider = .groq

    init() {
        // This is now just a wrapper for backwards compatibility
        selectedProvider = .groq
    }
}
