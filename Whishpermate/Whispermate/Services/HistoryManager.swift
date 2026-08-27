import Foundation
internal import Combine

/// Display/cache projection of the durable audio-processing journal.
///
/// This type never owns or deletes audio. AppState must first commit a store
/// tombstone/Clear generation and only then update this cache or remove a
/// legacy source that lives outside the managed store.
@MainActor
class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    // MARK: - Published Properties

    @Published var recordings: [Recording] = []

    // MARK: - Private Properties

    private enum Constants {
        static var appDirectoryName: String {
            Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
                ? "WhisperMate-Dev"
                : "WhisperMate"
        }
        static let recordingsDirectoryName = "Recordings"
        static let historyFileName = "history.json"
    }

    private let fileURL: URL
    private let audioDirectory: URL
    private var activeRecordingIDs: Set<UUID> = []
    private var persistenceIsHealthy = true

    // MARK: - Initialization

    private init() {
        // Get Application Support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent(Constants.appDirectoryName, isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        // Create audio storage directory
        audioDirectory = appDirectory.appendingPathComponent(Constants.recordingsDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        fileURL = appDirectory.appendingPathComponent(Constants.historyFileName)
        loadRecordings()
    }

    // MARK: - Public API

    /// Stable managed source location allocated before recognition starts.
    func audioFileURL(for recordingID: UUID) -> URL {
        audioDirectory.appendingPathComponent("recording_\(recordingID.uuidString).m4a")
    }

    func recording(id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    @discardableResult
    func registerActiveRecording(id: UUID) -> Bool {
        activeRecordingIDs.insert(id).inserted
    }

    func unregisterActiveRecording(id: UUID) {
        activeRecordingIDs.remove(id)
    }

    @discardableResult
    func addRecording(_ recording: Recording) -> Bool {
        upsertRecording(recording)
    }

    @discardableResult
    func upsertRecording(_ recording: Recording) -> Bool {
        let previous = recordings
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.insert(recording, at: 0)
        }

        guard saveRecordings() else {
            recordings = previous
            return false
        }
        return true
    }

    @discardableResult
    func updateRecording(_ recording: Recording) -> Bool {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            let previous = recordings[index]
            recordings[index] = recording
            guard saveRecordings() else {
                recordings[index] = previous
                return false
            }
            return true
        }
        return false
    }

    /// Keeps the current UI truthful when a terminal disk write fails. This is
    /// intentionally memory-only; the durable journal remains the recovery source.
    func showUnsavedTerminalState(_ recording: Recording) {
        guard recording.status != .processing && recording.status != .retrying,
              let index = recordings.firstIndex(where: { $0.id == recording.id })
        else { return }
        recordings[index] = recording
    }

    @discardableResult
    func removeRecordingMetadata(id: UUID) -> Bool {
        let previous = recordings
        recordings.removeAll { $0.id == id }
        guard saveRecordings() else {
            recordings = previous
            return false
        }
        return true
    }

    @discardableResult
    func clearMetadata() -> Bool {
        let previous = recordings
        recordings.removeAll()
        guard saveRecordings() else {
            recordings = previous
            return false
        }
        return true
    }

    // MARK: - Search

    func filteredRecordings(searchText: String) -> [Recording] {
        if searchText.isEmpty {
            return recordings
        }
        return recordings.filter { recording in
            recording.transcription?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    var failedRecordings: [Recording] {
        return recordings.filter { $0.isFailed }
    }

    var successfulRecordings: [Recording] {
        return recordings.filter { $0.isSuccessful }
    }

    // MARK: - Private Methods

    private func loadRecordings() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            recordings = try JSONDecoder().decode([Recording].self, from: data)
        } catch {
            // Never replace an unreadable history with an empty array. Preserve the
            // file and fail closed until journal reconciliation can recover it.
            persistenceIsHealthy = false
            DebugLog.error("History is unreadable; preserving it and disabling history changes: \(error)", context: "HistoryManager")
        }
    }

    @discardableResult
    private func saveRecordings() -> Bool {
        guard persistenceIsHealthy else { return false }
        do {
            let data = try JSONEncoder().encode(recordings)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            DebugLog.info("Failed to save recordings: \(error)", context: "HistoryManager")
            return false
        }
    }
}
