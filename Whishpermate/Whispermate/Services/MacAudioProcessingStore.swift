import Foundation
import Darwin
import AVFoundation
import CryptoKit

/// Durable ownership and recovery journal for the macOS audio-processing pipeline.
///
/// The store intentionally owns metadata and stable source locations, but never
/// performs recognition itself. Every mutation is fenced by a lease containing
/// the recording's current attempt, clear generation, and revision. Journal
/// state is persisted before it is published in memory or destructive cleanup
/// begins.
actor MacAudioProcessingStore {
    enum Stage: String, Codable, CaseIterable, Sendable {
        case preparing
        case recording
        case finalizing
        case readyForRecognition
        case recognizing
        case rawResultReady
        case cleaning
        case resultReady
        case succeeded
        case failed
        case deleted
    }

    enum SourceKind: String, Codable, Sendable {
        case partial
        case final
        case both
        case missing
    }

    enum Health: Equatable, Sendable {
        case healthy
        case readOnly(message: String)
    }

    struct Record: Codable, Equatable, Sendable {
        let recordingID: UUID
        var attemptID: UUID
        var stage: Stage
        var source: SourceKind
        var revision: UInt64
        var clearGeneration: UInt64
        var deadline: Date
        var audioIntegrity: AudioIntegrity?
        var audioFileIdentity: AudioFileIdentity? = nil
        var rawText: String?
        var resultText: String?
        var failureMessage: String?
        /// Present only after History durably accepted the successful result.
        /// Claiming is persisted before the non-idempotent account sink.
        var pendingUsageWordCount: Int? = nil
        var usageWasClaimed: Bool? = nil
        var updatedAt: Date
    }

    struct AudioIntegrity: Codable, Equatable, Sendable {
        let byteCount: Int64
        let frameCount: Int64
        let sampleRate: Double
        let duration: TimeInterval
        let sha256: String
    }

    /// Cheap, persisted identity for a source that has already passed the full
    /// decode/hash proof and has been flushed to stable storage. This lets the
    /// normal recognition handoff verify that it is still the same inode without
    /// synchronously decoding a long recording a second time.
    struct AudioFileIdentity: Codable, Equatable, Sendable {
        let deviceID: UInt64
        let inode: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    enum TestOperation: Equatable, Sendable {
        case journalWrite
        case journalFileSync
        case journalRename
        case journalDirectorySync
        case sourceFileSync
        case sourceRename
        case sourceDirectorySync
        case deepAudioValidation
    }

    struct TestHooks: Sendable {
        let before: @Sendable (TestOperation) throws -> Void
        let now: @Sendable () -> Date

        init(
            before: @escaping @Sendable (TestOperation) throws -> Void = { _ in },
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.before = before
            self.now = now
        }

        static let none = TestHooks()
    }

    /// Produced by the recorder only after its attempt has closed the writer.
    /// Exact byte count fences post-close truncation; minimum frame count fences
    /// a container that closes cleanly after losing captured buffers.
    struct ClosedAudioProof: Equatable, Sendable {
        let attemptID: UUID
        let expectedByteCount: Int64
        let expectedFrameCount: Int64
        let expectedSHA256: String
    }

    struct Lease: Equatable, Sendable {
        let recordingID: UUID
        let attemptID: UUID
        let clearGeneration: UInt64
        let revision: UInt64
    }

    struct Mutation: Equatable, Sendable {
        let lease: Lease
        let record: Record
    }

    struct View: Equatable, Sendable {
        let health: Health
        let clearGeneration: UInt64
        let revision: UInt64
        let records: [Record]
    }

    struct CleanupResult: Equatable, Sendable {
        let failedURLs: [URL]

        var completed: Bool { failedURLs.isEmpty }
    }

    enum StoreError: Error, Equatable, LocalizedError, Sendable {
        case readOnly
        case invalidIdentity
        case invalidDeadline
        case duplicateRecording
        case recordingNotFound
        case recordingDeleted
        case staleLease
        case invalidTransition
        case sourceMissing
        case sourceConflict
        case invalidAudio
        case sourceTooLarge
        case storageUnavailable
        case revisionExhausted

        var errorDescription: String? {
            switch self {
            case .readOnly:
                return "Saved recordings need attention. No files were changed."
            case .invalidIdentity:
                return "This recording attempt is not valid. Please try again."
            case .invalidDeadline:
                return "This recording attempt no longer has time to finish. Please try again."
            case .duplicateRecording:
                return "This recording is already being processed."
            case .recordingNotFound:
                return "This recording could not be found."
            case .recordingDeleted:
                return "This recording was deleted."
            case .staleLease:
                return "A newer recording attempt has already taken over."
            case .invalidTransition:
                return "This recording is no longer in the expected state."
            case .sourceMissing:
                return "The saved audio could not be found."
            case .sourceConflict:
                return "More than one saved audio file was found. No files were changed."
            case .invalidAudio:
                return "The recording did not finish saving correctly. Your file was preserved."
            case .sourceTooLarge:
                return "This recording is too large to import safely. The original file was not changed."
            case .storageUnavailable:
                return "The recording could not be saved. Your existing files were not changed."
            case .revisionExhausted:
                return "The recording history cannot accept more changes."
            }
        }
    }

    nonisolated let rootDirectory: URL
    nonisolated let incomingDirectory: URL
    nonisolated let recordingsDirectory: URL
    nonisolated let transientDirectory: URL
    nonisolated let journalURL: URL
    private nonisolated let lockURL: URL
    private nonisolated let testHooks: TestHooks
    private nonisolated let transientRoot: MacTransientWorkspaceRoot?

    private struct Journal: Codable, Equatable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var clearGeneration: UInt64
        var revision: UInt64
        var records: [Record]

        static let empty = Journal(
            schemaVersion: currentSchemaVersion,
            clearGeneration: 0,
            revision: 0,
            records: []
        )
    }

    private var journal: Journal
    private var health: Health
    private struct ClosedAudioValidation {
        let attemptID: UUID
        let clearGeneration: UInt64
        let sourcePath: String
        let modificationDate: Date
        let integrity: AudioIntegrity
        let fileIdentity: AudioFileIdentity
    }
    private struct DeepAudioVerification: Sendable {
        let integrity: AudioIntegrity
        let fileIdentity: AudioFileIdentity
    }
    private var closedAudioValidations: [UUID: ClosedAudioValidation] = [:]
    private static let maximumAdoptedAudioBytes: Int64 = 536_870_912

    init(
        rootDirectory: URL,
        recoverInterruptedWork: Bool = true,
        testHooks: TestHooks = .none
    ) {
        let storeDirectory = rootDirectory.appendingPathComponent("AudioProcessing", isDirectory: true)
        let incomingDirectory = storeDirectory.appendingPathComponent("Incoming", isDirectory: true)
        let recordingsDirectory = storeDirectory.appendingPathComponent("Recordings", isDirectory: true)
        let transientDirectory = storeDirectory.appendingPathComponent("Transient", isDirectory: true)
        let journalURL = storeDirectory.appendingPathComponent("journal.json", isDirectory: false)
        let lockURL = storeDirectory.appendingPathComponent(".journal.lock", isDirectory: false)

        self.rootDirectory = rootDirectory
        self.incomingDirectory = incomingDirectory
        self.recordingsDirectory = recordingsDirectory
        self.transientDirectory = transientDirectory
        self.journalURL = journalURL
        self.lockURL = lockURL
        self.testHooks = testHooks

        var loadedJournal = Journal.empty
        var loadedHealth = Health.healthy
        var loadedTransientRoot: MacTransientWorkspaceRoot?

        do {
            try Self.createDirectories(
                storeDirectory: storeDirectory,
                incomingDirectory: incomingDirectory,
                recordingsDirectory: recordingsDirectory,
                transientDirectory: transientDirectory
            )
            let transientRoot = try MacTransientWorkspaceRoot(
                rootDirectory: rootDirectory,
                storeDirectory: storeDirectory,
                transientDirectory: transientDirectory
            )
            try transientRoot.sweepAfterRestart()
            loadedTransientRoot = transientRoot

            try Self.withExclusiveLock(at: lockURL) {
                if FileManager.default.fileExists(atPath: journalURL.path) {
                    let data = try Data(contentsOf: journalURL)
                    loadedJournal = try Self.makeDecoder().decode(Journal.self, from: data)
                    try Self.validate(loadedJournal)
                }

                try Self.validateManagedSources(
                    loadedJournal,
                    incomingDirectory: incomingDirectory,
                    recordingsDirectory: recordingsDirectory
                )

                if recoverInterruptedWork {
                    let reconciliation = try Self.reconcileAfterRestart(
                        loadedJournal,
                        incomingDirectory: incomingDirectory,
                        recordingsDirectory: recordingsDirectory
                    )
                    loadedJournal = reconciliation.journal

                    if reconciliation.changed {
                        try Self.persist(loadedJournal, to: journalURL, testHooks: testHooks)
                    }
                }

                // A durable tombstone always wins. Cleanup is deliberately best
                // effort and is retried on every healthy restart.
                for record in loadedJournal.records where record.stage == .deleted {
                    _ = Self.removeSources(
                        recordingID: record.recordingID,
                        incomingDirectory: incomingDirectory,
                        recordingsDirectory: recordingsDirectory
                    )
                }
            }
        } catch {
            // Do not rename, truncate, repair, or delete anything when the
            // journal cannot be trusted. The caller can surface this health
            // state and retain every recoverable audio file for support.
            loadedJournal = Journal.empty
            loadedHealth = .readOnly(
                message: "Saved recordings need attention. No files were changed."
            )
        }

        self.journal = loadedJournal
        self.health = loadedHealth
        self.transientRoot = loadedTransientRoot
    }

    // MARK: - Read API

    func view() -> View {
        View(
            health: health,
            clearGeneration: journal.clearGeneration,
            revision: journal.revision,
            records: journal.records.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.recordingID.uuidString < rhs.recordingID.uuidString
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        )
    }

    func record(for recordingID: UUID) -> Record? {
        journal.records.first { $0.recordingID == recordingID }
    }

    nonisolated func partialURL(for recordingID: UUID) -> URL {
        incomingDirectory.appendingPathComponent("\(recordingID.uuidString).partial.m4a", isDirectory: false)
    }

    nonisolated func finalURL(for recordingID: UUID) -> URL {
        recordingsDirectory.appendingPathComponent("\(recordingID.uuidString).m4a", isDirectory: false)
    }

    /// Creates an attempt-scoped directory for derived exports. The returned
    /// capability owns an open directory descriptor, so Delete/Clear can remove
    /// the original derived files even if a same-user process later substitutes
    /// one of the path ancestors. New path-based writes fail closed after such a
    /// substitution.
    func makeTransientWorkspace(_ lease: Lease) throws -> MacTransientWorkspace {
        try requireWritable()
        let current = try currentRecord(for: lease)
        guard current.stage == .recognizing else { throw StoreError.invalidTransition }
        guard let transientRoot else { throw StoreError.storageUnavailable }
        do {
            return try transientRoot.makeWorkspace(
                recordingID: current.recordingID,
                attemptID: current.attemptID
            )
        } catch {
            health = .readOnly(
                message: "Saved recordings need attention. No files were changed."
            )
            throw StoreError.readOnly
        }
    }

    // MARK: - Recording lifecycle

    /// Persists the stable recording identity before creating the source file.
    /// The returned lease is the only owner allowed to advance this attempt.
    func prepare(recordingID: UUID, attemptID: UUID, deadline: Date) throws -> Mutation {
        try requireWritable()
        guard recordingID != attemptID else { throw StoreError.invalidIdentity }
        guard deadline > testHooks.now() else { throw StoreError.invalidDeadline }
        guard journal.records.first(where: { $0.recordingID == recordingID }) == nil else {
            throw StoreError.duplicateRecording
        }

        let revision = try nextRevision(after: journal.revision)
        let now = testHooks.now()
        let record = Record(
            recordingID: recordingID,
            attemptID: attemptID,
            stage: .preparing,
            source: .partial,
            revision: revision,
            clearGeneration: journal.clearGeneration,
            deadline: deadline,
            audioIntegrity: nil,
            rawText: nil,
            resultText: nil,
            failureMessage: nil,
            updatedAt: now
        )

        var proposed = journal
        proposed.revision = revision
        proposed.records.append(record)
        let partialURL = partialURL(for: recordingID)
        let finalURL = finalURL(for: recordingID)
        var creationFailure: StoreError?
        try commit(proposed) {
            guard !FileManager.default.fileExists(atPath: partialURL.path),
                  !FileManager.default.fileExists(atPath: finalURL.path) else {
                creationFailure = .sourceConflict
                return
            }
            do {
                // The journal identity is already durable and the cross-instance
                // lock remains held. Exclusive creation prevents truncating an
                // unexpected source.
                try Data().write(to: partialURL, options: .withoutOverwriting)
            } catch {
                creationFailure = .storageUnavailable
            }
        }

        if let creationFailure {
            _ = try? failCurrentRecord(
                recordingID: recordingID,
                message: creationFailure == .sourceConflict
                    ? "Saved audio already exists for this recording. No files were changed."
                    : "The recording could not be saved. Please check available storage and try again."
            )
            throw creationFailure
        }

        guard let stored = self.record(for: recordingID) else {
            throw StoreError.recordingNotFound
        }
        return mutation(for: stored)
    }

    func markRecording(_ lease: Lease, captureDeadline: Date) throws -> Mutation {
        guard captureDeadline > testHooks.now() else { throw StoreError.invalidDeadline }
        return try transition(
            lease,
            from: .preparing,
            to: .recording,
            deadline: captureDeadline
        )
    }

    /// Copies a legacy finalized recording into the managed layout without
    /// modifying its original source. The clear generation is caller-visible
    /// CAS state so a stale History row cannot be adopted after Clear.
    func adoptFinalizedSource(
        recordingID: UUID,
        attemptID: UUID,
        sourceURL: URL,
        expectedClearGeneration: UInt64,
        deadline: Date
    ) async throws -> Mutation {
        try requireWritable()
        guard recordingID != attemptID else { throw StoreError.invalidIdentity }
        guard deadline > testHooks.now() else { throw StoreError.invalidDeadline }
        guard expectedClearGeneration == journal.clearGeneration else {
            throw StoreError.staleLease
        }
        guard journal.records.first(where: { $0.recordingID == recordingID }) == nil else {
            throw StoreError.duplicateRecording
        }

        let sourcePath = sourceURL.standardizedFileURL.path
        let partialURL = partialURL(for: recordingID)
        let finalURL = finalURL(for: recordingID)
        guard sourcePath != partialURL.standardizedFileURL.path,
              sourcePath != finalURL.standardizedFileURL.path else {
            throw StoreError.sourceConflict
        }
        let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard sourceSize > 0 else { throw StoreError.invalidAudio }
        guard Int64(sourceSize) <= Self.maximumAdoptedAudioBytes else {
            throw StoreError.sourceTooLarge
        }
        let sourceVerification = try await Self.deeplyVerifyClosedAudio(
            at: sourceURL,
            deadline: deadline,
            testHooks: testHooks
        )
        let sourceIntegrity = sourceVerification.integrity
        guard deadline > testHooks.now() else { throw StoreError.invalidDeadline }
        guard expectedClearGeneration == journal.clearGeneration,
              journal.records.first(where: { $0.recordingID == recordingID }) == nil else {
            throw StoreError.staleLease
        }

        let revision = try nextRevision(after: journal.revision)
        let record = Record(
            recordingID: recordingID,
            attemptID: attemptID,
            stage: .finalizing,
            source: .partial,
            revision: revision,
            clearGeneration: journal.clearGeneration,
            deadline: deadline,
            audioIntegrity: nil,
            rawText: nil,
            resultText: nil,
            failureMessage: nil,
            updatedAt: Date()
        )
        var proposed = journal
        proposed.revision = revision
        proposed.records.append(record)

        var copyFailure: StoreError?
        try commit(proposed) {
            guard !FileManager.default.fileExists(atPath: partialURL.path),
                  !FileManager.default.fileExists(atPath: finalURL.path) else {
                copyFailure = .sourceConflict
                return
            }
            do {
                try FileManager.default.copyItem(at: sourceURL, to: partialURL)
            } catch {
                copyFailure = .storageUnavailable
            }
        }

        if let copyFailure {
            _ = try? failCurrentRecord(
                recordingID: recordingID,
                message: copyFailure == .sourceConflict
                    ? "Saved audio already exists for this recording. No files were changed."
                    : "The recording could not be imported. The original file was not changed."
            )
            throw copyFailure
        }

        guard let staged = self.record(for: recordingID) else {
            throw StoreError.recordingNotFound
        }
        let stagedLease = mutation(for: staged).lease
        let managedProof = try await proveClosedAudio(stagedLease)
        let checkpoint = try checkpointClosedAudio(stagedLease, proof: managedProof)
        let ready = try finishFinalization(
            checkpoint.lease,
            proof: managedProof
        )
        guard ready.record.audioIntegrity == sourceIntegrity else {
            _ = try? fail(
                ready.lease,
                message: "The imported recording could not be verified. The original file was not changed."
            )
            throw StoreError.invalidAudio
        }
        return ready
    }

    func beginFinalization(_ lease: Lease, deadline: Date) throws -> Mutation {
        let now = testHooks.now()
        guard deadline > now else { throw StoreError.invalidDeadline }
        try requireWritable()
        let current = try currentRecord(for: lease)
        guard current.stage == .recording else { throw StoreError.invalidTransition }
        // Scheduling at the exact capture boundary can arrive a fraction late.
        // Only this atomic recording->finalizing handoff may renew the lease,
        // and only within a small caller-supplied grace window.
        guard now.timeIntervalSince(current.deadline) <= 5 else {
            throw StoreError.invalidDeadline
        }
        return try transition(
            lease,
            from: .recording,
            to: .finalizing,
            deadline: deadline,
            permitsExpiredCurrentDeadline: true
        )
    }

    /// Creates an immutable content proof after the recorder reports that this
    /// exact attempt closed its writer. This does not advance journal state.
    func proveClosedAudio(_ lease: Lease) async throws -> ClosedAudioProof {
        try requireWritable()
        let current = try currentRecord(for: lease)
        guard current.stage == .finalizing else { throw StoreError.invalidTransition }
        let source = sourceKind(for: current.recordingID)
        let url: URL
        switch source {
        case .partial:
            url = partialURL(for: current.recordingID)
        case .final:
            url = finalURL(for: current.recordingID)
        case .both:
            throw StoreError.sourceConflict
        case .missing:
            throw StoreError.sourceMissing
        }
        let integrity = try await verifyClosedAudioBeforeDeadline(
            for: current,
            at: url,
            deadline: current.deadline
        )
        return Self.closedProof(attemptID: current.attemptID, integrity: integrity)
    }

    /// Persists the exact closed-container proof before the atomic source move.
    /// This checkpoint makes the move-before-ready crash window recoverable
    /// without accepting a merely nonempty or shorter valid container.
    func checkpointClosedAudio(
        _ lease: Lease,
        proof: ClosedAudioProof
    ) throws -> Mutation {
        try requireWritable()
        let current = try currentRecord(for: lease)
        guard current.stage == .finalizing else { throw StoreError.invalidTransition }
        guard proof.attemptID == lease.attemptID else { throw StoreError.staleLease }
        guard proof.expectedByteCount > 0,
              proof.expectedFrameCount > 0,
              !proof.expectedSHA256.isEmpty else {
            throw StoreError.invalidAudio
        }
        let source = sourceKind(for: current.recordingID)
        let url: URL
        switch source {
        case .partial: url = partialURL(for: current.recordingID)
        case .final: url = finalURL(for: current.recordingID)
        case .both: throw StoreError.sourceConflict
        case .missing: throw StoreError.sourceMissing
        }
        let integrity = try validatedClosedAudio(for: current, at: url)
        guard Self.matches(proof: proof, integrity: integrity) else {
            throw StoreError.invalidAudio
        }
        if current.audioIntegrity == integrity {
            return mutation(for: current)
        }
        return try transition(
            lease,
            from: .finalizing,
            to: .finalizing,
            audioIntegrity: integrity
        )
    }

    /// Atomically renames the completed partial source before journaling it as
    /// ready. If the process stops between those operations, restart recovery
    /// recognizes `finalizing + final file` and completes the journal step.
    func finishFinalization(_ lease: Lease, proof: ClosedAudioProof) throws -> Mutation {
        try requireWritable()
        let current = try currentRecord(for: lease)
        guard current.stage == .finalizing else { throw StoreError.invalidTransition }
        guard proof.attemptID == lease.attemptID else { throw StoreError.staleLease }
        guard proof.expectedByteCount > 0,
              proof.expectedFrameCount > 0,
              !proof.expectedSHA256.isEmpty else {
            _ = try? fail(
                lease,
                message: "The recording did not finish saving correctly. Your file was preserved."
            )
            throw StoreError.invalidAudio
        }

        guard let checkpointedIntegrity = current.audioIntegrity,
              Self.matches(proof: proof, integrity: checkpointedIntegrity) else {
            throw StoreError.invalidTransition
        }

        let partialURL = partialURL(for: current.recordingID)
        let finalURL = finalURL(for: current.recordingID)
        let partialExists = FileManager.default.fileExists(atPath: partialURL.path)
        let finalExists = FileManager.default.fileExists(atPath: finalURL.path)

        if partialExists && finalExists {
            throw StoreError.sourceConflict
        }
        if !partialExists && !finalExists {
            throw StoreError.sourceMissing
        }

        let sourceURL = partialExists ? partialURL : finalURL
        let validatedIntegrity = try validatedClosedAudio(for: current, at: sourceURL)
        guard validatedIntegrity == checkpointedIntegrity else {
            _ = try? fail(
                lease,
                message: "The recording did not finish saving completely. Your file was preserved."
            )
            throw StoreError.invalidAudio
        }
        guard testHooks.now() <= current.deadline else { throw StoreError.invalidDeadline }

        if partialExists {
            try Self.syncDirectory(
                incomingDirectory,
                operation: .sourceDirectorySync,
                testHooks: testHooks
            )
            try Self.syncDirectory(
                recordingsDirectory,
                operation: .sourceDirectorySync,
                testHooks: testHooks
            )
            do {
                try testHooks.before(.sourceRename)
                let renameResult = partialURL.path.withCString { source in
                    finalURL.path.withCString { destination in
                        Darwin.rename(source, destination)
                    }
                }
                guard renameResult == 0 else { throw StoreError.storageUnavailable }
                try Self.syncDirectory(
                    incomingDirectory,
                    operation: .sourceDirectorySync,
                    testHooks: testHooks
                )
                try Self.syncDirectory(
                    recordingsDirectory,
                    operation: .sourceDirectorySync,
                    testHooks: testHooks
                )
            } catch let error as StoreError {
                throw error
            } catch {
                throw StoreError.storageUnavailable
            }
        } else {
            try Self.syncDirectory(
                recordingsDirectory,
                operation: .sourceDirectorySync,
                testHooks: testHooks
            )
        }
        guard let cached = closedAudioValidations[current.recordingID],
              cached.integrity == validatedIntegrity,
              Self.matchesCachedSource(cached, at: finalURL) else {
            _ = try? fail(
                lease,
                message: "The recording changed while it was being saved. Your file was preserved."
            )
            throw StoreError.invalidAudio
        }

        try cacheClosedAudio(
            validatedIntegrity,
            for: current,
            at: finalURL
        )
        guard let finalizedValidation = closedAudioValidations[current.recordingID] else {
            throw StoreError.invalidAudio
        }

        let ready = try transition(
            lease,
            from: .finalizing,
            to: .readyForRecognition,
            source: .final,
            audioIntegrity: validatedIntegrity,
            audioFileIdentity: finalizedValidation.fileIdentity
        )
        return ready
    }

    /// Starts a new, independently fenced recognition attempt against a
    /// complete final source. A failed recognition can be retried without
    /// replacing or deleting the recording.
    func beginRecognition(
        recordingID: UUID,
        attemptID: UUID,
        expectedRevision: UInt64,
        deadline: Date
    ) async throws -> Mutation {
        try requireWritable()
        guard recordingID != attemptID else { throw StoreError.invalidIdentity }
        guard deadline > testHooks.now() else { throw StoreError.invalidDeadline }
        guard let index = index(of: recordingID) else { throw StoreError.recordingNotFound }
        let current = journal.records[index]
        guard current.stage != .deleted else { throw StoreError.recordingDeleted }
        guard current.revision == expectedRevision else { throw StoreError.staleLease }
        guard current.stage == .readyForRecognition
                || current.stage == .failed
                || current.stage == .succeeded
        else {
            throw StoreError.invalidTransition
        }

        let finalURL = finalURL(for: recordingID)
        let partialExists = FileManager.default.fileExists(atPath: partialURL(for: recordingID).path)
        let finalExists = FileManager.default.fileExists(atPath: finalURL.path)
        guard finalExists else {
            throw StoreError.sourceMissing
        }
        guard !partialExists else { throw StoreError.sourceConflict }

        guard let expectedIntegrity = current.audioIntegrity else {
            throw StoreError.invalidAudio
        }
        let actualIdentity = try Self.fileIdentity(at: finalURL)
        let verifiedIdentity: AudioFileIdentity
        if let persistedIdentity = current.audioFileIdentity,
           persistedIdentity == actualIdentity,
           persistedIdentity.byteCount == expectedIntegrity.byteCount {
            verifiedIdentity = persistedIdentity
        } else if let cached = closedAudioValidations[recordingID],
                  cached.integrity == expectedIntegrity,
                  Self.matchesCachedSource(cached, at: finalURL) {
            verifiedIdentity = cached.fileIdentity
        } else {
            let verification = try await Self.deeplyVerifyClosedAudio(
                at: finalURL,
                deadline: deadline,
                testHooks: testHooks
            )
            guard verification.integrity == expectedIntegrity else {
                throw StoreError.invalidAudio
            }
            verifiedIdentity = verification.fileIdentity
        }
        guard deadline > testHooks.now() else { throw StoreError.invalidDeadline }

        // Deep verification deliberately runs detached so its deadline can win.
        // Re-check all ownership after the suspension before publishing anything.
        guard let refreshedIndex = self.index(of: recordingID) else {
            throw StoreError.recordingNotFound
        }
        let refreshed = journal.records[refreshedIndex]
        guard refreshed == current,
              refreshedIndex == index,
              sourceKind(for: recordingID) == .final else {
            throw StoreError.staleLease
        }

        let revision = try nextRevision(after: journal.revision)
        var proposed = journal
        proposed.revision = revision
        proposed.records[refreshedIndex].attemptID = attemptID
        proposed.records[refreshedIndex].stage = .recognizing
        proposed.records[refreshedIndex].source = .final
        proposed.records[refreshedIndex].revision = revision
        proposed.records[refreshedIndex].clearGeneration = proposed.clearGeneration
        proposed.records[refreshedIndex].deadline = deadline
        proposed.records[refreshedIndex].audioFileIdentity = verifiedIdentity
        proposed.records[refreshedIndex].rawText = nil
        proposed.records[refreshedIndex].resultText = nil
        proposed.records[refreshedIndex].failureMessage = nil
        proposed.records[refreshedIndex].pendingUsageWordCount = nil
        proposed.records[refreshedIndex].usageWasClaimed = nil
        proposed.records[refreshedIndex].updatedAt = Date()
        try commit(proposed)
        return mutation(for: proposed.records[refreshedIndex])
    }

    /// Durably checkpoints complete raw recognition before optional cleanup.
    /// Cleanup may never replace or erase this value.
    func checkpointRecognition(_ lease: Lease, partialText: String) throws -> Mutation {
        let normalized = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw StoreError.invalidTransition }

        let current = try currentRecord(for: lease)
        guard current.stage == .recognizing else { throw StoreError.invalidTransition }
        if let previous = current.rawText {
            let normalizedPrevious = previous.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized == normalizedPrevious || normalized.hasPrefix(normalizedPrevious) else {
                throw StoreError.invalidTransition
            }
            if normalized == normalizedPrevious {
                return mutation(for: current)
            }
        }

        return try transition(
            lease,
            from: .recognizing,
            to: .recognizing,
            rawText: normalized
        )
    }

    /// Durably checkpoints complete raw recognition before optional cleanup.
    /// Cleanup may never replace or erase this value.
    func markRawResultReady(_ lease: Lease, rawText: String) throws -> Mutation {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw StoreError.invalidTransition }
        let current = try currentRecord(for: lease)
        if let checkpoint = current.rawText {
            let normalizedCheckpoint = checkpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized == normalizedCheckpoint || normalized.hasPrefix(normalizedCheckpoint) else {
                throw StoreError.invalidTransition
            }
        }
        return try transition(
            lease,
            from: .recognizing,
            to: .rawResultReady,
            rawText: rawText
        )
    }

    func beginCleanup(_ lease: Lease) throws -> Mutation {
        try transition(lease, from: .rawResultReady, to: .cleaning)
    }

    /// Empty or whitespace-only cleanup output falls back to the complete raw
    /// transcript. A cleanup timeout/failure should call `useRawResult`.
    func finishCleanup(_ lease: Lease, cleanedText: String?) throws -> Mutation {
        let current = try currentRecord(for: lease)
        guard current.stage == .cleaning, let rawText = current.rawText else {
            throw StoreError.invalidTransition
        }
        if testHooks.now() > current.deadline {
            return try useRawResult(
                lease,
                message: "Cleanup took too long. The complete raw transcript was kept."
            )
        }
        let finalText: String
        if let cleanedText,
           !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalText = cleanedText
        } else {
            finalText = rawText
        }
        return try transition(
            lease,
            from: .cleaning,
            to: .resultReady,
            resultText: finalText
        )
    }

    func useRawResult(_ lease: Lease, message: String? = nil) throws -> Mutation {
        let current = try currentRecord(for: lease)
        guard current.stage == .rawResultReady || current.stage == .cleaning,
              let rawText = current.rawText else {
            throw StoreError.invalidTransition
        }
        return try transition(
            lease,
            from: current.stage,
            to: .resultReady,
            resultText: rawText,
            failureMessage: message.map(normalizedFailureMessage)
        )
    }

    func markSucceeded(
        _ lease: Lease,
        pendingUsageWordCount: Int? = nil
    ) throws -> Mutation {
        if let pendingUsageWordCount {
            guard pendingUsageWordCount > 0 else { throw StoreError.invalidTransition }
        }
        return try transition(
            lease,
            from: .resultReady,
            to: .succeeded,
            pendingUsageWordCount: pendingUsageWordCount,
            resetsUsageClaim: pendingUsageWordCount != nil
        )
    }

    /// Atomically claims one pending usage event. A crash after this commit can
    /// under-report, but it can never charge twice. Callers must not invoke this
    /// until both the terminal journal and History projection are durable.
    func claimPendingUsage(
        recordingID: UUID,
        expectedRevision: UInt64
    ) throws -> Int? {
        try requireWritable()
        guard let index = index(of: recordingID) else {
            throw StoreError.recordingNotFound
        }
        let current = journal.records[index]
        guard current.stage == .succeeded,
              current.revision == expectedRevision else {
            throw StoreError.staleLease
        }
        guard current.usageWasClaimed != true,
              let wordCount = current.pendingUsageWordCount,
              wordCount > 0 else {
            return nil
        }

        let revision = try nextRevision(after: journal.revision)
        var proposed = journal
        proposed.revision = revision
        proposed.records[index].revision = revision
        proposed.records[index].usageWasClaimed = true
        proposed.records[index].updatedAt = Date()
        try commit(proposed)
        return wordCount
    }

    /// Records a terminal failure while preserving every source file. This is
    /// also the correct operation for transport deadlines and cancellations.
    func fail(_ lease: Lease, message: String) throws -> Mutation {
        try requireWritable()
        let current = try currentRecord(for: lease)
        if current.stage == .rawResultReady || current.stage == .cleaning {
            return try useRawResult(lease, message: message)
        }
        guard current.stage != .deleted, current.stage != .succeeded else {
            throw StoreError.invalidTransition
        }
        return try transition(
            lease,
            from: current.stage,
            to: .failed,
            source: sourceKind(for: current.recordingID),
            failureMessage: normalizedFailureMessage(message)
        )
    }

    func timeOut(_ lease: Lease) throws -> Mutation {
        let current = try currentRecord(for: lease)
        let message: String
        switch current.stage {
        case .preparing, .recording, .finalizing:
            message = "Processing took too long. Any captured audio was kept for recovery."
        case .rawResultReady, .cleaning:
            message = "Cleanup took too long. The complete raw transcript was kept."
        case .readyForRecognition, .recognizing, .resultReady, .failed:
            message = "Processing took too long. Your recording is saved and can be retried."
        case .succeeded, .deleted:
            throw StoreError.invalidTransition
        }
        return try fail(
            lease,
            message: message
        )
    }

    /// Revalidates a failed partial only after its former writer is known to be
    /// closed (for example, after restart). It remains failed until a fresh
    /// salvage attempt successfully promotes it.
    func proveRecoverablePartial(
        recordingID: UUID,
        expectedRevision: UInt64,
        expectedClearGeneration: UInt64,
        deadline: Date
    ) async throws -> ClosedAudioProof {
        try requireWritable()
        guard deadline > testHooks.now() else { throw StoreError.invalidDeadline }
        guard let current = record(for: recordingID) else { throw StoreError.recordingNotFound }
        guard current.stage != .deleted else { throw StoreError.recordingDeleted }
        guard current.stage == .failed,
              current.revision == expectedRevision,
              current.clearGeneration == expectedClearGeneration,
              journal.clearGeneration == expectedClearGeneration else {
            throw StoreError.staleLease
        }
        guard sourceKind(for: recordingID) == .partial else {
            throw StoreError.invalidTransition
        }
        let integrity = try await verifyClosedAudioBeforeDeadline(
            for: current,
            at: partialURL(for: recordingID),
            deadline: deadline
        )
        return Self.closedProof(attemptID: current.attemptID, integrity: integrity)
    }

    func salvageFinalizedPartial(
        recordingID: UUID,
        salvageAttemptID: UUID,
        expectedRevision: UInt64,
        expectedClearGeneration: UInt64,
        deadline: Date,
        proof: ClosedAudioProof
    ) throws -> Mutation {
        try requireWritable()
        guard salvageAttemptID != recordingID,
              salvageAttemptID != proof.attemptID else {
            throw StoreError.invalidIdentity
        }
        guard deadline > testHooks.now() else { throw StoreError.invalidDeadline }
        guard let index = index(of: recordingID) else { throw StoreError.recordingNotFound }
        let current = journal.records[index]
        guard current.stage != .deleted else { throw StoreError.recordingDeleted }
        guard current.stage == .failed,
              current.attemptID == proof.attemptID,
              current.revision == expectedRevision,
              current.clearGeneration == expectedClearGeneration,
              journal.clearGeneration == expectedClearGeneration else {
            throw StoreError.staleLease
        }
        guard sourceKind(for: recordingID) == .partial else {
            throw StoreError.invalidTransition
        }
        let integrity = try validatedClosedAudio(
            for: current,
            at: partialURL(for: recordingID)
        )
        guard Self.matches(proof: proof, integrity: integrity) else {
            throw StoreError.invalidAudio
        }
        guard deadline > testHooks.now() else { throw StoreError.invalidDeadline }

        let revision = try nextRevision(after: journal.revision)
        var proposed = journal
        proposed.revision = revision
        proposed.records[index].attemptID = salvageAttemptID
        proposed.records[index].stage = .finalizing
        proposed.records[index].revision = revision
        proposed.records[index].deadline = deadline
        proposed.records[index].audioIntegrity = nil
        proposed.records[index].failureMessage = nil
        proposed.records[index].updatedAt = Date()
        try commit(proposed)

        let lease = mutation(for: proposed.records[index]).lease
        try cacheClosedAudio(
            integrity,
            for: proposed.records[index],
            at: partialURL(for: recordingID)
        )
        let freshProof = Self.closedProof(
            attemptID: salvageAttemptID,
            integrity: integrity
        )
        let checkpoint = try checkpointClosedAudio(lease, proof: freshProof)
        return try finishFinalization(
            checkpoint.lease,
            proof: freshProof
        )
    }

    // MARK: - Destructive lifecycle

    /// Persists a tombstone before deleting either source path. This operation
    /// intentionally does not require the active lease: an explicit user delete
    /// must beat an in-flight callback.
    func tombstone(recordingID: UUID) throws -> CleanupResult {
        try requireWritable()
        guard let index = index(of: recordingID) else { throw StoreError.recordingNotFound }

        if journal.records[index].stage != .deleted {
            let revision = try nextRevision(after: journal.revision)
            var proposed = journal
            proposed.revision = revision
            proposed.records[index].stage = .deleted
            proposed.records[index].revision = revision
            proposed.records[index].clearGeneration = proposed.clearGeneration
            proposed.records[index].audioIntegrity = nil
            proposed.records[index].audioFileIdentity = nil
            proposed.records[index].rawText = nil
            proposed.records[index].resultText = nil
            proposed.records[index].failureMessage = nil
            proposed.records[index].pendingUsageWordCount = nil
            proposed.records[index].usageWasClaimed = nil
            proposed.records[index].updatedAt = Date()
            try commit(proposed)
        }
        closedAudioValidations.removeValue(forKey: recordingID)
        transientRoot?.invalidate(recordingID: recordingID)

        return CleanupResult(
            failedURLs: Self.removeSources(
                recordingID: recordingID,
                incomingDirectory: incomingDirectory,
                recordingsDirectory: recordingsDirectory
            )
        )
    }

    /// Advances the persisted clear generation and tombstones every known
    /// record in one atomic journal write. Old leases are invalid before any
    /// source deletion starts; recordings created afterward use the new
    /// generation and remain valid.
    func clearAll() throws -> CleanupResult {
        try requireWritable()
        let newGeneration = try nextRevision(after: journal.clearGeneration)
        var proposed = journal
        proposed.clearGeneration = newGeneration

        for index in proposed.records.indices {
            let revision = try nextRevision(after: proposed.revision)
            proposed.revision = revision
            proposed.records[index].stage = .deleted
            proposed.records[index].revision = revision
            proposed.records[index].clearGeneration = newGeneration
            proposed.records[index].audioIntegrity = nil
            proposed.records[index].audioFileIdentity = nil
            proposed.records[index].rawText = nil
            proposed.records[index].resultText = nil
            proposed.records[index].failureMessage = nil
            proposed.records[index].pendingUsageWordCount = nil
            proposed.records[index].usageWasClaimed = nil
            proposed.records[index].updatedAt = Date()
        }

        // Even an empty clear is durable and invalidates leases from another
        // in-memory owner of this journal generation.
        if proposed.records.isEmpty {
            proposed.revision = try nextRevision(after: proposed.revision)
        }

        try commit(proposed)
        closedAudioValidations.removeAll()
        transientRoot?.invalidateAll()

        var failures: [URL] = []
        for record in proposed.records {
            failures.append(contentsOf: Self.removeSources(
                recordingID: record.recordingID,
                incomingDirectory: incomingDirectory,
                recordingsDirectory: recordingsDirectory
            ))
        }
        return CleanupResult(failedURLs: failures)
    }

    // MARK: - Mutation helpers

    private func transition(
        _ lease: Lease,
        from expectedStage: Stage,
        to nextStage: Stage,
        source: SourceKind? = nil,
        audioIntegrity: AudioIntegrity? = nil,
        audioFileIdentity: AudioFileIdentity? = nil,
        rawText: String? = nil,
        resultText: String? = nil,
        failureMessage: String? = nil,
        deadline: Date? = nil,
        permitsExpiredCurrentDeadline: Bool = false,
        pendingUsageWordCount: Int? = nil,
        resetsUsageClaim: Bool = false
    ) throws -> Mutation {
        try requireWritable()
        let current = try currentRecord(for: lease)
        guard current.stage == expectedStage else { throw StoreError.invalidTransition }
        guard Self.isAllowedTransition(from: expectedStage, to: nextStage) else {
            throw StoreError.invalidTransition
        }
        let preservesCompletedWork = nextStage == .failed
            || nextStage == .succeeded
            || ((expectedStage == .rawResultReady || expectedStage == .cleaning) && nextStage == .resultReady)
        guard preservesCompletedWork
                || permitsExpiredCurrentDeadline
                || testHooks.now() <= current.deadline else {
            throw StoreError.invalidDeadline
        }

        let revision = try nextRevision(after: journal.revision)
        guard let index = index(of: current.recordingID) else {
            throw StoreError.recordingNotFound
        }

        var proposed = journal
        proposed.revision = revision
        proposed.records[index].stage = nextStage
        proposed.records[index].source = source ?? proposed.records[index].source
        if let audioIntegrity {
            proposed.records[index].audioIntegrity = audioIntegrity
        }
        if let audioFileIdentity {
            proposed.records[index].audioFileIdentity = audioFileIdentity
        }
        if let deadline {
            proposed.records[index].deadline = deadline
        }
        proposed.records[index].revision = revision
        if let rawText {
            proposed.records[index].rawText = rawText
        }
        if let resultText {
            proposed.records[index].resultText = resultText
        }
        if let pendingUsageWordCount {
            proposed.records[index].pendingUsageWordCount = pendingUsageWordCount
        }
        if resetsUsageClaim {
            proposed.records[index].usageWasClaimed = false
        }
        proposed.records[index].failureMessage = failureMessage
        proposed.records[index].updatedAt = Date()
        try commit(proposed)
        return mutation(for: proposed.records[index])
    }

    private func failCurrentRecord(recordingID: UUID, message: String) throws -> Mutation {
        try requireWritable()
        guard let index = index(of: recordingID) else { throw StoreError.recordingNotFound }
        guard journal.records[index].stage != .deleted else { throw StoreError.recordingDeleted }

        let revision = try nextRevision(after: journal.revision)
        var proposed = journal
        proposed.revision = revision
        proposed.records[index].stage = .failed
        proposed.records[index].source = sourceKind(for: recordingID)
        proposed.records[index].revision = revision
        proposed.records[index].failureMessage = normalizedFailureMessage(message)
        proposed.records[index].updatedAt = Date()
        try commit(proposed)
        return mutation(for: proposed.records[index])
    }

    private func currentRecord(for lease: Lease) throws -> Record {
        guard let current = record(for: lease.recordingID) else {
            throw StoreError.recordingNotFound
        }
        guard current.stage != .deleted else { throw StoreError.recordingDeleted }
        guard lease.clearGeneration == journal.clearGeneration,
              lease.clearGeneration == current.clearGeneration,
              lease.attemptID == current.attemptID,
              lease.revision == current.revision else {
            throw StoreError.staleLease
        }
        return current
    }

    private func mutation(for record: Record) -> Mutation {
        Mutation(
            lease: Lease(
                recordingID: record.recordingID,
                attemptID: record.attemptID,
                clearGeneration: record.clearGeneration,
                revision: record.revision
            ),
            record: record
        )
    }

    private func index(of recordingID: UUID) -> Int? {
        journal.records.firstIndex { $0.recordingID == recordingID }
    }

    private func requireWritable() throws {
        guard case .healthy = health else { throw StoreError.readOnly }
    }

    private func nextRevision(after revision: UInt64) throws -> UInt64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else { throw StoreError.revisionExhausted }
        return next
    }

    private func commit(
        _ proposed: Journal,
        afterPersistWhileLocked: (() -> Void)? = nil
    ) throws {
        do {
            try Self.validate(proposed)
            try Self.withExclusiveLock(at: lockURL) {
                let diskJournal = try Self.loadJournalForCAS(at: journalURL, base: journal)
                try Self.validateManagedSources(
                    diskJournal,
                    incomingDirectory: incomingDirectory,
                    recordingsDirectory: recordingsDirectory
                )
                guard Self.sameCASState(diskJournal, journal) else {
                    throw StoreError.staleLease
                }
                try Self.persist(proposed, to: journalURL, testHooks: testHooks)
                afterPersistWhileLocked?()
            }
            journal = proposed
        } catch let error as StoreError {
            if error == .readOnly {
                health = .readOnly(message: "Saved recordings need attention. No files were changed.")
            }
            throw error
        } catch {
            throw StoreError.storageUnavailable
        }
    }

    private func sourceKind(for recordingID: UUID) -> SourceKind {
        Self.sourceKind(
            recordingID: recordingID,
            incomingDirectory: incomingDirectory,
            recordingsDirectory: recordingsDirectory
        )
    }

    private func validatedClosedAudio(
        for record: Record,
        at url: URL
    ) throws -> AudioIntegrity {
        if let cached = closedAudioValidations[record.recordingID],
           cached.attemptID == record.attemptID,
           cached.clearGeneration == record.clearGeneration,
           cached.sourcePath == url.standardizedFileURL.path,
           Self.matchesCachedSource(cached, at: url) {
            return cached.integrity
        }
        // All full decode/hash work must enter through the detached,
        // deadline-fenced verifier. A cache miss here is never permission to
        // block the store actor synchronously.
        throw StoreError.invalidAudio
    }

    private func verifyClosedAudioBeforeDeadline(
        for record: Record,
        at url: URL,
        deadline: Date
    ) async throws -> AudioIntegrity {
        if let cached = closedAudioValidations[record.recordingID],
           cached.attemptID == record.attemptID,
           cached.clearGeneration == record.clearGeneration,
           cached.sourcePath == url.standardizedFileURL.path,
           Self.matchesCachedSource(cached, at: url) {
            return cached.integrity
        }

        let verification = try await Self.deeplyVerifyClosedAudio(
            at: url,
            deadline: deadline,
            testHooks: testHooks
        )
        try requireWritable()
        guard let refreshed = self.record(for: record.recordingID),
              refreshed == record,
              sourceKind(for: record.recordingID) != .missing,
              (try? Self.fileIdentity(at: url)) == verification.fileIdentity else {
            throw StoreError.staleLease
        }
        try cacheClosedAudio(verification.integrity, for: refreshed, at: url)
        return verification.integrity
    }

    private func cacheClosedAudio(
        _ integrity: AudioIntegrity,
        for record: Record,
        at url: URL
    ) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard values.isRegularFile == true,
              values.fileSize == Int(integrity.byteCount),
              let modificationDate = values.contentModificationDate else {
            throw StoreError.invalidAudio
        }
        closedAudioValidations[record.recordingID] = ClosedAudioValidation(
            attemptID: record.attemptID,
            clearGeneration: record.clearGeneration,
            sourcePath: url.standardizedFileURL.path,
            modificationDate: modificationDate,
            integrity: integrity,
            fileIdentity: try Self.fileIdentity(at: url)
        )
    }

    private static func matchesCachedSource(
        _ cached: ClosedAudioValidation,
        at url: URL
    ) -> Bool {
        guard let identity = try? fileIdentity(at: url) else { return false }
        return identity == cached.fileIdentity
            && identity.byteCount == cached.integrity.byteCount
    }

    private func normalizedFailureMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "Processing could not finish. Your recording is saved and can be retried."
            : trimmed
    }

    private static func isAllowedTransition(from: Stage, to: Stage) -> Bool {
        switch (from, to) {
        case (.preparing, .recording),
             (.recording, .finalizing),
             (.finalizing, .finalizing),
             (.finalizing, .readyForRecognition),
             (.recognizing, .recognizing),
             (.recognizing, .rawResultReady),
             (.rawResultReady, .cleaning),
             (.rawResultReady, .resultReady),
             (.cleaning, .resultReady),
             (.resultReady, .succeeded):
            return true
        case (_, .failed):
            return from != .deleted && from != .succeeded
        default:
            return false
        }
    }

    // MARK: - Persistence and restart recovery

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func createDirectories(
        storeDirectory: URL,
        incomingDirectory: URL,
        recordingsDirectory: URL,
        transientDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transientDirectory, withIntermediateDirectories: true)
    }

    private static func persist(
        _ journal: Journal,
        to journalURL: URL,
        testHooks: TestHooks
    ) throws {
        let data = try makeEncoder().encode(journal)
        let directoryURL = journalURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(journalURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var descriptor: Int32 = -1
        var renamed = false

        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            if !renamed {
                _ = temporaryURL.path.withCString { Darwin.unlink($0) }
            }
        }

        descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw StoreError.storageUnavailable }

        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
                var remaining = bytes.count
                while remaining > 0 {
                    try testHooks.before(.journalWrite)
                    let written = Darwin.write(descriptor, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw StoreError.storageUnavailable
                    }
                    guard written > 0 else { throw StoreError.storageUnavailable }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
            try syncFileDescriptor(
                descriptor,
                operation: .journalFileSync,
                testHooks: testHooks
            )
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw StoreError.storageUnavailable
            }
            descriptor = -1

            try testHooks.before(.journalRename)
            let renameResult = temporaryURL.path.withCString { source in
                journalURL.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renameResult == 0 else { throw StoreError.storageUnavailable }
            renamed = true

            do {
                try syncDirectory(
                    directoryURL,
                    operation: .journalDirectorySync,
                    testHooks: testHooks
                )
            } catch {
                // The rename is visible but its crash durability is now unknown.
                // Stop all further mutation so memory can never race a journal
                // whose post-crash version is ambiguous.
                throw StoreError.readOnly
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.storageUnavailable
        }
    }

    private static func syncRegularFile(
        at url: URL,
        operation: TestOperation,
        testHooks: TestHooks
    ) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw StoreError.storageUnavailable }
        defer { _ = Darwin.close(descriptor) }

        var fileStatus = Darwin.stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            throw StoreError.invalidAudio
        }
        try syncFileDescriptor(
            descriptor,
            operation: operation,
            testHooks: testHooks
        )
    }

    private static func syncFileDescriptor(
        _ descriptor: Int32,
        operation: TestOperation,
        testHooks: TestHooks
    ) throws {
        do {
            try testHooks.before(operation)
        } catch {
            throw StoreError.storageUnavailable
        }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw StoreError.storageUnavailable
        }
    }

    private static func syncDirectory(
        _ directoryURL: URL,
        operation: TestOperation,
        testHooks: TestHooks
    ) throws {
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw StoreError.storageUnavailable }
        defer { _ = Darwin.close(descriptor) }

        var directoryStatus = Darwin.stat()
        guard Darwin.fstat(descriptor, &directoryStatus) == 0,
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw StoreError.storageUnavailable
        }
        do {
            try testHooks.before(operation)
        } catch {
            throw StoreError.storageUnavailable
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw StoreError.storageUnavailable
        }
    }

    private static func fileIdentity(at url: URL) throws -> AudioFileIdentity {
        var fileStatus = Darwin.stat()
        let result = url.path.withCString { Darwin.lstat($0, &fileStatus) }
        guard result == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_size > 0 else {
            throw StoreError.invalidAudio
        }
        return AudioFileIdentity(
            deviceID: UInt64(fileStatus.st_dev),
            inode: UInt64(fileStatus.st_ino),
            byteCount: Int64(fileStatus.st_size),
            modificationSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec)
        )
    }

    private static func loadJournalForCAS(at journalURL: URL, base: Journal) throws -> Journal {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            guard base == .empty else { throw StoreError.readOnly }
            return .empty
        }
        do {
            let data = try Data(contentsOf: journalURL)
            let diskJournal = try makeDecoder().decode(Journal.self, from: data)
            try validate(diskJournal)
            return diskJournal
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.readOnly
        }
    }

    private static func sameCASState(_ lhs: Journal, _ rhs: Journal) -> Bool {
        guard lhs.schemaVersion == rhs.schemaVersion,
              lhs.clearGeneration == rhs.clearGeneration,
              lhs.revision == rhs.revision,
              lhs.records.count == rhs.records.count else {
            return false
        }

        let left = lhs.records.sorted { $0.recordingID.uuidString < $1.recordingID.uuidString }
        let right = rhs.records.sorted { $0.recordingID.uuidString < $1.recordingID.uuidString }
        return zip(left, right).allSatisfy { lhsRecord, rhsRecord in
            lhsRecord.recordingID == rhsRecord.recordingID
                && lhsRecord.attemptID == rhsRecord.attemptID
                && lhsRecord.stage == rhsRecord.stage
                && lhsRecord.source == rhsRecord.source
                && lhsRecord.revision == rhsRecord.revision
                && lhsRecord.clearGeneration == rhsRecord.clearGeneration
                && abs(lhsRecord.deadline.timeIntervalSince1970
                    - rhsRecord.deadline.timeIntervalSince1970) < 0.001
                && lhsRecord.audioIntegrity == rhsRecord.audioIntegrity
                && lhsRecord.audioFileIdentity == rhsRecord.audioFileIdentity
                && lhsRecord.rawText == rhsRecord.rawText
                && lhsRecord.resultText == rhsRecord.resultText
                && lhsRecord.failureMessage == rhsRecord.failureMessage
                && lhsRecord.pendingUsageWordCount == rhsRecord.pendingUsageWordCount
                && lhsRecord.usageWasClaimed == rhsRecord.usageWasClaimed
        }
    }

    private static func withExclusiveLock<T>(at lockURL: URL, body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.storageUnavailable }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw StoreError.storageUnavailable
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func validate(_ journal: Journal) throws {
        guard journal.schemaVersion == Journal.currentSchemaVersion,
              journal.clearGeneration <= journal.revision else {
            throw StoreError.readOnly
        }

        var recordingIDs = Set<UUID>()
        for record in journal.records {
            guard recordingIDs.insert(record.recordingID).inserted,
                  record.recordingID != record.attemptID,
                  record.revision > 0,
                  record.revision <= journal.revision,
                  record.clearGeneration == journal.clearGeneration,
                  record.deadline.timeIntervalSinceReferenceDate.isFinite else {
                throw StoreError.readOnly
            }
            if record.stage == .resultReady, record.resultText == nil {
                throw StoreError.readOnly
            }
            if let identity = record.audioFileIdentity {
                guard identity.byteCount > 0,
                      identity.byteCount == record.audioIntegrity?.byteCount,
                      identity.modificationNanoseconds >= 0,
                      identity.modificationNanoseconds < 1_000_000_000 else {
                    throw StoreError.readOnly
                }
            }
            switch record.stage {
            case .readyForRecognition, .recognizing, .rawResultReady, .cleaning, .resultReady, .succeeded:
                guard record.source == .final, record.audioIntegrity != nil else {
                    throw StoreError.readOnly
                }
            case .preparing, .recording, .finalizing, .failed, .deleted:
                break
            }
            if record.stage == .rawResultReady || record.stage == .cleaning {
                guard let rawText = record.rawText,
                      !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StoreError.readOnly
                }
            }
            if record.stage == .recognizing,
               let rawText = record.rawText,
               rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw StoreError.readOnly
            }
            if record.stage == .succeeded, record.resultText == nil {
                throw StoreError.readOnly
            }
            if let wordCount = record.pendingUsageWordCount {
                guard record.stage == .succeeded, wordCount > 0 else {
                    throw StoreError.readOnly
                }
            }
            if record.usageWasClaimed == true,
               record.pendingUsageWordCount == nil {
                throw StoreError.readOnly
            }
        }
    }

    /// Unknown audio in this store layout means metadata was lost or replaced.
    /// Treat that as a corrupt journal instead of silently adopting, deleting,
    /// or orphaning files whose ownership cannot be proven.
    private static func validateManagedSources(
        _ journal: Journal,
        incomingDirectory: URL,
        recordingsDirectory: URL
    ) throws {
        let knownIDs = Set(journal.records.map(\.recordingID))
        let incomingIDs = try managedSourceIDs(
            in: incomingDirectory,
            suffix: ".partial.m4a"
        )
        let finalIDs = try managedSourceIDs(
            in: recordingsDirectory,
            suffix: ".m4a"
        )
        guard incomingIDs.isSubset(of: knownIDs), finalIDs.isSubset(of: knownIDs) else {
            throw StoreError.readOnly
        }
    }

    private static func managedSourceIDs(in directory: URL, suffix: String) throws -> Set<UUID> {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var result = Set<UUID>()

        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard url.pathExtension.lowercased() == "m4a" else { continue }
            guard url.lastPathComponent.hasSuffix(suffix) else { throw StoreError.readOnly }
            let identifier = String(url.lastPathComponent.dropLast(suffix.count))
            guard let recordingID = UUID(uuidString: identifier) else {
                throw StoreError.readOnly
            }
            result.insert(recordingID)
        }
        return result
    }

    private struct Reconciliation {
        var journal: Journal
        var changed: Bool
    }

    private static func reconcileAfterRestart(
        _ original: Journal,
        incomingDirectory: URL,
        recordingsDirectory: URL
    ) throws -> Reconciliation {
        var proposed = original
        var changed = false

        for index in proposed.records.indices {
            let current = proposed.records[index]
            guard current.stage != .deleted else { continue }

            let actualSource = sourceKind(
                recordingID: current.recordingID,
                incomingDirectory: incomingDirectory,
                recordingsDirectory: recordingsDirectory
            )
            var nextStage = current.stage
            var nextMessage = current.failureMessage
            var nextIntegrity = current.audioIntegrity
            var nextResultText = current.resultText
            var shouldChange = current.source != actualSource
            let finalURL = recordingsDirectory.appendingPathComponent(
                "\(current.recordingID.uuidString).m4a"
            )
            // Restart normalization is intentionally metadata-only. A multi-hour
            // or damaged source must never be decoded while the journal lock is
            // held. Persisted file identity proves unchanged finalized sources;
            // exceptional deep proof is deferred to an explicit bounded retry.
            let currentFileIdentity = actualSource == .final
                ? try? fileIdentity(at: finalURL)
                : nil
            let finalIdentityMatches = currentFileIdentity != nil
                && currentFileIdentity == current.audioFileIdentity
                && currentFileIdentity?.byteCount == current.audioIntegrity?.byteCount

            switch current.stage {
            case .preparing, .recording:
                nextStage = .failed
                nextMessage = "Recording was interrupted. Any captured audio is saved."
                shouldChange = true

            case .finalizing:
                if finalIdentityMatches,
                   let checkpointedIntegrity = current.audioIntegrity {
                    // `finishFinalization` moves first and journals second, so
                    // this exact shape proves that the source rename completed.
                    nextStage = .failed
                    nextMessage = "Saving was interrupted after the complete audio was secured. Your recording is ready to retry."
                    nextIntegrity = checkpointedIntegrity
                } else {
                    nextStage = .failed
                    nextMessage = "Recording was interrupted while being saved. Any captured audio is preserved."
                }
                shouldChange = true

            case .readyForRecognition:
                nextStage = .failed
                if !finalIdentityMatches {
                    nextMessage = "The complete saved audio could not be confirmed. No files were changed."
                } else {
                    nextMessage = "Processing was interrupted. Your recording is ready to retry."
                }
                shouldChange = true

            case .recognizing:
                nextStage = .failed
                if !finalIdentityMatches {
                    nextMessage = "Processing was interrupted and the complete saved audio could not be confirmed."
                } else if current.rawText != nil {
                    nextMessage = "Processing was interrupted. Completed text and the recording were kept for retry."
                } else {
                    nextMessage = "Processing was interrupted. Your recording is ready to retry."
                }
                shouldChange = true

            case .rawResultReady:
                if let rawText = current.rawText {
                    nextStage = .resultReady
                    nextResultText = rawText
                    nextMessage = "Cleanup was interrupted. The complete raw transcript was kept."
                } else {
                    nextStage = .failed
                    nextMessage = "Processing was interrupted before a transcript could be recovered."
                }
                shouldChange = true

            case .cleaning:
                if let rawText = current.rawText {
                    nextStage = .resultReady
                    nextResultText = rawText
                    nextMessage = "Cleanup was interrupted. The complete raw transcript was kept."
                } else {
                    nextStage = .failed
                    nextMessage = "Processing was interrupted before a transcript could be recovered."
                }
                shouldChange = true

            case .resultReady:
                // History must accept the terminal projection before this stage
                // can advance to succeeded and become usage-eligible.
                break

            case .succeeded, .failed:
                break

            case .deleted:
                break
            }

            if shouldChange {
                let (revision, overflow) = proposed.revision.addingReportingOverflow(1)
                guard !overflow else { throw StoreError.revisionExhausted }
                proposed.revision = revision
                proposed.records[index].stage = nextStage
                proposed.records[index].source = actualSource
                proposed.records[index].audioIntegrity = nextIntegrity
                proposed.records[index].revision = revision
                proposed.records[index].resultText = nextResultText
                proposed.records[index].failureMessage = nextMessage
                changed = true
            }
        }

        try validate(proposed)
        return Reconciliation(journal: proposed, changed: changed)
    }

    private static func sourceKind(
        recordingID: UUID,
        incomingDirectory: URL,
        recordingsDirectory: URL
    ) -> SourceKind {
        let partialURL = incomingDirectory.appendingPathComponent(
            "\(recordingID.uuidString).partial.m4a",
            isDirectory: false
        )
        let finalURL = recordingsDirectory.appendingPathComponent(
            "\(recordingID.uuidString).m4a",
            isDirectory: false
        )
        let partialExists = FileManager.default.fileExists(atPath: partialURL.path)
        let finalExists = FileManager.default.fileExists(atPath: finalURL.path)

        switch (partialExists, finalExists) {
        case (true, false): return .partial
        case (false, true): return .final
        case (true, true): return .both
        case (false, false): return .missing
        }
    }

    /// Runs the exceptional deep proof off the store executor. The deadline or
    /// caller cancellation resolves immediately even if AVFoundation or a file
    /// system call ignores cancellation; the detached late result has no path to
    /// mutate actor state and is fenced again by the caller's journal snapshot.
    private static func deeplyVerifyClosedAudio(
        at url: URL,
        deadline: Date,
        testHooks: TestHooks
    ) async throws -> DeepAudioVerification {
        guard deadline > Date() else { throw StoreError.invalidDeadline }
        let gate = MacAudioDeadlineGate<DeepAudioVerification>()
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        let nanoseconds = UInt64(min(remaining, maximumSeconds) * 1_000_000_000)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)

                Task.detached(priority: .utility) {
                    do {
                        try testHooks.before(.deepAudioValidation)
                        let integrity = try validateClosedAudio(at: url)
                        try syncRegularFile(
                            at: url,
                            operation: .sourceFileSync,
                            testHooks: testHooks
                        )
                        try syncDirectory(
                            url.deletingLastPathComponent(),
                            operation: .sourceDirectorySync,
                            testHooks: testHooks
                        )
                        let identity = try fileIdentity(at: url)
                        gate.resolve(.success(DeepAudioVerification(
                            integrity: integrity,
                            fileIdentity: identity
                        )))
                    } catch let error as StoreError {
                        gate.resolve(.failure(error))
                    } catch {
                        gate.resolve(.failure(StoreError.invalidAudio))
                    }
                }

                Task.detached(priority: .utility) {
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    gate.resolve(.failure(StoreError.invalidDeadline))
                }
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
        }
    }

    /// Opens and decodes every advertised frame, then hashes the closed
    /// container while checking that its size and modification time remained
    /// stable. The caller's attempt-scoped close attestation plus this proof is
    /// required before the source can become recognition-ready.
    private static func validateClosedAudio(at url: URL) throws -> AudioIntegrity {
        do {
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
            let before = try url.resourceValues(forKeys: keys)
            guard before.isRegularFile == true,
                  let byteCount = before.fileSize,
                  byteCount > 0,
                  let modificationDate = before.contentModificationDate else {
                throw StoreError.invalidAudio
            }

            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let frameCount = audioFile.length
            guard frameCount > 0,
                  format.sampleRate.isFinite,
                  format.sampleRate > 0,
                  format.channelCount > 0 else {
                throw StoreError.invalidAudio
            }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 8_192
            ) else {
                throw StoreError.invalidAudio
            }
            var decodedFrames: AVAudioFramePosition = 0
            while decodedFrames < frameCount {
                let remaining = frameCount - decodedFrames
                let requested = AVAudioFrameCount(min(remaining, 8_192))
                buffer.frameLength = 0
                try audioFile.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0 else { throw StoreError.invalidAudio }
                decodedFrames += AVAudioFramePosition(buffer.frameLength)
            }
            guard decodedFrames == frameCount else { throw StoreError.invalidAudio }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }

            let after = try url.resourceValues(forKeys: keys)
            guard after.isRegularFile == true,
                  after.fileSize == byteCount,
                  after.contentModificationDate == modificationDate else {
                throw StoreError.invalidAudio
            }

            let duration = Double(frameCount) / format.sampleRate
            guard duration.isFinite, duration > 0 else { throw StoreError.invalidAudio }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return AudioIntegrity(
                byteCount: Int64(byteCount),
                frameCount: Int64(frameCount),
                sampleRate: format.sampleRate,
                duration: duration,
                sha256: digest
            )
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.invalidAudio
        }
    }

    private static func closedProof(
        attemptID: UUID,
        integrity: AudioIntegrity
    ) -> ClosedAudioProof {
        ClosedAudioProof(
            attemptID: attemptID,
            expectedByteCount: integrity.byteCount,
            expectedFrameCount: integrity.frameCount,
            expectedSHA256: integrity.sha256
        )
    }

    private static func matches(
        proof: ClosedAudioProof,
        integrity: AudioIntegrity
    ) -> Bool {
        proof.expectedByteCount == integrity.byteCount
            && proof.expectedFrameCount == integrity.frameCount
            && proof.expectedSHA256 == integrity.sha256
    }

    private static func removeSources(
        recordingID: UUID,
        incomingDirectory: URL,
        recordingsDirectory: URL
    ) -> [URL] {
        let urls = [
            incomingDirectory.appendingPathComponent("\(recordingID.uuidString).partial.m4a"),
            recordingsDirectory.appendingPathComponent("\(recordingID.uuidString).m4a")
        ]
        var failures: [URL] = []

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append(url)
            }
        }
        return failures
    }
}

