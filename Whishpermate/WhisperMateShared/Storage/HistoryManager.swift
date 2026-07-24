import Foundation
public import Combine

#if canImport(Darwin)
    import Darwin
#endif

public enum HistoryPersistenceError: LocalizedError, Equatable, Sendable {
    case unavailable
    case corrupt
    case deleted
    case counterExhausted

    public var errorDescription: String? {
        switch self {
        case .unavailable, .corrupt, .counterExhausted:
            return "Saved recordings are temporarily unavailable. Restart the app and try again."
        case .deleted:
            return "This recording was deleted."
        }
    }
}

/// Main-actor projection of a revisioned, cross-scene history journal.
///
/// Every mutation reloads under a process/file lock and commits atomically before this observable
/// projection changes. Deletion tombstones prevent a stale scene from resurrecting a row, while
/// the revision notification makes other live scenes converge on the committed order.
@MainActor
public final class HistoryManager: ObservableObject {
    @Published public private(set) var recordings: [Recording] = []

    public static let appGroupIdentifier = "group.com.whispermate.shared"

    private static let revisionNotification = Notification.Name(
        "WhisperMateHistoryRevisionCommitted"
    )

    private let persistence: MobileHistoryPersistence?
    private let rootDirectory: URL?
    private let audioDirectory: URL?
    private var observedRevision: UInt64 = 0
    private var revisionObserver: NSObjectProtocol?

    public init() {
        let root = try? Self.defaultRootDirectory()
        rootDirectory = root
        audioDirectory = root?.appendingPathComponent("Recordings", isDirectory: true)
        persistence = root.map { MobileHistoryPersistence(rootDirectory: $0) }
        installRevisionObserver()
        scheduleInitialLoad()
    }

    /// Isolated-root initializer used by deterministic recovery validators.
    public init(
        rootDirectory: URL,
        beforeCommit: @escaping @Sendable () throws -> Void = {}
    ) {
        try? FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        self.rootDirectory = rootDirectory
        audioDirectory = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        persistence = MobileHistoryPersistence(
            rootDirectory: rootDirectory,
            beforeCommit: beforeCommit
        )
        installRevisionObserver()
        scheduleInitialLoad()
    }

    deinit {
        if let revisionObserver {
            NotificationCenter.default.removeObserver(revisionObserver)
        }
    }

    public var isAvailable: Bool {
        persistence != nil
    }

    public func reload() async throws {
        guard let persistence else { throw HistoryPersistenceError.unavailable }
        apply(try await persistence.load())
    }

    @discardableResult
    public func upsertRecording(_ recording: Recording) async throws -> UInt64 {
        guard let persistence else { throw HistoryPersistenceError.unavailable }
        let snapshot = try await persistence.upsert(recording)
        apply(snapshot)
        publish(snapshot.revision)
        return snapshot.revision
    }

    public func deleteRecording(_ recording: Recording) async throws {
        guard let persistence else { throw HistoryPersistenceError.unavailable }
        let snapshot = try await persistence.delete(recordingID: recording.id)
        apply(snapshot)
        publish(snapshot.revision)
    }

    public func clearAll(recordingIDs: [UUID]? = nil) async throws {
        guard let persistence else { throw HistoryPersistenceError.unavailable }
        let snapshot = try await persistence.clear(
            recordingIDs: recordingIDs ?? recordings.map(\.id),
            minimumRevision: observedRevision
        )
        apply(snapshot)
        publish(snapshot.revision)
    }

    /// Re-reads the durable journal before authorizing an irreversible usage claim.
    public func containsDurably(recordingID: UUID) async throws -> Bool {
        guard let persistence else { throw HistoryPersistenceError.unavailable }
        let snapshot = try await persistence.load()
        apply(snapshot)
        return snapshot.recordings.contains(where: { $0.id == recordingID })
            && !snapshot.deletedRecordingIDs.contains(recordingID)
    }

    public func saveAudioFile(
        from sourceURL: URL,
        for recordingID: UUID
    ) async throws -> URL {
        guard let persistence else { throw HistoryPersistenceError.unavailable }
        return try await persistence.saveAudioFile(
            from: sourceURL,
            recordingID: recordingID
        )
    }

