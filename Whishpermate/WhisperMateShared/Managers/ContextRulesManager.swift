import Foundation
public import Combine

/// Manages app-specific context rules for transcription formatting
public class ContextRulesManager: ObservableObject {
    public static let shared = ContextRulesManager()

    // MARK: - Published Properties

    @Published public var rules: [ContextRule] = []

    // MARK: - Private Properties

    private enum Keys {
        static let contextRules = "tone_styles" // Keep same key for backward compatibility
    }

    // MARK: - Initialization

    public init() {
        loadRules()
    }

    // MARK: - Public API

    public func loadRules() {
        if let data = AppDefaults.shared.data(forKey: Keys.contextRules),
           let decoded = try? JSONDecoder().decode([ContextRule].self, from: data)
        {
            rules = decoded
            DebugLog.info("Loaded \(rules.count) context rules", context: "ContextRulesManager")
        } else {
            // Add default rule templates (all disabled by default)
            rules = [
                ContextRule(
                    name: "Casual Messaging",
                    appBundleIds: ["com.apple.MobileSMS", "com.discord.Discord", "net.whatsapp.WhatsApp"],
                    instructions: "Keep it casual and friendly, use emojis if appropriate, short sentences, very conversational",
                    isEnabled: false
                ),
                ContextRule(
                    name: "Professional Work Chat",
                    appBundleIds: ["com.tinyspeck.slackmacgap", "com.microsoft.teams2"],
                    instructions: "Friendly but professional tone, proper grammar, conversational but not too casual",
                    isEnabled: false
                ),
                ContextRule(
                    name: "Business Email",
                    appBundleIds: ["com.apple.mail", "com.microsoft.Outlook"],
                    instructions: "Professional business tone, complete sentences, formal vocabulary, no contractions, include proper greetings",
                    isEnabled: false
                ),
                ContextRule(
                    name: "Technical Documentation",
                    appBundleIds: ["com.microsoft.Word", "com.apple.Pages", "com.notion.id"],
                    instructions: "Clear and formal technical writing, complete sentences, proper structure, objective tone",
                    isEnabled: false
                ),
                ContextRule(
                    name: "English Only",
                    appBundleIds: [],
                    instructions: "Always respond in English, regardless of the input language",
                    isEnabled: false
                ),
            ]
            saveRules()
            DebugLog.info("Created default context rules", context: "ContextRulesManager")
        }
    }

    public func saveRules() {
        if let encoded = try? JSONEncoder().encode(rules) {
            AppDefaults.shared.set(encoded, forKey: Keys.contextRules)
            DebugLog.info("Saved \(rules.count) context rules", context: "ContextRulesManager")
        }
    }

    public func addRule(name: String, appBundleIds: [String], titlePatterns: [String] = [], instructions: String) {
        // Remove these apps from other rules to ensure mutual exclusivity
        removeAppsFromOtherRules(appBundleIds: appBundleIds, excludingRuleId: nil)

        let rule = ContextRule(name: name, appBundleIds: appBundleIds, titlePatterns: titlePatterns, instructions: instructions)
        rules.append(rule)
        saveRules()
        DebugLog.info("Added rule: \(name)", context: "ContextRulesManager")
    }

    public func removeRule(_ rule: ContextRule) {
        rules.removeAll { $0.id == rule.id }
        saveRules()
        DebugLog.info("Removed rule: \(rule.name)", context: "ContextRulesManager")
    }

