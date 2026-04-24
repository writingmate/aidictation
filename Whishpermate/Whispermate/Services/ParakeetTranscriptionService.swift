import AVFoundation
internal import Combine
import FluidAudio
import Foundation

/// On-device transcription service using NVIDIA Parakeet model via FluidAudio
/// Provides private, offline, low-latency speech recognition on Apple Silicon
class ParakeetTranscriptionService: ObservableObject {
    static let shared = ParakeetTranscriptionService()

    // MARK: - Types

    enum ServiceState {
        case notInitialized
        case downloading
        case initializing
        case ready
        case transcribing
        case error(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    // MARK: - Published Properties

    @Published var state: ServiceState = .notInitialized
    @Published var isModelDownloaded: Bool = false

    // MARK: - Private Properties

    private var asrManager: AsrManager?
    private let audioConverter = AudioConverter()

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Download and initialize the Parakeet model (v3 multilingual)
    func initialize() async throws {
        guard case .notInitialized = state else {
            DebugLog.info("Already initialized or in progress", context: "ParakeetTranscriptionService")
            return
        }

        await MainActor.run {
            self.state = .downloading
        }

        do {
            DebugLog.info("Downloading Parakeet v3 multilingual model...", context: "ParakeetTranscriptionService")

            // Download v3 multilingual model (will use cache if already downloaded)
            let downloadedModels = try await AsrModels.downloadAndLoad(version: .v3)

            await MainActor.run { self.state = .initializing }

            DebugLog.info("Initializing ASR manager...", context: "ParakeetTranscriptionService")

            // Initialize ASR manager
            let manager = AsrManager(config: .default)
            try await manager.loadModels(downloadedModels)

            await MainActor.run {
                self.asrManager = manager
                self.state = .ready
                self.isModelDownloaded = true
            }

            DebugLog.info("Parakeet model ready", context: "ParakeetTranscriptionService")

        } catch {
            DebugLog.error("Failed to initialize Parakeet: \(error.localizedDescription)", context: "ParakeetTranscriptionService")
            await MainActor.run {
                self.state = .error(error.localizedDescription)
            }
            throw error
        }
    }

    /// Transcribe audio file to text
    /// - Parameter audioURL: URL to audio file (any format supported by AVFoundation)
    /// - Returns: Transcribed text
    func transcribe(audioURL: URL) async throws -> String {
        // Initialize if needed
        if case .notInitialized = state {
            try await initialize()
        }

        guard let manager = asrManager else {
            throw NSError(domain: "ParakeetTranscriptionService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized"])
        }

        await MainActor.run {
            self.state = .transcribing
        }

        defer {
            Task { @MainActor in
                self.state = .ready
            }
        }

        do {
            DebugLog.info("Converting audio to 16kHz mono...", context: "ParakeetTranscriptionService")

            // Convert audio to 16kHz mono PCM (required by Parakeet)
            let samples = try audioConverter.resampleAudioFile(path: audioURL.path)

            DebugLog.info("Transcribing \(samples.count) samples...", context: "ParakeetTranscriptionService")

            // Perform transcription
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples, decoderState: &decoderState)

            DebugLog.info("Transcription complete: \(result.text.prefix(100))...", context: "ParakeetTranscriptionService")

            return result.text

        } catch {
            DebugLog.error("Transcription failed: \(error.localizedDescription)", context: "ParakeetTranscriptionService")
            throw error
        }
    }

    /// Cleanup resources
    func cleanup() {
        let manager = asrManager
        asrManager = nil
        Task {
            await manager?.cleanup()
            await MainActor.run {
                self.state = .notInitialized
                self.isModelDownloaded = false
            }
        }
    }
}
