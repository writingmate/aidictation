import Foundation
public import Combine
#if os(macOS)
import Carbon
#endif

public enum Language: String, CaseIterable, Identifiable {
    case auto
    case english = "en"
    case britishEnglish = "en-GB"
    case russian = "ru"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case italian = "it"
    case portuguese = "pt"
    case polish = "pl"
    case turkish = "tr"
    case dutch = "nl"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"
    case cantonese = "yue"
    case arabic = "ar"
    case hindi = "hi"
    case hinglish = "hi-Latn"
    case ukrainian = "uk"
    case belarusian = "be"
    case czech = "cs"
    case swedish = "sv"
    case finnish = "fi"

    public var id: String { rawValue }

    public var supportsParakeet: Bool {
        switch self {
        case .auto,
             .english,
             .britishEnglish,
             .russian,
             .spanish,
             .french,
             .german,
             .greek,
             .italian,
             .portuguese,
             .polish,
             .dutch,
             .ukrainian,
             .czech,
             .swedish,
             .finnish:
            return true
        case .turkish,
             .japanese,
             .korean,
             .chinese,
             .cantonese,
             .arabic,
             .hindi,
             .hinglish,
             .belarusian:
            return false
        }
    }

    public static var parakeetSupportedCases: [Language] {
        allCases.filter(\.supportsParakeet)
    }

    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .britishEnglish: return "English - British"
        case .russian: return "Russian"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .greek: return "Greek"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .polish: return "Polish"
        case .turkish: return "Turkish"
        case .dutch: return "Dutch"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        case .cantonese: return "Cantonese"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .hinglish: return "Hinglish"
        case .ukrainian: return "Ukrainian"
        case .belarusian: return "Belarusian"
        case .czech: return "Czech"
        case .swedish: return "Swedish"
        case .finnish: return "Finnish"
        }
    }

    public var flag: String {
        switch self {
        case .auto: return "🌐"
        case .english: return "🇬🇧"
        case .britishEnglish: return "🇬🇧"
        case .russian: return "🇷🇺"
        case .spanish: return "🇪🇸"
        case .french: return "🇫🇷"
        case .german: return "🇩🇪"
        case .greek: return "🇬🇷"
        case .italian: return "🇮🇹"
        case .portuguese: return "🇵🇹"
        case .polish: return "🇵🇱"
        case .turkish: return "🇹🇷"
        case .dutch: return "🇳🇱"
        case .japanese: return "🇯🇵"
        case .korean: return "🇰🇷"
        case .chinese: return "🇨🇳"
        case .cantonese: return "🇭🇰"
        case .arabic: return "🇸🇦"
        case .hindi: return "🇮🇳"
        case .hinglish: return "🇮🇳"
        case .ukrainian: return "🇺🇦"
        case .belarusian: return "🇧🇾"
        case .czech: return "🇨🇿"
        case .swedish: return "🇸🇪"
        case .finnish: return "🇫🇮"
        }
    }

    init?(systemLanguageCode: String) {
        let normalizedCode = systemLanguageCode
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()

        guard let normalizedCode else { return nil }
        self.init(rawValue: normalizedCode)
    }
}

public class LanguageManager: ObservableObject {
    public static let shared = LanguageManager()

    @Published public var selectedLanguages: Set<Language> = []

    private let userDefaultsKey = "selected_languages"

    private init() {
        loadLanguages()
    }

    public func loadLanguages() {
        if let savedLanguages = AppDefaults.shared.array(forKey: userDefaultsKey) as? [String] {
            selectedLanguages = Set(savedLanguages.compactMap { Language(rawValue: $0) })
            DebugLog.info("Loaded languages: \(selectedLanguages.map { $0.displayName })", context: "LanguageManager LOG")
        } else {
            selectedLanguages = Self.defaultLanguages()
            DebugLog.info("No saved languages, defaulting to \(selectedLanguages.map { $0.displayName })", context: "LanguageManager LOG")
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

    public func restrictToParakeetSupported() {
        let supported = selectedLanguages.filter(\.supportsParakeet)
        selectedLanguages = supported.isEmpty ? [.english] : supported
        saveLanguages()
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

    public var apiLanguageCodes: [String] {
        guard !selectedLanguages.contains(.auto) else { return [] }
        return selectedLanguages
            .filter { $0 != .auto }
            .map(\.rawValue)
            .sorted()
    }

    /// Locales to ask Apple speech for. Auto-detect uses keyboard languages
    /// when available so a mixed dictation is not reduced to one locale.
    public var appleSpeechLanguageCodes: [String] {
        if !selectedLanguages.contains(.auto) {
            return apiLanguageCodes
        }
        #if os(macOS)
        let keyboardCodes = Self.systemKeyboardLanguages()
            .filter { $0 != .auto }
            .map(\.rawValue)
            .sorted()
        if !keyboardCodes.isEmpty {
            return keyboardCodes
        }
        #endif
        let fallback = Locale.current.identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map { String($0).lowercased() }
        return fallback.map { [$0] } ?? []
    }

    private static func defaultLanguages() -> Set<Language> {
        #if os(macOS)
        let keyboardLanguages = systemKeyboardLanguages()
        if !keyboardLanguages.isEmpty {
            return keyboardLanguages
        }
        #endif

        return [.auto]
    }

    #if os(macOS)
    private static func systemKeyboardLanguages() -> Set<Language> {
        let properties = [kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }

        var languages: [Language] = []
        for source in sources {
            guard let typePointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
                continue
            }

            let type = Unmanaged<CFString>.fromOpaque(typePointer).takeUnretainedValue() as String
            guard type == kTISTypeKeyboardLayout as String || type == kTISTypeKeyboardInputMode as String else {
                continue
            }

            guard let languagesPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
                continue
            }

            let sourceLanguages = Unmanaged<CFArray>.fromOpaque(languagesPointer).takeUnretainedValue() as? [String] ?? []
            if let language = sourceLanguages.lazy.compactMap(Language.init(systemLanguageCode:)).first,
               !languages.contains(language)
            {
                languages.append(language)
            }
        }

        return Set(languages)
    }
    #endif
}
