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

private func identity(
    id: UUID,
    status: String,
    transcription: String? = nil,
    errorMessage: String? = nil
) -> HistoryPresentationIdentity {
    HistoryPresentationIdentity(
        recordingID: id,
        status: status,
        transcription: transcription,
        errorMessage: errorMessage
    )
}

@main
private enum HistoryRowRefreshValidator {
    static func main() throws {
        let recordingID = UUID(uuidString: "9A3ACCC5-F758-4B3F-B5A6-6CFEC8CE7733")!
        let processing = identity(id: recordingID, status: "processing")
        let retrying = identity(id: recordingID, status: "retrying", transcription: "Earlier text")
        let success = identity(id: recordingID, status: "success", transcription: "Finished text")
        let failed = identity(
            id: recordingID,
            status: "failed",
            errorMessage: "Transcription stopped"
        )
        let cancelled = identity(id: recordingID, status: "cancelled")

        try require(processing != success, "processing to success did not refresh the presentation")
        try require(processing != failed, "processing to failed did not refresh the presentation")
        try require(processing != cancelled, "processing to cancelled did not refresh the presentation")
        try require(retrying != success, "retrying to success did not refresh the presentation")
        try require(
            success == identity(id: recordingID, status: "success", transcription: "Finished text"),
            "an unchanged completed row acquired unrelated identity churn"
        )
        try require(
            failed == identity(
                id: recordingID,
                status: "failed",
                errorMessage: "Transcription stopped"
            ),
            "an unchanged failed row acquired unrelated identity churn"
        )
        try require(
            success != identity(id: recordingID, status: "success", transcription: "Corrected text"),
            "a same-status transcript correction did not refresh the presentation"
        )
        try require(
            failed != identity(id: recordingID, status: "failed", errorMessage: "Network unavailable"),
            "a same-status failure-message correction did not refresh the presentation"
        )
        try require(
            success != identity(id: UUID(), status: "success", transcription: "Finished text"),
            "different recordings share a presentation identity"
        )

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let historyViewSource = try String(
            contentsOf: root.appendingPathComponent(
                "Whishpermate/Whispermate/Views/HistoryMasterDetailView.swift"
            ),
            encoding: .utf8
        )
        let integrationCount = historyViewSource
            .components(separatedBy: ".id(recording.historyPresentationIdentity)")
            .count - 1

        try require(
            integrationCount == 2,
            "the deterministic identity must guard both History sidebar and detail content"
        )
        try require(
            !historyViewSource.contains("hashValue"),
            "History refresh identity must not depend on process-random string hashes"
        )

        print("macOS History row refresh contracts passed")
    }
}
