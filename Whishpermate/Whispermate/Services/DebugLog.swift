import Foundation
import OSLog

/// Debug logging utility that only logs in DEBUG builds
/// Automatically strips all logging from Release builds for privacy and security
enum DebugLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.whispermate.macos",
        category: "AIDictation"
    )

    private static func emit(_ message: String) {
        print(message)
        DebugLogFileWriter.shared.append(message)
    }

    /// Log a general debug message
    static func log(_ items: Any..., separator: String = " ", file: String = #file, line: Int = #line) {
        #if DEBUG
            let filename = (file as NSString).lastPathComponent
            let message = items.map { "\($0)" }.joined(separator: separator)
            emit("[\(filename):\(line)] \(message)")
        #endif
    }

    /// Log an info message with context
    static func info(_ items: Any..., separator: String = " ", context: String? = nil) {
        #if DEBUG
            let message = items.map { "\($0)" }.joined(separator: separator)
            if let context = context {
                emit("ℹ️ [\(context)] \(message)")
            } else {
                emit("ℹ️ \(message)")
            }
        #endif
    }

    /// Log a warning message
    static func warning(_ items: Any..., separator: String = " ", context: String? = nil) {
        #if DEBUG
            let message = items.map { "\($0)" }.joined(separator: separator)
            if let context = context {
                emit("⚠️ [\(context)] \(message)")
            } else {
                emit("⚠️ \(message)")
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
        DebugLogFileWriter.shared.append(fullMessage)
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
                emit("🌐 [API][\(endpoint)] \(message)")
            } else {
                emit("🌐 [API] \(message)")
            }
        #endif
    }
}

private final class DebugLogFileWriter {
    static let shared = DebugLogFileWriter()

    private let queue = DispatchQueue(label: "com.whispermate.debug-log-writer", qos: .utility)
    private let maxLogBytes: UInt64 = 5 * 1024 * 1024

    private init() {}

    func append(_ message: String) {
        #if DEBUG
            queue.async { [maxLogBytes] in
                guard
                    let logsDirectory = FileManager.default.urls(
                        for: .libraryDirectory,
                        in: .userDomainMask
                    ).first?.appendingPathComponent("Logs/AIDictation", isDirectory: true),
                    let data = "\(Self.timestamp()) \(message)\n".data(using: .utf8)
                else {
                    return
                }

                let logURL = logsDirectory.appendingPathComponent("debug.log")

                do {
                    try FileManager.default.createDirectory(
                        at: logsDirectory,
                        withIntermediateDirectories: true
                    )

                    if
                        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
                        let size = attributes[.size] as? NSNumber,
                        size.uint64Value > maxLogBytes
                    {
                        try? FileManager.default.removeItem(at: logURL)
                    }

                    if FileManager.default.fileExists(atPath: logURL.path) {
                        let handle = try FileHandle(forWritingTo: logURL)
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    } else {
                        try data.write(to: logURL, options: .atomic)
                    }
                } catch {
                    // Avoid recursive logging if the debug log file cannot be written.
                }
            }
        #endif
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
