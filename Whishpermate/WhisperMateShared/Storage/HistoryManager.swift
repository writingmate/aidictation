import Foundation
public import Combine

public class HistoryManager: ObservableObject {
    @Published public var recordings: [Recording] = []

    private let storageKey = "recordings_history"
    private let fileURL: URL
    private let audioDirectory: URL

    // App Group identifier for sharing between app and keyboard extension
    public static let appGroupIdentifier = "group.com.whispermate.shared"

    public init() {
        // Use App Group container on iOS, Application Support on macOS
        #if os(iOS)
            let appDirectory: URL
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: HistoryManager.appGroupIdentifier) {
                // Use App Group container (real device or properly configured simulator)
                appDirectory = containerURL.appendingPathComponent("WhisperMate", isDirectory: true)
            } else {
                // Fall back to temporary directory (simulator without App Group support)
                DebugLog.warning("App Group container not available, using temporary directory", context: "HistoryManager")
                let tempDir = FileManager.default.temporaryDirectory
                appDirectory = tempDir.appendingPathComponent("WhisperMate", isDirectory: true)
            }
        #else
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDirectory = appSupport.appendingPathComponent("WhisperMate", isDirectory: true)
        #endif

        // Create main directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        // Create audio recordings directory
        audioDirectory = appDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        fileURL = appDirectory.appendingPathComponent("history.json")
        loadRecordings()
    }

    // Save audio file to persistent storage and return the permanent URL
    public func saveAudioFile(from temporaryURL: URL, for recordingID: UUID) -> URL? {
        let fileName = "\(recordingID.uuidString).m4a"
        let permanentURL = audioDirectory.appendingPathComponent(fileName)

        do {
            // If file already exists, remove it
            if FileManager.default.fileExists(atPath: permanentURL.path) {
                try FileManager.default.removeItem(at: permanentURL)
            }
            // Copy file to permanent location
            try FileManager.default.copyItem(at: temporaryURL, to: permanentURL)
            return permanentURL
        } catch {
            DebugLog.info("Failed to save audio file: \(error)", context: "HistoryManager")
            return nil
        }
    }

    public func addRecording(_ recording: Recording) {
        // Add to beginning of list (most recent first)
        recordings.insert(recording, at: 0)

        saveRecordings()
    }

    public func deleteRecording(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }

    public func clearAll() {
        recordings.removeAll()
        saveRecordings()
    }

    private func loadRecordings() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            recordings = try JSONDecoder().decode([Recording].self, from: data)
        } catch {
            DebugLog.info("Failed to load recordings: \(error)", context: "HistoryManager")
        }
    }

    private func saveRecordings() {
        do {
            let data = try JSONEncoder().encode(recordings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DebugLog.info("Failed to save recordings: \(error)", context: "HistoryManager")
        }
    }

    // Search functionality
    public func filteredRecordings(searchText: String) -> [Recording] {
        if searchText.isEmpty {
            return recordings
        }
        return recordings.filter { recording in
            recording.transcription.localizedCaseInsensitiveContains(searchText)
        }
    }
}
