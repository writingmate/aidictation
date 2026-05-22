using System.Collections.Generic;
using System.Linq;

namespace AIDictation.Models;

public enum Language
{
    Auto,
    English,
    BritishEnglish,
    Russian,
    Spanish,
    French,
    German,
    Greek,
    Italian,
    Portuguese,
    Polish,
    Turkish,
    Dutch,
    Japanese,
    Korean,
    Chinese,
    Cantonese,
    Arabic,
    Hindi,
    Hinglish,
    Ukrainian,
    Czech,
    Swedish,
    Finnish
}

public static class LanguageExtensions
{
    private static readonly Dictionary<Language, (string Code, string Name, string Flag)> LanguageData = new()
    {
        { Language.Auto, ("auto", "Auto-detect", "🌐") },
        { Language.English, ("en", "English", "🇬🇧") },
        { Language.BritishEnglish, ("en-GB", "English - British", "🇬🇧") },
        { Language.Russian, ("ru", "Russian", "🇷🇺") },
        { Language.Spanish, ("es", "Spanish", "🇪🇸") },
        { Language.French, ("fr", "French", "🇫🇷") },
        { Language.German, ("de", "German", "🇩🇪") },
        { Language.Greek, ("el", "Greek", "🇬🇷") },
        { Language.Italian, ("it", "Italian", "🇮🇹") },
        { Language.Portuguese, ("pt", "Portuguese", "🇵🇹") },
        { Language.Polish, ("pl", "Polish", "🇵🇱") },
        { Language.Turkish, ("tr", "Turkish", "🇹🇷") },
        { Language.Dutch, ("nl", "Dutch", "🇳🇱") },
        { Language.Japanese, ("ja", "Japanese", "🇯🇵") },
        { Language.Korean, ("ko", "Korean", "🇰🇷") },
        { Language.Chinese, ("zh", "Chinese", "🇨🇳") },
        { Language.Cantonese, ("yue", "Cantonese", "🇭🇰") },
        { Language.Arabic, ("ar", "Arabic", "🇸🇦") },
        { Language.Hindi, ("hi", "Hindi", "🇮🇳") },
        { Language.Hinglish, ("hi-Latn", "Hinglish", "🇮🇳") },
        { Language.Ukrainian, ("uk", "Ukrainian", "🇺🇦") },
        { Language.Czech, ("cs", "Czech", "🇨🇿") },
        { Language.Swedish, ("sv", "Swedish", "🇸🇪") },
        { Language.Finnish, ("fi", "Finnish", "🇫🇮") }
    };

    public static string GetCode(this Language language) => 
        LanguageData.TryGetValue(language, out var data) ? data.Code : "auto";

    public static string GetDisplayName(this Language language) => 
        LanguageData.TryGetValue(language, out var data) ? data.Name : "Unknown";

    public static string GetFlag(this Language language) => 
        LanguageData.TryGetValue(language, out var data) ? data.Flag : "🌐";

    public static IEnumerable<Language> GetAll() => LanguageData.Keys;

    public static Language? FromCode(string code)
    {
        var match = LanguageData.FirstOrDefault(x => x.Value.Code == code);
        return match.Value.Code != null ? match.Key : null;
    }
}
