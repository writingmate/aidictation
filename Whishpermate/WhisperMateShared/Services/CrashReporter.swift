import Foundation

/// Platform apps register a Sentry sink here so shared auth, transcription,
/// and keyboard code can report high-value failures without linking Sentry
/// into WhisperMateShared.
public enum CrashReporter {
    public static var captureErrorHandler: ((_ message: String, _ context: String?, _ feature: String?) -> Void)?
    public static var captureExceptionHandler: ((_ error: Error, _ context: String?, _ feature: String?) -> Void)?

    public static func captureError(_ message: String, context: String? = nil, feature: String? = nil) {
        captureErrorHandler?(message, context, feature)
    }

    public static func captureException(_ error: Error, context: String? = nil, feature: String? = nil) {
        captureExceptionHandler?(error, context, feature)
    }
}
