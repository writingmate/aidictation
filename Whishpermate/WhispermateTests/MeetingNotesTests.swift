import XCTest

final class MeetingNotesTests: XCTestCase {
    func testPausedSegmentsKeepTheirOrderAndFinalWords() {
        let first = UUID(), second = UUID()
        var note = MeetingNote()
        note.segments = [.init(id: first, startedAt: Date()), .init(id: second, startedAt: Date())]
        XCTAssertTrue(note.receive(recordingID: second, transcript: "Second part, including the final word.", duration: 7))
        XCTAssertTrue(note.receive(recordingID: first, transcript: "First part.", duration: 4))
        XCTAssertEqual(note.transcript, "First part.\n\nSecond part, including the final word.")
        XCTAssertFalse(note.receive(recordingID: second, transcript: "Second part, including the final word.", duration: 7))
        XCTAssertEqual(note.segments.count, 2)
    }

    func testDeletedNoteRejectsLateTranscription() {
        let id = UUID()
        var note = MeetingNote()
        note.segments = [.init(id: id, startedAt: Date())]
        note.deletedAt = Date()
        XCTAssertFalse(note.receive(recordingID: id, transcript: "Late result", duration: 1))
        XCTAssertTrue(note.transcript.isEmpty)
    }

    func testSummaryInvalidatesOnlyWhenItsSourceChanges() {
        var note = MeetingNote()
        note.thoughts = "Discuss launch timing."
        note.summary = "Discussed launch timing."
        note.summarizedContent = note.sourceContent
        note.title = "Planning"
        XCTAssertFalse(note.summaryIsOutdated)
        note.thoughts += " Bring the budget."
        XCTAssertTrue(note.summaryIsOutdated)
    }

    func testExportExcludesPersonalThoughtsUnlessRequested() {
        var note = MeetingNote()
        note.thoughts = "Private reminder"
        note.summary = "Meeting summary"
        XCTAssertFalse(note.exportedText().contains("Private reminder"))
        XCTAssertTrue(note.exportedText(includeThoughts: true).contains("Private reminder"))
        XCTAssertTrue(note.exportedText().contains("Meeting summary"))
    }

    @MainActor
    func testSaveReloadRestoreAndRetryKeepOneNote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.json")
        let store = MeetingNotesStore(fileURL: url)
        let id = try XCTUnwrap(store.create())
        let recording = UUID()
        store.update(id) { $0.title = "Planning"; $0.thoughts = "Remember the schedule"; $0.isPinned = true }
        XCTAssertTrue(store.attachRecording(recording, to: id))
        XCTAssertEqual(store.receive(recordingID: recording, transcript: "First result", duration: 2), id)
        XCTAssertEqual(store.receive(recordingID: recording, transcript: "Corrected result", duration: 2), id)
        store.update(id) { $0.deletedAt = Date() }
        let restored = MeetingNotesStore(fileURL: url)
        XCTAssertEqual(restored.notes.count, 1)
        XCTAssertNotNil(restored.note(id)?.deletedAt)
        restored.update(id) { $0.deletedAt = nil }
        XCTAssertEqual(restored.note(id)?.transcript, "Corrected result")
        XCTAssertEqual(restored.note(id)?.thoughts, "Remember the schedule")
        XCTAssertEqual(restored.note(id)?.isPinned, true)
        XCTAssertEqual(restored.note(id)?.segments.count, 1)
        XCTAssertTrue(restored.note(id)?.matches("corrected") == true)
    }

    @MainActor
    func testUnreadableStoreIsPreserved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("broken file".utf8)
        try original.write(to: url)
        let store = MeetingNotesStore(fileURL: url)
        XCTAssertFalse(store.isReadable)
        XCTAssertNotNil(store.saveError)
        XCTAssertNil(store.create())
        XCTAssertFalse(store.save())
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testFailedSaveKeepsTypedTextForRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.json")
        let store = MeetingNotesStore(fileURL: url)
        let id = try XCTUnwrap(store.create())
        try FileManager.default.removeItem(at: folder)
        try Data("blocks the directory".utf8).write(to: folder)
        store.update(id) { $0.thoughts = "Keep my unsaved text" }
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(store.note(id)?.thoughts, "Keep my unsaved text")
        try FileManager.default.removeItem(at: folder)
        XCTAssertTrue(store.save())
        XCTAssertEqual(MeetingNotesStore(fileURL: url).note(id)?.thoughts, "Keep my unsaved text")
    }
}
