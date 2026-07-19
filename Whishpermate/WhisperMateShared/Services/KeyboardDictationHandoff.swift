import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// A durable, app-group handoff between the custom keyboard and the containing app.
///
/// `sessionID` identifies the user-visible dictation session. `attemptID` identifies one
/// concrete try, while `generation` prevents callbacks from an older try from mutating a
/// newer one. The containing app must echo the complete identity on every acknowledgement.
public enum KeyboardDictationHandoff {
    public enum PersistenceError: Error, Equatable, Sendable {
        case storageUnavailable
        case journalReadFailed
        case journalCorrupt
        case journalWriteFailed
        case generationExhausted
        case activeAttemptExists
    }

    public enum Command: String, Codable, Sendable {
        case start
        case stop
        case cancel

        /// Kept for compatibility with already-delivered Live Activity intents.
        case shutdown
    }

    public enum Phase: String, Codable, CaseIterable, Sendable {
        case preparing
        case recording
        case finalizing
        case processing
        case succeeded
        case failed
        case cancelled

        public var isTerminal: Bool {
            switch self {
            case .succeeded, .failed, .cancelled:
                return true
            case .preparing, .recording, .finalizing, .processing:
                return false
            }
        }
    }

    public enum HostReconciliationAction: Equatable, Sendable {
        case none
        case stop
        case cancel
    }

    public struct AttemptIdentity: Codable, Hashable, Sendable {
        public let sessionID: String
        public let attemptID: String
        public let generation: UInt64

        public init(sessionID: String, attemptID: String, generation: UInt64) {
            self.sessionID = sessionID
            self.attemptID = attemptID
            self.generation = generation
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public let identity: AttemptIdentity
        public let phase: Phase
        public let recordingID: String?
        public let resultText: String?
        public let userMessage: String?
        public let createdAt: Date
        public let updatedAt: Date
        public let resultConsumed: Bool
        public let hostAcknowledged: Bool
        public let deadlineAt: Date?

        fileprivate init(
            identity: AttemptIdentity,
            phase: Phase,
            recordingID: String?,
            resultText: String?,
            userMessage: String?,
            createdAt: Date,
            updatedAt: Date,
            resultConsumed: Bool,
            hostAcknowledged: Bool,
            deadlineAt: Date?
        ) {
            self.identity = identity
            self.phase = phase
            self.recordingID = recordingID
            self.resultText = resultText
            self.userMessage = userMessage
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.resultConsumed = resultConsumed
            self.hostAcknowledged = hostAcknowledged
            self.deadlineAt = deadlineAt
        }
    }

    public struct CommandEnvelope: Codable, Equatable, Sendable {
        public let command: Command
        public let identity: AttemptIdentity
        public let sequence: UInt64
        public let createdAt: Date

        fileprivate init(command: Command, identity: AttemptIdentity, sequence: UInt64, createdAt: Date) {
            self.command = command
            self.identity = identity
            self.sequence = sequence
            self.createdAt = createdAt
        }
    }

    public static let appGroupIdentifier = "group.com.whispermate.shared"
    public static let openAppNotification = Notification.Name("KeyboardDictationHandoffOpenApp")
    public static let stopAppNotification = Notification.Name("KeyboardDictationHandoffStopApp")

    /// The keyboard uses these deadlines to guarantee that every visible busy state ends.
    public static let startAcknowledgementTimeout: TimeInterval = 12
    public static let stopAcknowledgementTimeout: TimeInterval = 15
    public static let resultTimeout: TimeInterval = 600
    public static let pollingInterval: TimeInterval = 0.25
    public static let recordingHeartbeatTimeout: TimeInterval = 5

    private struct Journal: Codable {
        var schemaVersion = 2
        var generation: UInt64
        var nextCommandSequence: UInt64
        var snapshot: Snapshot?
        var commands: [CommandEnvelope]
    }

    private enum JournalLoad {
        case missing
        case loaded(Journal)
        case failed(PersistenceError)
    }

    private struct MeterPayload: Codable {
        let identity: AttemptIdentity?
        let sessionID: String?
        let audioLevel: Float
        let frequencyBands: [Float]
        let timestamp: Date
    }

    private static let journalMirrorKey = "keyboardDictation.journal.v2"
    private static let journalFileName = "KeyboardDictationHandoff.v2.json"
    private static let meterPayloadKey = "keyboardDictation.meter.v2"
    private static let appReadyTimestampKey = "keyboardDictation.appReadyTimestamp"
    private static let diagnosticsKey = "keyboardDictation.diagnostics"

    // Legacy keys are read during a rolling app/extension update and removed on terminal cleanup.
    private static let pendingCommandKey = "keyboardDictation.pendingCommand"
    private static let pendingCommandSessionIDKey = "keyboardDictation.pendingCommandSessionID"
    private static let pendingCommandTimestampKey = "keyboardDictation.pendingCommandTimestamp"
    private static let pendingCommandQueueKey = "keyboardDictation.pendingCommandQueue"
    private static let pendingTextKey = "keyboardDictation.pendingText"
    private static let pendingTextSessionIDKey = "keyboardDictation.pendingTextSessionID"
    private static let pendingTextTimestampKey = "keyboardDictation.pendingTextTimestamp"
    private static let activeSessionIDKey = "keyboardDictation.activeSessionID"
    private static let activeSessionTimestampKey = "keyboardDictation.activeSessionTimestamp"
    private static let meterSessionIDKey = "keyboardDictation.meterSessionID"
    private static let meterAudioLevelKey = "keyboardDictation.meterAudioLevel"
    private static let meterFrequencyBandsKey = "keyboardDictation.meterFrequencyBands"
    private static let meterTimestampKey = "keyboardDictation.meterTimestamp"

    private static let commandTTL: TimeInterval = 30
    private static let pendingTextTTL: TimeInterval = 120
    private static let meterTTL: TimeInterval = 2
    private static let appReadyTTL: TimeInterval = 2
    private static let diagnosticsLimit = 120
    private static let lockAcquisitionTimeout: TimeInterval = 1
    private static let lockRetryInterval: TimeInterval = 0.01
    private static let processLock = NSLock()

