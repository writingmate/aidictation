import Foundation
internal import Combine

@MainActor
final class MeetingNotesStore: ObservableObject {
    static let shared = MeetingNotesStore()

    @Published private(set) var notes: [MeetingNote] = []
    @Published private(set) var saveError: String?
    @Published private(set) var isReadable = true
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "WhisperMate-Dev" : "WhisperMate")
        self.fileURL = fileURL ?? directory.appendingPathComponent("meeting-notes.json")
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                notes = try JSONDecoder().decode([MeetingNote].self, from: Data(contentsOf: self.fileURL))
            }
        } catch {
            isReadable = false
            saveError = "Your notes couldn’t be opened. The saved file has been kept."
        }
    }

    func note(_ id: UUID) -> MeetingNote? { notes.first { $0.id == id } }

    @discardableResult
    func create(title: String = "") -> UUID? {
        guard isReadable else { return nil }
        var note = MeetingNote()
        note.title = title
        notes.insert(note, at: 0)
        return save() ? note.id : nil
    }

    func update(_ id: UUID, _ edit: (inout MeetingNote) -> Void) {
        guard isReadable, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        edit(&notes[index])
        notes[index].updatedAt = Date()
        save()
    }

    @discardableResult
    func attachRecording(_ recordingID: UUID, to id: UUID) -> Bool {
        guard isReadable, let index = notes.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        notes[index].segments.append(.init(id: recordingID, startedAt: Date()))
        return save()
    }

    @discardableResult
    func receive(recordingID: UUID, transcript: String, duration: TimeInterval) -> UUID? {
        guard isReadable, let index = notes.firstIndex(where: { $0.segments.contains { $0.id == recordingID } }),
              notes[index].receive(recordingID: recordingID, transcript: transcript, duration: duration)
        else { return nil }
        notes[index].updatedAt = Date()
        save()
        return notes[index].id
    }

    @discardableResult
    func save() -> Bool {
        guard isReadable else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(notes).write(to: fileURL, options: .atomic)
            saveError = nil
            return true
        } catch {
            saveError = "Your latest changes aren’t saved yet. Keep this window open and try saving again."
            return false
        }
    }
}
