import AppKit
import AVFoundation
internal import Combine
import SwiftUI
import WhisperMateShared

enum AIApp: String, CaseIterable, Identifiable {
    case writingmate = "Writingmate"
    case claude = "Claude"
    case chatgpt = "ChatGPT"
    case perplexity = "Perplexity"
    case whatsapp = "WhatsApp"
    case email = "Email"
    case custom = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .writingmate: return "square.and.pencil"
        case .claude: return "sparkles"
        case .chatgpt: return "bubble.left.and.bubble.right"
        case .perplexity: return "magnifyingglass.circle"
        case .whatsapp: return "message.fill"
        case .email: return "envelope"
        case .custom: return "gearshape"
        }
    }

    var urlTemplate: String {
        switch self {
        case .writingmate: return "https://writingmate.ai/new?q={prompt}"
        case .chatgpt: return "https://chatgpt.com/?q={prompt}"
        case .perplexity: return "https://www.perplexity.ai/?q={prompt}"
        case .claude: return "https://claude.ai/new?q={prompt}"
        case .whatsapp: return "whatsapp://send?text={prompt}"
        case .email: return "mailto:?body={prompt}"
        case .custom: return "" // Will be loaded from UserDefaults
        }
    }
}

/// Master-detail view that combines history list with recording interface
struct HistoryMasterDetailView: View {
    var body: some View {
        HistoryMasterDetailContentView()
    }
}

private struct HistoryMasterDetailContentView: View {
    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var selectedRecording: Recording?

    var body: some View {
        NavigationSplitView {
            HistorySidebarView(
                historyManager: historyManager,
                selectedRecording: $selectedRecording
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            HistoryDetailPane(
                historyManager: historyManager,
                selectedRecording: $selectedRecording
            )
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .recordingCompleted)) { notification in
            // Switch to detail view when recording is completed
            if let recording = notification.object as? Recording {
                selectedRecording = recording
            }
        }
    }
}

private struct HistoryDetailPane: View {
    @ObservedObject var historyManager: HistoryManager
    @Binding var selectedRecording: Recording?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selectedId = selectedRecording?.id,
               let recording = historyManager.recordings.first(where: { $0.id == selectedId })
            {
                RecordingDetailView(
                    recording: recording,
                    historyManager: historyManager,
                    leadingPadding: 16,
                    onDelete: deleteRecording
                )
                .id("\(recording.id)-\(recording.status)-\(recording.transcription?.hashValue ?? 0)")
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "mic.circle")
                        .dsFont(.iconLarge)
                        .foregroundStyle(.tertiary)
                    Text("Select a recording")
                        .dsFont(.title2)
                        .foregroundStyle(.secondary)
                    Text("Press Fn to start recording")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(detailTitle)
    }

    private var detailTitle: String {
        if let selectedId = selectedRecording?.id,
           let recording = historyManager.recordings.first(where: { $0.id == selectedId })
        {
            return recording.formattedDate
        }

        return "Select a recording"
    }

    private func deleteRecording(_ recordingToDelete: Recording) {
        guard let index = historyManager.recordings.firstIndex(where: { $0.id == recordingToDelete.id }) else {
            return
        }

        let nextSelection: Recording?
        if index < historyManager.recordings.count - 1 {
            nextSelection = historyManager.recordings[index + 1]
        } else if index > 0 {
            nextSelection = historyManager.recordings[index - 1]
        } else {
            nextSelection = nil
        }

        historyManager.deleteRecording(recordingToDelete)
        selectedRecording = nextSelection
    }
}

/// Sidebar showing list of all recordings
struct HistorySidebarView: View {
    @ObservedObject var historyManager: HistoryManager
    @Binding var selectedRecording: Recording?
    @State private var searchText = ""

    var filteredRecordings: [Recording] {
        historyManager.filteredRecordings(searchText: searchText)
    }

