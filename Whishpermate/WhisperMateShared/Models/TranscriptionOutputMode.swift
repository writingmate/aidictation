import Foundation
public import Combine

public enum TranscriptionOutputMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case dictation
    case notes
    case meetings

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dictation: return "Dictation"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        }
    }

    public var description: String {
        switch self {
        case .dictation:
            return "Transcribe exactly what you say."
        case .notes:
            return "Turn speech into structured notes and action items."
        case .meetings:
            return "Turn speech into meeting notes with speakers and action items."
        }
    }

    public static let notesPostProcessingInstruction = """
    Transform the transcription into concise structured notes.

    Output only the notes, with no preamble or wrapper text.
    Use this format:
    Summary: A short one-line summary.

    Notes:
    - Concise bullets capturing the important points.

    Action Items:
    - Concrete follow-ups, owners, or deadlines mentioned by the speaker.

    If there are no action items, omit the Action Items section.
    Do not invent facts, owners, deadlines, or decisions that are not in the transcription.
    Preserve product names, people names, dates, and technical terms.
    """

    public static let meetingsPostProcessingInstruction = """
    Transform the transcript into structured meeting notes.

    Output only the meeting notes, with no preamble or wrapper text.
    Use this format:
    Summary: A short one-line meeting summary.

    Speakers:
    - Speaker labels and any clearly stated names.

    Notes:
    - Concise bullets grouped by topic when useful.
    - Attribute key points or decisions to speakers when supported by the transcript.

    Action Items:
    - Concrete follow-ups, owners, or deadlines mentioned in the transcript.

    If there are no action items, omit the Action Items section.
    Do not invent speaker names, decisions, owners, deadlines, or facts.
    Preserve provided speaker labels and timestamps as evidence when present.
    """
}

public final class TranscriptionOutputModeManager: ObservableObject {
    public static let shared = TranscriptionOutputModeManager()

    @Published public private(set) var selectedMode: TranscriptionOutputMode
    private let defaults: UserDefaults

    private enum Keys {
        static let selectedMode = "transcription_output_mode"
    }

    public convenience init() {
        self.init(defaults: Self.defaultDefaults())
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let rawValue = defaults.string(forKey: Keys.selectedMode),
           let mode = TranscriptionOutputMode(rawValue: rawValue)
        {
            selectedMode = mode
        } else {
            selectedMode = .dictation
        }
    }

    public var isNotesMode: Bool {
        selectedMode == .notes
    }

    public func setMode(_ mode: TranscriptionOutputMode) {
        selectedMode = mode
        defaults.set(mode.rawValue, forKey: Keys.selectedMode)
        defaults.synchronize()
    }

    private static func defaultDefaults() -> UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: KeyboardDictationHandoff.appGroupIdentifier) ?? AppDefaults.shared
        #else
        return AppDefaults.shared
        #endif
    }
}