    public func toggleRule(_ rule: ContextRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index].isEnabled.toggle()
            saveRules()
            DebugLog.info("Toggled rule: \(rule.name) -> \(rules[index].isEnabled)", context: "ContextRulesManager")
        }
    }

    public func updateRule(_ rule: ContextRule, name: String, appBundleIds: [String], titlePatterns: [String] = [], instructions: String) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            // Remove these apps from other rules to ensure mutual exclusivity
            removeAppsFromOtherRules(appBundleIds: appBundleIds, excludingRuleId: rule.id)

            rules[index].name = name
            rules[index].appBundleIds = appBundleIds
            rules[index].titlePatterns = titlePatterns
            rules[index].instructions = instructions
            saveRules()
            DebugLog.info("Updated rule: \(name)", context: "ContextRulesManager")
        }
    }

    // MARK: - ToneStyle Migration Compatibility

    public var styles: [ToneStyle] {
        rules
    }

    public func addStyle(name: String, appBundleIds: [String], titlePatterns: [String] = [], instructions: String) {
        addRule(name: name, appBundleIds: appBundleIds, titlePatterns: titlePatterns, instructions: instructions)
    }

    public func removeStyle(_ style: ToneStyle) {
        removeRule(style)
    }

    public func toggleStyle(_ style: ToneStyle) {
        toggleRule(style)
    }

    public func updateStyle(_ style: ToneStyle, name: String, appBundleIds: [String], titlePatterns: [String] = [], instructions: String) {
        updateRule(style, name: name, appBundleIds: appBundleIds, titlePatterns: titlePatterns, instructions: instructions)
    }

    // MARK: - Context Matching

    /// Get instructions for a specific app bundle ID and window title
    /// Returns instructions from all matching rules:
    /// - Rules with empty appBundleIds and empty titlePatterns (apply to all)
    /// - Rules that match the app's bundle ID OR the window title pattern (OR logic)
    public func instructions(for appBundleId: String?, windowTitle: String? = nil) -> String? {
        DebugLog.info("=== Checking context rules ===", context: "ContextRulesManager")
        DebugLog.info("App Bundle ID: '\(appBundleId ?? "none")'", context: "ContextRulesManager")
        DebugLog.info("Window Title: '\(windowTitle ?? "none")'", context: "ContextRulesManager")
        DebugLog.info("Total rules: \(rules.count), Enabled: \(rules.filter { $0.isEnabled }.count)", context: "ContextRulesManager")

        let matchingRules = matchingRules(for: appBundleId, windowTitle: windowTitle)

        // Return combined instructions
        if matchingRules.isEmpty {
            DebugLog.info("=== No matching rules found ===", context: "ContextRulesManager")
            return nil
        }

        let ruleNames = matchingRules.map { $0.name }.joined(separator: ", ")
        DebugLog.info("", context: "ContextRulesManager")
        DebugLog.info("=== Matched \(matchingRules.count) rule(s): \(ruleNames) ===", context: "ContextRulesManager")

        let instructions = matchingRules.map { $0.instructions }.joined(separator: ". ")
        DebugLog.info("Combined instructions: \(instructions)", context: "ContextRulesManager")
        return instructions
    }

    public func matchingRuleNames(for appBundleId: String?, windowTitle: String? = nil) -> [String] {
        matchingRules(for: appBundleId, windowTitle: windowTitle).map(\.name)
    }

    private func matchingRules(for appBundleId: String?, windowTitle: String?) -> [ContextRule] {
        rules.filter { rule in
            DebugLog.info("", context: "ContextRulesManager")
            DebugLog.info("Evaluating rule: '\(rule.name)' (enabled: \(rule.isEnabled))", context: "ContextRulesManager")

            guard rule.isEnabled else {
                DebugLog.info("  → Skipped (disabled)", context: "ContextRulesManager")
                return false
            }

            // If both appBundleIds and titlePatterns are empty, this rule applies to everything
            if rule.appBundleIds.isEmpty && rule.titlePatterns.isEmpty {
                DebugLog.info("  → Universal rule (no app or title restrictions) - MATCHES", context: "ContextRulesManager")
                return true
            }

            var appMatches = false
            var titleMatches = false

            // Check app bundle ID match
            if !rule.appBundleIds.isEmpty {
                DebugLog.info("  Checking app bundle IDs: \(rule.appBundleIds)", context: "ContextRulesManager")
                if let appBundleId = appBundleId, rule.appBundleIds.contains(appBundleId) {
                    appMatches = true
                    DebugLog.info("  → App matches: YES", context: "ContextRulesManager")
                } else {
                    DebugLog.info("  → App matches: NO", context: "ContextRulesManager")
                }
            } else {
                DebugLog.info("  → No app restriction", context: "ContextRulesManager")
            }

            // Check window title pattern match
            if !rule.titlePatterns.isEmpty {
                DebugLog.info("  Checking title patterns: \(rule.titlePatterns)", context: "ContextRulesManager")
                if let windowTitle = windowTitle {
                    for pattern in rule.titlePatterns {
                        if matchesTitlePattern(title: windowTitle, pattern: pattern) {
                            titleMatches = true
                            DebugLog.info("  → Title matches pattern '\(pattern)': YES", context: "ContextRulesManager")
                            break
                        }
                    }
                    if !titleMatches {
                        DebugLog.info("  → Title matches: NO (no patterns matched)", context: "ContextRulesManager")
                    }
                } else {
                    DebugLog.info("  → Title matches: NO (no window title provided)", context: "ContextRulesManager")
                }
            } else {
                DebugLog.info("  → No title restriction", context: "ContextRulesManager")
            }

            // OR logic: Either app OR title must match (if they have restrictions)
            let finalMatch = appMatches || titleMatches
            DebugLog.info("  Final result: \(finalMatch ? "✓ RULE MATCHES" : "✗ RULE DOES NOT MATCH") (app: \(appMatches), title: \(titleMatches)) [OR logic]", context: "ContextRulesManager")
            return finalMatch
        }
    }

    /// Match a window title against a pattern
    /// Patterns can be:
    /// - "Gmail" - matches if title contains "Gmail"
    /// - "* - LinkedIn" - wildcard pattern match
    /// - "Inbox (*)" - matches titles with wildcards
    private func matchesTitlePattern(title: String, pattern: String) -> Bool {
        DebugLog.info("Matching title pattern - Title: '\(title)', Pattern: '\(pattern)'", context: "ContextRulesManager")

        // Convert pattern to regex
        // * becomes .* (match any characters)
        // Escape special regex characters except *
        let patternRegex = pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "+", with: "\\+")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "^", with: "\\^")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "*", with: ".*")

        DebugLog.info("Converted to regex pattern: '\(patternRegex)'", context: "ContextRulesManager")

        guard let regex = try? NSRegularExpression(pattern: patternRegex, options: [.caseInsensitive]) else {
            DebugLog.info("Failed to create regex from pattern", context: "ContextRulesManager")
            return false
        }

        let range = NSRange(title.startIndex..., in: title)
        let matches = regex.firstMatch(in: title, options: [], range: range) != nil

        DebugLog.info("Pattern match result: \(matches ? "✓ MATCHED" : "✗ NO MATCH")", context: "ContextRulesManager")

        return matches
    }

    // MARK: - Computed Properties

    /// Get all enabled rule instructions as a combined prompt
    public var allInstructions: String {
        let enabledRules = rules.filter { $0.isEnabled }
        let instructions = enabledRules.map { "\($0.name): \($0.instructions)" }.joined(separator: ". ")
        return instructions
    }

    // MARK: - Private Methods

    /// Remove apps from other rules to ensure mutual exclusivity
    private func removeAppsFromOtherRules(appBundleIds: [String], excludingRuleId: UUID?) {
        let appBundleSet = Set(appBundleIds)

        for (index, rule) in rules.enumerated() {
            // Skip the rule we're updating/adding
            if let excludingId = excludingRuleId, rule.id == excludingId {
                continue
            }

            // Remove any overlapping apps from this rule
            let updatedBundleIds = rule.appBundleIds.filter { !appBundleSet.contains($0) }

            // Only update if there were changes
            if updatedBundleIds.count != rule.appBundleIds.count {
                rules[index].appBundleIds = updatedBundleIds
                DebugLog.info("Removed \(rule.appBundleIds.count - updatedBundleIds.count) app(s) from rule: \(rule.name)", context: "ContextRulesManager")
            }
        }
    }
}

// MARK: - Migration Support

/// Type alias for backward compatibility during migration
public typealias ToneStyleManager = ContextRulesManager