    var body: some View {
        Group {
            if filteredRecordings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: searchText.isEmpty ? "mic.slash" : "magnifyingglass")
                        .dsFont(.h2)
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "No Recordings" : "No Results")
                        .dsFont(.headline)
                    Text(searchText.isEmpty ? "Your recordings will appear here" : "Try a different search")
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                recordingsList
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search recordings")
    }

    @ViewBuilder
    private var recordingsList: some View {
        recordingsListWithSelectionContextMenu
    }

    private var recordingsListContent: some View {
        List(selection: $selectedRecording) {
            ForEach(filteredRecordings) { recording in
                HistorySidebarRow(recording: recording)
                    .tag(recording)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selectedRecording) { _ in }
    }

    private var recordingsListWithSelectionContextMenu: some View {
        recordingsListContent
            .contextMenu(forSelectionType: Recording.self) { recordings in
                if let recording = recordings.first {
                    Button {
                        copyTranscription(recording)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(recording.transcription == nil)

                    Button {
                        retryTranscription(recording)
                    } label: {
                        Label("Re-transcribe", systemImage: "arrow.clockwise")
                    }

                    Button {
                        revealInFinder(recording)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }

                    Button(role: .destructive) {
                        deleteRecording(recording)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
    }

    private func copyTranscription(_ recording: Recording) {
        guard let transcription = recording.transcription else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcription, forType: .string)
    }

    private func retryTranscription(_ recording: Recording) {
        AppState.shared.retranscribe(recording: recording)
    }

    private func revealInFinder(_ recording: Recording) {
        let fileURL = recording.audioFileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
        }
    }

    private func deleteRecording(_ recording: Recording) {
        if selectedRecording?.id == recording.id {
            if let index = historyManager.recordings.firstIndex(where: { $0.id == recording.id }) {
                if index < historyManager.recordings.count - 1 {
                    selectedRecording = historyManager.recordings[index + 1]
                } else if index > 0 {
                    selectedRecording = historyManager.recordings[index - 1]
                } else {
                    selectedRecording = nil
                }
            }
        }
        historyManager.deleteRecording(recording)
    }
}

/// Compact row in sidebar
struct HistorySidebarRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Main content
            if let transcription = recording.transcription {
                Text(transcription)
                    .dsFont(.body)
                    .lineLimit(3)
            } else {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if let errorMessage = recording.errorMessage {
                    Text(errorMessage)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // Metadata
            HStack(spacing: 4) {
                if recording.isNotes {
                    Label("Notes", systemImage: "note.text")
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(recording.formattedDate)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)

                if let duration = recording.formattedDuration {
                    Text("•")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                    Text(duration)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .badge(recording.status == .success ? nil : "!")
    }
}

/// Detail view showing a selected recording
struct RecordingDetailView: View {
    let recording: Recording
    @ObservedObject var historyManager: HistoryManager
    let leadingPadding: CGFloat
    let onDelete: (Recording) -> Void
    @State private var showCopiedNotification = false
    @StateObject private var audioPlayer = AudioPlayerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrollable content (title moved to toolbar)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Transcription or error
                    if recording.status == .retrying {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Re-transcribing…")
                                .dsFont(.body)
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    } else if let transcription = recording.transcription {
                        if recording.isNotes {
                            Label("Notes", systemImage: "note.text")
                                .dsFont(.labelMedium)
                                .foregroundStyle(.secondary)
                        }

                        Text(transcription)
                            .textSelection(.enabled)
                            .dsFont(.body)
                            .transition(.opacity)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Transcription Failed")
                                .dsFont(.headline)
                                .foregroundStyle(.orange)

                            if let errorMessage = recording.errorMessage {
                                Text(errorMessage)
                                    .dsFont(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.3), value: recording.status)
            }

            Spacer()

            // Bottom hint
            HStack {
                Spacer()
                Text("Press Fn to start a new recording")
                    .dsFont(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            // All action buttons grouped together
            ToolbarItemGroup(placement: .automatic) {
                // Status indicator for failed recordings
                if recording.status == .failed {
                    Label("Failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                // Play button
                Button(action: togglePlayback) {
                    Label(
                        audioPlayer.isPlaying ? "Stop" : "Play",
                        systemImage: audioPlayer.isPlaying ? "stop.fill" : "play.fill"
                    )
                }
                .disabled(!FileManager.default.fileExists(atPath: recording.audioFileURL.path))

                // Re-transcribe button
                if recording.status == .retrying {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: retryTranscription) {
                        Label("Re-transcribe", systemImage: "arrow.clockwise")
                    }
                    .disabled(!FileManager.default.fileExists(atPath: recording.audioFileURL.path))
                }

                // Copy button
                Button(action: copyTranscription) {
                    Label("Copy", systemImage: showCopiedNotification ? "checkmark" : "doc.on.doc")
                }
                .foregroundStyle(showCopiedNotification ? .green : .secondary)
                .disabled(recording.transcription == nil)
                .keyboardShortcut("c", modifiers: .command)

                // Share menu
                Menu {
                    ForEach(AIApp.allCases) { app in
                        Button(action: { sendToAI(app: app) }) {
                            Label(app.rawValue, systemImage: app.icon)
                        }
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(recording.transcription == nil)

                // Delete button - last item
                Button(action: deleteRecording) {
                    Label("Delete", systemImage: "trash")
                }
                .foregroundStyle(.red)
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
        .onDeleteCommand(perform: deleteRecording)
    }

    private func copyTranscription() {
        guard let transcription = recording.transcription else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcription, forType: .string)

        showCopiedNotification = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedNotification = false
        }
    }

    private func togglePlayback() {
        if audioPlayer.isPlaying {
            audioPlayer.stop()
        } else {
            audioPlayer.play(url: recording.audioFileURL)
        }
    }

    private func retryTranscription() {
        AppState.shared.retranscribe(recording: recording)
    }

    private func deleteRecording() {
        onDelete(recording)
    }

    private func sendToAI(app: AIApp) {
        guard let transcription = recording.transcription else { return }

        // Get URL template
        var urlTemplate = app.urlTemplate
        if app == .custom {
            // Load custom URL from UserDefaults
            urlTemplate = AppDefaults.shared.string(forKey: "aiPromptURL") ?? "https://chatgpt.com/?q={prompt}"
        }

        // URL encode the transcription
        guard let encodedPrompt = transcription.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return
        }

        // Replace {prompt} placeholder with encoded text
        let urlString = urlTemplate.replacingOccurrences(of: "{prompt}", with: encodedPrompt)

        guard let url = URL(string: urlString) else {
            return
        }

        // Open URL in default browser or app
        NSWorkspace.shared.open(url)
    }
}

/// Simple audio player for playback of recorded audio
class AudioPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    private var player: AVAudioPlayer?

    func play(url: URL) {
        stop()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            isPlaying = true
        } catch {
            DebugLog.error("Failed to play audio: \(error)", context: "AudioPlayerModel")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }
}

#Preview {
    HistoryMasterDetailView()
        .frame(width: 900, height: 600)
}
