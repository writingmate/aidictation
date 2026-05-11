import Foundation
import OSLog

/// Debug logging utility that only logs in DEBUG builds
/// Automatically strips all logging from Release builds for privacy and security
enum DebugLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.whispermate.macos",
        category: "AIDictation"
    )

    /// Log a general debug message
    static func log(_ items: Any..., separator: String = " ", file: String = #file, line: Int = #line) {
        #if DEBUG
            let filename = (file as NSString).lastPathComponent
            let message = items.map { "\($0)" }.joined(separator: separator)
            print("[\(filename):\(line)] \(message)")
        #endif
    }

    /// Log an info message with context
    static func info(_ items: Any..., separator: String = " ", context: String? = nil) {
        #if DEBUG
            let message = items.map { "\($0)" }.joined(separator: separator)
            if let context = context {
                print("ℹ️ [\(context)] \(message)")
            } else {
                print("ℹ️ \(message)")
            }
        #endif
    }

    /// Log a warning message
    static func warning(_ items: Any..., separator: String = " ", context: String? = nil) {
        #if DEBUG
            let message = items.map { "\($0)" }.joined(separator: separator)
            if let context = context {
                print("⚠️ [\(context)] \(message)")
            } else {
                print("⚠️ \(message)")
            }
        #endif
    }

    /// Log an error message (always logs, even in Release)
    static func error(_ items: Any..., separator: String = " ", context: String? = nil) {
        let message = items.map { "\($0)" }.joined(separator: separator)
        let fullMessage: String
        if let context = context {
            fullMessage = "❌ [\(context)] \(message)"
        } else {
            fullMessage = "❌ \(message)"
        }

        print(fullMessage)
        logger.error("\(fullMessage, privacy: .public)")
        SentryTelemetry.captureError(message, context: context)
    }

    /// Log sensitive data (only in DEBUG, never in Release)
    static func sensitive(_ items: Any..., separator: String = " ", context: String? = nil) {
        #if DEBUG
            let message = items.map { "\($0)" }.joined(separator: separator)
            if let context = context {
                print("🔒 [SENSITIVE][\(context)] \(message)")
            } else {
                print("🔒 [SENSITIVE] \(message)")
            }
        #endif
    }

    /// Log API-related information (only in DEBUG)
    static func api(_ items: Any..., separator: String = " ", endpoint: String? = nil) {
        #if DEBUG
            let message = items.map { "\($0)" }.joined(separator: separator)
            if let endpoint = endpoint {
                print("🌐 [API][\(endpoint)] \(message)")
            } else {
                print("🌐 [API] \(message)")
            }
        #endif
    }
}
