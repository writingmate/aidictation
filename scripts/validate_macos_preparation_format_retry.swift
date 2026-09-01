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

/// Validates that macOS capture uses the system-default AVAudioEngine input
/// (the 0.0.115 path) and that PR 105 still ignores device/configuration
/// changes during preparation and recording. The 0.0.116 HAL pin
/// (`kAudioOutputUnitProperty_CurrentDevice` + data-source restore) killed the
/// built-in IO unit and dismissed the overlay. This contract also keeps the
/// no-wait-on-record rule.
@main
private struct SourceChangePinningValidator {
    static func main() throws {
        try validateSourceContract()
        print("macOS source-change pinning contract: PASS")
    }

    private static func validateSourceContract() throws {
        let workspaceRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let audioRecorderPath = workspaceRoot
            .appendingPathComponent("Whishpermate/Whispermate/Services/AudioRecorder.swift")
        let deviceManagerPath = workspaceRoot
            .appendingPathComponent("Whishpermate/Whispermate/Services/AudioDeviceManager.swift")
        let pinPolicyPath = workspaceRoot
            .appendingPathComponent("Whishpermate/Whispermate/Services/MacCaptureGraphPinPolicy.swift")
        let recorderSource = try String(contentsOf: audioRecorderPath, encoding: .utf8)
        let deviceManagerSource = try String(contentsOf: deviceManagerPath, encoding: .utf8)

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

        // 15. HAL pin/bind from 0.0.116 must be gone. Built-in capture uses
        // AVAudioEngine().inputNode on the system default, matching 0.0.115.
        try require(
            !FileManager.default.fileExists(atPath: pinPolicyPath.path),
            "MacCaptureGraphPinPolicy.swift must be removed with the HAL pin"
        )
        try require(
            !deviceManagerSource.contains("kAudioOutputUnitProperty_CurrentDevice"),
            "AudioDeviceManager must not bind kAudioOutputUnitProperty_CurrentDevice"
        )
        try require(
            !deviceManagerSource.contains("func bindCaptureInputNode"),
            "AudioDeviceManager must not expose bindCaptureInputNode"
        )
        try require(
            !deviceManagerSource.contains("func beginCapturePin"),
            "AudioDeviceManager must not begin a HAL capture pin"
        )
        try require(
            !deviceManagerSource.contains("restorePinnedInputDataSourceIfNeeded"),
            "AudioDeviceManager must not restore a pinned HAL data source"
        )
        try require(
            !deviceManagerSource.contains("kAudioDevicePropertyDataSource"),
            "AudioDeviceManager must not pin kAudioDevicePropertyDataSource"
        )
        try require(
            !deviceManagerSource.contains("kAudioDevicePropertyJackIsConnected"),
            "AudioDeviceManager must not listen for jack-source changes during capture"
        )
        try require(
            !recorderSource.contains("bindCaptureInputNode"),
            "AudioRecorder must not bind the input node to a HAL device"
        )
        try require(
            !recorderSource.contains("makePinnedCaptureGraph"),
            "AudioRecorder must not build capture graphs through makePinnedCaptureGraph"
        )
        try require(
            !recorderSource.contains("beginCapturePin"),
            "AudioRecorder must not pin a HAL device before starting I/O"
        )
        try require(
            !recorderSource.contains("restorePinnedInputDataSourceIfNeeded"),
            "AudioRecorder must not restore a HAL data source after engine.start"
        )
        try require(
            !recorderSource.contains("endCapturePin"),
            "AudioRecorder must not end a HAL capture pin"
        )

        let prepareMethod = extractMethod(named: "prepareCapture", from: recorderSource)
        let recoveryMethod = extractMethod(named: "rebuildCaptureEngine", from: recorderSource)
        try require(
            prepareMethod.contains("let engine = AVAudioEngine()")
                && prepareMethod.contains("let inputNode = engine.inputNode")
                && prepareMethod.contains("inputNode.outputFormat"),
            "prepareCapture must create AVAudioEngine() and use inputNode.outputFormat"
        )
        try require(
            recoveryMethod.contains("let engine = AVAudioEngine()")
                && recoveryMethod.contains("let inputNode = engine.inputNode")
                && recoveryMethod.contains("inputNode.outputFormat"),
            "rebuildCaptureEngine must create AVAudioEngine() and use inputNode.outputFormat"
        )

        // 16. Start path must not gain the rejected wait-on-record delays
        let startMethod = extractMethod(named: "startRecording", from: recorderSource)
        try require(
            !startMethod.contains("asyncAfter") || startMethod.contains("recordingPreparationTimeout"),
            "startRecording may only delay for the preparation deadline, not a start wait"
        )
        try require(
            !prepareMethod.contains("Thread.sleep")
                && !prepareMethod.contains("Task.sleep")
                && !prepareMethod.contains("asyncAfter"),
            "prepareCapture must not wait, sleep, or delay before engine.start"
        )
        try require(
            !startMethod.contains("0.1")
                && !startMethod.contains("0.25")
                && !prepareMethod.contains("0.1")
                && !prepareMethod.contains("0.25")
                && !prepareMethod.contains("0.5"),
            "startRecording/prepareCapture must not wait 0.1/0.25/0.5s on the start path"
        )
    }

    /// Extracts a method body from source code (simple heuristic)
    private static func extractMethod(named name: String, from source: String) -> String {
        let prefixes = [
            "func \(name)",
            "private func \(name)",
            "@objc private func \(name)",
        ]
        var startIndex: String.Index?
        for prefix in prefixes {
            var searchStart = source.startIndex
            while let range = source.range(of: prefix, range: searchStart ..< source.endIndex) {
                let after = range.upperBound
                let nextIsIdentifier: Bool
                if after < source.endIndex {
                    let next = source[after]
                    nextIsIdentifier = next.isLetter || next.isNumber || next == "_"
                } else {
                    nextIsIdentifier = false
                }
                if !nextIsIdentifier {
                    startIndex = range.lowerBound
                    break
                }
                searchStart = after
            }
            if startIndex != nil { break }
        }
        guard let startIndex else { return "" }

        var depth = 0
        var started = false
        var result = ""
        var index = startIndex

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
