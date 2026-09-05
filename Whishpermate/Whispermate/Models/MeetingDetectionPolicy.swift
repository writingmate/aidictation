import Foundation

nonisolated struct MeetingDetectionPolicy {
    struct Candidate: Equatable, Identifiable, Sendable {
        let appBundleID: String
        let appName: String
        let title: String
        var id: String { appBundleID + ":" + title }
    }
    enum Observation: Sendable { case call(Candidate), absent, unknown }
    enum Event: Equatable { case detected(Candidate), ended(Candidate) }
    struct RecordingOwner {
        let callID: String
        let noteID: UUID
        let recordingID: UUID

        func matches(call: Candidate, noteID: UUID?, recordingID: UUID?) -> Bool {
            callID == call.id && self.noteID == noteID && self.recordingID == recordingID
        }
    }
    private(set) var current: Candidate?
    private var pending: Candidate?
    private var firstSeen: Date?
    private var absentSince: Date?
    private var promptWasOffered = false
    private var currentWasConfirmed = false

    mutating func claimPrompt(canStartRecording: Bool) -> Candidate? {
        guard canStartRecording, currentWasConfirmed, !promptWasOffered, let current else { return nil }
        promptWasOffered = true
        return current
    }

    mutating func observe(_ observation: Observation, now: Date) -> Event? {
        switch observation {
        case .unknown:
            currentWasConfirmed = false
            absentSince = nil
            pending = nil
            firstSeen = nil
            return nil
        case .call(let candidate):
            currentWasConfirmed = false
            if let current, current.appBundleID != candidate.appBundleID {
                if pending != candidate { pending = candidate; firstSeen = now }
                return endCurrentAfterGrace(now: now)
            }
            absentSince = nil
            if current?.appBundleID == candidate.appBundleID {
                currentWasConfirmed = true
                pending = nil
                firstSeen = nil
                return nil
            }
            if pending != candidate { pending = candidate; firstSeen = now; return nil }
            guard let firstSeen, now.timeIntervalSince(firstSeen) >= 4 else { return nil }
            current = candidate
            currentWasConfirmed = true
            promptWasOffered = false
            pending = nil
            self.firstSeen = nil
            return .detected(candidate)
        case .absent:
            currentWasConfirmed = false
            pending = nil
            firstSeen = nil
            return endCurrentAfterGrace(now: now)
        }
    }

    private mutating func endCurrentAfterGrace(now: Date) -> Event? {
        guard let current else { return nil }
        if absentSince == nil { absentSince = now }
        guard let absentSince, now.timeIntervalSince(absentSince) >= 20 else { return nil }
        self.current = nil
        promptWasOffered = false
        self.absentSince = nil
        return .ended(current)
    }

    static func isCallWindow(appBundleID: String, title: String, controls: [String]) -> Bool {
        let normalized = controls.map { $0.lowercased() }
        let hasLeave = normalized.contains { value in
            ["leave call", "leave meeting", "end call", "end meeting", "leave huddle", "hang up"].contains(where: value.contains)
        }
        if hasLeave { return true }
        let title = title.lowercased()
        if appBundleID == "us.zoom.xos" { return title == "zoom meeting" || title == "zoom webinar" }
        return false
    }
}
