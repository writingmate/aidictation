import Foundation
public import Combine

/// Manages custom dictionary entries for transcription vocabulary and replacements
public class DictionaryManager: ObservableObject {
    public static let shared = DictionaryManager()

    // MARK: - Published Properties

    @Published public var entries: [DictionaryEntry] = []

    // MARK: - Private Properties

    private enum Keys {
        static let dictionaryEntries = "dictionary_entries"
    }

    // MARK: - Initialization

    public init() {
        loadEntries()
    }

    // MARK: - Public API

    public func loadEntries() {
        if let data = AppDefaults.shared.data(forKey: Keys.dictionaryEntries),
           let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data)
        {
            entries = decoded
            DebugLog.info("Loaded \(entries.count) dictionary entries", context: "DictionaryManager")
        } else {
            // Add default vocabulary examples (all disabled by default)
            entries = [
                DictionaryEntry(trigger: "AIDictation", replacement: nil, isEnabled: false),
                DictionaryEntry(trigger: "Calendly", replacement: nil, isEnabled: false),
                DictionaryEntry(trigger: "OpenAI", replacement: nil, isEnabled: false),
                DictionaryEntry(trigger: "ChatGPT", replacement: nil, isEnabled: false),
                DictionaryEntry(trigger: "GitHub", replacement: nil, isEnabled: false),
                DictionaryEntry(trigger: "API", replacement: nil, isEnabled: false),
                DictionaryEntry(trigger: "iOS", replacement: nil, isEnabled: false),
                DictionaryEntry(trigger: "macOS", replacement: nil, isEnabled: false),
                DictionaryEntry(trigger: "JSON", replacement: nil, isEnabled: false),
                DictionaryEntry(trigger: "SQL", replacement: nil, isEnabled: false),
            ]
            saveEntries()
            DebugLog.info("Created default dictionary entries with examples", context: "DictionaryManager")
        }
    }

    public func saveEntries() {
        if let encoded = try? JSONEncoder().encode(entries) {
            AppDefaults.shared.set(encoded, forKey: Keys.dictionaryEntries)
            DebugLog.info("Saved \(entries.count) dictionary entries", context: "DictionaryManager")
        }
    }

    public func addEntry(trigger: String, replacement: String?) {
        let entry = DictionaryEntry(trigger: trigger, replacement: replacement)
        entries.append(entry)
        saveEntries()
        let logMsg = replacement != nil ? "\(trigger) -> \(replacement!)" : trigger
        DebugLog.info("Added entry: \(logMsg)", context: "DictionaryManager")
    }

    public func removeEntry(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        saveEntries()
        DebugLog.info("Removed entry: \(entry.trigger)", context: "DictionaryManager")
    }

    public func toggleEntry(_ entry: DictionaryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].isEnabled.toggle()
            saveEntries()
            DebugLog.info("Toggled entry: \(entry.trigger) -> \(entries[index].isEnabled)", context: "DictionaryManager")
        }
    }

    public func updateEntry(_ entry: DictionaryEntry, trigger: String, replacement: String?) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].trigger = trigger
            entries[index].replacement = replacement
            saveEntries()
            let logMsg = replacement != nil ? "\(trigger) -> \(replacement!)" : trigger
            DebugLog.info("Updated entry: \(logMsg)", context: "DictionaryManager")
        }
    }

    // MARK: - Computed Properties

    /// Get transcription hints for Whisper API (comma-separated list of trigger words)
    public var transcriptionHints: String {
        let enabledEntries = entries.filter { $0.isEnabled }
        let hints = enabledEntries.map { $0.trigger }.joined(separator: ", ")
        return hints
    }

    public var transcriptionKeywords: [String] {
        entries
            .filter(\.isEnabled)
            .flatMap { entry in
                [entry.trigger, entry.replacement]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
    }

    /// Apply dictionary replacements to transcribed text (only for entries with replacements)
    public func applyReplacements(to text: String) -> String {
        var result = text
        let enabledEntries = entries.filter { $0.isEnabled && $0.replacement != nil }

        // Sort by trigger length (longest first) to handle overlapping triggers
        let sortedEntries = enabledEntries.sorted { $0.trigger.count > $1.trigger.count }

        for entry in sortedEntries {
            guard let replacement = entry.replacement else { continue }
            // Case-insensitive replacement
            result = result.replacingOccurrences(
                of: entry.trigger,
                with: replacement,
                options: .caseInsensitive
            )
        }

        return result
    }

    /// Get formatting instructions for LLM to apply dictionary replacements
    public var formattingInstructions: String? {
        let enabledEntries = entries.filter { $0.isEnabled && $0.replacement != nil }
        guard !enabledEntries.isEmpty else { return nil }

        let replacements = enabledEntries.map { "\($0.trigger) → \($0.replacement!)" }.joined(separator: ", ")
        return "Apply these word replacements: \(replacements)"
    }
}
