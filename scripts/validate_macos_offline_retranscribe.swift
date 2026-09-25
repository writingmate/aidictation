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

@main
private enum OfflineRetranscribeValidator {
    static func main() throws {
        let ready = OfflineRetranscribeOption(runtimeSupported: true, modelDownloaded: true)
        try require(ready.isEnabled, "A downloaded offline model must enable offline re-transcription.")
        try require(
            ready.title == OfflineRetranscribeOption.offlineTitle,
            "A ready offline model shows the plain Offline title."
        )

        let notDownloaded = OfflineRetranscribeOption(runtimeSupported: true, modelDownloaded: false)
        try require(
            !notDownloaded.isEnabled,
            "Offline re-transcription must not start a model download."
        )
        try require(
            notDownloaded.title == OfflineRetranscribeOption.needsDownloadTitle,
            "A missing offline model must say where to download it."
        )

        let unsupported = OfflineRetranscribeOption(runtimeSupported: false, modelDownloaded: true)
        try require(!unsupported.isEnabled, "An unsupported Mac must disable offline re-transcription.")
        try require(
            unsupported.title == OfflineRetranscribeOption.unsupportedTitle,
            "An unsupported Mac must say what it needs."
        )

        let unsupportedAndMissing = OfflineRetranscribeOption(runtimeSupported: false, modelDownloaded: false)
        try require(
            unsupportedAndMissing.title == OfflineRetranscribeOption.unsupportedTitle,
            "An unsupported Mac reports the system requirement before the download."
        )

        for title in [
            OfflineRetranscribeOption.onlineTitle,
            OfflineRetranscribeOption.offlineTitle,
            OfflineRetranscribeOption.needsDownloadTitle,
            OfflineRetranscribeOption.unsupportedTitle,
        ] {
            for internalName in ["Parakeet", "Soniox", "FluidAudio", "Core ML", "provider"] {
                try require(
                    !title.localizedCaseInsensitiveContains(internalName),
                    "User-facing title \"\(title)\" exposes the internal name \(internalName)."
                )
            }
        }

        print("macOS offline re-transcription option: PASS")
    }
}
