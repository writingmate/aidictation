import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhisperMateShared

struct MeetingNotesView: View {
    @ObservedObject private var store = MeetingNotesStore.shared
    @ObservedObject private var coordinator = MeetingNotesCoordinator.shared
    @ObservedObject private var calendar = MeetingCalendar.shared
    @State private var search = ""
    @State private var showsTrash = false
    @State private var notePath: [UUID] = []

    private var notes: [MeetingNote] {
        store.notes.filter { ($0.deletedAt != nil) == showsTrash && $0.matches(search) }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $notePath) {
                library
                    .navigationDestination(for: UUID.self) { id in
                        MeetingNoteEditor(noteID: id, onBack: { notePath = [] })
                    }
            }
            if notePath.isEmpty { MeetingNoteSaveWarning() }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .dsFont(.body)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            if search.isEmpty && !showsTrash { upcomingMeetings }
            if let activeID = coordinator.activeNoteID, let active = store.note(activeID) {
                SettingsCard {
                    Button { notePath = [activeID] } label: {
                        HStack(spacing: 8) {
                            Image(systemName: coordinator.isPaused ? "pause.circle.fill" : "record.circle")
                                .foregroundStyle(coordinator.isPaused ? Color.orange : Color.red)
                            Text(active.displayTitle).dsFont(.bodyMedium)
                            Spacer()
                            Text(coordinator.isPaused ? "Paused" : "Recording").dsFont(.label).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").dsFont(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Picker("Notes", selection: $showsTrash) {
                    Text("My notes").tag(false)
                    Text("Recently deleted").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    .onChange(of: showsTrash) { _ in coordinator.selectedNoteID = nil }
                Spacer()
                Text("\(notes.count) \(notes.count == 1 ? "note" : "notes")").dsFont(.label).foregroundStyle(.secondary)
            }.padding(.top, 4)
            if notes.isEmpty {
                NoteEmptyState(icon: showsTrash ? "trash" : "note.text", title: search.isEmpty ?
                    (showsTrash ? "No deleted notes" : "No meeting notes") : "No results",
                    message: search.isEmpty ? (showsTrash ? "Deleted notes can be restored here." :
                        "Create a note to record a meeting or write your thoughts.") : "Try a different search.")
            } else {
                notesList
                    .onDeleteCommand {
                        if !showsTrash, let id = coordinator.selectedNoteID { coordinator.trash(id) }
                    }
                    .listStyle(.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .searchable(text: $search, placement: .toolbar, prompt: "Search notes and transcripts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let id = coordinator.create() { notePath = [id] }
                } label: { Label("New note", systemImage: "square.and.pencil") }
                .disabled(!store.isReadable).help("New meeting note (⌘N)").accessibilityIdentifier("notes.new")
            }
        }
        .onAppear { calendar.refresh() }
    }

    private var notesList: some View {
        List(selection: $coordinator.selectedNoteID) {
            ForEach(notes) { note in
                if showsTrash {
                    noteRow(note).tag(note.id)
                } else {
                    NavigationLink(value: note.id) { noteRow(note) }.tag(note.id)
                }
            }
        }
    }

    private var upcomingMeetings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming meetings").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    if !calendar.isConnected {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Google Calendar").dsFont(.body)
                                Text("Connect Google Calendar in Notetaker Settings").dsFont(.label).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open settings") { NotificationCenter.default.post(name: .showMeetingSettings, object: nil) }.controlSize(.small)
                        }
                    } else if calendar.meetings.isEmpty {
                        Text("No meetings in the next seven days").dsFont(.body).foregroundStyle(.secondary)
                    }
                    if let error = calendar.error { Text(error).dsFont(.label).foregroundStyle(.secondary) }
                    ForEach(calendar.meetings) { meeting in
                        Button {
                            if let id = coordinator.create(title: meeting.title) { notePath = [id] }
                        } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: meeting.color)).frame(width: 3, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meeting.title).dsFont(.bodyMedium).lineLimit(1)
                                    Text(meeting.start.formatted(date: .abbreviated, time: .shortened) + " · " +
                                         String(Int(meeting.end.timeIntervalSince(meeting.start) / 60)) + " min")
                                        .dsFont(.label).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
                            }.contentShape(Rectangle()).padding(.vertical, 2)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func noteRow(_ note: MeetingNote) -> some View {
        HStack(spacing: 8) {
            Image(systemName: note.isPinned ? "pin.fill" : "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle).dsFont(.bodyMedium).lineLimit(1)
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened)).dsFont(.label).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).contentShape(Rectangle())
        .contextMenu {
            if showsTrash {
                Button("Restore note") { store.update(note.id) { $0.deletedAt = nil } }
            } else {
                Button(note.isPinned ? "Unpin note" : "Pin note") { store.update(note.id) { $0.isPinned.toggle() } }
                Button("Delete note", role: .destructive) { coordinator.trash(note.id) }.disabled(coordinator.activeNoteID == note.id)
            }
        }
    }


}