/// Attempt-scoped capability for derived audio exports.
///
/// The public URL is needed by AVFoundation and URLSession, but ownership and
/// cleanup never trust that path. Every mutation uses the retained directory
/// descriptor and a generated basename. `validateCompletedOutput` additionally
/// proves that the visible path still names the retained inode before an export
/// can be uploaded.
nonisolated final class MacTransientWorkspace: @unchecked Sendable {
    enum WorkspaceError: Error {
        case unavailable
        case invalidOutput
    }

    let recordingID: UUID
    let attemptID: UUID
    let directoryURL: URL

    private weak var owner: MacTransientWorkspaceRoot?
    private let directoryName: String
    private let directoryIdentity: MacDirectoryIdentity
    private let lock = NSLock()
    private var directoryDescriptor: Int32
    private var generatedNames: Set<String> = []
    private var active = true

    fileprivate init(
        recordingID: UUID,
        attemptID: UUID,
        directoryName: String,
        directoryURL: URL,
        directoryDescriptor: Int32,
        directoryIdentity: MacDirectoryIdentity,
        owner: MacTransientWorkspaceRoot
    ) {
        self.recordingID = recordingID
        self.attemptID = attemptID
        self.directoryName = directoryName
        self.directoryURL = directoryURL
        self.directoryDescriptor = directoryDescriptor
        self.directoryIdentity = directoryIdentity
        self.owner = owner
    }

    func makeOutputURL(fileExtension: String = "m4a") throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard active,
              directoryDescriptor >= 0,
              owner?.visiblePathStillNames(
                directoryURL: directoryURL,
                expected: directoryIdentity
              ) == true
        else {
            throw WorkspaceError.unavailable
        }

        let normalizedExtension = fileExtension.lowercased()
        guard !normalizedExtension.isEmpty,
              normalizedExtension.allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            throw WorkspaceError.invalidOutput
        }
        let name = "\(UUID().uuidString.lowercased()).\(normalizedExtension)"
        var status = Darwin.stat()
        let statResult = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult != 0, errno == ENOENT else {
            throw WorkspaceError.invalidOutput
        }
        generatedNames.insert(name)
        return directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    /// Accepts only a generated direct child that is a nonempty regular file
    /// under the retained directory capability.
    func validateCompletedOutput(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard active,
              directoryDescriptor >= 0,
              url.deletingLastPathComponent().standardizedFileURL
                == directoryURL.standardizedFileURL,
              generatedNames.contains(url.lastPathComponent),
              owner?.visiblePathStillNames(
                directoryURL: directoryURL,
                expected: directoryIdentity
              ) == true
        else {
            throw WorkspaceError.unavailable
        }

        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw WorkspaceError.invalidOutput }
        defer { _ = Darwin.close(descriptor) }

        var status = Darwin.stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size > 0
        else {
            throw WorkspaceError.invalidOutput
        }
    }

    func removeOutput(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard directoryDescriptor >= 0,
              url.deletingLastPathComponent().standardizedFileURL
                == directoryURL.standardizedFileURL,
              generatedNames.remove(url.lastPathComponent) != nil
        else { return }
        _ = url.lastPathComponent.withCString {
            Darwin.unlinkat(directoryDescriptor, $0, 0)
        }
    }

    /// Invalidates new writes first, then removes the original directory via
    /// retained descriptors. A substituted visible ancestor is never followed.
    func cleanup() {
        let descriptor: Int32
        lock.lock()
        guard directoryDescriptor >= 0 else {
            active = false
            lock.unlock()
            return
        }
        active = false
        descriptor = directoryDescriptor
        directoryDescriptor = -1
        generatedNames.removeAll()
        lock.unlock()

        _ = try? MacDescriptorTree.removeAllEntries(in: descriptor)
        _ = Darwin.close(descriptor)
        owner?.removeWorkspaceDirectory(
            recordingID: recordingID,
            workspace: self,
            directoryName: directoryName
        )
    }

    fileprivate func invalidate() {
        cleanup()
    }

    deinit {
        cleanup()
    }
}

