import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationFailure.failed(message) }
}

/// Validates that AudioRecorder.swift ignores device/configuration changes
/// during preparation and recording to prevent source-change crashes.
/// This contract ensures NO waits, delays, or retries on the recording
/// start path while still protecting against mid-start reconfiguration.
@main
private struct SourceChangePinningValidator {
    static func main() throws {
        let workspaceRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let audioRecorderPath = workspaceRoot
            .appendingPathComponent("Whishpermate/Whispermate/Services/AudioRecorder.swift")
        let recorderSource = try String(contentsOf: audioRecorderPath, encoding: .utf8)

        // 1. Verify NO preparation format retry delays exist (removed)
        try require(
            !recorderSource.contains("preparationFormatRetryDelays"),
            "AudioRecorder must NOT have preparationFormatRetryDelays - no waits on start path"
        )

        // 2. Verify NO prepareCaptureWithRetry method exists (removed)
        try require(
            !recorderSource.contains("prepareCaptureWithRetry"),
            "AudioRecorder must NOT have prepareCaptureWithRetry - no retry waits on start"
        )

        // 3. Verify device change is IGNORED during preparation
        try require(
            recorderSource.contains("Ignoring device change during preparation"),
            "handleAudioDeviceChanged must ignore changes during preparation"
        )

        // 4. Verify device change is IGNORED during recording
        try require(
            recorderSource.contains("Ignoring device change during recording"),
            "handleAudioDeviceChanged must ignore changes during recording"
        )

        // 5. Verify engine config change is IGNORED during preparation
        try require(
            recorderSource.contains("Ignoring engine configuration change during preparation"),
            "handleAudioEngineConfigurationChanged must ignore changes during preparation"
        )

        // 6. Verify engine config change is IGNORED during recording
        try require(
            recorderSource.contains("Ignoring engine configuration change during recording"),
            "handleAudioEngineConfigurationChanged must ignore changes during recording"
        )

        // 7. Verify telemetry for ignored device changes
        try require(
            recorderSource.contains("device_change_ignored_preparation"),
            "Must log device_change_ignored_preparation telemetry"
        )
        try require(
            recorderSource.contains("device_change_ignored_recording"),
            "Must log device_change_ignored_recording telemetry"
        )

        // 8. Verify telemetry for ignored config changes
        try require(
            recorderSource.contains("config_change_ignored_preparation"),
            "Must log config_change_ignored_preparation telemetry"
        )
        try require(
            recorderSource.contains("config_change_ignored_recording"),
            "Must log config_change_ignored_recording telemetry"
        )

        // 9. Verify device is described as "pinned"
        try require(
            recorderSource.contains("device is pinned"),
            "Log messages must indicate device is pinned for the session"
        )

        // 10. Verify NO invalidatePendingPreparation in handleAudioDeviceChanged
        // (should not tear down preparation on device change)
        let deviceChangedMethod = extractMethod(
            named: "handleAudioDeviceChanged",
            from: recorderSource
        )
        try require(
            !deviceChangedMethod.contains("invalidatePendingPreparation"),
            "handleAudioDeviceChanged must NOT call invalidatePendingPreparation"
        )

        // 11. Verify NO invalidatePendingPreparation in handleAudioEngineConfigurationChanged
        let configChangedMethod = extractMethod(
            named: "handleAudioEngineConfigurationChanged",
            from: recorderSource
        )
        try require(
            !configChangedMethod.contains("invalidatePendingPreparation"),
            "handleAudioEngineConfigurationChanged must NOT call invalidatePendingPreparation"
        )

        // 12. Verify NO attemptCaptureRecovery in handleAudioDeviceChanged
        try require(
            !deviceChangedMethod.contains("attemptCaptureRecovery"),
            "handleAudioDeviceChanged must NOT call attemptCaptureRecovery (no delayed recovery on device change)"
        )

        // 13. Verify NO attemptCaptureRecovery in handleAudioEngineConfigurationChanged
        try require(
            !configChangedMethod.contains("attemptCaptureRecovery"),
            "handleAudioEngineConfigurationChanged must NOT call attemptCaptureRecovery"
        )

        // 14. Verify watchdog still uses attemptCaptureRecovery (for actual engine failures)
        let watchdogMethod = extractMethod(
            named: "checkRecordingHealth",
            from: recorderSource
        )
        try require(
            watchdogMethod.contains("attemptCaptureRecovery"),
            "checkRecordingHealth must still use attemptCaptureRecovery for engine failures"
        )

        print("macOS source-change pinning contract: PASS")
    }

    /// Extracts a method body from source code (simple heuristic)
    private static func extractMethod(named name: String, from source: String) -> String {
        guard let range = source.range(of: "func \(name)") ??
              source.range(of: "private func \(name)") ??
              source.range(of: "@objc private func \(name)")
        else {
            return ""
        }

        var depth = 0
        var started = false
        var result = ""
        var index = range.lowerBound

        while index < source.endIndex {
            let char = source[index]
            result.append(char)

            if char == "{" {
                depth += 1
                started = true
            } else if char == "}" {
                depth -= 1
                if started && depth == 0 {
                    break
                }
            }
            index = source.index(after: index)
        }

        return result
    }
}
