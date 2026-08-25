import AVFoundation
import Foundation

/// Analyzes completed audio files to detect if they contain speech
actor VoiceActivityAnalyzer {
    private let sileroVAD = SileroVAD()

    /// Check if audio file contains speech
    func containsSpeech(
        in audioURL: URL,
        threshold: Float = 0.3,
        minSpeechRatio _: Float = 0.1
    ) async throws -> Bool {
        DictationStopwatch.mark("VAD start")
        DebugLog.info("🎤 Analyzing audio for speech...", context: "VAD")

        let hasSpeech = try await sileroVAD.analyzeAudio(url: audioURL, threshold: threshold)

        if hasSpeech {
            DebugLog.info("✅ Speech detected", context: "VAD")
        } else {
            DebugLog.info("🔇 No speech detected", context: "VAD")
        }

        return hasSpeech
    }
}

// MARK: - Errors

enum VADError: LocalizedError {
    case notInitialized
    case formatConversionFailed
    case bufferAllocationFailed
    case bufferReadFailed
    case conversionError(Error)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "VAD is not initialized"
        case .formatConversionFailed:
            return "Failed to create audio format converter"
        case .bufferAllocationFailed:
            return "Failed to allocate audio buffer"
        case .bufferReadFailed:
            return "Failed to read audio buffer"
        case let .conversionError(error):
            return "Audio conversion error: \(error.localizedDescription)"
        }
    }
}
