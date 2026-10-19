import Foundation

/// Decides which input device a macOS recording attempt captures from, given
/// what Core Audio reports at that moment.
///
/// Capture runs through `AVAudioEngine.inputNode`, which always follows the
/// system default input. The app can steer that default from maintenance paths
/// (launch, hardware change, wake, Settings), but a recording attempt must never
/// wait for or perform a route change. So the only device a recording can use
/// is the current system default; this policy decides whether that default is
/// the device the user asked for, and if not, why we are recording from it
/// anyway.
///
/// Before this policy, a mismatch between the wanted device and the system
/// default failed the recording outright. One stale saved microphone UID, or a
/// closed lid with only the built-in mic left, then blocked every recording
/// until the user changed something by hand. The rules here are pure so that
/// fallback behaviour can be tested without audio hardware.
enum MacCaptureDevicePolicy {
    struct Candidate: Equatable, Hashable, Sendable {
        let uniqueID: String
        let name: String
        let isBuiltIn: Bool

        init(uniqueID: String, name: String, isBuiltIn: Bool = false) {
            self.uniqueID = uniqueID
            self.name = name
            self.isBuiltIn = isBuiltIn
        }

        var looksVirtual: Bool {
            let lowercasedName = name.lowercased()
            return MacCaptureDevicePolicy.virtualDeviceNameFragments.contains {
                lowercasedName.contains($0)
            }
        }

        var looksLikeMicrophone: Bool {
            let lowercasedName = name.lowercased()
            return lowercasedName.contains("microphone") || lowercasedName.contains("mic")
        }
    }

    struct Context: Sendable {
        let automaticallySelectDevice: Bool
        let savedSelectedDeviceUID: String?
        /// Input devices the app lists for the user. Aggregate and loopback
        /// devices are already filtered out by the caller.
        let availableDevices: [Candidate]
        /// The device Core Audio currently routes default input through, or
        /// nil when there is none. This may be a device that is not in
        /// `availableDevices` (for example a hidden aggregate); capture still
        /// works through it.
        let systemDefault: Candidate?
        let clamshellClosed: Bool
        let hasActiveBuiltInDisplay: Bool
        let hasActiveExternalDisplay: Bool

        init(
            automaticallySelectDevice: Bool,
            savedSelectedDeviceUID: String?,
            availableDevices: [Candidate],
            systemDefault: Candidate?,
            clamshellClosed: Bool = false,
            hasActiveBuiltInDisplay: Bool = true,
            hasActiveExternalDisplay: Bool = false
        ) {
            self.automaticallySelectDevice = automaticallySelectDevice
            self.savedSelectedDeviceUID = savedSelectedDeviceUID
            self.availableDevices = availableDevices
            self.systemDefault = systemDefault
            self.clamshellClosed = clamshellClosed
            self.hasActiveBuiltInDisplay = hasActiveBuiltInDisplay
            self.hasActiveExternalDisplay = hasActiveExternalDisplay
        }
    }

    enum FallbackReason: String, Equatable, Sendable {
        /// The device the user chose is not connected right now.
        case savedDeviceMissing = "saved_device_missing"
        /// The wanted device is connected but is not the system default yet.
        /// Capture uses the default now; the route is reconciled afterwards.
        case routeNotApplied = "route_not_applied"
        /// Every listed device was ruled out (for example a closed lid with
        /// only the built-in microphone left), so the default is used as-is.
        case noEligibleDevice = "no_eligible_device"
    }

    struct Decision: Equatable, Sendable {
        /// The device this recording captures from. Always the system default.
        let device: Candidate
        /// Nil when `device` is exactly what the user's preference asked for.
        let fallbackReason: FallbackReason?
        /// The device the user's preference resolves to when it differs from
        /// `device`. Maintenance should make it the default once capture ends.
        let preferredDevice: Candidate?

        var usedFallback: Bool { fallbackReason != nil }
    }

