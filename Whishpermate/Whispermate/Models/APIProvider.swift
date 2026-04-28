import Foundation
import WhisperMateShared
internal import Combine

// MARK: - Transcription Provider

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case parakeet // On-device (first for prominence)
    case groq
    case openai
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: return "Offline (Parakeet)"
        case .groq: return "Cloud (Groq)"
        case .openai: return "Cloud (OpenAI)"
        case .custom: return "Cloud (AIDictation)"
        }
    }

    var description: String {
        switch self {
        case .parakeet: return "Private, offline, fast"
        case .groq: return "Whisper Large V3"
        case .openai: return "Whisper API"
        case .custom: return "Enhanced Whisper + LLM"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .parakeet: return "" // On-device, no endpoint
        case .groq: return "https://api.groq.com/openai/v1/audio/transcriptions"
        case .openai: return "https://api.openai.com/v1/audio/transcriptions"
        case .custom: return "https://writingmate.ai/api/openai/v1/audio/transcriptions"
        }
    }

    var defaultModel: String {
        switch self {
        case .parakeet: return "parakeet-tdt-0.6b-v3" // Multilingual
        case .groq: return "whisper-large-v3-turbo"
        case .openai: return "whisper-1"
        case .custom: return "gpt-4o-transcribe"
        }
    }

    var defaultTransport: TranscriptionTransport {
        switch self {
        case .parakeet:
            return .local
        case .groq, .openai, .custom:
            return .batch
        }
    }

    var apiKeyName: String {
        return "\(rawValue)_transcription_api_key"
    }

    var isOnDevice: Bool {
        return self == .parakeet
    }

    var requiresAPIKey: Bool {
        return self != .parakeet
    }

    /// Returns all available providers
    static var availableProviders: [TranscriptionProvider] {
        if ParakeetTranscriptionService.isRuntimeSupported {
            return allCases
        }
        return allCases.filter { $0 != .parakeet }
    }
}

/// Runtime transport used by the Mac app. Server-side model/provider choices are
/// endpoint configuration, not app control-flow branches.
enum TranscriptionTransport: String, CaseIterable, Identifiable {
    case batch
    case realtime
    case local

    var id: String { rawValue }
}

// MARK: - Post-Processing Provider

enum PostProcessingProvider: String, CaseIterable, Identifiable {
    case aidictation // Use AIDictation cloud (no API key needed)
    case customLLM // Use user's own LLM provider

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aidictation: return "AIDictation"
        case .customLLM: return "Custom LLM"
        }
    }

    var description: String {
        switch self {
        case .aidictation: return "Cloud formatting, no API key required"
        case .customLLM: return "Use your own LLM provider"
        }
    }

    /// Default model for AIDictation post-processing
    static let aidictationModel = "openai/gpt-oss-20b"
}

/// User-facing transcription mode selection
enum TranscriptionMode: String, CaseIterable {
    case cloud  // Always cloud
    case local  // Always on-device
    case auto   // Cloud when online, local when offline

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .cloud: return "Cloud"
        case .local: return "Local"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Cloud when online, local when offline"
        case .cloud: return "Cloud-based, slower response, excellent quality"
        case .local: return "On-device, instant response, good quality"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .cloud:
            return true
        case .auto, .local:
            return ParakeetTranscriptionService.isRuntimeSupported
        }
    }

    static var availableCases: [TranscriptionMode] {
        allCases.filter(\.isAvailable)
    }
}

class TranscriptionProviderManager: ObservableObject {
    static let shared = TranscriptionProviderManager()

    @Published var selectedProvider: TranscriptionProvider = .custom
    @Published var transcriptionMode: TranscriptionMode = .auto
    @Published var customEndpoint: String = ""
    @Published var customModel: String = ""
    @Published var customTransport: TranscriptionTransport = .batch
    @Published var enableLLMPostProcessing: Bool = false
    @Published var postProcessingProvider: PostProcessingProvider = .aidictation

    private enum Keys {
        static let selectedProvider = "transcriptionProvider"
        static let transcriptionMode = "transcriptionMode"
        static let customTransport = "customTranscriptionTransport"
    }

    /// Whether the user prefers on-device transcription
    var isLocalMode: Bool {
        get { transcriptionMode == .local }
        set {
            setTranscriptionMode(newValue ? .local : .cloud)
        }
    }