private struct NoteEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).dsFont(.h2).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).dsFont(.headline)
            Text(message).dsFont(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MeetingNoteEditor: View {
    let noteID: UUID
    var onBack: (() -> Void)?
    @ObservedObject private var store = MeetingNotesStore.shared
    @ObservedObject private var coordinator = MeetingNotesCoordinator.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var history = HistoryManager.shared
    @ObservedObject private var recorder = AudioRecorder.shared
    @State private var tab: NoteTab = .thoughts
    @State private var question = ""
    @State private var submittedQuestion: String?
    @State private var showsChat = false
    @State private var copied = false
    @State private var exportError: String?
    @FocusState private var focusedField: EditorField?
    private enum EditorField { case title, thoughts, question }

    private enum NoteTab: String, CaseIterable { case thoughts = "My thoughts", transcript = "Transcript", summary = "Summary" }
    private var note: MeetingNote? { store.note(noteID) }
    private var active: Bool { coordinator.activeNoteID == noteID }
    private var busy: Bool { coordinator.requests.contains(noteID) }

    var body: some View {
        VStack(spacing: 0) {
            editorContent
            MeetingNoteSaveWarning()
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if let note, note.deletedAt == nil {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 13) {
                    TextField("Untitled note", text: field(\.title))
                        .dsFont(.title2).textFieldStyle(.plain)
                        .accessibilityLabel("Note title").accessibilityIdentifier("note.title")
                        .focused($focusedField, equals: .title)
                    Text(note.createdAt.formatted(date: .long, time: .shortened)).dsFont(.callout).foregroundStyle(.secondary)
                    Picker("Note content", selection: $tab) {
                        ForEach(NoteTab.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                    .onChange(of: tab) { _ in showsChat = false }
                    .padding(.bottom, 12)
                }.padding(.horizontal, 20)
                if let error = coordinator.errors[noteID] ?? exportError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .dsFont(.callout).foregroundStyle(.secondary).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08))
                }
                if showsChat { chat(note) }
                else {
                    switch tab {
                    case .thoughts: thoughts(note)
                    case .transcript: transcript(note)
                    case .summary: summary(note)
                    }
                }
                if !active { questionBar(note) }
                recordingBar(note)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) { noteActions(note) }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .dsFont(.body)
            .frame(minWidth: 560, minHeight: 480)
            .onAppear { focusedField = note.title.isEmpty ? .title : .thoughts }
        } else {
            NoteEmptyState(icon: "trash", title: "This note was deleted", message: "Restore it from Recently deleted to keep working.")
        }
    }

    private func field(_ keyPath: WritableKeyPath<MeetingNote, String>) -> Binding<String> {
        Binding(get: { note?[keyPath: keyPath] ?? "" }, set: { value in store.update(noteID) { $0[keyPath: keyPath] = value } })
    }

    @ViewBuilder
    private func noteActions(_ note: MeetingNote) -> some View {
            Menu {
                Button(note.isPinned ? "Unpin note" : "Pin note") { store.update(noteID) { $0.isPinned.toggle() } }
                Button("Export summary and transcript…") { export(note, includeThoughts: false) }
                Button("Export with my thoughts…") { export(note, includeThoughts: true) }
                Divider()
                Button("Delete note", role: .destructive) { coordinator.trash(noteID); onBack?() }.disabled(active)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28).help("Note actions")
            Button {
                NSPasteboard.general.clearContents()
                let text = tab == .thoughts ? note.thoughts : (tab == .transcript ? note.transcript : note.summary)
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
            .onChange(of: tab) { _ in copied = false }
            if onBack != nil {
                Button { MeetingNoteWindowController.open(noteID) } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Open in a separate window").accessibilityLabel("Open in a separate window")
            }
    }

    private func thoughts(_ note: MeetingNote) -> some View {
        ZStack(alignment: .topLeading) {
            if note.thoughts.isEmpty {
                Text("Take your own notes here…").foregroundStyle(.tertiary).padding(.top, 9).padding(.leading, 5).allowsHitTesting(false)
            }
            TextEditor(text: field(\.thoughts)).dsFont(.body).lineSpacing(5)
                .scrollContentBackground(.hidden).accessibilityLabel("My thoughts").accessibilityIdentifier("note.thoughts")
                .focused($focusedField, equals: .thoughts)
        }.padding(.horizontal, 20).padding(.top, 24)
    }

    private func transcript(_ note: MeetingNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if note.transcript.isEmpty {
                    NoteEmptyState(icon: "waveform", title: active ? "Listening to your meeting" : "No transcript yet",
                                   message: "Your transcript appears after you pause or stop recording.")
                }
                ForEach(note.segments) { segment in
                    if !segment.transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(segment.startedAt.formatted(date: .omitted, time: .shortened)).dsFont(.caption).foregroundStyle(.secondary)
                            Text(segment.transcript).textSelection(.enabled).lineSpacing(4)
                        }
                    }
                    if let recording = history.recording(id: segment.id), recording.isFailed {
                        HStack {
                            Label("This recording needs another try", systemImage: "exclamationmark.circle")
                            Spacer()
                            Button("Retry") { coordinator.retry(recording) }.disabled(app.isProcessing || app.recordingState != .idle || !recording.canRetranscribe)
                        }.dsFont(.callout)
                    }
                }
                if active, !coordinator.includeSystemAudio, !app.transcriptionText.isEmpty {
                    Text(app.transcriptionText).foregroundStyle(.secondary).lineSpacing(4)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }

    private func summary(_ note: MeetingNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label(active ? "Your summary will be ready after you stop" : (note.summaryIsOutdated ? "New content is ready to summarize" : "Summary"), systemImage: "sparkle")
                        .dsFont(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if !active {
                        Button(note.summary.isEmpty ? "Generate" : "Update") { coordinator.summarize(noteID) }
                            .disabled(!note.hasContent || busy).accessibilityIdentifier("note.summarize")
                    }
                }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                if busy { HStack { ProgressView().controlSize(.small); Text("Writing…").foregroundStyle(.secondary); Spacer(); Button("Cancel") { coordinator.cancelRequest(noteID) } } }
                if note.summary.isEmpty {
                    Text("Decisions, key points, and next steps will appear here.").foregroundStyle(.secondary)
                } else {
                    NoteMarkdown(text: note.summary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }

    private func chat(_ note: MeetingNote) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack { Text("Ask about this meeting").dsFont(.headline); Spacer(); Button("Back to note") { showsChat = false } }
                    ForEach(note.messages) { message in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(message.question).fontWeight(.semibold)
                            NoteMarkdown(text: message.answer)
                        }.id(message.id)
                    }
                    if busy { HStack { ProgressView().controlSize(.small); Text("Thinking…"); Spacer(); Button("Cancel") { coordinator.cancelRequest(noteID) } } }
                }.padding(20)
            }.onChange(of: note.messages.count) { _ in
                if question == submittedQuestion { question = "" }
                submittedQuestion = nil
                if let last = note.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func questionBar(_ note: MeetingNote) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle").foregroundStyle(.secondary)
            TextField("Ask anything about this meeting", text: $question).textFieldStyle(.plain).onSubmit { ask() }
                .accessibilityIdentifier("note.question")
                .focused($focusedField, equals: .question)
            if !note.messages.isEmpty { Button { showsChat.toggle() } label: { Image(systemName: "bubble.left.and.bubble.right") }.help("Past questions") }
            Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 23)) }
                .buttonStyle(.plain).disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !note.hasContent || busy)
                .accessibilityLabel("Ask question")
        }.padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)).padding(.horizontal, 20).padding(.vertical, 16)
    }

    private func ask() {
        guard !busy, note?.hasContent == true, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submittedQuestion = question
        coordinator.ask(noteID, question: question)
        showsChat = true
    }

    private func recordingBar(_ note: MeetingNote) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if active {
                    Image(systemName: coordinator.isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(coordinator.isPaused ? Color.orange : Color.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(coordinator.isPaused ? "Paused" : (app.recordingState == .recording ? "Recording" : "Saving your recording…"))
                            .dsFont(.callout).fontWeight(.medium)
                        Text(coordinator.includeSystemAudio ? "Microphone + Mac audio" : "Microphone only").dsFont(.caption).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = note.segments.reduce(0) { $0 + $1.duration }
                            + (app.recordingState == .recording ? coordinator.recordingStartedAt.map { context.date.timeIntervalSince($0) } ?? 0 : 0)
                        Text(Duration.seconds(max(0, elapsed)).formatted(.time(pattern: .minuteSecond)))
                            .dsFont(.monoSmall).foregroundStyle(.secondary)
                    }
                    if app.recordingState == .recording {
                        ProgressView(value: Double(recorder.audioLevel)).frame(width: 55).accessibilityLabel("Microphone level")
                    }
                    Spacer()
                    if coordinator.isPaused {
                        Button("Resume") { coordinator.start(noteID) }.disabled(app.recordingState != .idle)
                    } else {
                        Button { coordinator.pause() } label: { Label("Pause", systemImage: "pause.fill") }.disabled(app.recordingState != .recording)
                    }
                    Button("Stop") { coordinator.stop(); tab = .summary }.disabled(app.recordingState != .recording && app.recordingState != .idle)
                } else {
                    Toggle("Include Mac audio", isOn: $coordinator.includeSystemAudio).toggleStyle(.checkbox).dsFont(.callout)
                        .disabled(coordinator.activeNoteID != nil)
                    Spacer()
                    Button { coordinator.start(noteID) } label: { Label(note.segments.isEmpty ? "Start recording" : "Record more", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent).disabled(app.recordingState != .idle || app.isProcessing || coordinator.activeNoteID != nil || !store.isReadable)
                        .accessibilityIdentifier("note.record")
                }
            }.padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private func export(_ note: MeetingNote, includeThoughts: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = note.displayTitle.replacingOccurrences(of: "/", with: "-") + ".txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try note.exportedText(includeThoughts: includeThoughts).write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = "The note couldn’t be exported. Choose another location and try again." }
        }
    }
}

private struct MeetingNoteSaveWarning: View {
    @ObservedObject private var store = MeetingNotesStore.shared

    var body: some View {
        if let error = store.saveError {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                Text(error).dsFont(.callout)
                Spacer()
                Button("Try saving again") { store.save() }.disabled(!store.isReadable)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
            .accessibilityIdentifier("note.saveWarning")
        }
    }
}

private struct NoteMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") {
                    Text(line.drop(while: { $0 == "#" || $0 == " " })).dsFont(.headline).padding(.top, 8)
                } else {
                    Text((try? AttributedString(markdown: line)) ?? AttributedString(line)).lineSpacing(5)
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
enum MeetingNoteWindowController {
    static func open(_ id: UUID) {
        WindowBridge.openNoteWindow?(id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
