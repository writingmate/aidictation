import Foundation

/// What the menu bar's "last transcription" items can do when the menu opens.
///
/// Both items act on the newest recording in History. Keeping the choice and
/// the enable rules here, free of AppKit and app state, lets a validator prove
/// them without launching the app.
struct LastTranscriptionMenuState: Equatable {
    /// The fields of one History recording that decide the menu items.
    struct Candidate: Equatable {
        let recordingID: UUID
        let timestamp: Date
        let transcription: String?
        let isInProgress: Bool
        let canRetranscribe: Bool
    }

    static let retryTitle = "Retry Last Transcription"
    static let retryingTitle = "Retrying Last Transcription…"
    static let copyTitle = "Copy Last Transcription"

    /// The recording both items act on.
    let recordingID: UUID?
    /// Text Copy puts on the clipboard; nil disables Copy.
    let copyText: String?
    /// The newest recording is being transcribed right now.
    let isRetrying: Bool
    let canRetry: Bool

    var retryTitle: String {
        isRetrying ? Self.retryingTitle : Self.retryTitle
    }

    /// The newest recording by timestamp. History is stored newest-first, so a
    /// tie keeps the earlier position.
    static func newest(of candidates: [Candidate]) -> Candidate? {
        var newest: Candidate?
        for candidate in candidates {
            if let current = newest, candidate.timestamp <= current.timestamp {
                continue
            }
            newest = candidate
        }
        return newest
    }

    /// - Parameters:
    ///   - newest: The newest History recording, or nil when History is empty.
    ///   - audioIsAvailable: The newest recording's saved audio exists on disk.
    ///   - appCanStartRetry: Nothing else is recording, transcribing, or
    ///     changing History.
    init(newest: Candidate?, audioIsAvailable: Bool, appCanStartRetry: Bool) {
        guard let newest else {
            recordingID = nil
            copyText = nil
            isRetrying = false
            canRetry = false
            return
        }

        recordingID = newest.recordingID
        isRetrying = newest.isInProgress

        let text = newest.transcription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        copyText = newest.isInProgress || text.isEmpty ? nil : newest.transcription

        canRetry = appCanStartRetry
            && !newest.isInProgress
            && newest.canRetranscribe
            && audioIsAvailable
    }
}
