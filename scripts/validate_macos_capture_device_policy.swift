import Foundation

private enum ValidationFailure: Error {
    case assertion(String)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw ValidationFailure.assertion(message) }
}

private typealias Candidate = MacCaptureDevicePolicy.Candidate
private typealias Context = MacCaptureDevicePolicy.Context

private let builtIn = Candidate(uniqueID: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isBuiltIn: true)
private let usbMic = Candidate(uniqueID: "Yeti-UID", name: "Yeti Stereo Microphone")
private let headset = Candidate(uniqueID: "Headset-UID", name: "USB Headset")
private let aggregate = Candidate(uniqueID: "Aggregate-UID", name: "CADeviceAggregate:123")

@main
private enum ValidateMacCaptureDevicePolicy {
    static func main() throws {
        try savedDeviceMissingUsesDefault()
        try savedDeviceConnectedButNotDefault()
        try automaticSelection()
        try hiddenAndMissingDefault()
        try sourceContract()
        print("PASS: macOS capture falls back to the system default input instead of failing")
    }

    /// The reported case: a saved USB microphone is gone and macOS already
    /// moved the default to the built-in one. Recording must proceed from the
    /// built-in mic, with no route change to wait on.
    static func savedDeviceMissingUsesDefault() throws {
        let decision = MacCaptureDevicePolicy.captureDecision(Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn],
            systemDefault: builtIn
        ))
        try require(decision?.device == builtIn, "saved device missing must capture from the system default")
        try require(decision?.fallbackReason == .savedDeviceMissing, "saved device missing must be reported")
        try require(decision?.preferredDevice == nil, "nothing to reconcile when the default is already the best stand-in")

        let onDesk = MacCaptureDevicePolicy.captureDecision(Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn, headset],
            systemDefault: builtIn,
            hasActiveExternalDisplay: true
        ))
        try require(onDesk?.device == builtIn, "capture still uses the current default on a desk setup")
        try require(onDesk?.fallbackReason == .savedDeviceMissing, "desk fallback reason must stay saved_device_missing")
        try require(onDesk?.preferredDevice == headset, "the other external mic becomes the default after capture")
    }

    static func savedDeviceConnectedButNotDefault() throws {
        let decision = MacCaptureDevicePolicy.captureDecision(Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn, usbMic],
            systemDefault: builtIn
        ))
        try require(decision?.device == builtIn, "route not applied must still capture from the default")
        try require(decision?.fallbackReason == .routeNotApplied, "route not applied must be reported")
        try require(decision?.preferredDevice == usbMic, "the saved device is reconciled after capture")

        let matched = MacCaptureDevicePolicy.captureDecision(Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [builtIn, usbMic],
            systemDefault: usbMic
        ))
        try require(matched?.device == usbMic, "saved device that is the default is used")
        try require(matched?.fallbackReason == nil, "no fallback when the default matches the saved device")
        try require(matched?.preferredDevice == nil, "no reconciliation when the default matches")
    }

    static func automaticSelection() throws {
        let follows = MacCaptureDevicePolicy.captureDecision(Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [builtIn, usbMic],
            systemDefault: builtIn
        ))
        try require(follows?.device == builtIn && follows?.fallbackReason == nil, "automatic mode follows the default on a laptop")

        let clamshell = Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [builtIn],
            systemDefault: builtIn,
            clamshellClosed: true,
            hasActiveBuiltInDisplay: false,
            hasActiveExternalDisplay: true
        )
        try require(
            MacCaptureDevicePolicy.bestAutomaticDevice(in: clamshell) == builtIn,
            "closed lid with only the built-in mic must still pick it instead of nothing"
        )
        let clamshellDecision = MacCaptureDevicePolicy.captureDecision(clamshell)
        try require(clamshellDecision?.device == builtIn && clamshellDecision?.fallbackReason == nil, "closed lid records from the only mic without a fallback")

        let desk = Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [builtIn, usbMic],
            systemDefault: builtIn,
            hasActiveExternalDisplay: true
        )
        try require(MacCaptureDevicePolicy.bestAutomaticDevice(in: desk) == usbMic, "desk setup prefers the external mic")
        let deskDecision = MacCaptureDevicePolicy.captureDecision(desk)
        try require(deskDecision?.device == builtIn, "desk setup still captures from the current default")
        try require(deskDecision?.fallbackReason == .routeNotApplied && deskDecision?.preferredDevice == usbMic, "desk setup reconciles to the external mic afterwards")

        let virtual = Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [aggregate, usbMic],
            systemDefault: nil
        )
        try require(MacCaptureDevicePolicy.bestAutomaticDevice(in: virtual) == usbMic, "virtual devices lose to a physical mic")
    }

    static func hiddenAndMissingDefault() throws {
        let hidden = MacCaptureDevicePolicy.captureDecision(Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [builtIn],
            systemDefault: aggregate
        ))
        try require(hidden?.device == aggregate, "a hidden default is still what capture runs through")
        try require(hidden?.fallbackReason == .routeNotApplied && hidden?.preferredDevice == builtIn, "a hidden default is reconciled to a listed device afterwards")

        let none = MacCaptureDevicePolicy.captureDecision(Context(
            automaticallySelectDevice: false,
            savedSelectedDeviceUID: usbMic.uniqueID,
            availableDevices: [],
            systemDefault: nil
        ))
        try require(none == nil, "no default input is the only case that fails resolution")

        let unlisted = MacCaptureDevicePolicy.captureDecision(Context(
            automaticallySelectDevice: true,
            savedSelectedDeviceUID: nil,
            availableDevices: [],
            systemDefault: builtIn
        ))
        try require(unlisted?.device == builtIn && unlisted?.fallbackReason == nil, "a default with an empty list is still used")
    }

    /// Guards the recorder and manager against the two regressions this
    /// policy exists to prevent: failing resolution on a route mismatch, and
    /// changing or waiting on the route during a recording attempt.
    static func sourceContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Whishpermate/Whispermate/Services/AudioDeviceManager.swift"),
            encoding: .utf8
        )
        let recorderSource = try String(
            contentsOf: root.appendingPathComponent("Whishpermate/Whispermate/Services/AudioRecorder.swift"),
            encoding: .utf8
        )
        let appStateSource = try String(
            contentsOf: root.appendingPathComponent("Whishpermate/Whispermate/Services/AppState.swift"),
            encoding: .utf8
        )

        try require(
            managerSource.contains("MacCaptureDevicePolicy.captureDecision("),
            "AudioDeviceManager must resolve capture through MacCaptureDevicePolicy"
        )
        try require(
            !managerSource.contains("guard getDefaultInputDevice()?.uniqueID == target.uniqueID else"),
            "resolveCaptureDevice must not fail when the default differs from the wanted device"
        )
        try require(
            managerSource.contains("func captureDidEnd()"),
            "AudioDeviceManager must learn when capture ends so deferred route changes can run"
        )
        try require(
            managerSource.contains("!isCaptureActive"),
            "route reconciliation must not run while a recording is capturing"
        )

        let resolveRange = try requireRange(of: "func resolveCaptureDevice(", in: managerSource, through: "return CaptureDeviceResolution(")
        let resolveBody = String(managerSource[resolveRange])
        try require(
            !resolveBody.contains("setDefaultInputDevice") && !resolveBody.contains("asyncAfter") && !resolveBody.contains("sleep("),
            "resolveCaptureDevice must not change the route or wait"
        )

        try require(
            recorderSource.contains("AudioDeviceManager.shared.captureDidEnd()"),
            "AudioRecorder must report the end of capture to AudioDeviceManager"
        )
        try require(
            recorderSource.contains("No microphone is available."),
            "the no-default failure must be explained to the user"
        )
        try require(
            recorderSource.contains("isn’t sending audio.") && recorderSource.contains("couldn’t start."),
            "engine failures must name the microphone and point to Settings"
        )
        try require(
            appStateSource.contains("overlayManager.showCaptureFailure("),
            "a recording start failure must be surfaced on the overlay"
        )
    }

    private static func requireRange(
        of start: String,
        in source: String,
        through end: String
    ) throws -> Range<String.Index> {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound ..< source.endIndex)
        else {
            throw ValidationFailure.assertion("could not locate \(start) ... \(end)")
        }
        return startRange.lowerBound ..< endRange.upperBound
    }
}