    init() {
        if let saved = AppDefaults.shared.string(forKey: Keys.selectedProvider),
           let provider = TranscriptionProvider(rawValue: saved)
        {
            selectedProvider = provider
        } else {
            selectedProvider = .custom
        }

        if let savedMode = AppDefaults.shared.string(forKey: Keys.transcriptionMode),
           let mode = TranscriptionMode(rawValue: savedMode)
        {
            transcriptionMode = mode
        } else {
            // Migrate from old provider-based selection
            transcriptionMode = selectedProvider == .parakeet ? .local : .cloud
        }

        if !ParakeetTranscriptionService.isRuntimeSupported {
            if selectedProvider == .parakeet {
                selectedProvider = .custom
                AppDefaults.shared.set(TranscriptionProvider.custom.rawValue, forKey: Keys.selectedProvider)
            }
            if transcriptionMode == .local || transcriptionMode == .auto {
                transcriptionMode = .cloud
                AppDefaults.shared.set(TranscriptionMode.cloud.rawValue, forKey: Keys.transcriptionMode)
            }
        }

        enableLLMPostProcessing = false
        postProcessingProvider = .aidictation
        if let savedTransport = AppDefaults.shared.string(forKey: Keys.customTransport),
           let transport = TranscriptionTransport(rawValue: savedTransport)
        {
            customTransport = transport
        }
        DebugLog.info("Loaded: \(selectedProvider.displayName), mode: \(transcriptionMode.displayName), transport: \(effectiveTransport.rawValue), LLM post-processing: \(enableLLMPostProcessing), post-processor: \(postProcessingProvider.displayName)", context: "TranscriptionProviderManager")
    }

    func setTranscriptionMode(_ mode: TranscriptionMode) {
        guard mode.isAvailable else {
            DebugLog.warning("Ignoring unavailable transcription mode: \(mode.displayName)", context: "TranscriptionProviderManager")
            setTranscriptionMode(.cloud)
            return
        }

        transcriptionMode = mode
        AppDefaults.shared.set(mode.rawValue, forKey: Keys.transcriptionMode)

        // Keep selectedProvider in sync
        switch mode {
        case .local:
            selectedProvider = .parakeet
            AppDefaults.shared.set(TranscriptionProvider.parakeet.rawValue, forKey: Keys.selectedProvider)
        case .cloud, .auto:
            if selectedProvider == .parakeet {
                selectedProvider = .custom
                AppDefaults.shared.set(TranscriptionProvider.custom.rawValue, forKey: Keys.selectedProvider)
            }
        }
        DebugLog.info("Set mode: \(mode.displayName), provider: \(selectedProvider.displayName)", context: "TranscriptionProviderManager")
    }

    @discardableResult
    func requestTranscriptionMode(_ mode: TranscriptionMode, parakeetService: ParakeetTranscriptionService = .shared) -> TranscriptionMode? {
        guard mode.isAvailable else {
            setTranscriptionMode(.cloud)
            return nil
        }

        let modelReady: Bool = {
            if case .ready = parakeetService.state { return true }
            return false
        }()

        setTranscriptionMode(mode)

        if (mode == .local || mode == .auto) && !modelReady {
            initializeParakeetIfNeeded(parakeetService)
        }

        return nil
    }

    private func initializeParakeetIfNeeded(_ service: ParakeetTranscriptionService) {
        Task {
            if case .error = await MainActor.run(body: { service.state }) {
                await MainActor.run { service.cleanup() }
            }
            try? await service.initialize()
        }
    }

    func setProvider(_ provider: TranscriptionProvider) {
        selectedProvider = provider
        AppDefaults.shared.set(provider.rawValue, forKey: Keys.selectedProvider)
        DebugLog.info("Set provider: \(provider.displayName)", context: "TranscriptionProviderManager")
    }

    func setLLMPostProcessing(_ enabled: Bool) {
        enableLLMPostProcessing = enabled
        DebugLog.info("LLM post-processing: \(enabled)", context: "TranscriptionProviderManager")
    }

    func setPostProcessingProvider(_ provider: PostProcessingProvider) {
        postProcessingProvider = provider
        DebugLog.info("Post-processing provider: \(provider.displayName)", context: "TranscriptionProviderManager")
    }

    func saveCustomSettings(endpoint: String, model: String) {
        customEndpoint = endpoint
        customModel = model
    }

    func setCustomTransport(_ transport: TranscriptionTransport) {
        customTransport = transport
        AppDefaults.shared.set(transport.rawValue, forKey: Keys.customTransport)
        DebugLog.info("Set custom transcription transport: \(transport.rawValue)", context: "TranscriptionProviderManager")
    }

