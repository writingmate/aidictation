import Foundation

/// Millisecond timing across the stop-to-paste path.
///
/// The debug log only carries second granularity, which is enough to see that
/// several seconds vanish between the recording file being written and the
/// transcription request going out, but not enough to see where. This marks the
/// boundaries so the gap is attributable to a specific stage.
enum DictationStopwatch {
    // MARK: - Private Properties

    private static let lock = NSLock()
    private static var startedAt: CFAbsoluteTime?
    private static var lastMarkAt: CFAbsoluteTime?

    // MARK: - Public API

    /// Begins a new measurement at a hotkey edge.
    static func begin() {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        startedAt = now
        lastMarkAt = now
        DebugLog.info("⏱ 0ms — hotkey", context: "Stopwatch")
    }

    /// Records a boundary, reporting both the step cost and the running total.
    static func mark(_ label: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let sinceLast = (now - (lastMarkAt ?? startedAt)) * 1000
        let sinceStart = (now - startedAt) * 1000
        lastMarkAt = now
        DebugLog.info(
            "⏱ +\(String(format: "%.0f", sinceLast))ms (total \(String(format: "%.0f", sinceStart))ms) — \(label)",
            context: "Stopwatch"
        )
    }

    /// Ends the measurement so a later stray mark cannot attach to it.
    static func end(_ label: String) {
        mark(label)
        lock.lock()
        defer { lock.unlock() }
        startedAt = nil
        lastMarkAt = nil
    }
}
