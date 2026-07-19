import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import WhisperMateShared

private enum KeyboardDictationIntentError: LocalizedError {
    case storageUnavailable

    var errorDescription: String? {
        "Couldn't update this recording. Open AI Dictation and try again."
    }
}

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
                    Text("Transcribing your recording")
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

            if isProcessing {
                Button(
                    intent: CancelKeyboardDictationIntent(
                        sessionID: context.attributes.sessionID,
                        attemptID: context.attributes.attemptID,
                        generation: Int(clamping: context.attributes.generation)
                    )
                ) {
                    stopButtonImage
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel transcription")
            } else {
                Button(
                    intent: StopKeyboardDictationIntent(
                        sessionID: context.attributes.sessionID,
                        attemptID: context.attributes.attemptID,
                        generation: Int(clamping: context.attributes.generation)
                    )
                ) {
                    stopButtonImage
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Finish recording")
            }
        }
        .padding(.horizontal, compact ? 0 : 14)
        .padding(.vertical, compact ? 0 : 12)
    }

    private var stopButtonImage: some View {
        Image(systemName: "stop.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
            .background(Circle().fill(Color.red))
    }
}

@available(iOSApplicationExtension 17.0, *)
struct StopKeyboardDictationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish Recording"
    static var description = IntentDescription("Finishes recording and transcribes your dictation.")

    @Parameter(title: "Session")
    var sessionID: String

    @Parameter(title: "Attempt")
    var attemptID: String

    @Parameter(title: "Generation")
    var generation: Int

    init() {
        sessionID = ""
        attemptID = ""
        generation = 0
    }

    init(sessionID: String, attemptID: String, generation: Int) {
        self.sessionID = sessionID
        self.attemptID = attemptID
        self.generation = generation
    }

    func perform() async throws -> some IntentResult {
        if !sessionID.isEmpty, !attemptID.isEmpty, generation > 0 {
            let identity = KeyboardDictationHandoff.AttemptIdentity(
                sessionID: sessionID,
                attemptID: attemptID,
                generation: UInt64(generation)
            )
            let accepted = KeyboardDictationHandoff.publish(command: .stop, identity: identity)
            if !accepted {
                let phase = KeyboardDictationHandoff.snapshot(for: identity)?.phase
                guard phase == .processing || phase?.isTerminal == true else {
                    throw KeyboardDictationIntentError.storageUnavailable
                }
            }
            KeyboardDictationHandoff.appendDiagnostic(
                "live activity requested stop sessionID=\(sessionID) attemptID=\(attemptID) generation=\(generation)"
            )
        } else {
            // An activity created by an older build carries only a session ID. The compatibility
            // path still rejects it when that session is no longer current.
            guard !sessionID.isEmpty else { return .result() }
            guard KeyboardDictationHandoff.publish(command: .stop, sessionID: sessionID) else {
                throw KeyboardDictationIntentError.storageUnavailable
            }
            KeyboardDictationHandoff.appendDiagnostic("legacy live activity requested stop sessionID=\(sessionID)")
        }
        return .result()
    }
}

@available(iOSApplicationExtension 17.0, *)
struct CancelKeyboardDictationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Cancel Transcription"
    static var description = IntentDescription("Stops transcription. Your recording stays saved in the app.")

    @Parameter(title: "Session")
    var sessionID: String

    @Parameter(title: "Attempt")
    var attemptID: String

    @Parameter(title: "Generation")
    var generation: Int

    init() {
        sessionID = ""
        attemptID = ""
        generation = 0
    }

    init(sessionID: String, attemptID: String, generation: Int) {
        self.sessionID = sessionID
        self.attemptID = attemptID
        self.generation = generation
    }

    func perform() async throws -> some IntentResult {
        if !sessionID.isEmpty, !attemptID.isEmpty, generation > 0 {
            let identity = KeyboardDictationHandoff.AttemptIdentity(
                sessionID: sessionID,
                attemptID: attemptID,
                generation: UInt64(generation)
            )
            let accepted = KeyboardDictationHandoff.publish(command: .cancel, identity: identity)
            if !accepted,
               KeyboardDictationHandoff.snapshot(for: identity)?.phase.isTerminal != true
            {
                throw KeyboardDictationIntentError.storageUnavailable
            }
            KeyboardDictationHandoff.appendDiagnostic(
                "live activity requested cancel sessionID=\(sessionID) attemptID=\(attemptID) generation=\(generation)"
            )
        } else {
            guard !sessionID.isEmpty else { return .result() }
            guard KeyboardDictationHandoff.publish(command: .cancel, sessionID: sessionID) else {
                throw KeyboardDictationIntentError.storageUnavailable
            }
            KeyboardDictationHandoff.appendDiagnostic("legacy live activity requested cancel sessionID=\(sessionID)")
        }
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
