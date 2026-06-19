import Foundation

public enum CloudTranscriptionConsent {
    public static let requiredErrorMessage = "Allow cloud transcription before using cloud mode."

    private static let consentKey = "cloud_transcription_consent_granted"

    public static var isGranted: Bool {
        AppDefaults.shared.bool(forKey: consentKey)
    }

    public static func grant() {
        AppDefaults.shared.set(true, forKey: consentKey)
    }

    public static func revoke() {
        AppDefaults.shared.set(false, forKey: consentKey)
    }
}
