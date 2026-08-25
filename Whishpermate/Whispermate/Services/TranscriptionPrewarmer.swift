import Foundation
import WhisperMateShared

/// Opens the TCP + TLS connection to the transcription host while the user is
/// still speaking, so the upload at key-release lands on a pooled connection.
///
/// The handshake is per TCP connection, not per process: `URLSession` pools by
/// (scheme, host, port), so a cheap request issued through the same transport
/// that later carries the audio leaves a warm connection behind. Servers close
/// idle keep-alives after a minute or two, which is why this fires at every
/// recording start rather than once at launch.
///
/// Entirely best-effort. A failed ping degrades to a cold upload; it never
/// blocks or fails a recording.
@MainActor
final class TranscriptionPrewarmer {
    // MARK: - Types

    private struct WarmHost: Equatable {
        let origin: String
        let warmedAt: Date
    }

    // MARK: - Private Properties

    private var lastWarm: WarmHost?
    private var inFlight: Task<Void, Never>?

    // MARK: - Constants

    private enum Constants {
        /// Below this, the pooled connection is almost certainly still open and
        /// another ping would be pure waste.
        static let reuseWindow: TimeInterval = 20

        /// A ping that has not completed by the time the user stops talking is
        /// no longer useful; it must never outlive the recording it warms.
        static let timeout: TimeInterval = 5
    }

    // MARK: - Initialization

    static let shared = TranscriptionPrewarmer()

    private init() {}

    // MARK: - Public API

    /// Warms the connection for `endpoint`. Returns immediately; the ping runs
    /// detached and its result only ever reaches the debug log.
    func prewarm(endpoint: String) {
        guard let origin = Self.origin(of: endpoint) else {
            DebugLog.info("Prewarm skipped: no usable origin in \(endpoint)", context: "TranscriptionPrewarmer")
            return
        }

        if let lastWarm,
           lastWarm.origin == origin,
           Date().timeIntervalSince(lastWarm.warmedAt) < Constants.reuseWindow
        {
            DebugLog.info("Prewarm skipped: \(origin) warmed recently", context: "TranscriptionPrewarmer")
            return
        }

        inFlight?.cancel()
        inFlight = Task { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let warmed = await Self.ping(origin: origin)
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

            guard !Task.isCancelled else { return }
            guard let self else { return }

            if warmed {
                self.lastWarm = WarmHost(origin: origin, warmedAt: Date())
                DebugLog.info(
                    "Prewarmed \(origin) in \(String(format: "%.0f", elapsed))ms",
                    context: "TranscriptionPrewarmer"
                )
            } else {
                // Leave lastWarm untouched so the next recording retries.
                DebugLog.info(
                    "Prewarm ping failed for \(origin) after \(String(format: "%.0f", elapsed))ms",
                    context: "TranscriptionPrewarmer"
                )
            }
            self.inFlight = nil
        }
    }

    /// Drops the warm marker so the next `prewarm` reconnects. Call when the
    /// endpoint or credentials change underneath us.
    func invalidate() {
        inFlight?.cancel()
        inFlight = nil
        lastWarm = nil
    }

    // MARK: - Private Methods

    /// A HEAD against the origin root rather than the transcription path: same
    /// pool entry, none of the server-side work.
    private static func ping(origin: String) async -> Bool {
        guard let url = URL(string: origin) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = Constants.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            // Must go through the same transport that carries the audio, or the
            // connection lands in a pool the upload never reads from.
            let response = try await AppleAudioHTTPTransport.shared.response(for: request)
            // Any status proves the connection completed. A 404 or 405 on the
            // root is a warm socket just the same.
            return response.statusCode > 0
        } catch {
            return false
        }
    }

    private static func origin(of endpoint: String) -> String? {
        guard let components = URLComponents(string: endpoint),
              let scheme = components.scheme,
              let host = components.host,
              !host.isEmpty
        else { return nil }

        var origin = "\(scheme)://\(host)"
        if let port = components.port {
            origin += ":\(port)"
        }
        return origin
    }
}
