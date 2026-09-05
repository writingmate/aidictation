import Foundation
import WhisperMateShared
internal import Combine

@MainActor
final class MeetingNotesCoordinator: ObservableObject {
    static let shared = MeetingNotesCoordinator()
    @Published var selectedNoteID: UUID?
    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var isPaused = false
    @Published private(set) var recordingStartedAt: Date?
    @Published var includeSystemAudio = AppDefaults.shared.object(forKey: "meetingIncludeMacAudio") as? Bool ?? true {
        didSet { AppDefaults.shared.set(includeSystemAudio, forKey: "meetingIncludeMacAudio") }
    }
    @Published private(set) var requests: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    private var recordingID: UUID?
    private var shouldSummarize = false
    private var subscriptions: Set<AnyCancellable> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var requestIDs: [UUID: UUID] = [:]
    private let store = MeetingNotesStore.shared
    private let app = AppState.shared

    private init() {
        HistoryManager.shared.$recordings.receive(on: RunLoop.main).sink { [weak self] recordings in
            self?.receive(recordings)
        }.store(in: &subscriptions)
        app.$recordingState.receive(on: RunLoop.main).sink { [weak self] state in
            guard let self, let id = self.recordingID else { return }
            if state == .recording, self.recordingStartedAt == nil { self.recordingStartedAt = Date() }
            guard state == .idle else { return }
            if let recording = HistoryManager.shared.recording(id: id), recording.isInProgress { return }
            self.finishSegment()
        }.store(in: &subscriptions)
    }

    @discardableResult
    func create(title: String = "") -> UUID? {
        let id = store.create(title: title)
        selectedNoteID = id
        return id
    }

    func start(_ noteID: UUID) {
        guard app.recordingState == .idle, !app.isProcessing,
              activeNoteID == nil || activeNoteID == noteID,
              let note = store.note(noteID), note.deletedAt == nil else { return }
        let id = UUID()
        guard store.attachRecording(id, to: noteID) else { return }
        cancelRequest(noteID)
        errors[noteID] = nil
        activeNoteID = noteID
        recordingID = id
        isPaused = false
        recordingStartedAt = nil
        shouldSummarize = false
        app.startRecording(continuous: true, showOverlayControls: true, recordingID: id,
                           autoPaste: false, includeSystemAudio: includeSystemAudio)
        if app.activeRecordingID != id {
            errors[noteID] = app.errorMessage.isEmpty ? "Recording couldn’t start. Check microphone access in Settings." : app.errorMessage
            recordingID = nil
            activeNoteID = nil
            store.update(noteID) { $0.segments.removeAll { $0.id == id } }
        }
    }

    func startFromOverlay() {
        if let activeNoteID {
            MeetingNoteWindowController.open(activeNoteID)
            if isPaused, app.recordingState == .idle { start(activeNoteID) }
            return
        }
        guard app.recordingState == .idle, !app.isProcessing, let id = create() else { return }
        MeetingNoteWindowController.open(id)
        start(id)
    }

    func pause() {
        guard recordingID == app.activeRecordingID, app.recordingState == .recording else { return }
        isPaused = true
        app.stopRecording()
    }

    func stop() {
        guard let noteID = activeNoteID else { return }
        isPaused = false
        shouldSummarize = true
        if recordingID == nil {
            activeNoteID = nil
            summarize(noteID)
        } else if recordingID == app.activeRecordingID {
            app.stopRecording()
        }
    }

    func retry(_ recording: Recording) {
        guard app.recordingState == .idle, !app.isProcessing else { return }
        app.retranscribe(recording: recording)
    }

    func trash(_ id: UUID) {
        guard activeNoteID != id else { return }
        cancelRequest(id)
        store.update(id) { $0.deletedAt = Date() }
        if selectedNoteID == id { selectedNoteID = nil }
    }

    func summarize(_ id: UUID) { request(id, question: nil) }
    func ask(_ id: UUID, question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        request(id, question: trimmed)
    }

    func cancelRequest(_ id: UUID) {
        requestIDs[id] = nil
        tasks.removeValue(forKey: id)?.cancel()
        requests.remove(id)
    }

    private func receive(_ recordings: [Recording]) {
        for recording in recordings where recording.status == .success {
            guard store.notes.contains(where: { note in
                note.segments.contains { $0.id == recording.id && $0.transcript.isEmpty }
            }) else { continue }
            guard let text = recording.transcription else { continue }
            _ = store.receive(recordingID: recording.id, transcript: text, duration: recording.duration ?? 0)
        }
        guard let recordingID, let recording = recordings.first(where: { $0.id == recordingID }),
              !recording.isInProgress else { return }
        if recording.status != .success, let activeNoteID {
            errors[activeNoteID] = recording.errorMessage ?? "Transcription stopped. Your recording is available in History."
        }
        // Delivery is complete only when AppState has released its capture owner.
        if app.activeRecordingID != recordingID { finishSegment() }
    }

    private func finishSegment() {
        guard let noteID = activeNoteID else { return }
        if !app.errorMessage.isEmpty { errors[noteID] = app.errorMessage }
        recordingID = nil
        recordingStartedAt = nil
        if isPaused { return }
        activeNoteID = nil
        if shouldSummarize || store.note(noteID)?.hasContent == true { summarize(noteID) }
        shouldSummarize = false
    }

    private func request(_ id: UUID, question: String?) {
        guard let note = store.note(id), note.deletedAt == nil, note.hasContent,
              activeNoteID != id, !requests.contains(id) else { return }
        let requestID = UUID()
        requestIDs[id] = requestID
        requests.insert(id)
        errors[id] = nil
        tasks[id] = Task { [weak self] in
            do {
                let answer = try await MeetingNotesAssistant.respond(to: note, question: question)
                guard let self, self.requestIDs[id] == requestID,
                      let current = self.store.note(id), current.deletedAt == nil else { return }
                if current.sourceContent == note.sourceContent {
                    self.store.update(id) {
                        if let question {
                            $0.messages.append(.init(id: UUID(), question: question, answer: answer))
                        } else {
                            $0.summary = answer
                            $0.summarizedContent = note.sourceContent
                        }
                    }
                } else {
                    self.errors[id] = "The note changed while the answer was being written. Try again with the latest text."
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.requestIDs[id] == requestID else { return }
                self.errors[id] = (error as? NoteAssistantError)?.errorDescription
                    ?? "An answer couldn’t be generated. Your notes and transcript are unchanged. Try again."
            }
            guard let self, self.requestIDs[id] == requestID else { return }
            self.requests.remove(id)
            self.requestIDs[id] = nil
            self.tasks[id] = nil
        }
    }
}
