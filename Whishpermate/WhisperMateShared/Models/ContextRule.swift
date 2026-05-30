import Foundation

public struct ContextRule: Identifiable, Codable {
    public let id: UUID
    public var name: String
    public var appBundleIds: [String]
    public var titlePatterns: [String] // Window title patterns like "Gmail", "LinkedIn *", etc.
    public var instructions: String
    public var isEnabled: Bool
    public var transcriptionOptions: TranscriptionOptions

    private enum CodingKeys: String, CodingKey {
        case id, name, appBundleIds, titlePatterns, instructions, isEnabled, transcriptionOptions
    }

    public init(id: UUID = UUID(), name: String, appBundleIds: [String], titlePatterns: [String] = [], instructions: String, isEnabled: Bool = true, transcriptionOptions: TranscriptionOptions = .default) {
        self.id = id
        self.name = name
        self.appBundleIds = appBundleIds
        self.titlePatterns = titlePatterns
        self.instructions = instructions
        self.isEnabled = isEnabled
        self.transcriptionOptions = transcriptionOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        appBundleIds = try container.decode([String].self, forKey: .appBundleIds)
        titlePatterns = try container.decodeIfPresent([String].self, forKey: .titlePatterns) ?? []
        instructions = try container.decode(String.self, forKey: .instructions)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        transcriptionOptions = try container.decodeIfPresent(TranscriptionOptions.self, forKey: .transcriptionOptions) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(appBundleIds, forKey: .appBundleIds)
        try container.encode(titlePatterns, forKey: .titlePatterns)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(transcriptionOptions, forKey: .transcriptionOptions)
    }

    public var isNotesModeRule: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(ContextRulesManager.notesRuleName) == .orderedSame
    }

    public var isMeetingsModeRule: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(ContextRulesManager.meetingsRuleName) == .orderedSame
    }
}

// MARK: - Migration Support

/// Type alias for backward compatibility during migration
public typealias ToneStyle = ContextRule
