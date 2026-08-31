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

/// Validates that macOS capture binds the HAL graph to a specific device UID
/// and input data source. Ignoring notifications (PR 105) is not enough:
/// Core Audio can still retarget the built-in input's data source when I/O
/// starts. This contract also keeps the no-wait-on-record rule.
@main
private struct SourceChangePinningValidator {
    static func main() throws {
        try validatePinPolicy()
        try validateSourceContract()
        print("macOS source-change pinning contract: PASS")
    }

    private static func validatePinPolicy() throws {
        try require(
            !MacCaptureGraphPinPolicy.shouldRestoreInputDataSource(pinned: nil, current: 1),
            "A device without a data source must not attempt restore"
        )
        try require(
            !MacCaptureGraphPinPolicy.shouldRestoreInputDataSource(pinned: 0x696D_6963, current: 0x696D_6963),
            "Matching pinned and current data sources must not restore"
        )
        try require(
            MacCaptureGraphPinPolicy.shouldRestoreInputDataSource(pinned: 0x696D_6963, current: 0x656D_656D),
            "A drifted data source must be restored to the pinned source"
        )
        try require(
            MacCaptureGraphPinPolicy.shouldRestoreInputDataSource(pinned: 0x696D_6963, current: nil),
            "A missing current data source must be restored to the pinned source"
        )
        try require(
            MacCaptureGraphPinPolicy.shouldDeferHardwareReapply(isCapturePinned: true),
            "Hardware reapply must wait while the capture graph is pinned"
        )
        try require(
            !MacCaptureGraphPinPolicy.shouldDeferHardwareReapply(isCapturePinned: false),
            "Hardware reapply must run when no capture graph is pinned"
        )
    }

    private static func validateSourceContract() throws {
        let workspaceRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let audioRecorderPath = workspaceRoot
            .appendingPathComponent("Whishpermate/Whispermate/Services/AudioRecorder.swift")
        let deviceManagerPath = workspaceRoot
            .appendingPathComponent("Whishpermate/Whispermate/Services/AudioDeviceManager.swift")
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

        // 15. Verify the graph is bound to a specific AudioDeviceID / UID
        try require(
            deviceManagerSource.contains("kAudioOutputUnitProperty_CurrentDevice"),
            "AudioDeviceManager must set kAudioOutputUnitProperty_CurrentDevice to bind the HAL unit"
        )
        try require(
            deviceManagerSource.contains("func bindCaptureInputNode"),
            "AudioDeviceManager must expose bindCaptureInputNode"
        )
        try require(
            recorderSource.contains("makePinnedCaptureGraph"),
            "AudioRecorder must build capture graphs through makePinnedCaptureGraph"
        )
        try require(
            recorderSource.contains("bindCaptureInputNode"),
            "AudioRecorder must bind the input node to the resolved device"
        )

        // 16. Verify data-source / jack listeners on the selected device
        try require(
            deviceManagerSource.contains("kAudioDevicePropertyDataSource"),
            "AudioDeviceManager must read and pin kAudioDevicePropertyDataSource"
        )
        try require(
            deviceManagerSource.contains("kAudioDevicePropertyJackIsConnected"),
            "AudioDeviceManager must listen for jack-source changes on the selected device"
        )
        try require(
            deviceManagerSource.contains("pinnedInputPropertyChangedCallback"),
            "AudioDeviceManager must listen for pinned-device property changes"
        )
        try require(
            deviceManagerSource.contains("func beginCapturePin"),
            "AudioDeviceManager must begin a capture pin for the selected device"
        )

        // 17. Recovery must reuse the same selected device, not a fresh default engine
        let recoveryMethod = extractMethod(
            named: "rebuildCaptureEngine",
            from: recorderSource
        )
        try require(
            recoveryMethod.contains("session.deviceResolution"),
            "rebuildCaptureEngine must reuse session.deviceResolution"
        )
        try require(
            recoveryMethod.contains("makePinnedCaptureGraph"),
            "rebuildCaptureEngine must bind the replacement engine to the pinned device"
        )
        try require(
            !recoveryMethod.contains("AVAudioEngine()\n        let inputNode = engine.inputNode\n        let inputFormat = inputNode.outputFormat"),
            "rebuildCaptureEngine must not adopt an unbound system-default input node"
        )

        // 18. Hardware reapply must wait until the pin ends
        try require(
            deviceManagerSource.contains("hardware_changed_deferred_capture_pin"),
            "Device-list changes must be deferred while the capture graph is pinned"
        )
        try require(
            deviceManagerSource.contains("shouldDeferHardwareReapply"),
            "Hardware reapply must consult MacCaptureGraphPinPolicy"
        )

        // 19. Start path must not gain the rejected wait-on-record delays
        let startMethod = extractMethod(named: "startRecording", from: recorderSource)
        let prepareMethod = extractMethod(named: "prepareCapture", from: recorderSource)
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
            prepareMethod.contains("beginCapturePin"),
            "prepareCapture must pin the selected device before starting I/O"
        )
        try require(
            prepareMethod.contains("restorePinnedInputDataSourceIfNeeded"),
            "prepareCapture must restore a drifted data source after engine.start"
        )
        try require(
            recoveryMethod.contains("restorePinnedInputDataSourceIfNeeded"),
            "rebuildCaptureEngine must restore the pinned data source after recovery start"
        )
        try require(
            recorderSource.contains("endCapturePin(recordingID: session.recordingID)"),
            "stopRecording must end the capture pin for the session device"
        )
        try require(
            extractMethod(named: "resetFailedStart", from: recorderSource).contains("endCapturePin"),
            "Failed starts must end the capture pin"
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
