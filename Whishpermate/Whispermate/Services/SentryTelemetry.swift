import Foundation

#if canImport(Sentry)
import Sentry
#endif
import WhisperMateShared

#if canImport(Sentry)
enum SentryTelemetry {
    private static var started = false

    static func start() {
        guard !started else { return }

        guard let dsn = SecretsLoader.getValue(for: "SENTRY_DSN") ?? SecretsLoader.getValue(for: "SentryDSN"),
              !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            DebugLog.warning("Sentry DSN missing; crash reporting disabled", context: "Sentry")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environmentName
            options.releaseName = releaseName
            options.maxBreadcrumbs = 100
            options.enableAutoSessionTracking = true
            options.tracesSampleRate = 0.05
            options.diagnosticLevel = .warning
        }

        started = true
        configureStaticContext()
        addBreadcrumb("sentry_started", category: "app.lifecycle")
    }

    static func addBreadcrumb(
        _ message: String,
        category: String,
        level: SentryLevel = .info,
        data: [String: Any] = [:]
    ) {
        guard started else { return }

        let breadcrumb = Breadcrumb(level: level, category: category)
        breadcrumb.message = message
        breadcrumb.type = "debug"
        breadcrumb.data = data
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    static func captureError(_ message: String, context: String?) {
        guard started else { return }
        guard shouldCaptureIssue(message, context: context) else { return }

        addBreadcrumb(
            message,
            category: context.map { "app.\($0)" } ?? "app.error",
            level: .error
        )
        SentrySDK.capture(message: context.map { "[\($0)] \(message)" } ?? message)
    }

    private static func shouldCaptureIssue(_ message: String, context: String?) -> Bool {
        guard let context else { return true }

        switch context {
        case "HotkeyDiagnostics":
            return false
        case "FnKeyMonitor":
            return false
        case "DockIconManager":
            return false
        case "HotkeyManager LOG":
            return !message.contains("Accessibility permission")
                && !message.contains("event tap")
                && !message.contains("hotkey")
        default:
            return true
        }
    }

    static func recordAudioDeviceEvent(
        _ event: String,
        device: AudioDeviceManager.AudioDevice?,
        mode: String? = nil,
        fallback: Bool = false
    ) {
        var data: [String: Any] = [
            "fallback": fallback,
            "device_kind": deviceKind(device),
        ]
        if let mode {
            data["mode"] = mode
        }
        addBreadcrumb(event, category: "audio.device", data: data)

        guard started else { return }
        SentrySDK.configureScope { scope in
            scope.setTag(value: deviceKind(device), key: "audio.input.kind")
            scope.setTag(value: fallback ? "true" : "false", key: "audio.input.fallback")
            if let mode {
                scope.setTag(value: mode, key: "audio.input.mode")
            }
        }
    }

    static func recordAudioEngineEvent(_ event: String, reason: String? = nil) {
        var data: [String: Any] = [:]
        if let reason {
            data["reason"] = reason
        }
        addBreadcrumb(event, category: "audio.engine", data: data)
    }

    static func recordOnboardingStep(_ event: String, step: String, data: [String: Any] = [:]) {
        var payload = data
        payload["step"] = step
        addBreadcrumb(event, category: "onboarding", data: payload)

        guard started else { return }
        SentrySDK.configureScope { scope in
            scope.setTag(value: step, key: "onboarding.step")
            for (key, value) in data {
                guard let tagValue = tagValue(from: value) else { continue }
                scope.setTag(value: tagValue, key: "onboarding.\(key)")
            }
        }
    }

    private static func configureStaticContext() {
        SentrySDK.configureScope { scope in
            scope.setTag(value: architectureName, key: "device.arch")
            scope.setTag(value: ProcessInfo.processInfo.operatingSystemVersionString, key: "os.version")
            scope.setTag(value: Bundle.main.bundleIdentifier ?? "unknown", key: "app.bundle_id")
        }
    }

    private static func tagValue(from value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let float as Float:
            return String(float)
        case let strings as [String]:
            return strings.joined(separator: ",")
        default:
            return nil
        }
    }

    private static func deviceKind(_ device: AudioDeviceManager.AudioDevice?) -> String {
        guard let device else { return "none" }

        let name = device.name.lowercased()
        if name.contains("built-in") || name.contains("macbook") || name.contains("internal microphone") {
            return "built_in"
        }
        if name.contains("airpods") || name.contains("bluetooth") || name.contains("headphone") || name.contains("headset") {
            return "bluetooth"
        }
        if name.contains("blackhole") || name.contains("loopback") || name.contains("soundflower") || name.contains("aggregate") {
            return "virtual"
        }
        if name.contains("usb") {
            return "usb"
        }
        if name.contains("display") || name.contains("monitor") {
            return "display"
        }
        return "external"
    }

    private static var releaseName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.whispermate.macos"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(bundleID)@\(version)+\(build)"
    }

    private static var environmentName: String {
        #if DEBUG
            return "debug"
        #else
            return "production"
        #endif
    }

    private static var architectureName: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }
}
#else
enum SentryTelemetry {
    static func start() {
        DebugLog.warning("Sentry module unavailable; crash reporting disabled", context: "Sentry")
    }

    static func addBreadcrumb(
        _: String,
        category _: String,
        data _: [String: Any] = [:]
    ) {}

    static func captureError(_: String, context _: String?) {}

    static func recordAudioDeviceEvent(
        _: String,
        device _: AudioDeviceManager.AudioDevice?,
        mode _: String? = nil,
        fallback _: Bool = false
    ) {}

    static func recordAudioEngineEvent(_: String, reason _: String? = nil) {}

    static func recordOnboardingStep(_: String, step _: String, data _: [String: Any] = [:]) {}
}
#endif
