import Foundation
#if canImport(WhisperMateShared)
    import WhisperMateShared
#endif

/// Auto mode's offline fallback for when cloud transcription is unreachable or
/// failing on the server, and the cooldown that keeps later recordings off the
/// cloud while it recovers.
///
/// It depends only on Foundation and `AppleAudioHTTPRecovery` so the rules can
/// be validated outside the app.
enum CloudOutageFallback {
    /// Whether a failed cloud upload means the service is unavailable right
    /// now. Only these failures switch a recording to the offline model.
    ///
    /// Rejections (401, 403, 404, 400, 422), oversized recordings, and
    /// unreadable responses describe this recording or this account. The
    /// offline model must not hide them, so they still fail as before.
    static func isCloudUnavailable(_ failure: AppleAudioHTTPRecovery.Failure) -> Bool {
        switch failure {
        case .transientRetriesExhausted, .transportUnavailable:
            return true
        case .permanentHTTP, .payloadTooLarge, .invalidTranscriptionResponse, .splitLimitReached:
            return false
        }
    }

    /// Whether a failed cloud attempt means the service is unavailable.
    ///
    /// - Parameters:
    ///   - failure: The classified upload failure, when the upload itself
    ///     failed.
    ///   - recognitionTimedOut: The attempt ran out its recognition deadline.
    ///     A hung or very slow service ends this way before its retries finish.
    ///   - networkWasConnected: The Mac was online when the attempt started,
    ///     so the time went to the cloud rather than to the offline model.
    static func isCloudUnavailable(
        failure: AppleAudioHTTPRecovery.Failure?,
        recognitionTimedOut: Bool,
        networkWasConnected: Bool
    ) -> Bool {
        if let failure {
            return isCloudUnavailable(failure)
        }
        return recognitionTimedOut && networkWasConnected
    }

    /// Whether a recording whose cloud attempt failed may be transcribed again
    /// with the offline model.
    ///
    /// - Parameters:
    ///   - isAutoMode: The user chose Auto. Online mode means the user asked
    ///     for cloud, and Offline mode never reaches the cloud.
    ///   - cloudUnavailable: `isCloudUnavailable` for the failure.
    ///   - runtimeSupported: This Mac can run the offline model.
    ///   - modelDownloaded: The offline model is already on disk. A fallback
    ///     must never start a download: it would fail during an outage and
    ///     pull a large file without asking.
    ///   - recognitionTextSaved: The cloud attempt already saved part of a
    ///     transcript. The store only accepts text that extends what is saved,
    ///     so a second, independent transcript cannot replace it.
    ///   - usesSpeakerLabels: Speaker labels already run on this Mac.
    static func shouldTranscribeOffline(
        isAutoMode: Bool,
        cloudUnavailable: Bool,
        runtimeSupported: Bool,
        modelDownloaded: Bool,
        recognitionTextSaved: Bool,
        usesSpeakerLabels: Bool
    ) -> Bool {
        isAutoMode
            && cloudUnavailable
            && runtimeSupported
            && modelDownloaded
            && !recognitionTextSaved
            && !usesSpeakerLabels
    }
}

/// Keeps Auto mode on the offline model for a while after the cloud fails, so
/// each recording during an outage does not first wait through the cloud's
/// retries.
///
/// There is no background check. When the cooldown ends, the next recording
/// tries the cloud again, and a real transcription is the test of whether the
/// service is back. A cloud success ends the cooldown and resets its length.
/// Live streaming still starts for every recording, so a working stream is
/// used as soon as the service recovers.
struct CloudOutageCooldown: Equatable {
    static let initialSeconds: TimeInterval = 60
    static let maximumSeconds: TimeInterval = 600

    private(set) var offlineUntil: Date?
    private(set) var consecutiveOutages = 0

    /// Whether recordings should go straight to the offline model at `now`.
    func prefersOffline(at now: Date) -> Bool {
        guard let offlineUntil else { return false }
        return now < offlineUntil
    }

    /// Records a cloud outage. Each outage in a row doubles the cooldown, from
    /// one minute up to ten.
    mutating func recordOutage(at now: Date) {
        consecutiveOutages += 1
        let doublings = min(consecutiveOutages - 1, 10)
        let seconds = min(
            Self.maximumSeconds,
            Self.initialSeconds * pow(2, Double(doublings))
        )
        offlineUntil = now.addingTimeInterval(seconds)
    }

    /// Records a cloud transcription that succeeded.
    mutating func recordCloudSuccess() {
        offlineUntil = nil
        consecutiveOutages = 0
    }
}
