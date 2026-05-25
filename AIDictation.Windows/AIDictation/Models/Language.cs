using System.Collections.Generic;
using System.Linq;

namespace AIDictation.Models;

public enum Language
{
    Auto,
    Afrikaans,
    Arabic,
    Armenian,
    Azerbaijani,
    Belarusian,
    Bosnian,
    Bulgarian,
    Catalan,
    Chinese,
    Cantonese,
    Croatian,
    Czech,
    Danish,
    Dutch,
    English,
    BritishEnglish,
    Estonian,
    Finnish,
    French,
    Galician,
    German,
    Greek,
    Hebrew,
    Hindi,
    Hinglish,
    Hungarian,
    Icelandic,
    Indonesian,
    Italian,
    Japanese,
    Kannada,
    Kazakh,
    Korean,
    Latvian,
    Lithuanian,
    Macedonian,
    Maltese,
    Malay,
    Marathi,
    Maori,
    Nepali,
    Norwegian,
    Persian,
    Polish,
    Portuguese,
    Romanian,
    Russian,
    Serbian,
    Slovak,
    Slovenian,
    Spanish,
    Swahili,
    Swedish,
    Tagalog,
    Tamil,
    Thai,
    Turkish,
    Ukrainian,
    Urdu,
    Vietnamese,
    Welsh
}

public enum TranscriptionModel
{
    AIDictationCloud,
    Parakeet
}

public static class LanguageExtensions
{
    private static readonly Dictionary<Language, LanguageMetadata> LanguageData = new()
    {
        { Language.Auto, new("auto", "Auto-detect", "🌐") },
        { Language.Afrikaans, new("af", "Afrikaans", "🇿🇦") },
        { Language.Arabic, new("ar", "Arabic", "🇸🇦") },
        { Language.Armenian, new("hy", "Armenian", "🇦🇲") },
        { Language.Azerbaijani, new("az", "Azerbaijani", "🇦🇿") },
        { Language.Belarusian, new("be", "Belarusian", "🇧🇾") },
        { Language.Bosnian, new("bs", "Bosnian", "🇧🇦") },
        { Language.Bulgarian, new("bg", "Bulgarian", "🇧🇬", SupportsParakeet: true, OfflineWerPercent: 12.64) },
        { Language.Catalan, new("ca", "Catalan", "🇪🇸") },
        { Language.Chinese, new("zh", "Chinese", "🇨🇳") },
        { Language.Cantonese, new("yue", "Cantonese", "🇭🇰") },
        { Language.Croatian, new("hr", "Croatian", "🇭🇷", SupportsParakeet: true, OfflineWerPercent: 12.46) },
        { Language.Czech, new("cs", "Czech", "🇨🇿", SupportsParakeet: true, OfflineWerPercent: 11.01) },
        { Language.Danish, new("da", "Danish", "🇩🇰", SupportsParakeet: true, OfflineWerPercent: 18.41) },
        { Language.Dutch, new("nl", "Dutch", "🇳🇱", SupportsParakeet: true, OfflineWerPercent: 7.48) },
        { Language.English, new("en", "English", "🇬🇧", SupportsParakeet: true, OfflineWerPercent: 4.85) },
        { Language.BritishEnglish, new("en-GB", "English - British", "🇬🇧", SupportsParakeet: true, OfflineWerPercent: 4.85) },
        { Language.Estonian, new("et", "Estonian", "🇪🇪", SupportsParakeet: true, OfflineWerPercent: 17.73) },
        { Language.Finnish, new("fi", "Finnish", "🇫🇮", SupportsParakeet: true, OfflineWerPercent: 13.21) },
        { Language.French, new("fr", "French", "🇫🇷", SupportsParakeet: true, OfflineWerPercent: 5.15) },
        { Language.Galician, new("gl", "Galician", "🇪🇸") },
        { Language.German, new("de", "German", "🇩🇪", SupportsParakeet: true, OfflineWerPercent: 5.04) },
        { Language.Greek, new("el", "Greek", "🇬🇷", SupportsParakeet: true, OfflineWerPercent: 20.70) },
        { Language.Hebrew, new("he", "Hebrew", "🇮🇱") },
        { Language.Hindi, new("hi", "Hindi", "🇮🇳") },
        { Language.Hinglish, new("hi-Latn", "Hinglish", "🇮🇳") },
        { Language.Hungarian, new("hu", "Hungarian", "🇭🇺", SupportsParakeet: true, OfflineWerPercent: 15.72) },
        { Language.Icelandic, new("is", "Icelandic", "🇮🇸") },
        { Language.Indonesian, new("id", "Indonesian", "🇮🇩") },
        { Language.Italian, new("it", "Italian", "🇮🇹", SupportsParakeet: true, OfflineWerPercent: 3.00) },
        { Language.Japanese, new("ja", "Japanese", "🇯🇵") },
        { Language.Kannada, new("kn", "Kannada", "🇮🇳") },
        { Language.Kazakh, new("kk", "Kazakh", "🇰🇿") },
        { Language.Korean, new("ko", "Korean", "🇰🇷") },
        { Language.Latvian, new("lv", "Latvian", "🇱🇻", SupportsParakeet: true, OfflineWerPercent: 22.84) },
        { Language.Lithuanian, new("lt", "Lithuanian", "🇱🇹", SupportsParakeet: true, OfflineWerPercent: 20.35) },
        { Language.Macedonian, new("mk", "Macedonian", "🇲🇰") },
        { Language.Maltese, new("mt", "Maltese", "🇲🇹", SupportsParakeet: true, OfflineWerPercent: 20.46) },
        { Language.Malay, new("ms", "Malay", "🇲🇾") },
        { Language.Marathi, new("mr", "Marathi", "🇮🇳") },
        { Language.Maori, new("mi", "Maori", "🇳🇿") },
        { Language.Nepali, new("ne", "Nepali", "🇳🇵") },
        { Language.Norwegian, new("no", "Norwegian", "🇳🇴") },
        { Language.Persian, new("fa", "Persian", "🇮🇷") },
        { Language.Polish, new("pl", "Polish", "🇵🇱", SupportsParakeet: true, OfflineWerPercent: 7.31) },
        { Language.Portuguese, new("pt", "Portuguese", "🇵🇹", SupportsParakeet: true, OfflineWerPercent: 4.76) },
        { Language.Romanian, new("ro", "Romanian", "🇷🇴", SupportsParakeet: true, OfflineWerPercent: 12.44) },
        { Language.Russian, new("ru", "Russian", "🇷🇺", SupportsParakeet: true, OfflineWerPercent: 5.51) },
        { Language.Serbian, new("sr", "Serbian", "🇷🇸") },
        { Language.Slovak, new("sk", "Slovak", "🇸🇰", SupportsParakeet: true, OfflineWerPercent: 8.82) },
        { Language.Slovenian, new("sl", "Slovenian", "🇸🇮", SupportsParakeet: true, OfflineWerPercent: 24.03) },
        { Language.Spanish, new("es", "Spanish", "🇪🇸", SupportsParakeet: true, OfflineWerPercent: 3.45) },
        { Language.Swahili, new("sw", "Swahili", "🇰🇪") },
        { Language.Swedish, new("sv", "Swedish", "🇸🇪", SupportsParakeet: true, OfflineWerPercent: 15.08) },
        { Language.Tagalog, new("tl", "Tagalog", "🇵🇭") },
        { Language.Tamil, new("ta", "Tamil", "🇮🇳") },
        { Language.Thai, new("th", "Thai", "🇹🇭") },
        { Language.Turkish, new("tr", "Turkish", "🇹🇷") },
        { Language.Ukrainian, new("uk", "Ukrainian", "🇺🇦", SupportsParakeet: true, OfflineWerPercent: 6.79) },
        { Language.Urdu, new("ur", "Urdu", "🇵🇰") },
        { Language.Vietnamese, new("vi", "Vietnamese", "🇻🇳") },
        { Language.Welsh, new("cy", "Welsh", "🏴") }
    };