    public func removeAudioFileIfPresent(for recording: Recording) throws {
        guard let audioDirectory else { throw HistoryPersistenceError.unavailable }
        try Self.removeCanonicalAudioIfPresent(
            recordingID: recording.id,
            recordedAudioURL: recording.audioFileURL,
            audioDirectory: audioDirectory
        )
    }

    /// Removes only the canonical legacy audio owned by this History store. The parent directory
    /// and leaf are both opened without following symlinks; corrupt decoded URLs have no deletion
    /// authority.
    nonisolated static func removeCanonicalAudioIfPresent(
        recordingID: UUID,
        recordedAudioURL: URL?,
        audioDirectory: URL,
        fileManager _: FileManager = .default
    ) throws {
        guard let recordedAudioURL else { return }
        let name = "\(recordingID.uuidString).m4a"
        let expectedURL = audioDirectory.appendingPathComponent(name, isDirectory: false)
        guard recordedAudioURL.standardizedFileURL == expectedURL.standardizedFileURL else {
            return
        }

        #if canImport(Darwin)
            let parent = audioDirectory.deletingLastPathComponent()
            let parentDescriptor = parent.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard parentDescriptor >= 0 else { throw HistoryPersistenceError.unavailable }
            defer { Darwin.close(parentDescriptor) }

            let audioDescriptor = audioDirectory.lastPathComponent.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if audioDescriptor < 0, errno == ENOENT { return }
            // A substituted/symlinked legacy directory has no deletion authority. Ignore it
            // without following it; the durable store tombstone remains the source of truth.
            guard audioDescriptor >= 0 else { return }
            defer { Darwin.close(audioDescriptor) }

            var status = stat()
            let statResult = name.withCString {
                Darwin.fstatat(audioDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if statResult != 0, errno == ENOENT { return }
            guard statResult == 0, (status.st_mode & S_IFMT) == S_IFREG else { return }

            let unlinkResult = name.withCString { Darwin.unlinkat(audioDescriptor, $0, 0) }
            guard unlinkResult == 0 || errno == ENOENT else {
                throw HistoryPersistenceError.unavailable
            }
            guard Darwin.fsync(audioDescriptor) == 0 else {
                throw HistoryPersistenceError.unavailable
            }
        #else
            let values = try expectedURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            try FileManager.default.removeItem(at: expectedURL)
        #endif
    }

    public func filteredRecordings(searchText: String) -> [Recording] {
        if searchText.isEmpty { return recordings }
        return recordings.filter {
            $0.transcription.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func installRevisionObserver() {
        let rootPath = rootDirectory?.standardizedFileURL.path
        revisionObserver = NotificationCenter.default.addObserver(
            forName: Self.revisionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let rootPath,
                  notification.userInfo?["rootPath"] as? String == rootPath,
                  let revision = notification.userInfo?["revision"] as? UInt64
            else { return }
            Task { @MainActor [weak self] in
                guard let self, revision > self.observedRevision else { return }
                try? await self.reload()
            }
        }
    }

    private func scheduleInitialLoad() {
        Task { @MainActor [weak self] in
            try? await self?.reload()
        }
    }

    private func apply(_ snapshot: MobileHistoryPersistence.Snapshot) {
        guard snapshot.revision >= observedRevision else { return }
        observedRevision = snapshot.revision
        recordings = snapshot.recordings
    }

    private func publish(_ revision: UInt64) {
        guard let rootDirectory else { return }
        NotificationCenter.default.post(
            name: Self.revisionNotification,
            object: nil,
            userInfo: [
                "rootPath": rootDirectory.standardizedFileURL.path,
                "revision": revision,
            ]
        )
    }

    private static func defaultRootDirectory() throws -> URL {
        #if os(iOS)
            let container = try MobileAudioProcessingStore.trustedAppGroupContainerDirectory()
            return try MobileAudioProcessingStore.ensureDirectoryNoFollow(
                parent: container,
                name: "WhisperMate"
            )
        #else
            let applicationSupport = try MobileAudioProcessingStore
                .trustedAppGroupContainerDirectory()
            return try MobileAudioProcessingStore.ensureDirectoryNoFollow(
                parent: applicationSupport,
                name: "WhisperMate"
            )
        #endif
    }
}

private actor MobileHistoryPersistence {
    struct Snapshot: @unchecked Sendable {
        let revision: UInt64
        let recordings: [Recording]
        let deletedRecordingIDs: Set<UUID>
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var revision: UInt64
        var recordings: [Recording]
        var deletedRecordingIDs: Set<UUID>
    }

    private static let schemaVersion = 1

    private let rootDirectory: URL
    private let audioDirectory: URL
    private let historyURL: URL
    private let lockURL: URL
    private let beforeCommit: @Sendable () throws -> Void

    init(
        rootDirectory: URL,
        beforeCommit: @escaping @Sendable () throws -> Void = {}
    ) {
        self.rootDirectory = rootDirectory
        audioDirectory = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        historyURL = rootDirectory.appendingPathComponent("history.json", isDirectory: false)
        lockURL = rootDirectory.appendingPathComponent("history.lock", isDirectory: false)
        self.beforeCommit = beforeCommit
    }

    func load() throws -> Snapshot {
        try withExclusiveLock {
            snapshot(from: try loadEnvelopeLocked())
        }
    }

    func upsert(_ recording: Recording) throws -> Snapshot {
        try withExclusiveLock {
            var envelope = try loadEnvelopeLocked()
            guard !envelope.deletedRecordingIDs.contains(recording.id) else {
                throw HistoryPersistenceError.deleted
            }
            guard envelope.revision < UInt64.max else {
                throw HistoryPersistenceError.counterExhausted
            }
            envelope.recordings.removeAll { $0.id == recording.id }
            envelope.recordings.insert(recording, at: 0)
            envelope.revision += 1
            try saveEnvelopeLocked(envelope)
            return snapshot(from: envelope)
        }
    }

    func delete(recordingID: UUID) throws -> Snapshot {
        try withExclusiveLock {
            var envelope = try loadEnvelopeLocked()
            guard envelope.revision < UInt64.max else {
                throw HistoryPersistenceError.counterExhausted
            }
            envelope.deletedRecordingIDs.insert(recordingID)
            envelope.recordings.removeAll { $0.id == recordingID }
            envelope.revision += 1
            try saveEnvelopeLocked(envelope)
            return snapshot(from: envelope)
        }
    }

    /// Clear is deliberately repair-capable: once the caller supplies the visible IDs, a corrupt
    /// prior history file cannot prevent a durable user deletion from winning.
    func clear(recordingIDs: [UUID], minimumRevision: UInt64) throws -> Snapshot {
        try withExclusiveLock {
            var envelope: Envelope
            do {
                envelope = try loadEnvelopeLocked()
            } catch HistoryPersistenceError.corrupt {
                envelope = Envelope(
                    schemaVersion: Self.schemaVersion,
                    revision: minimumRevision,
                    recordings: [],
                    deletedRecordingIDs: []
                )
            }
            guard envelope.revision < UInt64.max else {
                throw HistoryPersistenceError.counterExhausted
            }
            envelope.deletedRecordingIDs.formUnion(recordingIDs)
            envelope.deletedRecordingIDs.formUnion(envelope.recordings.map(\.id))
            envelope.recordings.removeAll()
            envelope.revision += 1
            try saveEnvelopeLocked(envelope)
            return snapshot(from: envelope)
        }
    }

    func saveAudioFile(from sourceURL: URL, recordingID: UUID) throws -> URL {
        try withExclusiveLock {
            let destination = audioDirectory.appendingPathComponent(
                "\(recordingID.uuidString).m4a",
                isDirectory: false
            )
            let temporary = audioDirectory.appendingPathComponent(
                ".\(recordingID.uuidString).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            do {
                try FileManager.default.copyItem(at: sourceURL, to: temporary)
                try synchronizeRegularFile(temporary)
                let renameResult = temporary.path.withCString { source in
                    destination.path.withCString { target in Darwin.rename(source, target) }
                }
                guard renameResult == 0 else { throw HistoryPersistenceError.unavailable }
                try synchronizeDirectory(audioDirectory)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                if let historyError = error as? HistoryPersistenceError {
                    throw historyError
                }
                throw HistoryPersistenceError.unavailable
            }
        }
    }

    private func snapshot(from envelope: Envelope) -> Snapshot {
        Snapshot(
            revision: envelope.revision,
            recordings: envelope.recordings,
            deletedRecordingIDs: envelope.deletedRecordingIDs
        )
    }

    private func loadEnvelopeLocked() throws -> Envelope {
        let data: Data
        #if canImport(Darwin)
            let descriptor = historyURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            if descriptor < 0, errno == ENOENT {
                return Envelope(
                    schemaVersion: Self.schemaVersion,
                    revision: 0,
                    recordings: [],
                    deletedRecordingIDs: []
                )
            }
            guard descriptor >= 0 else { throw HistoryPersistenceError.corrupt }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size >= 0
            else { throw HistoryPersistenceError.corrupt }
            data = try readAll(descriptor: descriptor)
        #else
            guard FileManager.default.fileExists(atPath: historyURL.path) else {
                return Envelope(
                    schemaVersion: Self.schemaVersion,
                    revision: 0,
                    recordings: [],
                    deletedRecordingIDs: []
                )
            }
            data = try Data(contentsOf: historyURL)
        #endif

        let envelope: Envelope
        if let decoded = try? JSONDecoder().decode(Envelope.self, from: data) {
            envelope = decoded
        } else if let legacy = try? JSONDecoder().decode([Recording].self, from: data) {
            envelope = Envelope(
                schemaVersion: Self.schemaVersion,
                revision: legacy.isEmpty ? 0 : 1,
                recordings: legacy,
                deletedRecordingIDs: []
            )
        } else {
            throw HistoryPersistenceError.corrupt
        }

        guard envelope.schemaVersion == Self.schemaVersion,
              Set(envelope.recordings.map(\.id)).count == envelope.recordings.count,
              envelope.deletedRecordingIDs.isDisjoint(
                with: Set(envelope.recordings.map(\.id))
              )
        else { throw HistoryPersistenceError.corrupt }
        return envelope
    }

    private func saveEnvelopeLocked(_ envelope: Envelope) throws {
        try beforeCommit()
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            throw HistoryPersistenceError.unavailable
        }

        #if canImport(Darwin)
            let temporary = rootDirectory.appendingPathComponent(
                ".history.\(UUID().uuidString).tmp",
                isDirectory: false
            )
            var descriptor = temporary.path.withCString {
                Darwin.open(
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
            }
            guard descriptor >= 0 else { throw HistoryPersistenceError.unavailable }
            var renamed = false
            defer {
                if descriptor >= 0 { Darwin.close(descriptor) }
                if !renamed { try? FileManager.default.removeItem(at: temporary) }
            }
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw HistoryPersistenceError.unavailable }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw HistoryPersistenceError.unavailable
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw HistoryPersistenceError.unavailable
            }
            descriptor = -1
            let renameResult = temporary.path.withCString { source in
                historyURL.path.withCString { target in Darwin.rename(source, target) }
            }
            guard renameResult == 0 else { throw HistoryPersistenceError.unavailable }
            renamed = true
            try synchronizeDirectory(rootDirectory)
        #else
            do {
                try data.write(to: historyURL, options: .atomic)
            } catch {
                throw HistoryPersistenceError.unavailable
            }
        #endif
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try validateDirectory(rootDirectory)
            _ = try MobileAudioProcessingStore.ensureDirectoryNoFollow(
                parent: rootDirectory,
                name: "Recordings"
            )
            try validateDirectory(audioDirectory)
        } catch {
            throw HistoryPersistenceError.unavailable
        }

        #if canImport(Darwin)
            let descriptor = lockURL.path.withCString {
                Darwin.open(
                    $0,
                    O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
            }
            guard descriptor >= 0 else { throw HistoryPersistenceError.unavailable }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else {
                throw HistoryPersistenceError.unavailable
            }
            defer { flock(descriptor, LOCK_UN) }
        #endif
        return try body()
    }

    private func validateDirectory(_ url: URL) throws {
        #if canImport(Darwin)
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw HistoryPersistenceError.unavailable }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR
            else { throw HistoryPersistenceError.unavailable }
        #endif
    }

    private func synchronizeRegularFile(_ url: URL) throws {
        #if canImport(Darwin)
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw HistoryPersistenceError.unavailable }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else {
                throw HistoryPersistenceError.unavailable
            }
        #endif
    }

    private func synchronizeDirectory(_ url: URL) throws {
        #if canImport(Darwin)
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw HistoryPersistenceError.unavailable }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else {
                throw HistoryPersistenceError.unavailable
            }
        #endif
    }

    #if canImport(Darwin)
        private func readAll(descriptor: Int32) throws -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw HistoryPersistenceError.corrupt }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
    #endif
}
