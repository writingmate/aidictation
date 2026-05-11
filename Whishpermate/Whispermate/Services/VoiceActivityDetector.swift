import AVFoundation
import Foundation

/// Voice Activity Detection service using Silero VAD CoreML model
/// Analyzes completed audio files to determine if they contain speech
class VoiceActivityDetector {
    private static var shared: VoiceActivityAnalyzer?

    /// Get or create shared analyzer instance
    static func getAnalyzer() -> VoiceActivityAnalyzer {
        if shared == nil {
            shared = VoiceActivityAnalyzer()
        }
        return shared!
    }

    /// Check if an audio file contains speech
    /// - Parameters:
    ///   - audioURL: URL to the audio file
    ///   - settings: VAD settings (optional)
    /// - Returns: True if speech detected, false if only silence/noise
    static func hasSpeech(in audioURL: URL, settings: VADSettingsManager? = nil) async throws -> Bool {
        guard isCoreMLVADSupported else {
            DebugLog.warning(
                "Skipping CoreML VAD on this Mac because the bundled Silero model can crash the CoreML runtime; treating audio as speech",
                context: "VAD"
            )
            return true
        }

        let analyzer = getAnalyzer()
        let threshold = settings?.sensitivityThreshold ?? 0.3
        let minSpeechRatio: Float = 0.1

        return try await analyzer.containsSpeech(
            in: audioURL,
            threshold: threshold,
            minSpeechRatio: minSpeechRatio
        )
    }

    private static var isCoreMLVADSupported: Bool {
        #if arch(x86_64)
            // Crash reports show the Silero CoreML package can trigger a process-level
            // EXC_ARITHMETIC inside Espresso on Intel macOS 13 during first recording.
            // Swift error handling cannot catch that signal, so fail open before loading it.
            if #available(macOS 14.0, *) {
                return true
            }
            return false
        #else
            return true
        #endif
    }
}
