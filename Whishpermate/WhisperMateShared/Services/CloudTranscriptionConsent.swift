import Foundation

public enum CloudTranscriptionConsent {
    public static let requiredErrorMessage = "Allow cloud transcription before using cloud mode."
    public static let alertTitle = "Cloud Transcription Permission"
    public static let disclosureMessage = "Before using cloud mode, please allow AIDictation to send your voice recording and transcript to AIDictation's cloud transcription service, which uses Groq to create and format the transcript. Offline mode keeps transcription on this device."

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
