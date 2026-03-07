import Foundation
public import Combine

public enum Language: String, CaseIterable, Identifiable {
    case auto
    case english = "en"
    case russian = "ru"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case polish = "pl"
    case turkish = "tr"
    case dutch = "nl"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"
    case arabic = "ar"
    case hindi = "hi"
    case ukrainian = "uk"
    case czech = "cs"
    case swedish = "sv"
    case finnish = "fi"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .russian: return "Russian"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .polish: return "Polish"
        case .turkish: return "Turkish"
        case .dutch: return "Dutch"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .ukrainian: return "Ukrainian"
        case .czech: return "Czech"
        case .swedish: return "Swedish"
        case .finnish: return "Finnish"
        }
    }

    public var flag: String {
        switch self {
        case .auto: return "🌐"
        case .english: return "🇬🇧"
        case .russian: return "🇷🇺"
        case .spanish: return "🇪🇸"
        case .french: return "🇫🇷"
        case .german: return "🇩🇪"
        case .italian: return "🇮🇹"
        case .portuguese: return "🇵🇹"
        case .polish: return "🇵🇱"
        case .turkish: return "🇹🇷"
        case .dutch: return "🇳🇱"
        case .japanese: return "🇯🇵"
        case .korean: return "🇰🇷"
        case .chinese: return "🇨🇳"
        case .arabic: return "🇸🇦"
        case .hindi: return "🇮🇳"
        case .ukrainian: return "🇺🇦"
        case .czech: return "🇨🇿"
        case .swedish: return "🇸🇪"
        case .finnish: return "🇫🇮"
        }
    }
}

public class LanguageManager: ObservableObject {
    @Published public var selectedLanguages: Set<Language> = []

    private let userDefaultsKey = "selected_languages"

    public init() {
        loadLanguages()
    }

    public func loadLanguages() {
        if let savedLanguages = AppDefaults.shared.array(forKey: userDefaultsKey) as? [String] {
            selectedLanguages = Set(savedLanguages.compactMap { Language(rawValue: $0) })
            DebugLog.info("Loaded languages: \(selectedLanguages.map { $0.displayName })", context: "LanguageManager LOG")
        } else {
            // Default to auto-detect
            selectedLanguages = [.auto]
            DebugLog.info("No saved languages, defaulting to auto-detect", context: "LanguageManager LOG")
        }
    }

    public func saveLanguages() {
        let languageCodes = Array(selectedLanguages.map { $0.rawValue })
        AppDefaults.shared.set(languageCodes, forKey: userDefaultsKey)
        DebugLog.info("Saved languages: \(selectedLanguages.map { $0.displayName })", context: "LanguageManager LOG")
    }

    public func toggleLanguage(_ language: Language) {
        if language == .auto {
            // If selecting auto-detect, clear all others
            selectedLanguages = [.auto]
        } else {
            // Remove auto-detect if selecting a specific language
            selectedLanguages.remove(.auto)

            if selectedLanguages.contains(language) {
                selectedLanguages.remove(language)
                // If no languages left, default to auto
                if selectedLanguages.isEmpty {
                    selectedLanguages = [.auto]
                }
            } else {
                selectedLanguages.insert(language)
            }
        }
        saveLanguages()
    }

    public func isSelected(_ language: Language) -> Bool {
        selectedLanguages.contains(language)
    }

    /// Get the language code to send to the API
    /// If auto-detect is selected, return nil (let API auto-detect)
    /// If multiple languages are selected, return comma-separated codes
    public var apiLanguageCode: String? {
        if selectedLanguages.contains(.auto) {
            return nil
        }
        // Return all selected language codes, comma-separated
        let languageCodes = selectedLanguages
            .filter { $0 != .auto }
            .map { $0.rawValue }
            .sorted() // Sort for consistency

        return languageCodes.isEmpty ? nil : languageCodes.joined(separator: ",")
    }
}
