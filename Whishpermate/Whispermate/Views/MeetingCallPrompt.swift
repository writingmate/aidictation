import AppKit
import SwiftUI
import WhisperMateShared

@MainActor
enum MeetingCallPrompt {
    private static var panel: NSPanel?

    static func show(_ call: MeetingDetectionPolicy.Candidate) {
        dismiss()
        guard let screen = OverlayWindowManager.shared.notificationScreen else { return }
        let visible = screen.visibleFrame
        let width = min(520, visible.width - 32)
        let height: CGFloat = 94
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: MeetingCallPromptView(call: call))
        panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.minY + 48))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    static func dismiss() {
        panel?.close()
        panel = nil
    }
}

private struct MeetingCallPromptView: View {
    let call: MeetingDetectionPolicy.Candidate
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var notes = MeetingNotesCoordinator.shared

    private var canStart: Bool {
        app.recordingState == .idle && !app.isProcessing && notes.activeNoteID == nil
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "video.fill")
                .font(.system(size: 21)).foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text("Meeting detected").dsFont(.title3)
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text("Now · \(call.appName)").dsFont(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Microphone and Mac audio") {
                    MeetingDetectionMonitor.shared.takeNotes(for: call, includeMacAudio: true)
                }.disabled(!canStart)
                Button("Microphone only") {
                    MeetingDetectionMonitor.shared.takeNotes(for: call, includeMacAudio: false)
                }.disabled(!canStart)
                Divider()
                Button("Notetaker settings…") {
                    MeetingCallPrompt.dismiss()
                    showMainSettingsWindow()
                    NotificationCenter.default.post(name: .showMeetingSettings, object: nil)
                }
            } label: {
                Label("Start Notetaker", systemImage: "waveform")
                    .dsFont(.bodySemibold)
            } primaryAction: {
                if canStart { MeetingDetectionMonitor.shared.takeNotes(for: call) }
            }
            .menuStyle(.button)
            .disabled(!canStart)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .fixedSize()
            .accessibilityIdentifier("meeting.startNotetaker")
            Button { MeetingCallPrompt.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss meeting suggestion")
            .accessibilityLabel("Dismiss meeting suggestion")
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DSCornerRadius.large))
        .overlay(RoundedRectangle(cornerRadius: DSCornerRadius.large).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