    public static string GetCode(this Language language) => 
        LanguageData.TryGetValue(language, out var data) ? data.Code : "auto";

    public static string GetDisplayName(this Language language) => 
        LanguageData.TryGetValue(language, out var data) ? data.Name : "Unknown";

    public static string GetFlag(this Language language) => 
        LanguageData.TryGetValue(language, out var data) ? data.Flag : "🌐";

    public static bool SupportsModel(this Language language, TranscriptionModel model) =>
        model == TranscriptionModel.AIDictationCloud ||
        (LanguageData.TryGetValue(language, out var data) && data.SupportsParakeet);

    public static bool RequiresCloudTranscription(this Language language) =>
        LanguageData.TryGetValue(language, out var data) &&
        data.OfflineWerPercent > 15.0;

    public static bool IsReliableOffline(this Language language) =>
        language.SupportsModel(TranscriptionModel.Parakeet) &&
        !language.RequiresCloudTranscription();

    public static bool IsSupportedByModel(string code, TranscriptionModel model) =>
        model == TranscriptionModel.AIDictationCloud ||
        (FromCode(code) is { } language && language.SupportsModel(model));

    public static bool RequiresCloudTranscription(string code) =>
        FromCode(code) is { } language && language.RequiresCloudTranscription();

    public static IEnumerable<Language> GetAll() => LanguageData.Keys;

    public static Language? FromCode(string code)
    {
        var match = LanguageData.FirstOrDefault(x => x.Value.Code == code);
        return match.Value != null ? match.Key : null;
    }

    private sealed record LanguageMetadata(
        string Code,
        string Name,
        string Flag,
        bool SupportsParakeet = false,
        double? OfflineWerPercent = null);
}
