import Foundation

/// Values that change the History row or detail content for one recording.
/// Keeping this separate from `Recording` identity preserves list selection
/// while still refreshing terminal status, transcript, and failure changes.
struct HistoryPresentationIdentity: Hashable {
    let recordingID: UUID
    let status: String
    let transcription: String?
    let errorMessage: String?
}
