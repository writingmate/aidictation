import AVFoundation
import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// A wall-clock watchdog for the combined mobile recognition/cleanup API.
///
/// Recognition and cleanup are one async call at the service boundary, but they are separate
/// recovery stages. The cleanup timer is armed only after its durable store checkpoint succeeds,
/// so recognition cannot borrow cleanup time and cleanup cannot keep the processing UI alive past
/// its own budget. As with the other iOS deadlines, a late non-cooperative operation is cancelled
/// and loses mutation authority through its exact attempt lease.
public enum MobileAudioStageDeadline {
    @MainActor
    public static func run<Value: Sendable>(
        recognitionSeconds: TimeInterval,
        cleanupSeconds: TimeInterval,
        operation: @escaping @MainActor (
            _ cleanupDidStart: @escaping @Sendable () -> Void
        ) async throws -> Value
    ) async throws -> Value {
        let recognitionNanoseconds = try nanoseconds(for: recognitionSeconds)
        let cleanupNanoseconds = try nanoseconds(for: cleanupSeconds)
        let resolver = MobileAudioStageDeadlineResolver<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolver.install(continuation)
                resolver.startRecognition(nanoseconds: recognitionNanoseconds)
                let operationTask = Task { @MainActor in
                    do {
                        let value = try await operation {
                            resolver.armCleanup(nanoseconds: cleanupNanoseconds)
                        }
                        resolver.resolve(.success(value))
                    } catch is CancellationError {
                        resolver.resolve(.failure(IOSAudioProcessingDeadlineError.cancelled))
                    } catch {
                        resolver.resolve(.failure(error))
                    }
                }
                resolver.installOperation(operationTask)
            }
        } onCancel: {
            resolver.resolve(.failure(IOSAudioProcessingDeadlineError.cancelled))
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) throws -> UInt64 {
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        guard seconds.isFinite, seconds > 0, seconds <= maximumSeconds else {
            throw IOSAudioProcessingDeadlineError.timedOut
        }
        return UInt64(seconds * 1_000_000_000)
    }
}

