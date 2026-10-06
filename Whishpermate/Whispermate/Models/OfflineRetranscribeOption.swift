import Foundation

/// The Offline choice in History's Re-transcribe menu.
///
/// Offline re-transcription runs the saved recording through the model on this
/// Mac, so it works when the internet is down. It is offered only when that
/// model is already downloaded: an offline retry must never start a download,
/// which fails without internet and pulls a large file without asking when
/// online.
struct OfflineRetranscribeOption: Equatable {
    static let onlineTitle = "Online"
    static let offlineTitle = "Offline"
    static let needsDownloadTitle = "Offline (download the offline model in Settings)"
    static let unsupportedTitle = "Offline (requires macOS 14 or later)"

    let title: String
    let isEnabled: Bool

    /// - Parameters:
    ///   - runtimeSupported: This Mac can run the offline model.
    ///   - modelDownloaded: The offline model files are on disk.
    init(runtimeSupported: Bool, modelDownloaded: Bool) {
        if !runtimeSupported {
            title = Self.unsupportedTitle
            isEnabled = false
        } else if !modelDownloaded {
            title = Self.needsDownloadTitle
            isEnabled = false
        } else {
            title = Self.offlineTitle
            isEnabled = true
        }
    }
}