    public static var defaults: UserDefaults {
        if let testSuite = ProcessInfo.processInfo.environment["AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE"],
           !testSuite.isEmpty,
           let testDefaults = UserDefaults(suiteName: testSuite)
        {
            return testDefaults
        }
        return UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    public static func makeDictationURL(sessionID: String) -> URL? {
        URL(string: "aidictation://keyboard-dictation?session=\(sessionID)")
    }

    public static func makeStopDictationURL(sessionID: String) -> URL? {
        URL(string: "aidictation://keyboard-dictation-stop?session=\(sessionID)")
    }

    /// Persists a new attempt before any deep link, command, recorder, or network work starts.
    @discardableResult
    public static func beginAttempt(
        sessionID: String = UUID().uuidString,
        attemptID: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> AttemptIdentity {
        try withThrowingTransaction { defaults in
            let previous: Journal?
            switch loadJournal() {
            case .missing:
                previous = nil
            case let .loaded(journal):
                previous = journal
            case let .failed(error):
                throw error
            }
            let baseGeneration = previous?.generation ?? 0
            guard baseGeneration < UInt64.max else {
                throw PersistenceError.generationExhausted
            }
            if let activeSnapshot = previous?.snapshot, !activeSnapshot.phase.isTerminal {
                throw PersistenceError.activeAttemptExists
            }
            let generation = baseGeneration + 1
            let identity = AttemptIdentity(
                sessionID: sessionID,
                attemptID: attemptID,
                generation: generation
            )
            let snapshot = Snapshot(
                identity: identity,
                phase: .preparing,
                recordingID: nil,
                resultText: nil,
                userMessage: nil,
                createdAt: now,
                updatedAt: now,
                resultConsumed: false,
                hostAcknowledged: false,
                deadlineAt: now.addingTimeInterval(startAcknowledgementTimeout)
            )
            let carriedCancellations: [CommandEnvelope]
            if previous?.snapshot?.phase == .cancelled {
                carriedCancellations = previous?.commands.filter {
                    $0.command == .cancel && commandIsFresh($0, now: now)
                } ?? []
            } else {
                carriedCancellations = []
            }
            let journal = Journal(
                generation: generation,
                nextCommandSequence: carriedCancellations.isEmpty
                    ? 1
                    : previous?.nextCommandSequence ?? 1,
                snapshot: snapshot,
                commands: carriedCancellations
            )
            guard save(journal: journal, to: defaults) else {
                throw PersistenceError.journalWriteFailed
            }
            updateLegacyActiveSession(identity.sessionID, at: now, defaults: defaults)
            clearLegacyPendingText(defaults)
            clearMeter(defaults: defaults)
            defaults.synchronize()
            DebugLog.info(
                "begin keyboard attempt sessionID=\(sessionID) attemptID=\(attemptID) generation=\(generation)",
                context: "KEYBOARD_DIAG"
            )
            return identity
        }
    }

    /// Compatibility shim. New code must retain and use the returned `AttemptIdentity` from `beginAttempt`.
    @discardableResult
    public static func beginSession(sessionID: String = UUID().uuidString) throws -> String {
        try beginAttempt(sessionID: sessionID).sessionID
    }

    public static func currentSnapshot() -> Snapshot? {
        try? loadCurrentSnapshot()
    }

    public static func snapshot(for identity: AttemptIdentity) -> Snapshot? {
        try? loadSnapshot(for: identity)
    }

    /// Throwing read API for callers that need to distinguish no active attempt from storage failure.
    public static func loadCurrentSnapshot() throws -> Snapshot? {
        try withThrowingTransaction { _ in
            switch loadJournal() {
            case .missing:
                return nil
            case let .loaded(journal):
                return journal.snapshot
            case let .failed(error):
                throw error
            }
        }
    }

    /// Throwing exact-identity read API. Mutating APIs independently re-check this identity under lock.
    public static func loadSnapshot(for identity: AttemptIdentity) throws -> Snapshot? {
        guard let snapshot = try loadCurrentSnapshot(), snapshot.identity == identity else {
            return nil
        }
        return snapshot
    }

    /// Keyboard API: expires a visible attempt whose persisted deadline or exact host heartbeat elapsed.
    /// The returned snapshot is authoritative and may be a newly persisted cancellation tombstone.
    @discardableResult
    public static func expireStaleAttempt(now: Date = Date()) throws -> Snapshot? {
        try withThrowingTransaction { defaults in
            let journal: Journal
            switch loadJournal() {
            case .missing:
                return nil
            case let .loaded(loadedJournal):
                journal = loadedJournal
            case let .failed(error):
                throw error
            }

            guard let current = journal.snapshot, !current.phase.isTerminal else {
                return journal.snapshot
            }

            let reason: String?
            switch current.phase {
            case .preparing where current.deadlineAt.map({ $0 <= now }) == true:
                reason = "Recording did not start in time."
            case .finalizing where current.deadlineAt.map({ $0 <= now }) == true:
                reason = "Recording did not finish in time."
            case .processing where current.deadlineAt.map({ $0 <= now }) == true:
                reason = "Transcription did not finish in time."
            case .recording:
                let snapshotIsOld = now.timeIntervalSince(current.updatedAt) >= recordingHeartbeatTimeout
                reason = snapshotIsOld && !hasFreshMeter(for: current.identity, now: now, defaults: defaults)
                    ? "Recording connection was lost."
                    : nil
            case .preparing, .finalizing, .processing, .succeeded, .failed, .cancelled:
                reason = nil
            }

            guard let reason else { return current }
            var mutableJournal = journal
            return try persistCancellation(
                journal: &mutableJournal,
                current: current,
                reason: reason,
                now: now,
                defaults: defaults
            )
        }
    }

    /// Host API: call once when a new containing-app process constructs its recording owner.
    /// Only a fresh start request that launched this process survives. Work owned by the dead
    /// process becomes a durable terminal tombstone before any new command is consumed.
    @discardableResult
    public static func normalizeAfterHostLaunch(now: Date = Date()) throws -> AttemptIdentity? {
        try withThrowingTransaction { defaults in
            let journal: Journal
            switch loadJournal() {
            case .missing:
                return nil
            case let .loaded(loadedJournal):
                journal = loadedJournal
            case let .failed(error):
                throw error
            }

            guard let current = journal.snapshot, !current.phase.isTerminal else { return nil }

            if current.phase == .preparing,
               current.hostAcknowledged == false,
               current.deadlineAt.map({ $0 > now }) == true,
               journal.commands.contains(where: {
                   $0.command == .start
                       && $0.identity == current.identity
                       && now.timeIntervalSince($0.createdAt) <= commandTTL
               })
            {
                return nil
            }

            let reason: String
            switch current.phase {
            case .preparing:
                reason = "Recording did not start."
            case .recording:
                reason = "Recording stopped when AI Dictation closed."
            case .finalizing:
                reason = "Recording did not finish when AI Dictation closed."
            case .processing:
                reason = "Transcription stopped when AI Dictation closed."
            case .succeeded, .failed, .cancelled:
                return nil
            }

            var mutableJournal = journal
            _ = try persistCancellation(
                journal: &mutableJournal,
                current: current,
                reason: reason,
                now: now,
                defaults: defaults
            )
            return current.identity
        }
    }

    public static func currentAttemptIdentity() -> AttemptIdentity? {
        currentSnapshot()?.identity
    }

    /// Decides what the host must do even when a command envelope expired or a replacement
    /// generation overwrote the old snapshot. Durable state, not notification delivery, wins.
    public static func hostReconciliationAction(
        activeIdentity: AttemptIdentity,
        snapshot: Snapshot?,
        now: Date = Date()
    ) -> HostReconciliationAction {
        guard let snapshot, snapshot.identity == activeIdentity else {
            return .cancel
        }
        if let deadlineAt = snapshot.deadlineAt, deadlineAt <= now {
            return .cancel
        }
        switch snapshot.phase {
        case .finalizing where !snapshot.hostAcknowledged:
            return snapshot.deadlineAt == nil ? .cancel : .stop
        case .succeeded, .failed, .cancelled:
            return .cancel
        case .preparing, .recording, .finalizing, .processing:
            return .none
        }
    }

    public static func activeSessionID() -> String? {
        do {
            return try withThrowingTransaction { defaults in
                switch loadJournal() {
                case let .loaded(journal):
                    return journal.snapshot?.identity.sessionID
                case .missing:
                    return defaults.string(forKey: activeSessionIDKey)
                case let .failed(error):
                    throw error
                }
            }
        } catch {
            return nil
        }
    }

    /// Enqueues an ordered command for the host. Exact duplicate pending commands are idempotent.
    @discardableResult
    public static func publish(command: Command, identity: AttemptIdentity, now: Date = Date()) -> Bool {
        if command == .cancel || command == .shutdown {
            return cancelAttempt(identity: identity, reason: "Recording cancelled.", now: now)
        }

        return withTransaction(or: false) { defaults in
            guard var journal = decodedJournal(from: defaults),
                  let snapshot = journal.snapshot,
                  snapshot.identity == identity,
                  !snapshot.phase.isTerminal,
                  commandIsAllowed(command, in: snapshot.phase)
            else {
                return false
            }

            if command == .stop, snapshot.phase == .finalizing {
                return true
            }

            if command == .stop,
               snapshot.phase == .preparing || snapshot.phase == .recording
            {
                journal.snapshot = Snapshot(
                    identity: identity,
                    phase: .finalizing,
                    recordingID: snapshot.recordingID,
                    resultText: nil,
                    userMessage: nil,
                    createdAt: snapshot.createdAt,
                    updatedAt: now,
                    resultConsumed: false,
                    hostAcknowledged: false,
                    deadlineAt: now.addingTimeInterval(stopAcknowledgementTimeout)
                )
            }

            journal.commands.removeAll { now.timeIntervalSince($0.createdAt) > commandTTL }
            if journal.commands.contains(where: { $0.command == command && $0.identity == identity }) {
                return true
            }

            guard journal.nextCommandSequence < UInt64.max else {
                return false
            }

            let envelope = CommandEnvelope(
                command: command,
                identity: identity,
                sequence: journal.nextCommandSequence,
                createdAt: now
            )
            journal.nextCommandSequence += 1
            journal.commands.append(envelope)
            guard save(journal: journal, to: defaults) else { return false }
            updateLegacyPendingCommand(envelope, defaults: defaults)
            defaults.synchronize()
            DebugLog.info(
                "publish keyboard command=\(command.rawValue) sessionID=\(identity.sessionID) attemptID=\(identity.attemptID) generation=\(identity.generation) sequence=\(envelope.sequence)",
                context: "KEYBOARD_DIAG"
            )
            return true
        }
    }

    /// Compatibility shim for callers compiled against the session-only bridge.
    @discardableResult
    public static func publish(command: Command, sessionID: String?) -> Bool {
        let identity: AttemptIdentity
        if let current = currentAttemptIdentity(),
           let sessionID,
           !sessionID.isEmpty,
           current.sessionID == sessionID
        {
            identity = current
        } else if command == .start {
            guard let started = try? beginAttempt(sessionID: sessionID ?? UUID().uuidString) else {
                return false
            }
            identity = started
        } else {
            return false
        }
        return publish(command: command, identity: identity)
    }

    /// Host API: consumes one request in sequence. Stale-generation requests are discarded.
    public static func consumePendingCommandEnvelope(now: Date = Date()) -> CommandEnvelope? {
        try? consumePendingCommandEnvelopePersisted(now: now)
    }

    /// Throwing host API for command consumers that must distinguish an empty queue from a
    /// journal read/write failure. A command is returned only after its removal is durable.
    public static func consumePendingCommandEnvelopePersisted(
        now: Date = Date()
    ) throws -> CommandEnvelope? {
        try withThrowingTransaction { defaults in
            let loadedJournal: Journal
            switch loadJournal() {
            case .missing:
                return nil
            case let .loaded(journal):
                loadedJournal = journal
            case let .failed(error):
                throw error
            }
            var journal = loadedJournal
            guard let currentIdentity = journal.snapshot?.identity else {
                return nil
            }

            let commandCountBeforePruning = journal.commands.count
            journal.commands.removeAll {
                !commandIsFresh($0, now: now)
                    || !commandBelongsToCurrentQueue($0, currentIdentity: currentIdentity)
            }
            guard !journal.commands.isEmpty else {
                if commandCountBeforePruning > 0 {
                    guard save(journal: journal, to: defaults) else {
                        throw PersistenceError.journalWriteFailed
                    }
                }
                clearLegacyPendingCommand(defaults)
                defaults.synchronize()
                return nil
            }

            let envelope = journal.commands.removeFirst()
            if envelope.command == .stop,
               let current = journal.snapshot,
               current.identity == envelope.identity,
               current.phase == .recording
            {
                journal.snapshot = Snapshot(
                    identity: current.identity,
                    phase: .finalizing,
                    recordingID: current.recordingID,
                    resultText: nil,
                    userMessage: nil,
                    createdAt: current.createdAt,
                    updatedAt: now,
                    resultConsumed: false,
                    hostAcknowledged: false,
                    deadlineAt: now.addingTimeInterval(stopAcknowledgementTimeout)
                )
            }
            guard save(journal: journal, to: defaults) else {
                throw PersistenceError.journalWriteFailed
            }
            if let newest = journal.commands.last {
                updateLegacyPendingCommand(newest, defaults: defaults)
            } else {
                clearLegacyPendingCommand(defaults)
            }
            defaults.synchronize()
            return envelope
        }
    }

    /// Compatibility shim. New host code must consume the full command envelope.
    public static func consumePendingCommand() -> (command: Command, sessionID: String?)? {
        guard let envelope = consumePendingCommandEnvelope() else { return nil }
        return (envelope.command, envelope.identity.sessionID)
    }

    /// Host API: acknowledges an ordered state transition using compare-and-set identity fencing.
    @discardableResult
    public static func publishHostPhase(
        _ phase: Phase,
        identity: AttemptIdentity,
        recordingID: String? = nil,
        userMessage: String? = nil,
        deadlineAt requestedDeadlineAt: Date? = nil,
        now: Date = Date()
    ) -> Bool {
        withTransaction(or: false) { defaults in
            guard var journal = decodedJournal(from: defaults),
                  let current = journal.snapshot,
                  current.identity == identity,
                  !current.phase.isTerminal,
                  hostTransitionIsAllowed(from: current.phase, to: phase)
            else {
                return false
            }

            if let requestedDeadlineAt {
                guard phase == .finalizing, requestedDeadlineAt > now else {
                    return false
                }
            }

            let resolvedRecordingID = nonempty(recordingID) ?? current.recordingID
            if phase == .recording || phase == .finalizing || phase == .processing {
                guard resolvedRecordingID != nil else { return false }
            }
            if let oldRecordingID = current.recordingID,
               let resolvedRecordingID,
               oldRecordingID != resolvedRecordingID
            {
                return false
            }

            let deadlineAt: Date?
            switch phase {
            case .preparing:
                deadlineAt = current.deadlineAt
            case .recording, .failed, .succeeded, .cancelled:
                deadlineAt = nil
            case .finalizing:
                // A queued stop owns only a short acknowledgement deadline. Once the host
                // acknowledges finalization, it replaces that deadline with the bounded budget
                // for closing and validating the actual recording.
                deadlineAt = requestedDeadlineAt
                    ?? current.deadlineAt
                    ?? now.addingTimeInterval(stopAcknowledgementTimeout)
            case .processing:
                deadlineAt = current.phase == .processing
                    ? current.deadlineAt
                    : now.addingTimeInterval(resultTimeout)
            }

            journal.snapshot = Snapshot(
                identity: identity,
                phase: phase,
                recordingID: resolvedRecordingID,
                resultText: nil,
                userMessage: nonempty(userMessage),
                createdAt: current.createdAt,
                updatedAt: now,
                resultConsumed: false,
                hostAcknowledged: true,
                deadlineAt: deadlineAt
            )
            guard save(journal: journal, to: defaults) else { return false }
            updateLegacyActiveSession(identity.sessionID, at: now, defaults: defaults)
            defaults.synchronize()
            return true
        }
    }

    /// Host API: persists the final non-empty result. Empty cleanup output must be replaced by raw text first.
    @discardableResult
    public static func publishHostResult(
        text: String,
        identity: AttemptIdentity,
        recordingID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return withTransaction(or: false) { defaults in
            guard var journal = decodedJournal(from: defaults),
                  let current = journal.snapshot,
                  current.identity == identity,
                  current.phase == .processing
            else {
                return false
            }

            let resolvedRecordingID = nonempty(recordingID) ?? current.recordingID
            guard resolvedRecordingID != nil else { return false }
            if let oldRecordingID = current.recordingID,
               let resolvedRecordingID,
               oldRecordingID != resolvedRecordingID
            {
                return false
            }

            journal.snapshot = Snapshot(
                identity: identity,
                phase: .succeeded,
                recordingID: resolvedRecordingID,
                resultText: text,
                userMessage: nil,
                createdAt: current.createdAt,
                updatedAt: now,
                resultConsumed: false,
                hostAcknowledged: true,
                deadlineAt: nil
            )
            guard save(journal: journal, to: defaults) else { return false }
            updateLegacyPendingText(text, sessionID: identity.sessionID, at: now, defaults: defaults)
            defaults.synchronize()
            return true
        }
    }

    /// Host API: publishes a terminal failure while retaining the stable recording ID, when available.
    @discardableResult
    public static func publishHostFailure(
        identity: AttemptIdentity,
        recordingID: String? = nil,
        userMessage: String,
        now: Date = Date()
    ) -> Bool {
        publishHostPhase(
            .failed,
            identity: identity,
            recordingID: recordingID,
            userMessage: userMessage,
            now: now
        )
    }

    /// Durable cancellation/tombstone for active work. An already persisted terminal result wins
    /// a cancellation race, while a cancellation tombstone rejects every later host callback.
    @discardableResult
    public static func cancelAttempt(
        identity: AttemptIdentity,
        reason: String = "Recording cancelled.",
        now: Date = Date()
    ) -> Bool {
        do {
            return try withThrowingTransaction { defaults in
                let journal: Journal
                switch loadJournal() {
                case .missing:
                    return false
                case let .loaded(loadedJournal):
                    journal = loadedJournal
                case let .failed(error):
                    throw error
                }
                guard let current = journal.snapshot, current.identity == identity else {
                    return false
                }
                if current.phase == .cancelled {
                    return true
                }
                guard !current.phase.isTerminal else {
                    return false
                }

                var mutableJournal = journal
                _ = try persistCancellation(
                    journal: &mutableJournal,
                    current: current,
                    reason: reason,
                    now: now,
                    defaults: defaults
                )
                return true
            }
        } catch {
            DebugLog.error("Keyboard handoff cancellation could not be persisted", context: "KEYBOARD_DIAG")
            return false
        }
    }

    /// Extension API: returns a successful result exactly once for the matching attempt.
    public static func consumeResult(for identity: AttemptIdentity, now: Date = Date()) -> String? {
        try? consumeResultPersisted(for: identity, now: now)
    }

    /// Throwing extension API. The text is returned only after the one-shot consumed marker is
    /// durably committed, so storage failure cannot masquerade as an empty result.
    public static func consumeResultPersisted(
        for identity: AttemptIdentity,
        now: Date = Date()
    ) throws -> String? {
        try withThrowingTransaction { defaults in
            let loadedJournal: Journal
            switch loadJournal() {
            case .missing:
                return nil
            case let .loaded(journal):
                loadedJournal = journal
            case let .failed(error):
                throw error
            }
            var journal = loadedJournal
            guard let current = journal.snapshot,
                  current.identity == identity,
                  current.phase == .succeeded,
                  !current.resultConsumed,
                  let text = current.resultText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }

            journal.snapshot = Snapshot(
                identity: identity,
                phase: .succeeded,
                recordingID: current.recordingID,
                resultText: text,
                userMessage: nil,
                createdAt: current.createdAt,
                updatedAt: now,
                resultConsumed: true,
                hostAcknowledged: true,
                deadlineAt: nil
            )
            guard save(journal: journal, to: defaults) else {
                throw PersistenceError.journalWriteFailed
            }
            clearLegacyPendingText(defaults)
            clearMeter(defaults: defaults)
            defaults.synchronize()
            return text
        }
    }

    // MARK: - Meter and readiness

    public static func publishMeter(
        audioLevel: Float,
        frequencyBands: [Float],
        identity: AttemptIdentity,
        now: Date = Date()
    ) {
        withTransaction(or: ()) { defaults in
            guard let snapshot = decodedJournal(from: defaults)?.snapshot,
                  snapshot.identity == identity,
                  snapshot.phase == .recording
            else { return }
            let payload = MeterPayload(
                identity: identity,
                sessionID: identity.sessionID,
                audioLevel: audioLevel,
                frequencyBands: frequencyBands,
                timestamp: now
            )
            if let data = try? JSONEncoder().encode(payload) {
                defaults.set(data, forKey: meterPayloadKey)
            }
            updateLegacyMeter(payload, defaults: defaults)
            defaults.synchronize()
        }
    }

    public static func consumeMeter(
        for identity: AttemptIdentity,
        now: Date = Date()
    ) -> (audioLevel: Float, frequencyBands: [Float])? {
        withTransaction(or: nil) { defaults in
            guard decodedJournal(from: defaults)?.snapshot?.identity == identity,
                  let data = defaults.data(forKey: meterPayloadKey),
                  let payload = try? JSONDecoder().decode(MeterPayload.self, from: data),
                  payload.identity == identity,
                  now.timeIntervalSince(payload.timestamp) <= meterTTL,
                  !payload.frequencyBands.isEmpty
            else {
                return nil
            }
            return (payload.audioLevel, payload.frequencyBands)
        }
    }

    /// Compatibility shim for session-only host code.
    public static func publishMeter(audioLevel: Float, frequencyBands: [Float], sessionID: String?) {
        if let identity = currentAttemptIdentity(), sessionID == nil || identity.sessionID == sessionID {
            publishMeter(audioLevel: audioLevel, frequencyBands: frequencyBands, identity: identity)
            return
        }

        withTransaction(or: ()) { defaults in
            let payload = MeterPayload(
                identity: nil,
                sessionID: sessionID,
                audioLevel: audioLevel,
                frequencyBands: frequencyBands,
                timestamp: Date()
            )
            if let data = try? JSONEncoder().encode(payload) {
                defaults.set(data, forKey: meterPayloadKey)
            }
            updateLegacyMeter(payload, defaults: defaults)
            defaults.synchronize()
        }
    }

    /// Compatibility shim for session-only keyboard code.
    public static func consumeMeter(for sessionID: String?) -> (audioLevel: Float, frequencyBands: [Float])? {
        if let identity = currentAttemptIdentity(), sessionID == nil || identity.sessionID == sessionID {
            return consumeMeter(for: identity)
        }

        return withTransaction(or: nil) { defaults in
            guard case .missing = loadJournal() else { return nil }
            guard let data = defaults.data(forKey: meterPayloadKey),
                  let payload = try? JSONDecoder().decode(MeterPayload.self, from: data),
                  sessionID == nil || payload.sessionID == sessionID,
                  Date().timeIntervalSince(payload.timestamp) <= meterTTL,
                  !payload.frequencyBands.isEmpty
            else {
                return nil
            }
            return (payload.audioLevel, payload.frequencyBands)
        }
    }

    public static func publishAppReady(now: Date = Date()) {
        withTransaction(or: ()) { defaults in
            defaults.set(now.timeIntervalSince1970, forKey: appReadyTimestampKey)
            defaults.synchronize()
        }
    }

    public static func isAppReady(now: Date = Date()) -> Bool {
        withTransaction(or: false) { defaults in
            let timestamp = defaults.double(forKey: appReadyTimestampKey)
            return timestamp > 0 && now.timeIntervalSince1970 - timestamp <= appReadyTTL
        }
    }

    // MARK: - Compatibility text bridge

    /// Compatibility shim. New host code must call `publishHostResult` with the exact identity.
    public static func publish(text: String, sessionID: String?) {
        guard let identity = currentAttemptIdentity(),
              let sessionID,
              !sessionID.isEmpty,
              identity.sessionID == sessionID
        else {
            return
        }

        if publishHostResult(text: text, identity: identity) {
            return
        }

        // Allow an old containing app to finish a handoff during a rolling update. The new
        // identity still fences it, and cancellation continues to dominate this compatibility path.
        withTransaction(or: ()) { defaults in
            guard var journal = decodedJournal(from: defaults),
                  let current = journal.snapshot,
                  current.identity == identity,
                  !current.phase.isTerminal,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            journal.snapshot = Snapshot(
                identity: identity,
                phase: .succeeded,
                recordingID: current.recordingID,
                resultText: text,
                userMessage: nil,
                createdAt: current.createdAt,
                updatedAt: Date(),
                resultConsumed: false,
                hostAcknowledged: true,
                deadlineAt: nil
            )
            guard save(journal: journal, to: defaults) else { return }
            updateLegacyPendingText(text, sessionID: identity.sessionID, at: Date(), defaults: defaults)
            defaults.synchronize()
        }
    }

    public static func consumePendingText(for sessionID: String?) -> String? {
        if let identity = currentAttemptIdentity(),
           let sessionID,
           !sessionID.isEmpty,
           identity.sessionID == sessionID,
           let result = consumeResult(for: identity)
        {
            return result
        }

        return withTransaction(or: nil) { defaults in
            guard case .missing = loadJournal() else { return nil }
            guard let text = defaults.string(forKey: pendingTextKey), !text.isEmpty else {
                return nil
            }
            let timestamp = defaults.double(forKey: pendingTextTimestampKey)
            if timestamp > 0, Date().timeIntervalSince1970 - timestamp > pendingTextTTL {
                clearLegacyPendingText(defaults)
                defaults.synchronize()
                return nil
            }
            let pendingSessionID = defaults.string(forKey: pendingTextSessionIDKey)
            guard sessionID == nil || pendingSessionID == nil || pendingSessionID == sessionID else {
                return nil
            }
            clearLegacyPendingText(defaults)
            defaults.synchronize()
            return text
        }
    }

    public static func sessionID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "session" })?
            .value
    }

    public static func clearPendingText() {
        withTransaction(or: ()) { defaults in
            clearLegacyPendingText(defaults)
            defaults.synchronize()
        }
    }

    @discardableResult
    public static func clearPendingCommand() -> Bool {
        withTransaction(or: false) { defaults in
            let loaded = loadJournal()
            guard case let .loaded(existingJournal) = loaded else {
                guard case .missing = loaded else { return false }
                clearLegacyPendingCommand(defaults)
                defaults.synchronize()
                return true
            }
            var journal = existingJournal
            journal.commands = []
            guard save(journal: journal, to: defaults) else { return false }
            clearLegacyPendingCommand(defaults)
            defaults.synchronize()
            return true
        }
    }

    /// Compatibility cleanup. New code should use `cancelAttempt` so the terminal reason remains visible.
    @discardableResult
    public static func clearActiveSession() -> Bool {
        withTransaction(or: false) { defaults in
            switch loadJournal() {
            case let .loaded(existingJournal):
                var journal = existingJournal
                journal.snapshot = nil
                journal.commands = []
                guard save(journal: journal, to: defaults) else { return false }
            case .missing:
                break
            case .failed:
                return false
            }
            defaults.removeObject(forKey: activeSessionIDKey)
            defaults.removeObject(forKey: activeSessionTimestampKey)
            clearLegacyPendingText(defaults)
            clearLegacyPendingCommand(defaults)
            clearMeter(defaults: defaults)
            defaults.synchronize()
            return true
        }
    }

    public static func clearMeter() {
        withTransaction(or: ()) { defaults in
            clearMeter(defaults: defaults)
            defaults.synchronize()
        }
    }

    // MARK: - Diagnostics

    public static func appendDiagnostic(_ message: String) {
        withTransaction(or: ()) { defaults in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let entry = "\(timestamp) \(message)"
            var diagnostics = defaults.stringArray(forKey: diagnosticsKey) ?? []
            diagnostics.append(entry)
            if diagnostics.count > diagnosticsLimit {
                diagnostics.removeFirst(diagnostics.count - diagnosticsLimit)
            }
            defaults.set(diagnostics, forKey: diagnosticsKey)
            defaults.synchronize()
            DebugLog.info(entry, context: "KEYBOARD_DIAG")
        }
    }

    public static func consumeDiagnostics() -> [String] {
        withTransaction(or: []) { defaults in
            let diagnostics = defaults.stringArray(forKey: diagnosticsKey) ?? []
            guard !diagnostics.isEmpty else { return [] }
            defaults.removeObject(forKey: diagnosticsKey)
            defaults.synchronize()
            return diagnostics
        }
    }

    // MARK: - State validation

    private static func commandIsAllowed(_ command: Command, in phase: Phase) -> Bool {
        switch command {
        case .start:
            return phase == .preparing
        case .stop:
            return phase == .preparing || phase == .recording || phase == .finalizing
        case .cancel, .shutdown:
            return !phase.isTerminal
        }
    }

    private static func commandIsFresh(_ command: CommandEnvelope, now: Date) -> Bool {
        let age = now.timeIntervalSince(command.createdAt)
        // A wall-clock rollback must not discard a durable cancellation before the host sees it.
        return age <= commandTTL
    }

    private static func commandBelongsToCurrentQueue(
        _ command: CommandEnvelope,
        currentIdentity: AttemptIdentity
    ) -> Bool {
        if command.identity == currentIdentity {
            return true
        }
        return command.command == .cancel
            && command.identity.generation > 0
            && command.identity.generation < currentIdentity.generation
    }

    private static func hostTransitionIsAllowed(from current: Phase, to next: Phase) -> Bool {
        if current == next {
            return !current.isTerminal
        }
        switch (current, next) {
        case (.preparing, .recording),
             (.preparing, .failed),
             (.recording, .finalizing),
             (.recording, .failed),
             (.finalizing, .processing),
             (.finalizing, .failed),
             (.processing, .failed):
            return true
        default:
            return false
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func hasFreshMeter(
        for identity: AttemptIdentity,
        now: Date,
        defaults: UserDefaults
    ) -> Bool {
        guard let data = defaults.data(forKey: meterPayloadKey),
              let payload = try? JSONDecoder().decode(MeterPayload.self, from: data),
              payload.identity == identity
        else {
            return false
        }
        let age = now.timeIntervalSince(payload.timestamp)
        return age >= 0 && age <= recordingHeartbeatTimeout
    }

    /// Mutates and durably saves a cancellation while the caller owns the process and file locks.
    /// If the command sequence is exhausted, the tombstone still wins without reusing a sequence.
    private static func persistCancellation(
        journal: inout Journal,
        current: Snapshot,
        reason: String,
        now: Date,
        defaults: UserDefaults
    ) throws -> Snapshot {
        let cancelled = Snapshot(
            identity: current.identity,
            phase: .cancelled,
            recordingID: current.recordingID,
            resultText: nil,
            userMessage: nonempty(reason) ?? "Recording cancelled.",
            createdAt: current.createdAt,
            updatedAt: now,
            resultConsumed: true,
            hostAcknowledged: false,
            deadlineAt: nil
        )
        journal.snapshot = cancelled

        // Preserve older cancellation envelopes ahead of an immediate retry so the host tears
        // down their owners before it consumes the newer start. All non-cancel work is discarded.
        journal.commands = journal.commands.filter {
            $0.command == .cancel
                && $0.identity.generation < current.identity.generation
                && commandIsFresh($0, now: now)
        }
        let envelope: CommandEnvelope?
        if journal.nextCommandSequence < UInt64.max {
            let nextEnvelope = CommandEnvelope(
                command: .cancel,
                identity: current.identity,
                sequence: journal.nextCommandSequence,
                createdAt: now
            )
            journal.nextCommandSequence += 1
            journal.commands.append(nextEnvelope)
            envelope = nextEnvelope
        } else {
            envelope = nil
        }

        guard save(journal: journal, to: defaults) else {
            throw PersistenceError.journalWriteFailed
        }
        if let envelope {
            updateLegacyPendingCommand(envelope, defaults: defaults)
        } else {
            clearLegacyPendingCommand(defaults)
        }
        clearLegacyPendingText(defaults)
        clearMeter(defaults: defaults)
        defaults.synchronize()
        return cancelled
    }

    // MARK: - Persistence

    private static func decodedJournal(from defaults: UserDefaults) -> Journal? {
        switch loadJournal() {
        case let .loaded(journal):
            return journal
        case .missing, .failed:
            return nil
        }
    }

    private static func loadJournal() -> JournalLoad {
        if ProcessInfo.processInfo.environment["AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_READS"] == "1" {
            return .failed(.journalReadFailed)
        }
        guard let url = handoffJournalURL() else {
            return .failed(.storageUnavailable)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failed(.journalReadFailed)
        }
        guard let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journalIsValid(journal)
        else {
            return .failed(.journalCorrupt)
        }
        return .loaded(journal)
    }

    @discardableResult
    private static func save(journal: Journal, to defaults: UserDefaults) -> Bool {
        guard journalIsValid(journal),
              ProcessInfo.processInfo.environment["AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_WRITES"] != "1",
              let url = handoffJournalURL(),
              let data = try? JSONEncoder().encode(journal),
              writeDurably(data, to: url)
        else {
            return false
        }

        // UserDefaults is only a rolling-update mirror. The fsynced JSON file is authoritative.
        defaults.set(data, forKey: journalMirrorKey)
        defaults.synchronize()
        return true
    }

    private static func journalIsValid(_ journal: Journal) -> Bool {
        guard journal.schemaVersion == 2,
              journal.generation > 0,
              journal.nextCommandSequence > 0
        else {
            return false
        }

        guard let snapshot = journal.snapshot else {
            return journal.commands.isEmpty
        }
        guard snapshot.identity.generation == journal.generation,
              !snapshot.identity.sessionID.isEmpty,
              !snapshot.identity.attemptID.isEmpty
        else {
            return false
        }

        if snapshot.phase == .recording
            || snapshot.phase == .processing
            || snapshot.phase == .succeeded
        {
            guard nonempty(snapshot.recordingID) != nil else { return false }
        }
        // A stop can win before the host creates a recording. That unacknowledged finalizing
        // snapshot deliberately has no recording ID; the host must terminalize it without
        // starting capture. Any host-acknowledged finalization must own a stable recording ID.
        if snapshot.phase == .finalizing,
           snapshot.hostAcknowledged,
           nonempty(snapshot.recordingID) == nil
        {
            return false
        }
        if snapshot.phase == .succeeded {
            guard nonempty(snapshot.resultText) != nil else { return false }
        } else if snapshot.resultText != nil {
            return false
        }

        switch snapshot.phase {
        case .preparing, .finalizing, .processing:
            guard snapshot.deadlineAt != nil else { return false }
        case .recording, .succeeded, .failed, .cancelled:
            guard snapshot.deadlineAt == nil else { return false }
        }

        var previousSequence: UInt64 = 0
        for command in journal.commands {
            guard commandBelongsToCurrentQueue(command, currentIdentity: snapshot.identity),
                  !command.identity.sessionID.isEmpty,
                  !command.identity.attemptID.isEmpty,
                  command.sequence > previousSequence,
                  command.sequence < journal.nextCommandSequence
            else {
                return false
            }
            previousSequence = command.sequence
        }
        return true
    }

    private static func writeDurably(_ data: Data, to url: URL) -> Bool {
        #if canImport(Darwin)
            let directory = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return false
            }

            let temporaryURL = directory.appendingPathComponent(".\(journalFileName).\(UUID().uuidString).tmp")
            let descriptor = open(temporaryURL.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return false }

            var descriptorIsOpen = true
            func closeAndRemoveTemporaryFile() {
                if descriptorIsOpen {
                    _ = close(descriptor)
                    descriptorIsOpen = false
                }
                _ = unlink(temporaryURL.path)
            }

            let wroteAllBytes = data.withUnsafeBytes { bytes -> Bool in
                guard let baseAddress = bytes.baseAddress else { return false }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
            guard wroteAllBytes, fsync(descriptor) == 0, close(descriptor) == 0 else {
                closeAndRemoveTemporaryFile()
                return false
            }
            descriptorIsOpen = false

            guard rename(temporaryURL.path, url.path) == 0 else {
                _ = unlink(temporaryURL.path)
                return false
            }

            let directoryDescriptor = open(directory.path, O_RDONLY)
            guard directoryDescriptor >= 0 else { return false }
            let directoryWasSynced = fsync(directoryDescriptor) == 0
            let directoryWasClosed = close(directoryDescriptor) == 0
            return directoryWasSynced && directoryWasClosed
        #else
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        #endif
    }

    private static func updateLegacyActiveSession(_ sessionID: String, at date: Date, defaults: UserDefaults) {
        defaults.set(sessionID, forKey: activeSessionIDKey)
        defaults.set(date.timeIntervalSince1970, forKey: activeSessionTimestampKey)
    }

    private static func updateLegacyPendingCommand(_ envelope: CommandEnvelope, defaults: UserDefaults) {
        defaults.set(envelope.command.rawValue, forKey: pendingCommandKey)
        defaults.set(envelope.identity.sessionID, forKey: pendingCommandSessionIDKey)
        defaults.set(envelope.createdAt.timeIntervalSince1970, forKey: pendingCommandTimestampKey)
        updateLegacyActiveSession(envelope.identity.sessionID, at: envelope.createdAt, defaults: defaults)
    }

    private static func clearLegacyPendingCommand(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingCommandKey)
        defaults.removeObject(forKey: pendingCommandSessionIDKey)
        defaults.removeObject(forKey: pendingCommandTimestampKey)
        defaults.removeObject(forKey: pendingCommandQueueKey)
    }

    private static func clearLegacyPendingText(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingTextKey)
        defaults.removeObject(forKey: pendingTextSessionIDKey)
        defaults.removeObject(forKey: pendingTextTimestampKey)
    }

    private static func updateLegacyPendingText(
        _ text: String,
        sessionID: String,
        at date: Date,
        defaults: UserDefaults
    ) {
        defaults.set(text, forKey: pendingTextKey)
        defaults.set(sessionID, forKey: pendingTextSessionIDKey)
        defaults.set(date.timeIntervalSince1970, forKey: pendingTextTimestampKey)
    }

    private static func updateLegacyMeter(_ payload: MeterPayload, defaults: UserDefaults) {
        if let sessionID = payload.sessionID {
            defaults.set(sessionID, forKey: meterSessionIDKey)
        } else {
            defaults.removeObject(forKey: meterSessionIDKey)
        }
        defaults.set(Double(payload.audioLevel), forKey: meterAudioLevelKey)
        defaults.set(payload.frequencyBands.map(Double.init), forKey: meterFrequencyBandsKey)
        defaults.set(payload.timestamp.timeIntervalSince1970, forKey: meterTimestampKey)
    }

    private static func clearMeter(defaults: UserDefaults) {
        defaults.removeObject(forKey: meterPayloadKey)
        defaults.removeObject(forKey: meterSessionIDKey)
        defaults.removeObject(forKey: meterAudioLevelKey)
        defaults.removeObject(forKey: meterFrequencyBandsKey)
        defaults.removeObject(forKey: meterTimestampKey)
    }

    private static func withTransaction<T>(
        or fallback: @autoclosure () -> T,
        _ body: (UserDefaults) -> T
    ) -> T {
        do {
            return try withThrowingTransaction(body)
        } catch {
            DebugLog.error("Keyboard handoff storage unavailable", context: "KEYBOARD_DIAG")
            return fallback()
        }
    }

    private static func withThrowingTransaction<T>(
        _ body: (UserDefaults) throws -> T
    ) throws -> T {
        let lockDeadline = ProcessInfo.processInfo.systemUptime + lockAcquisitionTimeout
        while !processLock.try() {
            guard ProcessInfo.processInfo.systemUptime < lockDeadline else {
                throw PersistenceError.storageUnavailable
            }
            Thread.sleep(forTimeInterval: lockRetryInterval)
        }
        defer { processLock.unlock() }

        #if canImport(Darwin)
            guard let lockURL = handoffLockURL() else {
                throw PersistenceError.storageUnavailable
            }
            do {
                try FileManager.default.createDirectory(
                    at: lockURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw PersistenceError.storageUnavailable
            }
            let lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockDescriptor >= 0 else {
                throw PersistenceError.storageUnavailable
            }
            while flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
                let lockError = errno
                guard lockError == EWOULDBLOCK || lockError == EAGAIN || lockError == EINTR,
                      ProcessInfo.processInfo.systemUptime < lockDeadline
                else {
                    _ = close(lockDescriptor)
                    throw PersistenceError.storageUnavailable
                }
                Thread.sleep(forTimeInterval: lockRetryInterval)
            }
            defer {
                _ = flock(lockDescriptor, LOCK_UN)
                _ = close(lockDescriptor)
            }
        #endif

        let sharedDefaults = defaults
        sharedDefaults.synchronize()
        return try body(sharedDefaults)
    }

    private static func handoffDirectoryURL() -> URL? {
        if let testSuite = ProcessInfo.processInfo.environment["AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE"],
           !testSuite.isEmpty
        {
            let safeName = testSuite.replacingOccurrences(of: "/", with: "_")
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(safeName, isDirectory: true)
        }

        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("KeyboardDictationHandoffV2", isDirectory: true)
    }

    private static func handoffLockURL() -> URL? {
        handoffDirectoryURL()?.appendingPathComponent("KeyboardDictationHandoff.lock")
    }

    private static func handoffJournalURL() -> URL? {
        handoffDirectoryURL()?.appendingPathComponent(journalFileName)
    }
}
