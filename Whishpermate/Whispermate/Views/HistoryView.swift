import AppKit
import SwiftUI
import WhisperMateShared

struct HistoryView: View {
    @ObservedObject var historyManager: HistoryManager
    @ObservedObject private var appState = AppState.shared
    @State private var searchText = ""
    @State private var showingClearConfirmation = false
    @State private var operationError: String?
    @Environment(\.dismiss) var dismiss

    var onRetry: ((Recording) -> Void)?

    var filteredRecordings: [Recording] {
        historyManager.filteredRecordings(searchText: searchText)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header with title and close button (matching Settings style)
                HStack {
                    Text("History")
                        .dsFont(.h5)
                        .foregroundStyle(Color.dsForeground)

                    Spacer()

                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .dsFont(.h5)
                            .foregroundStyle(Color.dsMutedForeground)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .dsFont(.label)
                        .foregroundStyle(Color.dsMutedForeground)

                    TextField("Search transcriptions...", text: $searchText)
                        .textFieldStyle(.plain)
                        .dsFont(.label)
                        .foregroundStyle(Color.dsForeground)

                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .dsFont(.label)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DSCornerRadius.small)
                        .fill(Color.dsCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DSCornerRadius.small)
                        .stroke(Color.dsBorder, lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                // Recordings List
                if filteredRecordings.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: searchText.isEmpty ? "mic.slash" : "magnifyingglass")
                            .dsFont(.h1)
                            .foregroundStyle(Color.dsMuted)
                        Text(searchText.isEmpty ? "No recordings yet" : "No results found")
                            .dsFont(.bodyMedium)
                            .foregroundStyle(Color.dsMutedForeground)
                        if searchText.isEmpty {
                            Text("Start recording to build your history")
                                .dsFont(.small)
                                .foregroundStyle(Color.dsMutedForeground)
                        }
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredRecordings) { recording in
                                RecordingRow(recording: recording, onRetry: onRetry)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                // Bottom Actions
                HStack {
                    Button(action: {
                        showingClearConfirmation = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .dsFont(.label)
                            Text("Clear All")
                                .dsFont(.label)
                        }
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(historyManager.recordings.isEmpty || appState.isHistoryMutationInProgress)

                    Spacer()
                }
                .padding(.horizontal, max(24, geometry.size.width * 0.06))
                .padding(.vertical, 16)
            }
        }
        .frame(minWidth: 800, maxWidth: 1600, minHeight: 800, maxHeight: 1400)
        .alert("Clear All History?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                Task {
                    if let message = await appState.clearHistory() {
                        operationError = message
                    }
                }
            }
        } message: {
            Text("This will permanently delete all \(historyManager.recordings.count) recordings. This action cannot be undone.")
        }
        .alert("History Couldn’t Be Changed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "Please try again.")
        }
    }
}

struct RecordingRow: View {
    let recording: Recording
    let onRetry: ((Recording) -> Void)?
    @ObservedObject private var appState = AppState.shared

    @State private var isHovering = false
    @State private var showingDeleteConfirmation = false
    @State private var operationError: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Status indicator
            if recording.isInProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: recording.status == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .dsFont(.body)
                    .foregroundStyle(recording.status == .success ? Color.dsSecondary : Color.dsAccent)
            }

            // Timestamp
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.formattedDate)
                    .dsFont(.labelMedium)
                    .foregroundStyle(Color.dsForeground)

                if let duration = recording.formattedDuration {
                    Text(duration)
                        .dsFont(.small)
                        .foregroundStyle(Color.dsMutedForeground)
                }

                if recording.retryCount > 0 {
                    Text("Retried \(recording.retryCount)x")
                        .dsFont(.tiny)
                        .foregroundStyle(Color.dsAccent)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            // Transcription or Error
            if recording.status == .processing || recording.status == .retrying {
                Text(recording.status == .retrying ? "Transcribing again…" : "Processing…")
                    .dsFont(.label)
                    .foregroundStyle(Color.dsMutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if recording.status == .cancelled {
                Text("Cancelled")
                    .dsFont(.label)
                    .foregroundStyle(Color.dsMutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if recording.status == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription stopped")
                        .dsFont(.labelMedium)
                        .foregroundStyle(Color.dsAccent)
                    if let errorMessage = recording.errorMessage {
                        Text(errorMessage)
                            .dsFont(.small)
                            .foregroundStyle(Color.dsMutedForeground)
                    }
                    if let transcription = recording.transcription {
                        Text("Recovered text: \(transcription)")
                            .dsFont(.label)
                            .foregroundStyle(Color.dsForeground)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let transcription = recording.transcription {
                VStack(alignment: .leading, spacing: 4) {
                    if recording.isNotes {
                        Label("Notes", systemImage: "note.text")
                            .dsFont(.tiny)
                            .foregroundStyle(Color.dsMutedForeground)
                    }
                    Text(transcription)
                        .dsFont(.label)
                        .foregroundStyle(Color.dsForeground)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            // Actions (always rendered, opacity changes on hover)
            HStack(spacing: 8) {
                if recording.status == .success {
                    Button(action: {
                        if let transcription = recording.transcription {
                            copyToClipboard(transcription)
                        }
                    }) {
                        Image(systemName: "doc.on.doc")
                            .dsFont(.label)
                            .foregroundStyle(Color.dsPrimary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                    .opacity(isHovering ? 1 : 0)
                } else if recording.status == .failed {
                    Button(action: {
                        onRetry?(recording)
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .dsFont(.label)
                            .foregroundStyle(Color.dsPrimary)
                    }
                    .buttonStyle(.plain)
                    .help("Retry")
                    .opacity(isHovering ? 1 : 0)
                    .disabled(
                        onRetry == nil ||
                        !recording.canRetranscribe ||
                        appState.isHistoryMutationInProgress ||
                        !FileManager.default.fileExists(atPath: recording.audioFileURL.path)
                    )
                }

                Button(action: {
                    showingDeleteConfirmation = true
                }) {
                    Image(systemName: "trash")
                        .dsFont(.label)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Delete")
                .opacity(isHovering ? 1 : 0)
                .disabled(appState.isHistoryMutationInProgress)
            }
            .frame(width: 80)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(isHovering ? Color.dsMuted.opacity(0.5) : Color.clear)
        .onHover { hovering in
            isHovering = hovering
        }
        .alert("Delete Recording?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    if let message = await appState.deleteRecording(recording) {
                        operationError = message
                    }
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Recording Couldn’t Be Deleted", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "Please try again.")
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

#Preview {
    HistoryView(historyManager: HistoryManager.shared)
        .frame(width: 640, height: 540)
}