    static let virtualDeviceNameFragments = [
        "cadeviceaggregate",
        "aggregate",
        "multi-output",
        "blackhole",
        "loopback",
        "soundflower",
    ]

    // MARK: - Capture

    /// Returns nil only when there is nothing to capture from at all.
    static func captureDecision(_ context: Context) -> Decision? {
        guard let systemDefault = context.systemDefault else {
            // Core Audio has no default input. Nothing we return can record,
            // and a recording attempt must not try to set the route itself.
            return nil
        }

        let manualChoiceMissing = !context.automaticallySelectDevice
            && context.savedSelectedDeviceUID != nil
            && !isSavedDeviceConnected(in: context)
        let preferred = preferredDevice(in: context)

        if let preferred, preferred.uniqueID != systemDefault.uniqueID {
            return Decision(
                device: systemDefault,
                fallbackReason: manualChoiceMissing ? .savedDeviceMissing : .routeNotApplied,
                preferredDevice: preferred
            )
        }

        if manualChoiceMissing {
            // The default is the best stand-in we have; there is no route to
            // reconcile, but the user's choice is still not being honoured.
            return Decision(device: systemDefault, fallbackReason: .savedDeviceMissing, preferredDevice: nil)
        }

        guard preferred != nil else {
            return Decision(device: systemDefault, fallbackReason: .noEligibleDevice, preferredDevice: nil)
        }

        return Decision(device: systemDefault, fallbackReason: nil, preferredDevice: nil)
    }

    static func isSavedDeviceConnected(in context: Context) -> Bool {
        guard let savedUID = context.savedSelectedDeviceUID else { return false }
        return context.availableDevices.contains { $0.uniqueID == savedUID }
    }

    // MARK: - Preference

    /// The device the user's preference resolves to right now, or nil when it
    /// cannot be honoured (saved device unplugged, or no eligible device).
    static func preferredDevice(in context: Context) -> Candidate? {
        if context.automaticallySelectDevice {
            return bestAutomaticDevice(in: context)
        }

        if let savedUID = context.savedSelectedDeviceUID,
           let saved = context.availableDevices.first(where: { $0.uniqueID == savedUID })
        {
            return saved
        }

        // A manual choice that is not connected falls back to the automatic
        // pick, exactly as if the user had never made it. The saved UID is kept
        // so plugging the device back in restores it.
        return bestAutomaticDevice(in: context)
    }

    /// The automatic choice. Prefers the current default, avoids the built-in
    /// microphone on a desk setup when an external one exists, and never
    /// returns nil while any device is listed: refusing to pick is what left
    /// clamshell users unable to record at all.
    static func bestAutomaticDevice(in context: Context) -> Candidate? {
        let devices = context.availableDevices
        guard !devices.isEmpty else { return context.systemDefault }

        if let systemDefault = context.systemDefault,
           devices.contains(systemDefault),
           !shouldAvoidAutomaticallySelecting(systemDefault, in: context)
        {
            return systemDefault
        }

        let allowed = devices.filter { !shouldAvoidAutomaticallySelecting($0, in: context) }
        let physical = allowed.filter { !$0.looksVirtual }

        if let pick = physical.first(where: \.looksLikeMicrophone)
            ?? physical.first
            ?? allowed.first
        {
            return pick
        }

        // Everything was ruled out by the desk heuristics. Recording from the
        // only microphone we have beats recording from nothing.
        if let systemDefault = context.systemDefault, devices.contains(systemDefault) {
            return systemDefault
        }
        return devices.first
    }

    static func shouldAvoidAutomaticallySelecting(_ device: Candidate, in context: Context) -> Bool {
        guard device.isBuiltIn else { return false }
        return context.clamshellClosed
            || !context.hasActiveBuiltInDisplay
            || shouldPreferExternalInputOverBuiltIn(in: context)
    }

    private static func shouldPreferExternalInputOverBuiltIn(in context: Context) -> Bool {
        context.hasActiveExternalDisplay && context.availableDevices.contains { !$0.isBuiltIn }
    }
}
