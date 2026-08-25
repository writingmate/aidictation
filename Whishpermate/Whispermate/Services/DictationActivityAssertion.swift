import Foundation

/// Holds an App Nap assertion for the lifetime of one dictation.
///
/// The overlay is a non-activating panel, so focus stays in the target app and
/// AIDictation is a *background* app for the entire dictation — the log says
/// "App went to background" immediately after the bubble appears. macOS then
/// applies App Nap: timer coalescing and QoS demotion.
///
/// A `sample` profile of a real dictation showed every dispatch worker thread
/// parked in `__workq_kernreturn` while ~12ms of measured work took 2–4s of
/// wall clock. The work was queued and not scheduled. Raising QoS on the hot
/// path helps, but a napped process can still be throttled, so the process also
/// declares that user-initiated work is in flight.
///
/// Assertions are reference counted: overlapping dictations hold one activity
/// and release it when the last one finishes.
@MainActor
enum DictationActivityAssertion {
    // MARK: - Private Properties

    private static var activity: NSObjectProtocol?
    private static var holders = 0

    // MARK: - Public API

    /// Declares a dictation in flight. Balance every call with `release()`.
    static func acquire() {
        holders += 1
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Dictation in flight"
        )
        DebugLog.info("App Nap assertion acquired", context: "DictationActivityAssertion")
    }

    /// Drops one holder, ending the assertion when the last one goes away.
    static func release() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0, let current = activity else { return }
        ProcessInfo.processInfo.endActivity(current)
        activity = nil
        DebugLog.info("App Nap assertion released", context: "DictationActivityAssertion")
    }

    /// Drops every holder. For teardown paths that cannot guarantee balance.
    static func releaseAll() {
        guard let current = activity else { holders = 0; return }
        ProcessInfo.processInfo.endActivity(current)
        activity = nil
        holders = 0
        DebugLog.info("App Nap assertion force-released", context: "DictationActivityAssertion")
    }
}