private nonisolated struct MacDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private nonisolated final class MacTransientWorkspaceRoot: @unchecked Sendable {
    private let transientDirectory: URL
    private let lock = NSLock()
    private var transientDescriptor: Int32
    private let transientIdentity: MacDirectoryIdentity
    private var workspaces: [ObjectIdentifier: MacTransientWorkspace] = [:]
    private var blockedRecordingIDs: Set<UUID> = []

    init(
        rootDirectory: URL,
        storeDirectory: URL,
        transientDirectory: URL
    ) throws {
        let rootDescriptor = try MacDescriptorTree.openDirectory(at: rootDirectory)
        defer { _ = Darwin.close(rootDescriptor) }
        let storeDescriptor = try MacDescriptorTree.openDirectory(
            named: storeDirectory.lastPathComponent,
            relativeTo: rootDescriptor
        )
        defer { _ = Darwin.close(storeDescriptor) }
        let transientDescriptor = try MacDescriptorTree.openDirectory(
            named: transientDirectory.lastPathComponent,
            relativeTo: storeDescriptor
        )

        self.transientDirectory = transientDirectory
        self.transientDescriptor = transientDescriptor
        self.transientIdentity = try MacDescriptorTree.identity(of: transientDescriptor)
        guard visiblePathStillNames(
            directoryURL: transientDirectory,
            expected: transientIdentity
        ) else {
            _ = Darwin.close(transientDescriptor)
            self.transientDescriptor = -1
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }
    }

    func sweepAfterRestart() throws {
        lock.lock()
        defer { lock.unlock() }
        guard transientDescriptor >= 0,
              visiblePathStillNames(
                directoryURL: transientDirectory,
                expected: transientIdentity
              )
        else {
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }
        try MacDescriptorTree.removeAllEntries(in: transientDescriptor)
    }

    func makeWorkspace(recordingID: UUID, attemptID: UUID) throws -> MacTransientWorkspace {
        lock.lock()
        defer { lock.unlock() }
        guard transientDescriptor >= 0,
              !blockedRecordingIDs.contains(recordingID),
              visiblePathStillNames(
                directoryURL: transientDirectory,
                expected: transientIdentity
              )
        else {
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }

        let directoryName = [
            recordingID.uuidString.lowercased(),
            attemptID.uuidString.lowercased(),
            UUID().uuidString.lowercased()
        ].joined(separator: "_")
        let creationResult = directoryName.withCString {
            Darwin.mkdirat(transientDescriptor, $0, S_IRWXU)
        }
        guard creationResult == 0 else {
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }

        var workspaceDescriptor: Int32 = -1
        do {
            workspaceDescriptor = try MacDescriptorTree.openDirectory(
                named: directoryName,
                relativeTo: transientDescriptor
            )
            let workspace = MacTransientWorkspace(
                recordingID: recordingID,
                attemptID: attemptID,
                directoryName: directoryName,
                directoryURL: transientDirectory.appendingPathComponent(
                    directoryName,
                    isDirectory: true
                ),
                directoryDescriptor: workspaceDescriptor,
                directoryIdentity: try MacDescriptorTree.identity(of: workspaceDescriptor),
                owner: self
            )
            workspaces[ObjectIdentifier(workspace)] = workspace
            return workspace
        } catch {
            if workspaceDescriptor >= 0 {
                _ = Darwin.close(workspaceDescriptor)
            }
            _ = directoryName.withCString {
                Darwin.unlinkat(transientDescriptor, $0, AT_REMOVEDIR)
            }
            throw error
        }
    }

    func invalidate(recordingID: UUID) {
        lock.lock()
        blockedRecordingIDs.insert(recordingID)
        let matches = workspaces.values.filter { $0.recordingID == recordingID }
        lock.unlock()
        matches.forEach { $0.invalidate() }
    }

    func invalidateAll() {
        lock.lock()
        blockedRecordingIDs.formUnion(workspaces.values.map(\.recordingID))
        let current = Array(workspaces.values)
        lock.unlock()
        current.forEach { $0.invalidate() }
    }

    fileprivate func visiblePathStillNames(
        directoryURL: URL,
        expected: MacDirectoryIdentity
    ) -> Bool {
        guard let descriptor = try? MacDescriptorTree.openDirectory(at: directoryURL) else {
            return false
        }
        defer { _ = Darwin.close(descriptor) }
        return (try? MacDescriptorTree.identity(of: descriptor)) == expected
    }

    fileprivate func removeWorkspaceDirectory(
        recordingID: UUID,
        workspace: MacTransientWorkspace,
        directoryName: String
    ) {
        lock.lock()
        workspaces.removeValue(forKey: ObjectIdentifier(workspace))
        let descriptor = transientDescriptor
        lock.unlock()
        guard descriptor >= 0 else { return }
        _ = directoryName.withCString {
            Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR)
        }
    }

    deinit {
        invalidateAll()
        lock.lock()
        let descriptor = transientDescriptor
        transientDescriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }
}

