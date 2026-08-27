import Foundation
public import Combine

public class ShortcutManager: ObservableObject {
    public static let shared = ShortcutManager()

    @Published public var shortcuts: [Shortcut] = []

    private let userDefaultsKey = "shortcuts"

    public init() {
        loadShortcuts()
    }

    public func loadShortcuts() {
        if let data = AppDefaults.shared.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([Shortcut].self, from: data)
        {
            shortcuts = decoded
            DebugLog.info("Loaded \(shortcuts.count) shortcuts", context: "ShortcutManager")
        } else {
            // Add default shortcuts (all disabled by default)
            shortcuts = [
                Shortcut(
                    voiceTrigger: "my calendly",
                    expansion: "https://calendly.com/yourname",
                    isEnabled: false
                ),
                Shortcut(
                    voiceTrigger: "my email",
                    expansion: "your.email@example.com",
                    isEnabled: false
                ),
                Shortcut(
                    voiceTrigger: "my phone",
                    expansion: "+1 (555) 123-4567",
                    isEnabled: false
                ),
                Shortcut(
                    voiceTrigger: "my address",
                    expansion: "123 Main Street, City, State 12345",
                    isEnabled: false
                ),
            ]
            saveShortcuts()
            DebugLog.info("Created default shortcuts", context: "ShortcutManager")
        }
    }

    public func saveShortcuts() {
        if let encoded = try? JSONEncoder().encode(shortcuts) {
            AppDefaults.shared.set(encoded, forKey: userDefaultsKey)
            DebugLog.info("Saved \(shortcuts.count) shortcuts", context: "ShortcutManager")
        }
    }

    public func addShortcut(voiceTrigger: String, expansion: String) {
        let shortcut = Shortcut(voiceTrigger: voiceTrigger, expansion: expansion)
        shortcuts.append(shortcut)
        saveShortcuts()
        DebugLog.info("Added shortcut: \(voiceTrigger) -> \(expansion)", context: "ShortcutManager")
    }

    public func removeShortcut(_ shortcut: Shortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        saveShortcuts()
        DebugLog.info("Removed shortcut: \(shortcut.voiceTrigger)", context: "ShortcutManager")
    }

    public func toggleShortcut(_ shortcut: Shortcut) {
        if let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts[index].isEnabled.toggle()
            saveShortcuts()
            DebugLog.info("Toggled shortcut: \(shortcut.voiceTrigger) -> \(shortcuts[index].isEnabled)", context: "ShortcutManager")
        }
    }

    public func updateShortcut(_ shortcut: Shortcut, voiceTrigger: String, expansion: String) {
        if let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts[index].voiceTrigger = voiceTrigger
            shortcuts[index].expansion = expansion
            saveShortcuts()
            DebugLog.info("Updated shortcut: \(voiceTrigger) -> \(expansion)", context: "ShortcutManager")
        }
    }

    /// Get transcription hints for voice triggers (comma-separated)
    public var transcriptionHints: String {
        let enabledShortcuts = shortcuts.filter { $0.isEnabled }
        let hints = enabledShortcuts.map { $0.voiceTrigger }.joined(separator: ", ")
        return hints
    }

    public var transcriptionKeywords: [String] {
        shortcuts
            .filter(\.isEnabled)
            .flatMap { [$0.voiceTrigger, $0.expansion] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Expand shortcuts in transcribed text
    public func expandShortcuts(in text: String) -> String {
        var result = text
        let enabledShortcuts = shortcuts.filter { $0.isEnabled }

        // Sort by trigger length (longest first) to handle overlapping triggers
        let sortedShortcuts = enabledShortcuts.sorted { $0.voiceTrigger.count > $1.voiceTrigger.count }

        for shortcut in sortedShortcuts {
            // Case-insensitive replacement
            result = result.replacingOccurrences(
                of: shortcut.voiceTrigger,
                with: shortcut.expansion,
                options: .caseInsensitive
            )
        }

        return result
    }

    /// Get formatting instructions for LLM to expand shortcuts
    public var formattingInstructions: String? {
        let enabledShortcuts = shortcuts.filter { $0.isEnabled }
        guard !enabledShortcuts.isEmpty else { return nil }

        let expansions = enabledShortcuts.map { "\($0.voiceTrigger) → \($0.expansion)" }.joined(separator: ", ")
        return "Expand these voice shortcuts: \(expansions)"
    }
}