    var effectiveEndpoint: String {
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

    var effectiveModel: String {
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

    var effectiveTransport: TranscriptionTransport {
        if selectedProvider == .custom {
            if let secretTransport = SecretsLoader.getValue(for: "CustomTranscriptionTransport")?.lowercased(),
               let transport = TranscriptionTransport(rawValue: secretTransport)
            {
                return transport
            }
            return customTransport
        }
        return selectedProvider.defaultTransport
    }
}

// MARK: - LLM Provider

enum LLMProvider: String, CaseIterable, Identifiable {
    case groq
    case lfm25
    case openai
    case anthropic
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .lfm25: return "LFM 2.5 (Ollama)"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .custom: return "Custom"
        }
    }

    var description: String {
        switch self {
        case .groq: return "Fast LLM (GPT-OSS-20B)"
        case .lfm25: return "Local Liquid AI via Ollama"
        case .openai: return "GPT-4o"
        case .anthropic: return "Claude"
        case .custom: return "OpenAI-compatible API"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1/chat/completions"
        case .lfm25: return "http://localhost:11434/v1/chat/completions"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .groq: return "openai/gpt-oss-120b"
        case .lfm25: return "hf.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF"
        case .openai: return "gpt-4o"
        case .anthropic: return "claude-3-5-sonnet-20241022"
        case .custom: return ""
        }
    }

    var apiKeyName: String {
        return "\(rawValue)_llm_api_key"
    }

    var requiresAPIKey: Bool {
        switch self {
        case .lfm25:
            return false
        case .groq, .openai, .anthropic, .custom:
            return true
        }
    }
}

/// Manages LLM provider selection for post-processing
class LLMProviderManager: ObservableObject {
    static let shared = LLMProviderManager()

    // MARK: - Published Properties

    @Published var selectedProvider: LLMProvider = .groq
    @Published var customEndpoint: String = ""
    @Published var customModel: String = ""

    private enum Keys {
        static let selectedProvider = "selected_llm_provider"
        static let customEndpoint = "llm_custom_endpoint"
        static let customModel = "llm_custom_model"
    }

    // MARK: - Initialization

    private init() {
        if let saved = AppDefaults.shared.string(forKey: Keys.selectedProvider),
           let provider = LLMProvider(rawValue: saved)
        {
            selectedProvider = provider
        } else {
            selectedProvider = .groq
        }
        customEndpoint = AppDefaults.shared.string(forKey: Keys.customEndpoint) ?? ""
        customModel = AppDefaults.shared.string(forKey: Keys.customModel) ?? ""
        DebugLog.info("Loaded: \(selectedProvider.displayName)", context: "LLMProviderManager")
    }

    // MARK: - Public API

    func setProvider(_ provider: LLMProvider) {
        selectedProvider = provider
        AppDefaults.shared.set(provider.rawValue, forKey: Keys.selectedProvider)
        DebugLog.info("Set provider: \(provider.displayName)", context: "LLMProviderManager")
    }

    func saveCustomSettings(endpoint: String, model: String) {
        customEndpoint = endpoint
        customModel = model
        AppDefaults.shared.set(endpoint, forKey: Keys.customEndpoint)
        AppDefaults.shared.set(model, forKey: Keys.customModel)
    }

    // MARK: - Computed Properties

    var effectiveEndpoint: String {
        if selectedProvider == .custom, !customEndpoint.isEmpty {
            return customEndpoint
        }
        return selectedProvider.defaultEndpoint
    }

    var effectiveModel: String {
        if selectedProvider == .custom, !customModel.isEmpty {
            return customModel
        }
        return selectedProvider.defaultModel
    }

    var effectiveApiKey: String? {
        if let secretKey = SecretsLoader.llmKey(for: selectedProvider), !secretKey.isEmpty {
            return secretKey
        }

        if let storedKey = KeychainHelper.get(key: selectedProvider.apiKeyName), !storedKey.isEmpty {
            return storedKey
        }

        if !selectedProvider.requiresAPIKey || isLoopbackEndpoint {
            return "not-needed"
        }

        return nil
    }

    private var isLoopbackEndpoint: Bool {
        guard let url = URL(string: effectiveEndpoint),
              let host = url.host?.lowercased()
        else {
            return false
        }

        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    var requiresAPIKeyEntry: Bool {
        return selectedProvider.requiresAPIKey && !isLoopbackEndpoint
    }
}

// MARK: - Legacy API Provider (for backwards compatibility during migration)

class APIProviderManager: ObservableObject {
    @Published var selectedProvider: TranscriptionProvider = .groq

    init() {
        // This is now just a wrapper for backwards compatibility
        selectedProvider = .groq
    }
}
