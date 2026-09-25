import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw ValidationFailure.assertion(message)
    }
}

private func candidate(
    _ id: UUID,
    at seconds: TimeInterval,
    transcription: String? = "Hello there",
    isInProgress: Bool = false,
    canRetranscribe: Bool = true
) -> LastTranscriptionMenuState.Candidate {
    LastTranscriptionMenuState.Candidate(
        recordingID: id,
        timestamp: Date(timeIntervalSinceReferenceDate: seconds),
        transcription: transcription,
        isInProgress: isInProgress,
        canRetranscribe: canRetranscribe
    )
}

private func state(
    _ newest: LastTranscriptionMenuState.Candidate?,
    audioIsAvailable: Bool = true,
    appCanStartRetry: Bool = true
) -> LastTranscriptionMenuState {
    LastTranscriptionMenuState(
        newest: newest,
        audioIsAvailable: audioIsAvailable,
        appCanStartRetry: appCanStartRetry
    )
}

@main
private enum LastTranscriptionMenuValidator {
    static func main() throws {
        let older = UUID(uuidString: "0B8D3E43-3E0B-4B1B-8C8F-6F6A1B0A1111")!
        let newer = UUID(uuidString: "0B8D3E43-3E0B-4B1B-8C8F-6F6A1B0A2222")!
        let tied = UUID(uuidString: "0B8D3E43-3E0B-4B1B-8C8F-6F6A1B0A3333")!

        // The newest recording is chosen by timestamp, not by list position.
        try require(
            LastTranscriptionMenuState.newest(of: [
                candidate(older, at: 100),
                candidate(newer, at: 200),
            ])?.recordingID == newer,
            "The newest recording must win even when it is not first in History."
        )
        try require(
            LastTranscriptionMenuState.newest(of: [
                candidate(newer, at: 200),
                candidate(tied, at: 200),
            ])?.recordingID == newer,
            "A timestamp tie must keep the earlier (newest-first) History position."
        )
        try require(
            LastTranscriptionMenuState.newest(of: []) == nil,
            "Empty History has no newest recording."
        )

        // Empty History disables both items.
        let empty = state(nil)
        try require(empty.recordingID == nil, "Empty History must not target a recording.")
        try require(empty.copyText == nil, "Empty History must disable Copy.")
        try require(!empty.canRetry, "Empty History must disable Retry.")
        try require(
            empty.retryTitle == LastTranscriptionMenuState.retryTitle,
            "Empty History shows the normal Retry title."
        )

        // A finished recording can be copied and retried.
        let finished = state(candidate(newer, at: 200, transcription: "Final text"))
        try require(finished.recordingID == newer, "Both items must act on the newest recording.")
        try require(finished.copyText == "Final text", "Copy must use the saved transcript exactly.")
        try require(finished.canRetry, "A finished recording with saved audio can be retried.")
        try require(!finished.isRetrying, "A finished recording is not retrying.")

        // A failed recording has no text: Copy is off, Retry is on.
        let failed = state(candidate(newer, at: 200, transcription: nil))
        try require(failed.copyText == nil, "A recording without text must disable Copy.")
        try require(failed.canRetry, "A failed recording with saved audio can be retried.")

        // Whitespace-only text is nothing to copy.
        let blank = state(candidate(newer, at: 200, transcription: "  \n "))
        try require(blank.copyText == nil, "Whitespace-only text must disable Copy.")

        // While the newest recording is being transcribed, both items wait.
        let retrying = state(candidate(newer, at: 200, transcription: "Earlier text", isInProgress: true))
        try require(retrying.isRetrying, "An in-progress recording must report retrying.")
        try require(
            retrying.retryTitle == LastTranscriptionMenuState.retryingTitle,
            "An in-progress recording must show the Retrying title."
        )
        try require(!retrying.canRetry, "An in-progress recording cannot be retried again.")
        try require(retrying.copyText == nil, "Copy must not hand out text that is about to be replaced.")

        // Retry needs saved audio, a complete source, and an idle app.
        try require(
            !state(candidate(newer, at: 200), audioIsAvailable: false).canRetry,
            "Missing saved audio must disable Retry."
        )
        try require(
            !state(candidate(newer, at: 200, canRetranscribe: false)).canRetry,
            "A known-incomplete recording must disable Retry."
        )
        let busy = state(candidate(newer, at: 200), appCanStartRetry: false)
        try require(!busy.canRetry, "Retry must wait while the app is recording or transcribing.")
        try require(
            busy.copyText == "Hello there",
            "Copy of a finished recording stays available while the app is busy."
        )

        print("macOS last-transcription menu: PASS")
    }
}