private nonisolated enum MacDescriptorTree {
    static func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }
        do {
            _ = try identity(of: descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func openDirectory(named name: String, relativeTo parent: Int32) throws -> Int32 {
        guard isDirectChildName(name) else {
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }
        do {
            _ = try identity(of: descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func identity(of descriptor: Int32) throws -> MacDirectoryIdentity {
        var status = Darwin.stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR
        else {
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }
        return MacDirectoryIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    /// Uses a fresh open-file description for every enumeration. `dup` is
    /// intentionally forbidden here because duplicated directory descriptors
    /// share their read offset and can make a later Clear incorrectly see EOF.
    static func removeAllEntries(in directoryDescriptor: Int32) throws {
        let enumerationDescriptor = ".".withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard enumerationDescriptor >= 0,
              let stream = Darwin.fdopendir(enumerationDescriptor)
        else {
            if enumerationDescriptor >= 0 {
                _ = Darwin.close(enumerationDescriptor)
            }
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }
        defer { _ = Darwin.closedir(stream) }

        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = entryName(entry)
            guard name != ".", name != ".." else { continue }
            guard isDirectChildName(name) else {
                throw MacTransientWorkspace.WorkspaceError.unavailable
            }

            var status = Darwin.stat()
            let statResult = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if statResult != 0 {
                guard errno == ENOENT else {
                    throw MacTransientWorkspace.WorkspaceError.unavailable
                }
                errno = 0
                continue
            }

            if (status.st_mode & S_IFMT) == S_IFDIR {
                let child = try openDirectory(named: name, relativeTo: directoryDescriptor)
                do {
                    try removeAllEntries(in: child)
                    _ = Darwin.close(child)
                } catch {
                    _ = Darwin.close(child)
                    throw error
                }
                let result = name.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, AT_REMOVEDIR)
                }
                guard result == 0 || errno == ENOENT else {
                    throw MacTransientWorkspace.WorkspaceError.unavailable
                }
            } else {
                let result = name.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
                guard result == 0 || errno == ENOENT else {
                    throw MacTransientWorkspace.WorkspaceError.unavailable
                }
            }
            errno = 0
        }
        guard errno == 0 else {
            throw MacTransientWorkspace.WorkspaceError.unavailable
        }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
            namePointer.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
            ) {
                String(cString: $0)
            }
        }
    }

    private static func isDirectChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}

private nonisolated final class MacAudioDeadlineGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