private final class MobileAudioStageDeadlineResolver<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var timeoutGeneration: UInt64 = 0
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func startRecognition(nanoseconds: UInt64) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        let oldTimeout = armTimeoutLocked(nanoseconds: nanoseconds)
        lock.unlock()
        oldTimeout?.cancel()
    }

    func installOperation(_ operation: Task<Void, Never>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            operation.cancel()
            return
        }
        operationTask = operation
        lock.unlock()
    }

    func armCleanup(nanoseconds: UInt64) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        let oldTimeout = armTimeoutLocked(nanoseconds: nanoseconds)
        lock.unlock()
        oldTimeout?.cancel()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        timeoutGeneration &+= 1
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }

    private func armTimeoutLocked(nanoseconds: UInt64) -> Task<Void, Never>? {
        timeoutGeneration &+= 1
        let generation = timeoutGeneration
        let oldTimeout = timeoutTask
        timeoutTask = Task.detached { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.timeoutFired(generation: generation)
        }
        return oldTimeout
    }

    private func timeoutFired(generation: UInt64) {
        lock.lock()
        guard !resolved, generation == timeoutGeneration else {
            lock.unlock()
            return
        }
        resolved = true
        timeoutGeneration &+= 1
        let result: Result<Value, Error> = .failure(IOSAudioProcessingDeadlineError.timedOut)
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

/// Disk-backed, cross-instance compare-and-swap journal for iOS host recording work.
/// The keyboard owns only its handoff journal; the containing app is the sole audio-store writer.
public actor MobileAudioProcessingStore {
    public enum Stage: String, Codable, Sendable {
        case preparing
        case recording
        case finalizing
        case readyForRecognition
        case recognizing
        case recognitionPartial
        case rawReady
        case cleaning
        case resultReady
        case succeeded
        case failed
        case cancelled
        case deleted

        public var isTerminal: Bool {
            switch self {
            case .succeeded, .failed, .cancelled, .deleted:
                return true
            case .preparing, .recording, .finalizing, .readyForRecognition,
                 .recognizing, .recognitionPartial, .rawReady, .cleaning, .resultReady:
                return false
            }
        }
    }

    public enum SourceIntegrity: String, Codable, Sendable {
        case unfinalized
        case knownIncomplete
        case complete
    }

    public enum UsageAccountingState: String, Codable, Sendable {
        case pending
        case inFlight
        case acknowledged
    }

    public struct Lease: Codable, Equatable, Sendable {
        public let recordingID: UUID
        public let attemptID: UUID
        public let generation: UInt64
        public let storeGeneration: UInt64
        public let sourceURL: URL
    }

    public struct UsageAccountingLease: Equatable, Sendable {
        public let recordingID: UUID
        public let attemptID: UUID
        public let wordCount: Int
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public let recordingID: UUID
        public let attemptID: UUID
        public var generation: UInt64
        public let storeGeneration: UInt64
        public var revision: UInt64
        public var stage: Stage
        public var sourceIntegrity: SourceIntegrity
        public var sourcePath: String
        public var partialTranscriptPath: String?
        public var rawTranscriptPath: String?
        public var resultPath: String?
        public var previousResultPath: String?
        public var sourceProof: ClosedSourceProof?
        public let outputModeRaw: String?
        public let transcriptionOptions: TranscriptionOptions?
        public var usageAccountingState: UsageAccountingState?
        public var usageAccountingAttemptID: UUID?
        public var usageAccountingDeadlineAt: Date?
        public var usageAccountingWordCount: Int?
        public var duration: TimeInterval?
        public var userMessage: String?
        public var deadlineAt: Date?
        public let createdAt: Date
        public var updatedAt: Date

        public var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
        public var partialTranscriptURL: URL? { partialTranscriptPath.map(URL.init(fileURLWithPath:)) }
        public var rawTranscriptURL: URL? { rawTranscriptPath.map(URL.init(fileURLWithPath:)) }
        public var resultURL: URL? { resultPath.map(URL.init(fileURLWithPath:)) }
        public var previousResultURL: URL? { previousResultPath.map(URL.init(fileURLWithPath:)) }
    }

    public struct FinalizedSource: Equatable, Sendable {
        public let url: URL
        public let byteCount: Int64
        public let duration: TimeInterval
    }

    public enum TerminalIntent: Equatable, Sendable {
        case succeeded(text: String)
        case failed(message: String, integrity: SourceIntegrity?)
        case cancelled(message: String)
    }

    public enum TerminalCommitResult: Equatable, Sendable {
        /// The exact attempt reached a durable terminal state. Cleanup fallback can make the
        /// committed state `succeeded` when complete raw text had already been checkpointed.
        case committed(Snapshot)
        /// Delete, Clear, a retry, or another terminal owner won before this exact lease.
        case superseded
        /// The terminal write failed or exceeded its bounded persistence deadline. The caller
        /// must release its UI while leaving the managed source/journal for launch recovery.
        case persistenceUnavailable
    }

    public static let terminalPersistenceWarning =
        "Processing stopped, but History could not be updated. Restart AI Dictation to recover your recording."

    /// A per-attempt, app-group-owned directory for derived upload leaves.
    ///
    /// The directory descriptor is retained for the lifetime of the workspace so cleanup never
    /// trusts a decoded or reconstructed path. Every removable leaf has a UUID basename and is
    /// unlinked relative to that descriptor; a late exporter therefore cannot escape through a
    /// replaced parent or delete another attempt's file.
    public final class ChunkWorkspace: @unchecked Sendable {
        private let directoryURL: URL
        #if canImport(Darwin)
            private var directoryDescriptor: Int32
            private let directoryDevice: UInt64
            private let directoryInode: UInt64
        #endif
        private let lock = NSLock()
        private var ownedNames = Set<String>()
        private var closed = false

        fileprivate init(directoryURL: URL) throws {
            self.directoryURL = directoryURL
            #if canImport(Darwin)
                let descriptor = directoryURL.path.withCString {
                    Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard descriptor >= 0 else { throw StoreError.unavailable }
                var status = stat()
                guard Darwin.fstat(descriptor, &status) == 0,
                      (status.st_mode & S_IFMT) == S_IFDIR
                else {
                    Darwin.close(descriptor)
                    throw StoreError.unavailable
                }
                directoryDescriptor = descriptor
                directoryDevice = UInt64(status.st_dev)
                directoryInode = UInt64(status.st_ino)
            #endif
        }

        deinit {
            cleanupAll()
            #if canImport(Darwin)
                lock.lock()
                let descriptor = directoryDescriptor
                directoryDescriptor = -1
                closed = true
                lock.unlock()
                if descriptor >= 0 {
                    Darwin.close(descriptor)
                }
                var status = stat()
                let stillNamesSameDirectory = directoryURL.path.withCString {
                    Darwin.lstat($0, &status)
                } == 0
                    && (status.st_mode & S_IFMT) == S_IFDIR
                    && UInt64(status.st_dev) == directoryDevice
                    && UInt64(status.st_ino) == directoryInode
                if stillNamesSameDirectory {
                    _ = directoryURL.path.withCString { Darwin.rmdir($0) }
                }
            #endif
        }

        public func allocateOutputURL() throws -> URL {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { throw StoreError.unavailable }

            for _ in 0 ..< 32 {
                let name = "\(UUID().uuidString).m4a"
                #if canImport(Darwin)
                    var status = stat()
                    let result = name.withCString {
                        Darwin.fstatat(
                            directoryDescriptor,
                            $0,
                            &status,
                            AT_SYMLINK_NOFOLLOW
                        )
                    }
                    guard result != 0 else { continue }
                    guard errno == ENOENT else { throw StoreError.unavailable }
                #else
                    guard !FileManager.default.fileExists(
                        atPath: directoryURL.appendingPathComponent(name).path
                    ) else { continue }
                #endif
                ownedNames.insert(name)
                return directoryURL.appendingPathComponent(name, isDirectory: false)
            }
            throw StoreError.unavailable
        }

        public func remove(_ url: URL) {
            let name = url.lastPathComponent
            guard Self.isOwnedLeafName(name),
                  url.deletingLastPathComponent().standardizedFileURL
                    == directoryURL.standardizedFileURL
            else { return }

            lock.lock()
            guard !closed, ownedNames.remove(name) != nil else {
                lock.unlock()
                return
            }
            #if canImport(Darwin)
                let descriptor = directoryDescriptor
                lock.unlock()
                let result = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
                if result != 0, errno != ENOENT {
                    DebugLog.warning(
                        "Could not remove a managed upload part.",
                        context: "MobileAudioProcessingStore"
                    )
                }
            #else
                lock.unlock()
                try? FileManager.default.removeItem(at: url)
            #endif
        }

        public func cleanupAll() {
            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            let names = ownedNames
            ownedNames.removeAll()
            #if canImport(Darwin)
                let descriptor = directoryDescriptor
                lock.unlock()
                for name in names {
                    let result = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
                    if result != 0, errno != ENOENT {
                        DebugLog.warning(
                            "Could not remove a managed upload part.",
                            context: "MobileAudioProcessingStore"
                        )
                    }
                }
            #else
                lock.unlock()
                for name in names {
                    try? FileManager.default.removeItem(
                        at: directoryURL.appendingPathComponent(name)
                    )
                }
            #endif
        }

        fileprivate static func isOwnedLeafName(_ name: String) -> Bool {
            guard name.hasSuffix(".m4a") else { return false }
            return UUID(uuidString: String(name.dropLast(4))) != nil
        }
    }

    /// Immutable proof produced once, off the store actor, after a full decode of the closed
    /// container. Normal recognition and restart paths compare only this stable file identity.
    public struct ClosedSourceProof: Codable, Equatable, Sendable {
        public let recordingID: UUID
        public let attemptID: UUID
        public let generation: UInt64
        public let storeGeneration: UInt64
        public let byteCount: Int64
        public let frameCount: Int64
        public let sampleRate: Double
        public let duration: TimeInterval
        public let device: UInt64
        public let inode: UInt64
        public let modificationSeconds: Int64
        public let modificationNanoseconds: Int64
    }

    public enum StoreError: LocalizedError, Equatable, Sendable {
        case unavailable
        case quarantined
        case recordingIDAlreadyExists
        case attemptAlreadyActive
        case staleAttempt
        case invalidTransition
        case deadlineExceeded
        case sourceMissing
        case sourceConflict
        case sourceIncomplete
        case emptyResult
        case checkpointRegression
        case counterExhausted

        public var errorDescription: String? {
            switch self {
            case .unavailable, .quarantined, .counterExhausted:
                return "Recordings are temporarily unavailable. Please restart the app and try again."
            case .recordingIDAlreadyExists, .attemptAlreadyActive:
                return "Another recording is already active."
            case .staleAttempt:
                return "This recording attempt is no longer active."
            case .invalidTransition, .sourceConflict, .checkpointRegression:
                return "The recording could not continue safely. Your audio was kept."
            case .deadlineExceeded:
                return "This is taking too long. Your recording was kept."
            case .sourceMissing, .sourceIncomplete:
                return "The recording was not complete, so it was not sent."
            case .emptyResult:
                return "No speech was recognized. Your recording was kept."
            }
        }
    }

    private struct StoreMetadata: Codable {
        var schemaVersion: Int
        var generation: UInt64
        /// IDs deleted from legacy history before they had a managed attempt manifest.
        /// Keeping this in the atomically replaced store metadata makes Delete/Clear durable
        /// before the fallible history-file mutation and lets launch recovery materialize the
        /// corresponding tombstones after a crash.
        var deletedHistoryRecordingIDs: Set<UUID>? = nil
    }

    private struct FileProof: Equatable, Sendable {
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let device: UInt64
        let inode: UInt64
    }

    private struct DeepSourceInspection: Sendable {
        let fileProof: FileProof
        let frameCount: Int64
        let sampleRate: Double
        let duration: TimeInterval
    }

    public static let shared: MobileAudioProcessingStore = {
        #if os(iOS)
            do {
                let container = try trustedAppGroupContainerDirectory()
                let root = try ensureDirectoryNoFollow(
                    parent: try ensureDirectoryNoFollow(parent: container, name: "WhisperMate"),
                    name: "MobileAudioProcessing"
                )
                return MobileAudioProcessingStore(
                    trustedRootDirectory: root,
                    trustedContainerDirectory: container
                )
            } catch {
                return MobileAudioProcessingStore(unavailable: ())
            }
        #else
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                return MobileAudioProcessingStore(unavailable: ())
            }
            return MobileAudioProcessingStore(
                rootDirectory: applicationSupport
                    .appendingPathComponent("WhisperMate", isDirectory: true)
                    .appendingPathComponent("MobileAudioProcessing", isDirectory: true)
            )
        #endif
    }()

    private let rootDirectory: URL
    private let attemptsDirectory: URL
    private let chunkWorkspacesDirectory: URL
    private let metadataURL: URL
    private let quarantineURL: URL
    private let lockURL: URL
    private let trustedContainerDirectory: URL?
    private let fileManager: FileManager
    private let beforeAttemptAllocation: @Sendable () -> Void
    private let beforeDeepSourceValidation: @Sendable () -> Void
    private let beforeTerminalCommit: @Sendable (Lease) throws -> Void
    private let afterHistoryDeletionIntentPersisted: @Sendable () throws -> Void
    private var initializationFailed = false

    private static let schemaVersion = 4
    private static let finalizationStartGrace: TimeInterval = 5
    static let appGroupIdentifier = "group.com.whispermate.shared"
    private static let allowedPayloadNames: Set<String> = [
        "attempt.json", "source.partial.m4a", "source.m4a",
        "recognition-partial.txt", "raw.txt", "result.txt", "previous-result.txt",
    ]

    public init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        beforeAttemptAllocation: @escaping @Sendable () -> Void = {},
        beforeDeepSourceValidation: @escaping @Sendable () -> Void = {},
        beforeTerminalCommit: @escaping @Sendable (Lease) throws -> Void = { _ in },
        afterHistoryDeletionIntentPersisted: @escaping @Sendable () throws -> Void = {}
    ) {
        self.rootDirectory = rootDirectory
        attemptsDirectory = rootDirectory.appendingPathComponent("Attempts", isDirectory: true)
        chunkWorkspacesDirectory = rootDirectory.appendingPathComponent(
            "ChunkWorkspaces",
            isDirectory: true
        )
        metadataURL = rootDirectory.appendingPathComponent("store.json")
        quarantineURL = rootDirectory.appendingPathComponent("QUARANTINED")
        lockURL = rootDirectory.appendingPathComponent("store.lock")
        trustedContainerDirectory = nil
        self.fileManager = fileManager
        self.beforeAttemptAllocation = beforeAttemptAllocation
        self.beforeDeepSourceValidation = beforeDeepSourceValidation
        self.beforeTerminalCommit = beforeTerminalCommit
        self.afterHistoryDeletionIntentPersisted = afterHistoryDeletionIntentPersisted

        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: attemptsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: chunkWorkspacesDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            initializationFailed = true
        }
    }

    private init(
        trustedRootDirectory rootDirectory: URL,
        trustedContainerDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        attemptsDirectory = rootDirectory.appendingPathComponent("Attempts", isDirectory: true)
        chunkWorkspacesDirectory = rootDirectory.appendingPathComponent(
            "ChunkWorkspaces",
            isDirectory: true
        )
        metadataURL = rootDirectory.appendingPathComponent("store.json")
        quarantineURL = rootDirectory.appendingPathComponent("QUARANTINED")
        lockURL = rootDirectory.appendingPathComponent("store.lock")
        self.trustedContainerDirectory = trustedContainerDirectory
        self.fileManager = fileManager
        beforeAttemptAllocation = {}
        beforeDeepSourceValidation = {}
        beforeTerminalCommit = { _ in }
        afterHistoryDeletionIntentPersisted = {}

        do {
            _ = try Self.ensureDirectoryNoFollow(parent: rootDirectory, name: "Attempts")
            _ = try Self.ensureDirectoryNoFollow(
                parent: rootDirectory,
                name: "ChunkWorkspaces"
            )
        } catch {
            initializationFailed = true
        }
    }

    private init(unavailable _: Void) {
        let unavailableRoot = URL(
            fileURLWithPath: "/WhisperMate-AppGroup-Unavailable",
            isDirectory: true
        )
        rootDirectory = unavailableRoot
        attemptsDirectory = unavailableRoot.appendingPathComponent("Attempts", isDirectory: true)
        chunkWorkspacesDirectory = unavailableRoot.appendingPathComponent(
            "ChunkWorkspaces",
            isDirectory: true
        )
        metadataURL = unavailableRoot.appendingPathComponent("store.json")
        quarantineURL = unavailableRoot.appendingPathComponent("QUARANTINED")
        lockURL = unavailableRoot.appendingPathComponent("store.lock")
        trustedContainerDirectory = nil
        fileManager = .default
        beforeAttemptAllocation = {}
        beforeDeepSourceValidation = {}
        beforeTerminalCommit = { _ in }
        afterHistoryDeletionIntentPersisted = {}
        initializationFailed = true
    }

    /// Creates a never-before-used stable recording ID. Existing payloads are never replaced.
    public func beginNewAttempt(
        recordingID: UUID,
        attemptID: UUID = UUID(),
        outputModeRaw: String? = nil,
        transcriptionOptions: TranscriptionOptions? = nil,
        deadlineAt: Date
    ) throws -> Lease {
        try withExclusiveLock {
            try requireFutureDeadline(deadlineAt)
            let metadata = try requireWritableMetadataLocked()
            guard !historyDeletionIDs(metadata).contains(recordingID) else {
                throw StoreError.recordingIDAlreadyExists
            }
            beforeAttemptAllocation()
            let directory = attemptDirectory(recordingID: recordingID)
            guard !fileManager.fileExists(atPath: directory.path) else {
                throw StoreError.recordingIDAlreadyExists
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try synchronizeDirectoryLocked(attemptsDirectory)

            let partialURL = directory.appendingPathComponent("source.partial.m4a")
            try durableWriteLocked(Data(), to: partialURL)
            let now = Date()
            let snapshot = Snapshot(
                recordingID: recordingID,
                attemptID: attemptID,
                generation: 1,
                storeGeneration: metadata.generation,
                revision: 1,
                stage: .preparing,
                sourceIntegrity: .unfinalized,
                sourcePath: partialURL.path,
                partialTranscriptPath: nil,
                rawTranscriptPath: nil,
                resultPath: nil,
                previousResultPath: nil,
                sourceProof: nil,
                outputModeRaw: outputModeRaw,
                transcriptionOptions: transcriptionOptions,
                usageAccountingState: .pending,
                usageAccountingAttemptID: nil,
                usageAccountingDeadlineAt: nil,
                usageAccountingWordCount: nil,
                duration: nil,
                userMessage: nil,
                deadlineAt: deadlineAt,
                createdAt: now,
                updatedAt: now
            )
            try saveLocked(snapshot)
            return lease(for: snapshot)
        }
    }

    /// Explicit retry path: it preserves the canonical complete source and prior result.
    public func beginRetry(
        recordingID: UUID,
        attemptID: UUID = UUID(),
        deadlineAt: Date
    ) throws -> Lease {
        try withExclusiveLock {
            try requireFutureDeadline(deadlineAt)
            let metadata = try requireWritableMetadataLocked()
            guard !historyDeletionIDs(metadata).contains(recordingID) else {
                throw StoreError.invalidTransition
            }
            var old = try loadSnapshotLocked(recordingID: recordingID)
            guard old.stage.isTerminal, old.stage != .deleted,
                  old.sourceIntegrity == .complete,
                  old.storeGeneration == metadata.generation,
                  fileManager.fileExists(atPath: old.sourcePath)
            else { throw StoreError.invalidTransition }
            _ = try resolveCompletedRecognitionLocked(
                &old,
                message: "Recognition completed before the previous attempt stopped."
            )
            guard old.generation < UInt64.max, old.revision < UInt64.max else {
                throw StoreError.counterExhausted
            }
            beforeAttemptAllocation()

            let previousResultURL = attemptDirectory(recordingID: recordingID)
                .appendingPathComponent("previous-result.txt")
            let previousResultData = try preservedResultDataLocked(old)
            if let previousResultData {
                guard old.revision < UInt64.max - 1 else {
                    throw StoreError.counterExhausted
                }
                try durableWriteLocked(previousResultData, to: previousResultURL)

                // First move the old terminal attempt's recovery authority to the stable
                // previous-result checkpoint. Only after that manifest is durable may the old
                // raw/result leaves be removed and a new generation become authoritative.
                old.stage = .failed
                old.partialTranscriptPath = nil
                old.rawTranscriptPath = nil
                old.resultPath = nil
                old.previousResultPath = previousResultURL.path
                old.deadlineAt = nil
                old.userMessage = "Retry preparation was interrupted. The previous text was kept."
                if old.usageAccountingState == .inFlight {
                    old.usageAccountingState = .acknowledged
                    old.usageAccountingAttemptID = nil
                    old.usageAccountingDeadlineAt = nil
                }
                try advanceRevision(&old)
                try saveLocked(old)
            }
            try removeRetryTransientPayloadsLocked(recordingID: recordingID)

            let nextGeneration = old.generation + 1
            let nextRevision = old.revision + 1
            let updatedAt = Date()
            let retryProof = old.sourceProof.map {
                ClosedSourceProof(
                    recordingID: old.recordingID,
                    attemptID: attemptID,
                    generation: nextGeneration,
                    storeGeneration: metadata.generation,
                    byteCount: $0.byteCount,
                    frameCount: $0.frameCount,
                    sampleRate: $0.sampleRate,
                    duration: $0.duration,
                    device: $0.device,
                    inode: $0.inode,
                    modificationSeconds: $0.modificationSeconds,
                    modificationNanoseconds: $0.modificationNanoseconds
                )
            }
            // The identity changes while the canonical source remains untouched.
            let replacement = Snapshot(
                recordingID: old.recordingID,
                attemptID: attemptID,
                generation: nextGeneration,
                storeGeneration: metadata.generation,
                revision: nextRevision,
                stage: .readyForRecognition,
                sourceIntegrity: old.sourceIntegrity,
                sourcePath: old.sourcePath,
                partialTranscriptPath: nil,
                rawTranscriptPath: nil,
                resultPath: nil,
                previousResultPath: previousResultData == nil ? nil : previousResultURL.path,
                sourceProof: retryProof,
                outputModeRaw: old.outputModeRaw,
                transcriptionOptions: old.transcriptionOptions,
                usageAccountingState: old.usageAccountingState,
                usageAccountingAttemptID: old.usageAccountingAttemptID,
                usageAccountingDeadlineAt: old.usageAccountingDeadlineAt,
                usageAccountingWordCount: old.usageAccountingWordCount,
                duration: old.duration,
                userMessage: nil,
                deadlineAt: deadlineAt,
                createdAt: old.createdAt,
                updatedAt: updatedAt
            )
            try saveLocked(replacement)
            return lease(for: replacement)
        }
    }

    public func captureBecameReady(_ lease: Lease, deadlineAt: Date) throws {
        try mutate(lease, allowed: [.preparing], next: .recording, deadlineAt: deadlineAt)
    }

    public func beginFinalization(_ lease: Lease, deadlineAt: Date) throws {
        try withExclusiveLock {
            try requireFutureDeadline(deadlineAt)
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: false)
            guard snapshot.stage == .recording,
                  let captureDeadline = snapshot.deadlineAt,
                  Date() <= captureDeadline.addingTimeInterval(Self.finalizationStartGrace)
            else { throw StoreError.deadlineExceeded }
            snapshot.stage = .finalizing
            snapshot.deadlineAt = deadlineAt
            try advanceRevision(&snapshot)
            try saveLocked(snapshot)
        }
    }

    /// Performs the only full-container decode off the store actor and behind the already
    /// persisted finalization deadline. A late detached result has no mutation authority.
    public func proveFinalizedSource(
        _ lease: Lease,
        minimumBytes: Int64,
        minimumDuration: TimeInterval
    ) async throws -> ClosedSourceProof {
        let candidate: (url: URL, deadline: Date) = try withExclusiveLock {
            let snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard snapshot.stage == .finalizing,
                  let deadline = snapshot.deadlineAt
            else { throw StoreError.invalidTransition }
            let partialURL = attemptDirectory(recordingID: lease.recordingID)
                .appendingPathComponent("source.partial.m4a")
            guard snapshot.sourcePath == partialURL.path,
                  fileManager.fileExists(atPath: partialURL.path)
            else { throw StoreError.sourceMissing }
            return (partialURL, deadline)
        }

        let remaining = candidate.deadline.timeIntervalSinceNow
        let validationHook = beforeDeepSourceValidation
        let inspection = try await IOSAudioProcessingDeadline.run(seconds: remaining) {
            try await Task.detached(priority: .utility) {
                validationHook()
                return try Self.inspectClosedSourceDetached(
                    candidate.url,
                    minimumBytes: minimumBytes,
                    minimumDuration: minimumDuration
                )
            }.value
        }
        let proof = ClosedSourceProof(
            recordingID: lease.recordingID,
            attemptID: lease.attemptID,
            generation: lease.generation,
            storeGeneration: lease.storeGeneration,
            byteCount: inspection.fileProof.byteCount,
            frameCount: inspection.frameCount,
            sampleRate: inspection.sampleRate,
            duration: inspection.duration,
            device: inspection.fileProof.device,
            inode: inspection.fileProof.inode,
            modificationSeconds: inspection.fileProof.modificationSeconds,
            modificationNanoseconds: inspection.fileProof.modificationNanoseconds
        )

        return try withExclusiveLock {
            let snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard snapshot.stage == .finalizing,
                  try sourceMatchesProofLocked(candidate.url, proof: proof)
            else { throw StoreError.staleAttempt }
            return proof
        }
    }

    public func checkpointFinalizedSourceProof(
        _ lease: Lease,
        proof: ClosedSourceProof
    ) throws {
        try withExclusiveLock {
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard snapshot.stage == .finalizing,
                  proofMatchesLease(proof, lease: lease),
                  try sourceMatchesProofLocked(snapshot.sourceURL, proof: proof)
            else { throw StoreError.invalidTransition }
            if snapshot.sourceProof == proof { return }
            snapshot.sourceProof = proof
            try advanceRevision(&snapshot)
            try saveLocked(snapshot)
        }
    }

    /// Promotes a source only after its immutable proof was durably checkpointed. A crash on
    /// either side of the move is metadata-only recoverable.
    public func acceptFinalizedSource(
        _ lease: Lease,
        proof: ClosedSourceProof
    ) throws -> FinalizedSource {
        try withExclusiveLock {
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard snapshot.stage == .finalizing,
                  snapshot.sourceProof == proof,
                  proofMatchesLease(proof, lease: lease),
                  proof.byteCount > 0,
                  proof.frameCount > 0,
                  proof.sampleRate.isFinite,
                  proof.sampleRate > 0,
                  proof.duration.isFinite,
                  proof.duration > 0
            else { throw StoreError.invalidTransition }

            let partialURL = attemptDirectory(recordingID: lease.recordingID)
                .appendingPathComponent("source.partial.m4a")
            let finalURL = attemptDirectory(recordingID: lease.recordingID)
                .appendingPathComponent("source.m4a")
            guard snapshot.sourcePath == partialURL.path else { throw StoreError.sourceConflict }
            guard fileManager.fileExists(atPath: partialURL.path) else { throw StoreError.sourceMissing }
            guard !fileManager.fileExists(atPath: finalURL.path) else {
                try quarantineLocked("Both partial and final source exist for \(lease.recordingID)")
                throw StoreError.sourceConflict
            }

            guard try sourceMatchesProofLocked(partialURL, proof: proof) else {
                throw StoreError.sourceIncomplete
            }
            try requireUnexpiredSnapshotDeadline(snapshot)
            try moveSourceDurablyLocked(from: partialURL, to: finalURL)
            try requireUnexpiredSnapshotDeadline(snapshot)
            guard try sourceMatchesProofLocked(finalURL, proof: proof) else {
                throw StoreError.sourceIncomplete
            }

            snapshot.stage = .readyForRecognition
            snapshot.sourceIntegrity = .complete
            snapshot.sourcePath = finalURL.path
            snapshot.duration = proof.duration
            snapshot.deadlineAt = nil
            try advanceRevision(&snapshot)
            try saveLocked(snapshot)
            return FinalizedSource(url: finalURL, byteCount: proof.byteCount, duration: proof.duration)
        }
    }

    @discardableResult
    public func beginRecognition(_ lease: Lease, deadlineAt: Date) throws -> URL {
        try withExclusiveLock {
            try requireFutureDeadline(deadlineAt)
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: false)
            guard snapshot.stage == .readyForRecognition,
                  snapshot.sourceIntegrity == .complete,
                  let proof = snapshot.sourceProof,
                  fileManager.fileExists(atPath: snapshot.sourcePath),
                  try sourceMatchesProofLocked(snapshot.sourceURL, proof: proof)
            else { throw StoreError.sourceIncomplete }
            snapshot.stage = .recognizing
            snapshot.deadlineAt = deadlineAt
            try advanceRevision(&snapshot)
            try saveLocked(snapshot)
            return snapshot.sourceURL
        }
    }

    /// Allocates a fresh derived-audio workspace only for the current recognition lease.
    /// Delete/Clear can unlink its pathname while a late exporter still holds the descriptor;
    /// that exporter can then clean only the detached directory it originally owned.
    public func makeChunkWorkspace(for lease: Lease) throws -> ChunkWorkspace {
        try withExclusiveLock {
            let snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard snapshot.stage == .recognizing || snapshot.stage == .recognitionPartial else {
                throw StoreError.invalidTransition
            }

            let recordingDirectory = chunkWorkspacesDirectory.appendingPathComponent(
                lease.recordingID.uuidString,
                isDirectory: true
            )
            if !fileManager.fileExists(atPath: recordingDirectory.path) {
                _ = try Self.ensureDirectoryNoFollow(
                    parent: chunkWorkspacesDirectory,
                    name: lease.recordingID.uuidString
                )
            } else {
                try validateDirectoryNoFollow(recordingDirectory)
            }

            let workspaceDirectory = recordingDirectory.appendingPathComponent(
                lease.attemptID.uuidString,
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: workspaceDirectory.path) else {
                throw StoreError.sourceConflict
            }
            _ = try Self.ensureDirectoryNoFollow(
                parent: recordingDirectory,
                name: lease.attemptID.uuidString
            )
            try synchronizeDirectoryLocked(recordingDirectory)
            return try ChunkWorkspace(directoryURL: workspaceDirectory)
        }
    }

    /// The shared service supplies the cumulative ordered transcript after every completed leaf.
    /// Replacing this checkpoint avoids duplicated text if the process stops between leaves.
    public func checkpointRecognitionPartial(_ text: String, lease: Lease) throws {
        let chunk = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }
        try withExclusiveLock {
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard snapshot.stage == .recognizing || snapshot.stage == .recognitionPartial else {
                throw StoreError.invalidTransition
            }
            let url = attemptDirectory(recordingID: lease.recordingID)
                .appendingPathComponent("recognition-partial.txt")
            if snapshot.stage == .recognitionPartial {
                guard let previousURL = snapshot.partialTranscriptURL,
                      let previous = try? String(contentsOf: previousURL, encoding: .utf8),
                      chunk.hasPrefix(previous),
                      chunk.count >= previous.count
                else { throw StoreError.checkpointRegression }
                if chunk == previous { return }
            }
            try durableWriteLocked(Data(chunk.utf8), to: url)
            snapshot.stage = .recognitionPartial
            snapshot.partialTranscriptPath = url.path
            try advanceRevision(&snapshot)
            // The lease and deadline were validated before the payload write began. Once that
            // durable write succeeds, crossing the deadline during fsync must not orphan it.
            try saveLocked(snapshot, requireFutureActiveDeadline: false)
        }
    }

    public func checkpointRawTranscript(_ text: String, lease: Lease) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.emptyResult
        }
        try withExclusiveLock {
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard snapshot.stage == .recognizing || snapshot.stage == .recognitionPartial else {
                throw StoreError.invalidTransition
            }
            let rawURL = attemptDirectory(recordingID: lease.recordingID).appendingPathComponent("raw.txt")
            try durableWriteLocked(Data(text.utf8), to: rawURL)
            snapshot.stage = .rawReady
            snapshot.rawTranscriptPath = rawURL.path
            try advanceRevision(&snapshot)
            // Complete raw recognition that entered before the deadline is authoritative even if
            // its fsync finishes just after the deadline. The timeout path will terminalize it.
            try saveLocked(snapshot, requireFutureActiveDeadline: false)
        }
    }

    public func cleanupStarted(_ lease: Lease, deadlineAt: Date) throws {
        try mutate(lease, allowed: [.rawReady], next: .cleaning, deadlineAt: deadlineAt)
    }

    /// Commits cleaned output, or the durable raw transcript when cleanup is empty/unavailable.
    public func checkpointFinalText(_ text: String, lease: Lease) throws -> String {
        try withExclusiveLock {
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard [.recognizing, .recognitionPartial, .rawReady, .cleaning].contains(snapshot.stage) else {
                throw StoreError.invalidTransition
            }

            var resolved = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
            if resolved.isEmpty, let rawURL = snapshot.rawTranscriptURL {
                resolved = (try? String(contentsOf: rawURL, encoding: .utf8)) ?? ""
            }
            guard !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoreError.emptyResult
            }

            // A pipeline without cleanup callbacks treats its complete return value as raw.
            if snapshot.rawTranscriptPath == nil {
                let rawURL = attemptDirectory(recordingID: lease.recordingID).appendingPathComponent("raw.txt")
                try durableWriteLocked(Data(resolved.utf8), to: rawURL)
                snapshot.rawTranscriptPath = rawURL.path
            }
            let resultURL = attemptDirectory(recordingID: lease.recordingID).appendingPathComponent("result.txt")
            try durableWriteLocked(Data(resolved.utf8), to: resultURL)
            try requireUnexpiredSnapshotDeadline(snapshot)
            snapshot.stage = .resultReady
            snapshot.resultPath = resultURL.path
            snapshot.usageAccountingWordCount = Self.wordCount(in: resolved)
            snapshot.deadlineAt = nil
            try advanceRevision(&snapshot)
            try saveLocked(snapshot)
            return resolved
        }
    }

    public func resolveCleanupToRaw(_ lease: Lease) throws -> String {
        try checkpointFinalText("", lease: lease)
    }

    public func markSucceeded(_ lease: Lease) throws {
        try withExclusiveLock {
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard snapshot.stage == .resultReady,
                  let resultURL = snapshot.resultURL
            else { throw StoreError.invalidTransition }
            if snapshot.usageAccountingWordCount == nil {
                snapshot.usageAccountingWordCount = Self.wordCount(
                    in: try readNonEmptyTextLocked(resultURL)
                )
            }
            snapshot.stage = .succeeded
            snapshot.deadlineAt = nil
            try advanceRevision(&snapshot)
            try saveLocked(snapshot)
        }
    }

    public func markFailed(
        _ lease: Lease,
        message: String,
        integrity: SourceIntegrity? = nil
    ) throws {
        _ = try persistTerminalState(
            .failed(message: message, integrity: integrity),
            lease: lease
        )
    }

    public func markCancelled(_ lease: Lease, message: String = "Recording cancelled.") throws {
        _ = try persistTerminalState(.cancelled(message: message), lease: lease)
    }

    /// Persists one exact attempt's terminal state under a bounded, cancellation-independent
    /// deadline. A timed-out synchronous disk operation may finish later, so the store validates
    /// the full lease again after the injected/stalled boundary. Delete, Clear, and retry therefore
    /// remain authoritative over every late terminal completion.
    public nonisolated func commitTerminalState(
        _ intent: TerminalIntent,
        lease: Lease,
        timeout: TimeInterval = 3
    ) async -> TerminalCommitResult {
        let terminalTask = Task.detached(priority: .userInitiated) { [self] in
            try await IOSAudioProcessingDeadline.run(seconds: timeout) {
                try await self.persistTerminalState(intent, lease: lease)
            }
        }

        do {
            return .committed(try await terminalTask.value)
        } catch let error as StoreError where error == .staleAttempt {
            return .superseded
        } catch let error as StoreError where error == .invalidTransition {
            return await reconcileAlreadyTerminalState(lease: lease, timeout: timeout)
        } catch {
            DebugLog.warning(
                "Could not durably finish recording \(lease.recordingID): \(error.localizedDescription)",
                context: "MobileAudioProcessingStore"
            )
            return .persistenceUnavailable
        }
    }

    private nonisolated func reconcileAlreadyTerminalState(
        lease: Lease,
        timeout: TimeInterval
    ) async -> TerminalCommitResult {
        let reconciliationTask = Task.detached(priority: .userInitiated) { [self] in
            try await IOSAudioProcessingDeadline.run(seconds: timeout) {
                try await self.snapshot(recordingID: lease.recordingID)
            }
        }
        do {
            guard let snapshot = try await reconciliationTask.value,
                  snapshot.attemptID == lease.attemptID,
                  snapshot.generation == lease.generation,
                  snapshot.storeGeneration == lease.storeGeneration,
                  snapshot.stage.isTerminal,
                  snapshot.stage != .deleted
            else { return .superseded }
            return .committed(snapshot)
        } catch {
            DebugLog.warning(
                "Could not reconcile terminal recording \(lease.recordingID): \(error.localizedDescription)",
                context: "MobileAudioProcessingStore"
            )
            return .persistenceUnavailable
        }
    }

    /// The deletion intent is persisted in store metadata before the attempt manifest or legacy
    /// history file is touched. A crash at any later point is repaired from that intent.
    public func tombstone(recordingID: UUID) throws {
        try withExclusiveLock {
            var metadata = try requireWritableMetadataLocked()
            var deletionIDs = historyDeletionIDs(metadata)
            if deletionIDs.insert(recordingID).inserted {
                metadata.deletedHistoryRecordingIDs = deletionIDs
                try saveMetadataLocked(metadata)
                try afterHistoryDeletionIntentPersisted()
            }
            try applyHistoryDeletionIntentLocked(recordingID: recordingID, metadata: metadata)
            try removeChunkWorkspacesLocked(recordingID: recordingID)
        }
    }

    /// The legacy history IDs and global generation advance in one atomic metadata replacement.
    /// A crash during later manifest/history cleanup therefore cannot resurrect an old row or lease.
    public func clearAll(recordingIDs: [UUID] = []) throws {
        try withExclusiveLock {
            var metadata = try requireWritableMetadataLocked()
            let snapshots = try scanSnapshotsLocked(validateReferencedPayloads: false)
            guard metadata.generation < UInt64.max else { throw StoreError.counterExhausted }
            var deletionIDs = historyDeletionIDs(metadata)
            deletionIDs.formUnion(recordingIDs)
            metadata.deletedHistoryRecordingIDs = deletionIDs
            metadata.generation += 1
            try saveMetadataLocked(metadata)
            try afterHistoryDeletionIntentPersisted()

            for var snapshot in snapshots {
                guard snapshot.generation < UInt64.max else { throw StoreError.counterExhausted }
                snapshot.generation += 1
                snapshot.stage = .deleted
                snapshot.sourceProof = nil
                snapshot.deadlineAt = nil
                snapshot.userMessage = nil
                if snapshot.usageAccountingState == .inFlight {
                    snapshot.usageAccountingState = .acknowledged
                    snapshot.usageAccountingAttemptID = nil
                    snapshot.usageAccountingDeadlineAt = nil
                }
                try advanceRevision(&snapshot)
                try saveLocked(snapshot)
                try removePayloadsLocked(snapshot)
                try removeChunkWorkspacesLocked(recordingID: snapshot.recordingID)
            }
            try applyHistoryDeletionIntentsLocked(metadata)
            for recordingID in recordingIDs {
                try removeChunkWorkspacesLocked(recordingID: recordingID)
            }
        }
    }

    /// Removes payloads recreated by an abandoned native writer only when Delete/Clear has
    /// already won. It never grants the late writer authority to mutate the tombstone.
    public func purgePayloadsIfDeleted(recordingID: UUID) throws {
        try withExclusiveLock {
            let metadata = try requireWritableMetadataLocked()
            if historyDeletionIDs(metadata).contains(recordingID) {
                try applyHistoryDeletionIntentLocked(recordingID: recordingID, metadata: metadata)
            }
            guard let snapshot = try loadSnapshotIfPresentLocked(
                recordingID: recordingID,
                validateReferencedPayloads: false
            ), snapshot.stage == .deleted || snapshot.storeGeneration != metadata.generation
            else { return }
            try removePayloadsLocked(snapshot)
            try removeChunkWorkspacesLocked(recordingID: recordingID)
        }
    }

    public func isActive(recordingID: UUID) throws -> Bool {
        try withExclusiveLock {
            let metadata = try requireReadableMetadataLocked()
            guard !historyDeletionIDs(metadata).contains(recordingID) else { return false }
            guard let snapshot = try loadSnapshotIfPresentLocked(recordingID: recordingID) else { return false }
            return snapshot.storeGeneration == metadata.generation && !snapshot.stage.isTerminal
        }
    }

    public func snapshot(recordingID: UUID) throws -> Snapshot? {
        try withExclusiveLock {
            let metadata = try requireWritableMetadataLocked()
            if historyDeletionIDs(metadata).contains(recordingID) {
                try applyHistoryDeletionIntentLocked(recordingID: recordingID, metadata: metadata)
            }
            return try loadSnapshotIfPresentLocked(recordingID: recordingID)
        }
    }

    public func allSnapshots() throws -> [Snapshot] {
        try withExclusiveLock {
            let metadata = try requireWritableMetadataLocked()
            try applyHistoryDeletionIntentsLocked(metadata)
            return try scanSnapshotsLocked()
        }
    }

    /// Strict restart reconciliation: unknown/corrupt layouts quarantine the store; known
    /// interruptions become terminal without deleting their only source or raw checkpoint.
    @discardableResult
    public func normalizeInterruptedAttempts() throws -> [Snapshot] {
        try withExclusiveLock {
            let metadata = try requireWritableMetadataLocked()
            try applyHistoryDeletionIntentsLocked(metadata)
            try sweepChunkWorkspacesLocked()
            var normalized: [Snapshot] = []
            for var snapshot in try scanSnapshotsLocked() {
                if snapshot.storeGeneration != metadata.generation {
                    snapshot.stage = .deleted
                    snapshot.deadlineAt = nil
                    if snapshot.usageAccountingState == .inFlight {
                        // An older app may have completed the non-idempotent side effect before
                        // crashing. Never replay that ambiguous operation.
                        snapshot.usageAccountingState = .acknowledged
                        snapshot.usageAccountingAttemptID = nil
                        snapshot.usageAccountingDeadlineAt = nil
                    }
                    try advanceRevision(&snapshot)
                    try saveLocked(snapshot)
                    try removePayloadsLocked(snapshot)
                    normalized.append(snapshot)
                    continue
                }
                guard !snapshot.stage.isTerminal else {
                    if [.failed, .cancelled].contains(snapshot.stage),
                       try resolveCompletedRecognitionLocked(
                           &snapshot,
                           message: "Recognition completed before the interrupted attempt stopped."
                       )
                    {
                        normalized.append(snapshot)
                        continue
                    }
                    if [.succeeded, .deleted].contains(snapshot.stage),
                       snapshot.usageAccountingState == .inFlight
                    {
                        snapshot.usageAccountingState = .acknowledged
                        snapshot.usageAccountingAttemptID = nil
                        snapshot.usageAccountingDeadlineAt = nil
                        try advanceRevision(&snapshot)
                        try saveLocked(snapshot)
                        normalized.append(snapshot)
                    }
                    if snapshot.stage == .deleted { try removePayloadsLocked(snapshot) }
                    continue
                }

                let directory = attemptDirectory(recordingID: snapshot.recordingID)
                let partialURL = directory.appendingPathComponent("source.partial.m4a")
                let finalURL = directory.appendingPathComponent("source.m4a")
                let partialTextURL = directory.appendingPathComponent("recognition-partial.txt")
                let rawURL = directory.appendingPathComponent("raw.txt")
                let resultURL = directory.appendingPathComponent("result.txt")
                var hasPartial = fileManager.fileExists(atPath: partialURL.path)
                var hasFinal = fileManager.fileExists(atPath: finalURL.path)

                if snapshot.stage == .finalizing {
                    guard hasFinal != hasPartial else {
                        try quarantineLocked("Ambiguous finalized source for \(snapshot.recordingID)")
                        throw StoreError.sourceConflict
                    }
                    let sourceURL = hasFinal ? finalURL : partialURL
                    if let proof = snapshot.sourceProof,
                       try sourceMatchesProofLocked(sourceURL, proof: proof)
                    {
                        if hasPartial {
                            try moveSourceDurablyLocked(from: partialURL, to: finalURL)
                            guard try sourceMatchesProofLocked(finalURL, proof: proof) else {
                                throw StoreError.sourceIncomplete
                            }
                            hasPartial = false
                            hasFinal = true
                        }
                        snapshot.sourcePath = finalURL.path
                        snapshot.sourceIntegrity = .complete
                        snapshot.duration = proof.duration
                        snapshot.stage = .readyForRecognition
                    } else if hasFinal {
                        // A move without its preceding durable proof can only be retained as an
                        // incomplete source. Startup must never perform an unbounded deep decode.
                        snapshot.sourcePath = finalURL.path
                        snapshot.sourceIntegrity = .knownIncomplete
                        snapshot.sourceProof = nil
                        snapshot.stage = .failed
                        snapshot.deadlineAt = nil
                        snapshot.userMessage = "Recording was interrupted before its saved audio could be verified."
                        try advanceRevision(&snapshot)
                        try saveLocked(snapshot)
                        normalized.append(snapshot)
                        continue
                    } else {
                        snapshot.sourceProof = nil
                        snapshot.sourceIntegrity = .knownIncomplete
                    }
                }

                if [.preparing, .recording].contains(snapshot.stage), hasFinal {
                    try quarantineLocked("Unexpected final source for \(snapshot.recordingID)")
                    throw StoreError.sourceConflict
                }

                if [.readyForRecognition, .recognizing, .recognitionPartial, .rawReady, .cleaning, .resultReady]
                    .contains(snapshot.stage), (!hasFinal || hasPartial)
                {
                    try quarantineLocked("Ambiguous complete source for \(snapshot.recordingID)")
                    throw StoreError.sourceConflict
                }

                if [.recognizing, .recognitionPartial, .rawReady, .cleaning].contains(snapshot.stage) {
                    let orphanResult = snapshot.resultPath == nil
                        ? try readNonEmptyTextIfPresentLocked(resultURL)
                        : nil
                    let orphanRaw = snapshot.rawTranscriptPath == nil
                        ? try readNonEmptyTextIfPresentLocked(rawURL)
                        : nil
                    let orphanPartial = snapshot.partialTranscriptPath == nil
                        ? try readNonEmptyTextIfPresentLocked(partialTextURL)
                        : nil

                    if let orphanResult {
                        let resolvedRaw: String
                        if let existingRawURL = snapshot.rawTranscriptURL {
                            resolvedRaw = try readNonEmptyTextLocked(existingRawURL)
                        } else if let orphanRaw {
                            resolvedRaw = orphanRaw
                            snapshot.rawTranscriptPath = rawURL.path
                        } else {
                            // The final checkpoint is complete enough to preserve as raw fallback.
                            resolvedRaw = orphanResult
                            try durableWriteLocked(Data(orphanResult.utf8), to: rawURL)
                            snapshot.rawTranscriptPath = rawURL.path
                        }
                        _ = resolvedRaw
                        snapshot.resultPath = resultURL.path
                        snapshot.usageAccountingWordCount = Self.wordCount(in: orphanResult)
                        snapshot.stage = .succeeded
                        snapshot.sourceIntegrity = .complete
                        snapshot.deadlineAt = nil
                        snapshot.userMessage = "Processing was interrupted after the text was saved."
                        try advanceRevision(&snapshot)
                        try saveLocked(snapshot)
                        normalized.append(snapshot)
                        continue
                    }

                    if orphanRaw != nil {
                        snapshot.rawTranscriptPath = rawURL.path
                        snapshot.stage = .rawReady
                    } else if orphanPartial != nil {
                        snapshot.partialTranscriptPath = partialTextURL.path
                        snapshot.stage = .recognitionPartial
                    }
                }

                if snapshot.stage == .readyForRecognition {
                    // A retry manifest produced by an older build could have become authoritative
                    // before that build removed the prior generation's raw/result leaves. This
                    // stage has not started recognition, so those unreferenced leaves are
                    // necessarily stale and must not be adopted after terminalization.
                    try removeRetryTransientPayloadsLocked(recordingID: snapshot.recordingID)
                }

                switch snapshot.stage {
                case .rawReady, .cleaning:
                    guard let rawURL = snapshot.rawTranscriptURL,
                          hasFinal
                    else {
                        try quarantineLocked("Missing raw checkpoint for \(snapshot.recordingID)")
                        throw StoreError.sourceConflict
                    }
                    let raw = try readNonEmptyTextLocked(rawURL)
                    try durableWriteLocked(Data(raw.utf8), to: resultURL)
                    snapshot.resultPath = resultURL.path
                    snapshot.usageAccountingWordCount = Self.wordCount(in: raw)
                    snapshot.stage = .succeeded
                    snapshot.sourceIntegrity = .complete
                    snapshot.userMessage = "Cleanup was interrupted. The recognized text was kept."
                case .resultReady:
                    guard let resultURL = snapshot.resultURL,
                          hasFinal
                    else {
                        try quarantineLocked("Missing result checkpoint for \(snapshot.recordingID)")
                        throw StoreError.sourceConflict
                    }
                    let result = try readNonEmptyTextLocked(resultURL)
                    snapshot.usageAccountingWordCount = Self.wordCount(in: result)
                    snapshot.stage = .succeeded
                    snapshot.sourceIntegrity = .complete
                    snapshot.userMessage = "Processing was interrupted after the text was saved."
                case .readyForRecognition, .recognizing, .recognitionPartial:
                    guard hasFinal else {
                        try quarantineLocked("Complete source missing for \(snapshot.recordingID)")
                        throw StoreError.sourceMissing
                    }
                    snapshot.stage = .failed
                    snapshot.sourceIntegrity = .complete
                    snapshot.userMessage = "Processing was interrupted. Your recording was kept."
                case .preparing, .recording, .finalizing:
                    snapshot.stage = .failed
                    if snapshot.sourceIntegrity != .knownIncomplete {
                        snapshot.sourceIntegrity = .unfinalized
                    }
                    snapshot.userMessage = "Recording was interrupted before it finished."
                case .succeeded, .failed, .cancelled, .deleted:
                    break
                }
                snapshot.deadlineAt = nil
                try advanceRevision(&snapshot)
                try saveLocked(snapshot)
                normalized.append(snapshot)
            }
            return normalized
        }
    }

    public func recognizedText(for recordingID: UUID) throws -> String? {
        try withExclusiveLock {
            _ = try requireReadableMetadataLocked()
            guard let snapshot = try loadSnapshotIfPresentLocked(recordingID: recordingID) else { return nil }
            let candidate = snapshot.resultURL
                ?? snapshot.rawTranscriptURL
                ?? snapshot.previousResultURL
                ?? snapshot.partialTranscriptURL
            guard let candidate else { return nil }
            return try String(contentsOf: candidate, encoding: .utf8)
        }
    }

    /// Durably claims one pending non-idempotent usage operation before returning it to the caller.
    /// Once this succeeds the operation is never returned again, including after restart. A crash
    /// before delivery can undercount, but can never charge the same transcript twice.
    public func beginUsageAccounting(
        recordingID: UUID,
        attemptID: UUID = UUID(),
        now: Date = Date()
    ) throws -> UsageAccountingLease? {
        try withExclusiveLock { () -> UsageAccountingLease? in
            _ = try requireWritableMetadataLocked()
            var snapshot = try loadSnapshotLocked(recordingID: recordingID)
            guard [.succeeded, .deleted].contains(snapshot.stage),
                  now.timeIntervalSinceReferenceDate.isFinite
            else { return nil }

            if snapshot.usageAccountingState == .inFlight {
                // Migration from the former retrying lease model. Delivery may already have
                // happened, so replay would risk a duplicate charge.
                snapshot.usageAccountingState = .acknowledged
                snapshot.usageAccountingAttemptID = nil
                snapshot.usageAccountingDeadlineAt = nil
                try advanceRevision(&snapshot)
                try saveLocked(snapshot)
                return nil
            }
            guard (snapshot.usageAccountingState ?? .pending) == .pending else { return nil }

            let wordCount: Int
            if let storedWordCount = snapshot.usageAccountingWordCount {
                wordCount = storedWordCount
            } else if snapshot.stage == .succeeded, let resultURL = snapshot.resultURL {
                wordCount = Self.wordCount(in: try readNonEmptyTextLocked(resultURL))
                snapshot.usageAccountingWordCount = wordCount
            } else {
                return nil
            }

            snapshot.usageAccountingState = .acknowledged
            snapshot.usageAccountingAttemptID = nil
            snapshot.usageAccountingDeadlineAt = nil
            try advanceRevision(&snapshot)
            try saveLocked(snapshot)
            return UsageAccountingLease(
                recordingID: recordingID,
                attemptID: attemptID,
                wordCount: wordCount
            )
        }
    }

    private func mutate(
        _ lease: Lease,
        allowed: Set<Stage>,
        next: Stage,
        deadlineAt: Date?,
        retainDeadline: Bool = false
    ) throws {
        try withExclusiveLock {
            if let deadlineAt { try requireFutureDeadline(deadlineAt) }
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: true)
            guard allowed.contains(snapshot.stage) else { throw StoreError.invalidTransition }
            snapshot.stage = next
            if !retainDeadline { snapshot.deadlineAt = deadlineAt }
            try advanceRevision(&snapshot)
            try saveLocked(snapshot)
        }
    }

    private func persistTerminalState(
        _ intent: TerminalIntent,
        lease: Lease
    ) throws -> Snapshot {
        // Keep this hook outside the store lock. It models a blocked persistence boundary while
        // allowing another process/store instance to durably accept Delete, Clear, or retry.
        try beforeTerminalCommit(lease)

        return try withExclusiveLock {
            var snapshot = try currentSnapshotLocked(for: lease, enforceDeadline: false)
            try reconcileMovedFinalSourceLocked(&snapshot)
            guard snapshot.stage != .deleted else { throw StoreError.staleAttempt }

            switch intent {
            case .succeeded(let text):
                if snapshot.stage == .succeeded {
                    return snapshot
                }
                guard [
                    .recognizing,
                    .recognitionPartial,
                    .rawReady,
                    .cleaning,
                    .resultReady,
                ].contains(snapshot.stage)
                else { throw StoreError.invalidTransition }

                var resolved = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ""
                    : text
                if resolved.isEmpty, let rawURL = snapshot.rawTranscriptURL {
                    resolved = try readNonEmptyTextLocked(rawURL)
                }
                guard !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StoreError.emptyResult
                }

                let directory = attemptDirectory(recordingID: lease.recordingID)
                if snapshot.rawTranscriptPath == nil {
                    let rawURL = directory.appendingPathComponent("raw.txt")
                    try durableWriteLocked(Data(resolved.utf8), to: rawURL)
                    snapshot.rawTranscriptPath = rawURL.path
                }
                let resultURL = directory.appendingPathComponent("result.txt")
                try durableWriteLocked(Data(resolved.utf8), to: resultURL)
                snapshot.resultPath = resultURL.path
                snapshot.stage = .succeeded
                snapshot.sourceIntegrity = .complete
                snapshot.usageAccountingWordCount = Self.wordCount(in: resolved)
                snapshot.userMessage = nil

            case .failed(let message, let integrity):
                if snapshot.stage.isTerminal, snapshot.stage != .failed {
                    throw StoreError.invalidTransition
                }
                if try resolveCompletedRecognitionLocked(
                    &snapshot,
                    message: "Cleanup was unavailable. The recognized text was kept."
                ) {
                    return snapshot
                }
                snapshot.stage = .failed
                if snapshot.sourceIntegrity != .complete {
                    snapshot.sourceIntegrity = integrity ?? snapshot.sourceIntegrity
                }
                snapshot.userMessage = message

            case .cancelled(let message):
                if snapshot.stage == .cancelled {
                    return snapshot
                }
                guard !snapshot.stage.isTerminal else { throw StoreError.invalidTransition }
                if try resolveCompletedRecognitionLocked(
                    &snapshot,
                    message: "Processing stopped after the recognized text was saved."
                ) {
                    return snapshot
                }
                snapshot.stage = .cancelled
                snapshot.userMessage = message
            }

            snapshot.deadlineAt = nil
            try advanceRevision(&snapshot)
            try saveLocked(snapshot)
            return snapshot
        }
    }

    private func currentSnapshotLocked(for lease: Lease, enforceDeadline: Bool) throws -> Snapshot {
        let metadata = try requireWritableMetadataLocked()
        guard metadata.generation == lease.storeGeneration,
              !historyDeletionIDs(metadata).contains(lease.recordingID)
        else { throw StoreError.staleAttempt }
        let snapshot = try loadSnapshotLocked(recordingID: lease.recordingID)
        guard snapshot.attemptID == lease.attemptID,
              snapshot.generation == lease.generation,
              snapshot.storeGeneration == lease.storeGeneration,
              snapshot.stage != .deleted
        else { throw StoreError.staleAttempt }
        if enforceDeadline, let deadlineAt = snapshot.deadlineAt, Date() > deadlineAt {
            throw StoreError.deadlineExceeded
        }
        return snapshot
    }

    private func lease(for snapshot: Snapshot) -> Lease {
        Lease(
            recordingID: snapshot.recordingID,
            attemptID: snapshot.attemptID,
            generation: snapshot.generation,
            storeGeneration: snapshot.storeGeneration,
            sourceURL: snapshot.sourceURL
        )
    }

    private func advanceRevision(_ snapshot: inout Snapshot) throws {
        guard snapshot.revision < UInt64.max else { throw StoreError.counterExhausted }
        snapshot.revision += 1
        snapshot.updatedAt = Date()
    }

    private nonisolated static func inspectClosedSourceDetached(
        _ url: URL,
        minimumBytes: Int64,
        minimumDuration: TimeInterval
    ) throws -> DeepSourceInspection {
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.sourceMissing }
        let proofBefore = try detachedRegularFileProof(url)
        try validateContainerStructure(url, byteCount: proofBefore.byteCount)
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw StoreError.sourceIncomplete
        }
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let declaredFrames = audioFile.length
        guard sampleRate.isFinite, sampleRate > 0,
              format.channelCount > 0,
              declaredFrames > 0,
              let decodeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)
        else { throw StoreError.sourceIncomplete }

        var decodedFrames: AVAudioFramePosition = 0
        do {
            while decodedFrames < declaredFrames {
                let remaining = declaredFrames - decodedFrames
                let requested = AVAudioFrameCount(min(AVAudioFramePosition(8_192), remaining))
                decodeBuffer.frameLength = 0
                try audioFile.read(into: decodeBuffer, frameCount: requested)
                guard decodeBuffer.frameLength > 0 else { throw StoreError.sourceIncomplete }
                decodedFrames += AVAudioFramePosition(decodeBuffer.frameLength)
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.sourceIncomplete
        }
        guard decodedFrames == declaredFrames else { throw StoreError.sourceIncomplete }

        try synchronizeDetachedRegularFile(url)
        try synchronizeDetachedDirectory(url.deletingLastPathComponent())
        let proofAfter = try detachedRegularFileProof(url)
        guard proofBefore == proofAfter else { throw StoreError.sourceIncomplete }
        let duration = Double(decodedFrames) / sampleRate
        guard duration.isFinite,
              proofAfter.byteCount >= minimumBytes,
              duration >= minimumDuration
        else {
            throw StoreError.sourceIncomplete
        }
        return DeepSourceInspection(
            fileProof: proofAfter,
            frameCount: Int64(decodedFrames),
            sampleRate: sampleRate,
            duration: duration
        )
    }

    private nonisolated static func synchronizeDetachedRegularFile(_ url: URL) throws {
        #if canImport(Darwin)
            let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw StoreError.unavailable }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw StoreError.unavailable }
        #endif
    }

    private nonisolated static func synchronizeDetachedDirectory(_ url: URL) throws {
        #if canImport(Darwin)
            let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw StoreError.unavailable }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw StoreError.unavailable }
        #endif
    }

    private nonisolated static func validateContainerStructure(_ url: URL, byteCount: Int64) throws {
        guard byteCount >= 12 else { throw StoreError.sourceIncomplete }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try read(handle, offset: 0, count: 12)
        let bytes = [UInt8](prefix)
        if String(bytes: bytes[4 ..< 8], encoding: .ascii) == "ftyp" {
            try validateISOBaseMedia(handle, byteCount: UInt64(byteCount))
        } else if String(bytes: bytes[0 ..< 4], encoding: .ascii) == "RIFF",
                  String(bytes: bytes[8 ..< 12], encoding: .ascii) == "WAVE"
        {
            try validateRIFFWave(handle, byteCount: UInt64(byteCount), prefix: bytes)
        }
    }

    private nonisolated static func validateISOBaseMedia(_ handle: FileHandle, byteCount: UInt64) throws {
        var offset: UInt64 = 0
        var foundFileType = false
        var foundMovie = false
        var foundMediaData = false
        while offset < byteCount {
            let header = [UInt8](try read(handle, offset: offset, count: 8))
            let shortSize = bigEndianUInt32(header, offset: 0)
            let type = String(bytes: header[4 ..< 8], encoding: .ascii) ?? ""
            var headerSize: UInt64 = 8
            let atomSize: UInt64
            if shortSize == 1 {
                let extended = [UInt8](try read(handle, offset: offset + 8, count: 8))
                atomSize = bigEndianUInt64(extended, offset: 0)
                headerSize = 16
            } else if shortSize == 0 {
                atomSize = byteCount - offset
            } else {
                atomSize = UInt64(shortSize)
            }
            guard atomSize >= headerSize, atomSize <= byteCount - offset else {
                throw StoreError.sourceIncomplete
            }
            foundFileType = foundFileType || type == "ftyp"
            foundMovie = foundMovie || type == "moov"
            foundMediaData = foundMediaData || type == "mdat"
            offset += atomSize
        }
        guard offset == byteCount, foundFileType, foundMovie, foundMediaData else {
            throw StoreError.sourceIncomplete
        }
    }

    private nonisolated static func validateRIFFWave(
        _ handle: FileHandle,
        byteCount: UInt64,
        prefix: [UInt8]
    ) throws {
        let declaredSize = UInt64(littleEndianUInt32(prefix, offset: 4)) + 8
        guard declaredSize <= byteCount, declaredSize >= 12 else { throw StoreError.sourceIncomplete }
        var offset: UInt64 = 12
        var foundFormat = false
        var foundAudioData = false
        while offset < declaredSize {
            guard declaredSize - offset >= 8 else { throw StoreError.sourceIncomplete }
            let header = [UInt8](try read(handle, offset: offset, count: 8))
            let type = String(bytes: header[0 ..< 4], encoding: .ascii) ?? ""
            let payloadSize = UInt64(littleEndianUInt32(header, offset: 4))
            let paddedPayloadSize = payloadSize + (payloadSize & 1)
            guard paddedPayloadSize <= declaredSize - offset - 8 else {
                throw StoreError.sourceIncomplete
            }
            foundFormat = foundFormat || type == "fmt "
            foundAudioData = foundAudioData || type == "data"
            offset += 8 + paddedPayloadSize
        }
        guard offset == declaredSize, foundFormat, foundAudioData else {
            throw StoreError.sourceIncomplete
        }
    }

    private nonisolated static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw StoreError.sourceIncomplete
            }
            return data
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.sourceIncomplete
        }
    }

    private nonisolated static func bigEndianUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private nonisolated static func bigEndianUInt64(_ bytes: [UInt8], offset: Int) -> UInt64 {
        (0 ..< 8).reduce(UInt64(0)) { value, index in
            (value << 8) | UInt64(bytes[offset + index])
        }
    }

    private nonisolated static func littleEndianUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private func scanSnapshotsLocked(validateReferencedPayloads: Bool = true) throws -> [Snapshot] {
        let directories = try fileManager.contentsOfDirectory(
            at: attemptsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var snapshots: [Snapshot] = []
        for directory in directories {
            guard let recordingID = UUID(uuidString: directory.lastPathComponent) else {
                try quarantineLocked("Unknown attempt directory \(directory.lastPathComponent)")
                throw StoreError.quarantined
            }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                try quarantineLocked("Unsafe attempt directory \(recordingID)")
                throw StoreError.quarantined
            }
            let names = try validatedPayloadNamesLocked(recordingID: recordingID)
            if !names.contains("attempt.json") {
                if try removeSafeAllocationFragmentLocked(recordingID: recordingID, names: names) {
                    continue
                }
                try quarantineLocked("Attempt directory has no manifest for \(recordingID)")
                throw StoreError.quarantined
            }
            let snapshot = try loadSnapshotLocked(
                recordingID: recordingID,
                validateReferencedPayloads: validateReferencedPayloads
            )
            snapshots.append(snapshot)
        }
        return snapshots
    }

    private func loadSnapshotLocked(
        recordingID: UUID,
        validateReferencedPayloads: Bool = true
    ) throws -> Snapshot {
        do {
            _ = try validatedPayloadNamesLocked(recordingID: recordingID)
            _ = try regularFileProofLocked(manifestURL(recordingID: recordingID))
            let data = try Data(contentsOf: manifestURL(recordingID: recordingID))
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            try validateSnapshotLayoutLocked(snapshot, expectedRecordingID: recordingID)
            if validateReferencedPayloads { try self.validateReferencedPayloadsLocked(snapshot) }
            return snapshot
        } catch {
            try? quarantineLocked("Unreadable or unsafe manifest for \(recordingID)")
            throw StoreError.quarantined
        }
    }

    private func loadSnapshotIfPresentLocked(
        recordingID: UUID,
        validateReferencedPayloads: Bool = true
    ) throws -> Snapshot? {
        let url = manifestURL(recordingID: recordingID)
        guard fileManager.fileExists(atPath: url.path) else {
            let directory = attemptDirectory(recordingID: recordingID)
            if fileManager.fileExists(atPath: directory.path) {
                let names = try validatedPayloadNamesLocked(recordingID: recordingID)
                if try removeSafeAllocationFragmentLocked(recordingID: recordingID, names: names) {
                    return nil
                }
                try quarantineLocked("Attempt directory has no manifest for \(recordingID)")
                throw StoreError.quarantined
            }
            return nil
        }
        return try loadSnapshotLocked(
            recordingID: recordingID,
            validateReferencedPayloads: validateReferencedPayloads
        )
    }

    private func saveLocked(
        _ snapshot: Snapshot,
        requireFutureActiveDeadline: Bool = true
    ) throws {
        do {
            try validateSnapshotLayoutLocked(
                snapshot,
                expectedRecordingID: snapshot.recordingID,
                requireFutureActiveDeadline: requireFutureActiveDeadline
            )
            let data = try JSONEncoder().encode(snapshot)
            try durableWriteLocked(data, to: manifestURL(recordingID: snapshot.recordingID))
        } catch {
            if let error = error as? StoreError { throw error }
            throw StoreError.unavailable
        }
    }

    private func requireReadableMetadataLocked() throws -> StoreMetadata {
        guard !initializationFailed else { throw StoreError.unavailable }
        guard !fileManager.fileExists(atPath: quarantineURL.path) else { throw StoreError.quarantined }
        if !fileManager.fileExists(atPath: metadataURL.path) {
            let contents = try fileManager.contentsOfDirectory(atPath: attemptsDirectory.path)
            guard contents.isEmpty else {
                try quarantineLocked("Store metadata missing while attempts exist")
                throw StoreError.quarantined
            }
            let metadata = StoreMetadata(schemaVersion: Self.schemaVersion, generation: 1)
            try saveMetadataLocked(metadata)
            return metadata
        }
        do {
            _ = try regularFileProofLocked(metadataURL)
            let metadata = try JSONDecoder().decode(
                StoreMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
            guard metadata.schemaVersion == Self.schemaVersion, metadata.generation > 0 else {
                throw StoreError.quarantined
            }
            return metadata
        } catch {
            try? quarantineLocked("Unreadable store metadata")
            throw StoreError.quarantined
        }
    }

    private func requireWritableMetadataLocked() throws -> StoreMetadata {
        try requireReadableMetadataLocked()
    }

    private func saveMetadataLocked(_ metadata: StoreMetadata) throws {
        do {
            guard metadata.schemaVersion == Self.schemaVersion, metadata.generation > 0 else {
                throw StoreError.counterExhausted
            }
            try durableWriteLocked(try JSONEncoder().encode(metadata), to: metadataURL)
        } catch {
            if let error = error as? StoreError { throw error }
            throw StoreError.unavailable
        }
    }

    private func historyDeletionIDs(_ metadata: StoreMetadata) -> Set<UUID> {
        metadata.deletedHistoryRecordingIDs ?? []
    }

    private func applyHistoryDeletionIntentsLocked(_ metadata: StoreMetadata) throws {
        for recordingID in historyDeletionIDs(metadata).sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            try applyHistoryDeletionIntentLocked(recordingID: recordingID, metadata: metadata)
        }
    }

    /// Materializes the metadata deletion ledger into attempt tombstones. The ledger itself is
    /// already the authority, so this repair is safe to repeat after any interrupted file write.
    private func applyHistoryDeletionIntentLocked(
        recordingID: UUID,
        metadata: StoreMetadata
    ) throws {
        if var snapshot = try loadSnapshotIfPresentLocked(
            recordingID: recordingID,
            validateReferencedPayloads: false
        ) {
            var needsSave = false
            if snapshot.stage != .deleted {
                guard snapshot.generation < UInt64.max else {
                    throw StoreError.counterExhausted
                }
                snapshot.generation += 1
                snapshot.stage = .deleted
                snapshot.sourceProof = nil
                snapshot.deadlineAt = nil
                snapshot.userMessage = nil
                needsSave = true
            }
            if snapshot.usageAccountingState == .inFlight {
                snapshot.usageAccountingState = .acknowledged
                snapshot.usageAccountingAttemptID = nil
                snapshot.usageAccountingDeadlineAt = nil
                needsSave = true
            }
            if needsSave {
                try advanceRevision(&snapshot)
                try saveLocked(snapshot)
            }
            try removePayloadsLocked(snapshot)
            return
        }

        let directory = attemptDirectory(recordingID: recordingID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try synchronizeDirectoryLocked(attemptsDirectory)
        let now = Date()
        let snapshot = Snapshot(
            recordingID: recordingID,
            attemptID: UUID(),
            generation: 1,
            storeGeneration: metadata.generation,
            revision: 1,
            stage: .deleted,
            sourceIntegrity: .unfinalized,
            sourcePath: directory.appendingPathComponent("source.partial.m4a").path,
            partialTranscriptPath: nil,
            rawTranscriptPath: nil,
            resultPath: nil,
            previousResultPath: nil,
            sourceProof: nil,
            outputModeRaw: nil,
            transcriptionOptions: nil,
            usageAccountingState: .acknowledged,
            usageAccountingAttemptID: nil,
            usageAccountingDeadlineAt: nil,
            usageAccountingWordCount: nil,
            duration: nil,
            userMessage: nil,
            deadlineAt: nil,
            createdAt: now,
            updatedAt: now
        )
        try saveLocked(snapshot)
    }

    private func quarantineLocked(_ reason: String) throws {
        try durableWriteLocked(Data(reason.utf8), to: quarantineURL)
    }

    private func removePayloadsLocked(_ snapshot: Snapshot) throws {
        try validateSnapshotLayoutLocked(snapshot, expectedRecordingID: snapshot.recordingID)
        let directory = attemptDirectory(recordingID: snapshot.recordingID)
        let names = try validatedPayloadNamesLocked(recordingID: snapshot.recordingID)
        for name in names where name != "attempt.json" {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        try synchronizeDirectoryLocked(directory)
    }

    private func validateSnapshotLayoutLocked(
        _ snapshot: Snapshot,
        expectedRecordingID: UUID,
        requireFutureActiveDeadline: Bool = false
    ) throws {
        let directory = attemptDirectory(recordingID: expectedRecordingID)
        let partialSource = directory.appendingPathComponent("source.partial.m4a").path
        let finalSource = directory.appendingPathComponent("source.m4a").path
        let partialText = directory.appendingPathComponent("recognition-partial.txt").path
        let rawText = directory.appendingPathComponent("raw.txt").path
        let resultText = directory.appendingPathComponent("result.txt").path
        let previousResult = directory.appendingPathComponent("previous-result.txt").path

        guard snapshot.recordingID == expectedRecordingID,
              snapshot.generation > 0,
              snapshot.storeGeneration > 0,
              snapshot.revision > 0,
              snapshot.sourcePath == partialSource || snapshot.sourcePath == finalSource,
              snapshot.partialTranscriptPath == nil || snapshot.partialTranscriptPath == partialText,
              snapshot.rawTranscriptPath == nil || snapshot.rawTranscriptPath == rawText,
              snapshot.resultPath == nil || snapshot.resultPath == resultText,
              snapshot.previousResultPath == nil || snapshot.previousResultPath == previousResult,
              snapshot.createdAt.timeIntervalSinceReferenceDate.isFinite,
              snapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              snapshot.duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
              snapshot.deadlineAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              snapshot.usageAccountingDeadlineAt.map({
                  $0.timeIntervalSinceReferenceDate.isFinite
              }) ?? true,
              snapshot.usageAccountingWordCount.map({ $0 >= 0 }) ?? true,
              snapshot.sourceProof.map({ proof in
                  proof.recordingID == snapshot.recordingID
                      && proof.attemptID == snapshot.attemptID
                      && proof.generation == snapshot.generation
                      && proof.storeGeneration == snapshot.storeGeneration
                      && proof.byteCount > 0
                      && proof.frameCount > 0
                      && proof.sampleRate.isFinite
                      && proof.sampleRate > 0
                      && proof.duration.isFinite
                      && proof.duration > 0
              }) ?? true
        else { throw StoreError.quarantined }

        switch snapshot.usageAccountingState {
        case nil, .pending?, .acknowledged?:
            guard snapshot.usageAccountingAttemptID == nil,
                  snapshot.usageAccountingDeadlineAt == nil
            else { throw StoreError.quarantined }
        case .inFlight?:
            guard [.succeeded, .deleted].contains(snapshot.stage),
                  snapshot.usageAccountingAttemptID != nil,
                  snapshot.usageAccountingDeadlineAt != nil,
                  snapshot.usageAccountingWordCount != nil
            else { throw StoreError.quarantined }
        }

        switch snapshot.sourceIntegrity {
        case .complete:
            guard snapshot.sourcePath == finalSource,
                  snapshot.stage == .deleted || snapshot.sourceProof != nil
            else { throw StoreError.quarantined }
        case .unfinalized:
            guard snapshot.sourcePath == partialSource else { throw StoreError.quarantined }
        case .knownIncomplete:
            guard snapshot.sourcePath == partialSource || snapshot.sourcePath == finalSource else {
                throw StoreError.quarantined
            }
        }

        switch snapshot.stage {
        case .preparing, .recording, .finalizing:
            guard snapshot.sourceIntegrity != .complete,
                  snapshot.partialTranscriptPath == nil,
                  snapshot.rawTranscriptPath == nil,
                  snapshot.resultPath == nil,
                  snapshot.previousResultPath == nil
            else { throw StoreError.quarantined }
        case .readyForRecognition, .recognizing:
            guard snapshot.sourceIntegrity == .complete,
                  snapshot.partialTranscriptPath == nil,
                  snapshot.rawTranscriptPath == nil,
                  snapshot.resultPath == nil
            else { throw StoreError.quarantined }
        case .recognitionPartial:
            guard snapshot.sourceIntegrity == .complete,
                  snapshot.partialTranscriptPath == partialText,
                  snapshot.rawTranscriptPath == nil,
                  snapshot.resultPath == nil
            else { throw StoreError.quarantined }
        case .rawReady, .cleaning:
            guard snapshot.sourceIntegrity == .complete,
                  snapshot.rawTranscriptPath == rawText,
                  snapshot.resultPath == nil
            else { throw StoreError.quarantined }
        case .resultReady, .succeeded:
            guard snapshot.sourceIntegrity == .complete,
                  snapshot.rawTranscriptPath == rawText,
                  snapshot.resultPath == resultText
            else { throw StoreError.quarantined }
        case .failed, .cancelled, .deleted:
            break
        }

        let deadlineRequired: Bool
        switch snapshot.stage {
        case .preparing, .recording, .finalizing, .recognizing, .recognitionPartial, .rawReady, .cleaning:
            deadlineRequired = true
        case .readyForRecognition, .resultReady, .succeeded, .failed, .cancelled, .deleted:
            deadlineRequired = false
        }
        if deadlineRequired, snapshot.deadlineAt == nil { throw StoreError.quarantined }
        if snapshot.stage.isTerminal || snapshot.stage == .resultReady,
           snapshot.deadlineAt != nil
        {
            throw StoreError.quarantined
        }
        if requireFutureActiveDeadline,
           deadlineRequired,
           let deadlineAt = snapshot.deadlineAt,
           deadlineAt <= Date()
        {
            throw StoreError.deadlineExceeded
        }
    }

    private func validatedPayloadNamesLocked(recordingID: UUID) throws -> Set<String> {
        let directory = attemptDirectory(recordingID: recordingID)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw StoreError.quarantined
        }

        var names = Set(try fileManager.contentsOfDirectory(atPath: directory.path))
        var removedTemporaryFile = false
        for name in names where isDurableTemporaryName(name, allowedDestinations: Self.allowedPayloadNames) {
            _ = try regularFileProofLocked(directory.appendingPathComponent(name))
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
            names.remove(name)
            removedTemporaryFile = true
        }
        if removedTemporaryFile { try synchronizeDirectoryLocked(directory) }
        guard names.isSubset(of: Self.allowedPayloadNames) else { throw StoreError.quarantined }
        for name in names {
            _ = try regularFileProofLocked(directory.appendingPathComponent(name))
        }
        return names
    }

    private func validateReferencedPayloadsLocked(_ snapshot: Snapshot) throws {
        guard snapshot.stage != .deleted else { return }
        let directory = attemptDirectory(recordingID: snapshot.recordingID)
        let partialSource = directory.appendingPathComponent("source.partial.m4a")
        let finalSource = directory.appendingPathComponent("source.m4a")
        let hasPartialSource = fileManager.fileExists(atPath: partialSource.path)
        let hasFinalSource = fileManager.fileExists(atPath: finalSource.path)

        switch snapshot.sourceIntegrity {
        case .complete:
            guard let proof = snapshot.sourceProof,
                  hasFinalSource, !hasPartialSource,
                  try sourceMatchesProofLocked(finalSource, proof: proof)
            else { throw StoreError.quarantined }
            _ = try regularFileProofLocked(finalSource)
        case .unfinalized:
            if snapshot.stage == .finalizing, !hasPartialSource, hasFinalSource {
                _ = try regularFileProofLocked(finalSource)
            } else {
                guard hasPartialSource, !hasFinalSource else { throw StoreError.quarantined }
                _ = try regularFileProofLocked(partialSource)
            }
        case .knownIncomplete:
            let expectedURL = snapshot.sourcePath == finalSource.path ? finalSource : partialSource
            let conflictingURL = expectedURL == finalSource ? partialSource : finalSource
            guard fileManager.fileExists(atPath: expectedURL.path),
                  !fileManager.fileExists(atPath: conflictingURL.path)
            else { throw StoreError.quarantined }
            _ = try regularFileProofLocked(expectedURL)
        }

        for url in [
            snapshot.partialTranscriptURL,
            snapshot.rawTranscriptURL,
            snapshot.resultURL,
            snapshot.previousResultURL,
        ].compactMap({ $0 }) {
            _ = try readNonEmptyTextLocked(url)
        }
    }

    private func removeSafeAllocationFragmentLocked(recordingID: UUID, names: Set<String>) throws -> Bool {
        guard names.isEmpty || names == ["source.partial.m4a"] else { return false }
        let directory = attemptDirectory(recordingID: recordingID)
        if names.contains("source.partial.m4a") {
            let proof = try regularFileProofLocked(directory.appendingPathComponent("source.partial.m4a"))
            guard proof.byteCount == 0 else { return false }
        }
        try fileManager.removeItem(at: directory)
        try synchronizeDirectoryLocked(attemptsDirectory)
        return true
    }

    private func preservedResultDataLocked(_ snapshot: Snapshot) throws -> Data? {
        for candidate in [
            snapshot.resultURL,
            snapshot.rawTranscriptURL,
            snapshot.previousResultURL,
            snapshot.partialTranscriptURL,
        ] {
            guard let candidate else { continue }
            let text = try readNonEmptyTextLocked(candidate)
            return Data(text.utf8)
        }
        return nil
    }

    private func removeRetryTransientPayloadsLocked(recordingID: UUID) throws {
        let directory = attemptDirectory(recordingID: recordingID)
        var removed = false
        for name in ["recognition-partial.txt", "raw.txt", "result.txt"] {
            let url = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                _ = try regularFileProofLocked(url)
                try fileManager.removeItem(at: url)
                removed = true
            }
        }
        if removed { try synchronizeDirectoryLocked(directory) }
        try removeChunkWorkspacesLocked(recordingID: recordingID)
    }

    private func sweepChunkWorkspacesLocked() throws {
        let recordingDirectories = try fileManager.contentsOfDirectory(
            at: chunkWorkspacesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for recordingDirectory in recordingDirectories {
            guard let recordingID = UUID(uuidString: recordingDirectory.lastPathComponent) else {
                throw StoreError.quarantined
            }
            try validateDirectoryNoFollow(recordingDirectory)
            try removeChunkWorkspacesLocked(recordingID: recordingID)
        }
    }

    private func removeChunkWorkspacesLocked(recordingID: UUID) throws {
        let recordingDirectory = chunkWorkspacesDirectory.appendingPathComponent(
            recordingID.uuidString,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: recordingDirectory.path) else { return }
        try validateDirectoryNoFollow(recordingDirectory)

        let workspaces = try fileManager.contentsOfDirectory(
            at: recordingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for workspace in workspaces {
            guard UUID(uuidString: workspace.lastPathComponent) != nil else {
                throw StoreError.quarantined
            }
            try validateDirectoryNoFollow(workspace)
            let leaves = try fileManager.contentsOfDirectory(
                at: workspace,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
            for leaf in leaves {
                guard ChunkWorkspace.isOwnedLeafName(leaf.lastPathComponent) else {
                    throw StoreError.quarantined
                }
                let values = try leaf.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw StoreError.quarantined
                }
                try fileManager.removeItem(at: leaf)
            }
            try fileManager.removeItem(at: workspace)
        }
        try fileManager.removeItem(at: recordingDirectory)
        try synchronizeDirectoryLocked(chunkWorkspacesDirectory)
    }

    private func readNonEmptyTextIfPresentLocked(_ url: URL) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readNonEmptyTextLocked(url)
    }

    private func readNonEmptyTextLocked(_ url: URL) throws -> String {
        _ = try regularFileProofLocked(url)
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            try quarantineLocked("Unreadable text checkpoint")
            throw StoreError.quarantined
        }
        return text
    }

    private nonisolated static func wordCount(in text: String) -> Int {
        text.split { character in
            !(character.isLetter || character.isNumber)
        }.count
    }

    private func requireFutureDeadline(_ deadlineAt: Date) throws {
        guard deadlineAt.timeIntervalSinceReferenceDate.isFinite, deadlineAt > Date() else {
            throw StoreError.deadlineExceeded
        }
    }

    private func requireUnexpiredSnapshotDeadline(_ snapshot: Snapshot) throws {
        guard let deadlineAt = snapshot.deadlineAt, deadlineAt > Date() else {
            throw StoreError.deadlineExceeded
        }
    }

    private func reconcileMovedFinalSourceLocked(_ snapshot: inout Snapshot) throws {
        guard snapshot.stage == .finalizing else { return }
        let directory = attemptDirectory(recordingID: snapshot.recordingID)
        let partialURL = directory.appendingPathComponent("source.partial.m4a")
        let finalURL = directory.appendingPathComponent("source.m4a")
        guard !fileManager.fileExists(atPath: partialURL.path),
              fileManager.fileExists(atPath: finalURL.path)
        else { return }
        snapshot.sourcePath = finalURL.path
        if let proof = snapshot.sourceProof,
           try sourceMatchesProofLocked(finalURL, proof: proof)
        {
            snapshot.sourceIntegrity = .complete
            snapshot.duration = proof.duration
        } else {
            snapshot.sourceProof = nil
            snapshot.sourceIntegrity = .knownIncomplete
        }
    }

    /// Once complete recognition text is durable, later cleanup, delivery, timeout, or
    /// cancellation failures must not downgrade it to a failed/cancelled attempt.
    private func resolveCompletedRecognitionLocked(
        _ snapshot: inout Snapshot,
        message: String
    ) throws -> Bool {
        guard snapshot.sourceIntegrity == .complete,
              [
                  .recognizing,
                  .recognitionPartial,
                  .rawReady,
                  .cleaning,
                  .resultReady,
                  .failed,
                  .cancelled,
              ].contains(snapshot.stage)
        else { return false }

        let directory = attemptDirectory(recordingID: snapshot.recordingID)
        let rawURL = directory.appendingPathComponent("raw.txt")
        let resultURL = directory.appendingPathComponent("result.txt")

        let rawText: String?
        if let referencedRawURL = snapshot.rawTranscriptURL {
            rawText = try readNonEmptyTextLocked(referencedRawURL)
        } else {
            rawText = try readNonEmptyTextIfPresentLocked(rawURL)
        }

        let resultText: String?
        if let referencedResultURL = snapshot.resultURL {
            resultText = try readNonEmptyTextLocked(referencedResultURL)
        } else {
            resultText = try readNonEmptyTextIfPresentLocked(resultURL)
        }

        guard rawText != nil || resultText != nil else { return false }

        let durableRaw: String
        if let rawText {
            durableRaw = rawText
            snapshot.rawTranscriptPath = rawURL.path
        } else if let resultText {
            durableRaw = resultText
            try durableWriteLocked(Data(resultText.utf8), to: rawURL)
            snapshot.rawTranscriptPath = rawURL.path
        } else {
            throw StoreError.sourceConflict
        }

        let completedText: String
        if let resultText {
            completedText = resultText
            snapshot.resultPath = resultURL.path
        } else {
            completedText = durableRaw
            try durableWriteLocked(Data(durableRaw.utf8), to: resultURL)
            snapshot.resultPath = resultURL.path
        }

        snapshot.stage = .succeeded
        snapshot.usageAccountingWordCount = Self.wordCount(in: completedText)
        snapshot.sourceIntegrity = .complete
        snapshot.deadlineAt = nil
        snapshot.userMessage = message
        try advanceRevision(&snapshot)
        try saveLocked(snapshot)
        return true
    }

    private func regularFileProofLocked(_ url: URL) throws -> FileProof {
        try Self.detachedRegularFileProof(url)
    }

    private nonisolated static func detachedRegularFileProof(_ url: URL) throws -> FileProof {
        #if canImport(Darwin)
            var information = Darwin.stat()
            let status = url.path.withCString { Darwin.lstat($0, &information) }
            guard status == 0, (information.st_mode & S_IFMT) == S_IFREG else {
                throw StoreError.sourceIncomplete
            }
            return FileProof(
                byteCount: Int64(information.st_size),
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino)
            )
        #else
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw StoreError.sourceIncomplete
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return FileProof(
                byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modificationSeconds: Int64((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0),
                modificationNanoseconds: 0,
                device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            )
        #endif
    }

    private func sourceMatchesProofLocked(_ url: URL, proof: ClosedSourceProof) throws -> Bool {
        let actual = try regularFileProofLocked(url)
        return actual.byteCount == proof.byteCount
            && actual.modificationSeconds == proof.modificationSeconds
            && actual.modificationNanoseconds == proof.modificationNanoseconds
            && actual.device == proof.device
            && actual.inode == proof.inode
    }

    private func proofMatchesLease(_ proof: ClosedSourceProof, lease: Lease) -> Bool {
        proof.recordingID == lease.recordingID
            && proof.attemptID == lease.attemptID
            && proof.generation == lease.generation
            && proof.storeGeneration == lease.storeGeneration
    }

    private func durableWriteLocked(_ data: Data, to destination: URL) throws {
        guard isManagedWriteDestination(destination) else { throw StoreError.quarantined }
        #if canImport(Darwin)
            let directory = destination.deletingLastPathComponent()
            let temporaryURL = directory.appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
            )
            var descriptor = temporaryURL.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else { throw StoreError.unavailable }
            var renamed = false
            defer {
                if descriptor >= 0 { Darwin.close(descriptor) }
                if !renamed { try? fileManager.removeItem(at: temporaryURL) }
            }

            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw StoreError.unavailable }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw StoreError.unavailable }
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw StoreError.unavailable
            }
            descriptor = -1
            let renameStatus = temporaryURL.path.withCString { source in
                destination.path.withCString { target in Darwin.rename(source, target) }
            }
            guard renameStatus == 0 else { throw StoreError.unavailable }
            renamed = true
            try synchronizeDirectoryLocked(directory)
        #else
            try data.write(to: destination, options: .atomic)
        #endif
    }

    private func moveSourceDurablyLocked(from source: URL, to destination: URL) throws {
        guard isManagedWriteDestination(source), isManagedWriteDestination(destination),
              !fileManager.fileExists(atPath: destination.path)
        else { throw StoreError.sourceConflict }
        try synchronizeRegularFileLocked(source)
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw StoreError.sourceConflict
        }
        try synchronizeDirectoryLocked(destination.deletingLastPathComponent())
    }

    private func synchronizeRegularFileLocked(_ url: URL) throws {
        _ = try regularFileProofLocked(url)
        #if canImport(Darwin)
            let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw StoreError.unavailable }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw StoreError.unavailable }
        #endif
    }

    private func synchronizeDirectoryLocked(_ directory: URL) throws {
        #if canImport(Darwin)
            let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw StoreError.unavailable }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw StoreError.unavailable }
        #endif
    }

    private func isManagedWriteDestination(_ url: URL) -> Bool {
        if url == metadataURL || url == quarantineURL { return true }
        let parent = url.deletingLastPathComponent()
        guard parent.deletingLastPathComponent() == attemptsDirectory,
              UUID(uuidString: parent.lastPathComponent) != nil
        else { return false }
        return Self.allowedPayloadNames.contains(url.lastPathComponent)
    }

    private func isDurableTemporaryName(_ name: String, allowedDestinations: Set<String>) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        for destination in allowedDestinations {
            let prefix = ".\(destination)."
            guard name.hasPrefix(prefix) else { continue }
            let uuidStart = name.index(name.startIndex, offsetBy: prefix.count)
            let uuidEnd = name.index(name.endIndex, offsetBy: -4)
            return UUID(uuidString: String(name[uuidStart ..< uuidEnd])) != nil
        }
        return false
    }

    private func attemptDirectory(recordingID: UUID) -> URL {
        attemptsDirectory.appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }

    private func manifestURL(recordingID: UUID) -> URL {
        attemptDirectory(recordingID: recordingID).appendingPathComponent("attempt.json")
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        guard !initializationFailed else { throw StoreError.unavailable }
        try validateManagedDirectoryTree()
        #if canImport(Darwin)
            let descriptor = lockURL.path.withCString {
                Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else { throw StoreError.unavailable }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.unavailable }
            defer { flock(descriptor, LOCK_UN) }
        #endif
        return try body()
    }

    private func validateManagedDirectoryTree() throws {
        if let trustedContainerDirectory {
            try validateDirectoryNoFollow(trustedContainerDirectory)
            let containerPath = trustedContainerDirectory.standardizedFileURL.path
            let rootPath = rootDirectory.standardizedFileURL.path
            guard rootPath.hasPrefix(containerPath + "/") else {
                throw StoreError.quarantined
            }
        }
        try validateDirectoryNoFollow(rootDirectory)
        try validateDirectoryNoFollow(attemptsDirectory)
        try validateDirectoryNoFollow(chunkWorkspacesDirectory)
    }

    private func validateDirectoryNoFollow(_ directory: URL) throws {
        #if canImport(Darwin)
            let descriptor = directory.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw StoreError.quarantined }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR
            else { throw StoreError.quarantined }
        #else
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw StoreError.quarantined
            }
        #endif
    }

    static func trustedAppGroupContainerDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        #if os(iOS)
            guard let containerURL = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
            ) else { throw StoreError.unavailable }
            #if canImport(Darwin)
                let descriptor = containerURL.path.withCString {
                    Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard descriptor >= 0 else { throw StoreError.unavailable }
                defer { Darwin.close(descriptor) }
                var status = stat()
                guard Darwin.fstat(descriptor, &status) == 0,
                      (status.st_mode & S_IFMT) == S_IFDIR
                else { throw StoreError.unavailable }
            #endif
            return containerURL
        #else
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { throw StoreError.unavailable }
            return applicationSupport
        #endif
    }

    @discardableResult
    static func ensureDirectoryNoFollow(parent: URL, name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw StoreError.quarantined
        }
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        #if canImport(Darwin)
            let parentDescriptor = parent.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard parentDescriptor >= 0 else { throw StoreError.unavailable }
            defer { Darwin.close(parentDescriptor) }

            let creationResult = name.withCString {
                Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
            }
            guard creationResult == 0 || errno == EEXIST else {
                throw StoreError.unavailable
            }
            let childDescriptor = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard childDescriptor >= 0 else { throw StoreError.quarantined }
            defer { Darwin.close(childDescriptor) }
            var status = stat()
            guard Darwin.fstat(childDescriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR
            else { throw StoreError.quarantined }
            guard Darwin.fsync(parentDescriptor) == 0 else { throw StoreError.unavailable }
        #else
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw StoreError.quarantined
            }
        #endif
        return directory
    }
}
