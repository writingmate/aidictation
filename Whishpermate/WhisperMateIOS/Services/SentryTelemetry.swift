import Foundation

#if canImport(Sentry)
import Sentry
#endif
import WhisperMateShared

#if canImport(Sentry)
enum SentryTelemetry {
    private enum Constants {
        static let defaultDSN = "https://6ed8609739f2bb7b446805e666990c8a@o4505732389470208.ingest.us.sentry.io/4511373194166272"
        static let tracesSampleRate = 0.05
    }

    private static var started = false

    static func start() {
        guard !started else { return }

        let dsn = SecretsLoader.getValue(for: "SENTRY_DSN_IOS")
            ?? SecretsLoader.getValue(for: "SENTRY_DSN")
            ?? SecretsLoader.getValue(for: "SentryDSN")
            ?? Constants.defaultDSN

        guard !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DebugLog.warning("Sentry DSN missing; crash reporting disabled", context: "Sentry")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environmentName
            options.releaseName = releaseName
            options.maxBreadcrumbs = 100
            options.enableAutoSessionTracking = true
            options.tracesSampleRate = Constants.tracesSampleRate
            options.diagnosticLevel = .warning
        }

        started = true
        configureStaticContext()
        CrashReporter.captureErrorHandler = { message, context, feature in
            captureError(message, context: context, feature: feature)
        }
        CrashReporter.captureExceptionHandler = { error, context, feature in
            captureException(error, context: context, feature: feature)
        }
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

    static func captureError(_ message: String, context: String?, feature: String? = nil) {
        guard started else { return }
        guard shouldCaptureIssue(message, context: context) else { return }

        let resolvedFeature = feature ?? featureName(from: context)
        addBreadcrumb(
            message,
            category: context.map { "app.\($0)" } ?? "app.error",
            level: .error
        )
        SentrySDK.capture(message: context.map { "[\($0)] \(message)" } ?? message) { scope in
            scope.setTag(value: "ios", key: "platform")
            scope.setTag(value: resolvedFeature, key: "feature")
            if let context {
                scope.setTag(value: context, key: "error.context")
            }
        }
    }

    static func captureException(_ error: Error, context: String?, feature: String? = nil) {
        guard started else { return }

        let resolvedFeature = feature ?? featureName(from: context)
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: "ios", key: "platform")
            scope.setTag(value: resolvedFeature, key: "feature")
            if let context {
                scope.setTag(value: context, key: "error.context")
            }
        }
    }

    private static func shouldCaptureIssue(_ message: String, context: String?) -> Bool {
        let haystack = "\(context ?? "") \(message)".lowercased()
        if haystack.contains("hotkey") || haystack.contains("event tap") {
            return false
        }
        return true
    }

    private static func featureName(from context: String?) -> String {
        guard let context else { return "app" }
        let lowered = context.lowercased()
        if lowered.contains("auth") || lowered.contains("supabase") || lowered.contains("sign") {
            return "auth"
        }
        if lowered.contains("transcri") || lowered.contains("openai") || lowered.contains("realtime") {
            return "transcription"
        }
        if lowered.contains("clipboard") || lowered.contains("insert") || lowered.contains("paste") || lowered.contains("keyboard") {
            return "text_insert"
        }
        return context
    }

    private static func configureStaticContext() {
        SentrySDK.configureScope { scope in
            scope.setTag(value: "ios", key: "platform")
            scope.setTag(value: architectureName, key: "device.arch")
            scope.setTag(value: ProcessInfo.processInfo.operatingSystemVersionString, key: "os.version")
            scope.setTag(value: Bundle.main.bundleIdentifier ?? "unknown", key: "app.bundle_id")
        }
    }

    private static var releaseName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.whispermate.ios"
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

    static func captureError(_: String, context _: String?, feature _: String? = nil) {}

    static func captureException(_: Error, context _: String?, feature _: String? = nil) {}
}
#endif
