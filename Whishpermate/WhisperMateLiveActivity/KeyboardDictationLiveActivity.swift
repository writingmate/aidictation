import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import WhisperMateShared

@available(iOSApplicationExtension 17.0, *)
struct KeyboardDictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KeyboardDictationActivityAttributes.self) { context in
            KeyboardDictationLiveActivityView(context: context, compact: false)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    KeyboardDictationLiveActivityView(context: context, compact: true)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .processing ? "waveform.badge.magnifyingglass" : "waveform")
                    .foregroundStyle(Color(red: 1, green: 0.388, blue: 0))
            } compactTrailing: {
                Text(context.state.phase == .processing ? "..." : "On")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(Color(red: 1, green: 0.388, blue: 0))
            }
        }
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct KeyboardDictationLiveActivityView: View {
    let context: ActivityViewContext<KeyboardDictationActivityAttributes>
    var compact: Bool

    private var isProcessing: Bool {
        context.state.phase == .processing
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isProcessing ? "waveform.badge.magnifyingglass" : "waveform")
                .font(.system(size: compact ? 20 : 24, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.388, blue: 0))
                .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(isProcessing ? "Processing dictation" : "AI Dictation is listening")
                    .font(.system(size: compact ? 13 : 16, weight: .semibold))
                    .lineLimit(1)

                if isProcessing {
                    Text("Keeping microphone ready")
                        .font(.system(size: compact ? 11 : 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: compact ? 11 : 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(intent: StopKeyboardDictationIntent(sessionID: context.attributes.sessionID)) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
                    .background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, compact ? 0 : 14)
        .padding(.vertical, compact ? 0 : 12)
    }
}

@available(iOSApplicationExtension 17.0, *)
struct StopKeyboardDictationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish Recording"
    static var description = IntentDescription("Finishes recording and transcribes your dictation.")

    @Parameter(title: "Session")
    var sessionID: String

    init() {
        sessionID = ""
    }

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func perform() async throws -> some IntentResult {
        KeyboardDictationHandoff.publish(command: .stop, sessionID: sessionID.isEmpty ? nil : sessionID)
        KeyboardDictationHandoff.appendDiagnostic("live activity requested stop sessionID=\(sessionID)")
        return .result()
    }
}

@main
struct WhisperMateLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOSApplicationExtension 17.0, *) {
            KeyboardDictationLiveActivity()
        }
    }
}
