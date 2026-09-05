import SwiftUI
import WhisperMateShared

struct NotetakerSettingsView: View {
    @ObservedObject private var google = GoogleCalendarClient.shared
    @ObservedObject private var calendar = MeetingCalendar.shared
    @ObservedObject private var monitor = MeetingDetectionMonitor.shared
    @ObservedObject private var notes = MeetingNotesCoordinator.shared

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if google.isConnecting {
                            ProgressView().controlSize(.small)
                            Text("Signing in…").foregroundStyle(.secondary)
                            Button("Cancel") { google.cancelConnection() }
                        } else if google.isConnected {
                            Button("Refresh") { Task { await google.refresh() } }.disabled(google.isRefreshing)
                            Button(google.isDisconnecting ? "Disconnecting…" : "Disconnect") { Task { await google.disconnect() } }
                                .disabled(google.isDisconnecting)
                        } else {
                            Button("Connect Google Calendar") { Task { await google.connect() } }
                                .accessibilityIdentifier("notetaker.connectGoogle")
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Google Calendar")
                        Text(google.isConnecting ? "Finish signing in with your browser" : (google.account ?? "See upcoming meetings and name your notes automatically"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = google.error {
                    Text(error).foregroundStyle(.secondary).font(.callout)
                    if google.isConnected {
                        Button("Reconnect Google Calendar") { Task { await google.connect() } }.disabled(google.isConnecting)
                    }
                }
                if let lastSynced = google.lastSynced {
                    LabeledContent("Last updated", value: lastSynced.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.secondary).font(.caption)
                }
                LabeledContent {
                    if calendar.hasAccess { Text("Connected").foregroundStyle(.secondary) }
                    else { Button("Connect…") { Task { await calendar.connect() } } }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac calendars")
                        Text("Use calendars on this Mac when Google Calendar isn’t connected").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = calendar.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Calendars") } footer: {
                Text("Google Calendar connects through Composio. AIDictation reads your meetings without changing events or invitations.")
            }
            if google.isConnected, !google.calendars.isEmpty {
                Section("Calendars to sync") {
                    ForEach(google.calendars) { calendar in
                        Toggle(calendar.title, isOn: Binding(
                            get: { google.selectedCalendarIDs.contains(calendar.id) },
                            set: { google.setCalendar(calendar.id, selected: $0) }
                        ))
                    }
                }
            }
            Section {
                Toggle("Detect calls", isOn: $monitor.isEnabled)
                Toggle("Stop recording when the call ends", isOn: $monitor.autoStop).disabled(!monitor.isEnabled)
            } header: { Text("Meeting detection") } footer: {
                Text(monitor.status + ". Choose Start Notetaker to begin recording. Automatic stop applies to recordings started from a call prompt.")
            }
            Section {
                Toggle("Include Mac audio", isOn: $notes.includeSystemAudio).disabled(notes.activeNoteID != nil)
            } header: { Text("Recording") } footer: {
                Text("Capture the other people on the call along with your microphone. Headphones help prevent echoes.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 480)
    }
}
