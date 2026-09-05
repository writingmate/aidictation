import Foundation

nonisolated enum MacCapturePhase: Equatable, Sendable {
    case preparing, ready, active, paused, retired
    case pausing(UUID), resuming(UUID)

    var acceptsWrites: Bool { self == .preparing || self == .ready || self == .active }

    mutating func beginPauseChange(paused: Bool, id: UUID) -> Bool {
        guard self == (paused ? .active : .paused) else { return false }
        self = paused ? .pausing(id) : .resuming(id)
        return true
    }

    mutating func completePauseChange(paused: Bool, id: UUID) -> Bool {
        guard self == (paused ? .pausing(id) : .resuming(id)) else { return false }
        self = paused ? .paused : .active
        return true
    }
    mutating func cancelPauseChange(id: UUID) {
        if self == .pausing(id) || self == .resuming(id) { self = .retired }
    }
}

