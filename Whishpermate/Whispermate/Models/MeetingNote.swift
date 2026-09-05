import Foundation

nonisolated struct MeetingNote: Codable, Identifiable, Equatable, Sendable {
    struct Segment: Codable, Identifiable, Equatable {
        let id: UUID
        let startedAt: Date
        var transcript = ""
        var duration: TimeInterval = 0
    }

    struct Message: Codable, Identifiable, Equatable {
        let id: UUID
        let question: String
        let answer: String
    }

    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var title = ""
    var thoughts = ""
    var summary = ""
    var summarizedContent: String?
    var segments: [Segment] = []
    var messages: [Message] = []
    var isPinned = false
    var deletedAt: Date?

    init(id: UUID = UUID(), now: Date = Date()) {
        self.id = id
        createdAt = now
        updatedAt = now
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled note" : trimmed
    }

    var transcript: String {
        segments.map(\.transcript).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var sourceContent: String {
        "<transcript>\n\(transcript)\n</transcript>\n<personal_notes>\n\(thoughts)\n</personal_notes>"
    }

    var hasContent: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var summaryIsOutdated: Bool { !summary.isEmpty && summarizedContent != sourceContent }

    var preview: String {
        let text = !summary.isEmpty ? summary : (!thoughts.isEmpty ? thoughts : transcript)
        return text.replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || [displayTitle, thoughts, transcript, summary].contains {
            $0.localizedStandardContains(query)
        }
    }

    mutating func receive(recordingID: UUID, transcript: String, duration: TimeInterval) -> Bool {
        guard deletedAt == nil, let index = segments.firstIndex(where: { $0.id == recordingID }),
              segments[index].transcript != transcript || segments[index].duration != duration
        else { return false }
        segments[index].transcript = transcript
        segments[index].duration = duration
        return true
    }

    func exportedText(includeThoughts: Bool = false) -> String {
        var sections = ["# \(displayTitle)"]
        if !summary.isEmpty { sections.append("## Summary\n\n\(summary)") }
        if includeThoughts, !thoughts.isEmpty { sections.append("## My thoughts\n\n\(thoughts)") }
        if !transcript.isEmpty { sections.append("## Transcript\n\n\(transcript)") }
        return sections.joined(separator: "\n\n")
    }
}
