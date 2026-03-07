import AVFoundation
internal import Combine
import FluidAudio
import Foundation
import WhisperMateShared

/// On-device transcription service using NVIDIA Parakeet model via FluidAudio for iOS
class ParakeetTranscriptionService: ObservableObject {
    static let shared = ParakeetTranscriptionService()

    // MARK: - Types

    enum ServiceState: Equatable {
        case notInitialized
        case downloading
        case initializing
        case ready
        case transcribing
        case error(String)

        static func == (lhs: ServiceState, rhs: ServiceState) -> Bool {
            switch (lhs, rhs) {
            case (.notInitialized, .notInitialized),
                 (.downloading, .downloading),
                 (.initializing, .initializing),
                 (.ready, .ready),
                 (.transcribing, .transcribing):
                return true
            case let (.error(a), .error(b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Published Properties

    @Published var state: ServiceState = .notInitialized
    @Published var isModelDownloaded: Bool = false

    // MARK: - Private Properties

    private var asrManager: AsrManager?
    private var models: AsrModels?
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

            let downloadedModels = try await AsrModels.downloadAndLoad(version: .v3)

            await MainActor.run {
                self.state = .initializing
                self.models = downloadedModels
            }

            DebugLog.info("Initializing ASR manager...", context: "ParakeetTranscriptionService")

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: downloadedModels)

            await MainActor.run {
                self.asrManager = manager
                self.state = .ready
                self.isModelDownloaded = true
            }

            DebugLog.info("Parakeet model ready", context: "ParakeetTranscriptionService")

        } catch {
            DebugLog.info("Failed to initialize Parakeet: \(error.localizedDescription)", context: "ParakeetTranscriptionService")
            await MainActor.run {
                self.state = .error(error.localizedDescription)
            }
            throw error
        }
    }

    /// Transcribe audio file to text
    func transcribe(audioURL: URL) async throws -> String {
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

            let samples = try audioConverter.resampleAudioFile(path: audioURL.path)

            DebugLog.info("Transcribing \(samples.count) samples...", context: "ParakeetTranscriptionService")

            let result = try await manager.transcribe(samples)

            DebugLog.info("Transcription complete: \(result.text.prefix(100))...", context: "ParakeetTranscriptionService")

            return result.text

        } catch {
            DebugLog.info("Transcription failed: \(error.localizedDescription)", context: "ParakeetTranscriptionService")
            throw error
        }
    }

    /// Cleanup resources
    func cleanup() {
        asrManager?.cleanup()
        asrManager = nil
        models = nil
        state = .notInitialized
        isModelDownloaded = false
    }
}
