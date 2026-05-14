package com.whispermate.aidictation.domain.model

data class WhisperLanguage(
    val code: String,
    val englishName: String,
    val nativeName: String,
    val supportsParakeet: Boolean = false
)

object WhisperLanguages {
    val all: List<WhisperLanguage> = listOf(
        WhisperLanguage("af", "Afrikaans", "Afrikaans"),
        WhisperLanguage("ar", "Arabic", "العربية"),
        WhisperLanguage("hy", "Armenian", "Հայերեն"),
        WhisperLanguage("az", "Azerbaijani", "Azərbaycan"),
        WhisperLanguage("be", "Belarusian", "Беларуская"),
        WhisperLanguage("bs", "Bosnian", "Bosanski"),
        WhisperLanguage("bg", "Bulgarian", "Български", supportsParakeet = true),
        WhisperLanguage("ca", "Catalan", "Català"),
        WhisperLanguage("zh", "Chinese", "中文"),
        WhisperLanguage("yue", "Cantonese", "粵語"),
        WhisperLanguage("hr", "Croatian", "Hrvatski", supportsParakeet = true),
        WhisperLanguage("cs", "Czech", "Čeština", supportsParakeet = true),
        WhisperLanguage("da", "Danish", "Dansk", supportsParakeet = true),
        WhisperLanguage("nl", "Dutch", "Nederlands", supportsParakeet = true),
        WhisperLanguage("en", "English", "English", supportsParakeet = true),
        WhisperLanguage("en-GB", "English - British", "English - British", supportsParakeet = true),
        WhisperLanguage("et", "Estonian", "Eesti", supportsParakeet = true),
        WhisperLanguage("fi", "Finnish", "Suomi", supportsParakeet = true),
        WhisperLanguage("fr", "French", "Français", supportsParakeet = true),
        WhisperLanguage("gl", "Galician", "Galego"),
        WhisperLanguage("de", "German", "Deutsch", supportsParakeet = true),
        WhisperLanguage("el", "Greek", "Ελληνικά", supportsParakeet = true),
        WhisperLanguage("he", "Hebrew", "עברית"),
        WhisperLanguage("hi", "Hindi", "हिन्दी"),
        WhisperLanguage("hi-Latn", "Hinglish", "Hinglish"),
        WhisperLanguage("hu", "Hungarian", "Magyar", supportsParakeet = true),
        WhisperLanguage("is", "Icelandic", "Íslenska"),
        WhisperLanguage("id", "Indonesian", "Bahasa Indonesia"),
        WhisperLanguage("it", "Italian", "Italiano", supportsParakeet = true),
        WhisperLanguage("ja", "Japanese", "日本語"),
        WhisperLanguage("kn", "Kannada", "ಕನ್ನಡ"),
        WhisperLanguage("kk", "Kazakh", "Қазақ"),
        WhisperLanguage("ko", "Korean", "한국어"),
        WhisperLanguage("lv", "Latvian", "Latviešu", supportsParakeet = true),
        WhisperLanguage("lt", "Lithuanian", "Lietuvių", supportsParakeet = true),
        WhisperLanguage("mk", "Macedonian", "Македонски"),
        WhisperLanguage("mt", "Maltese", "Malti", supportsParakeet = true),
        WhisperLanguage("ms", "Malay", "Bahasa Melayu"),
        WhisperLanguage("mr", "Marathi", "मराठी"),
        WhisperLanguage("mi", "Maori", "Te Reo Māori"),
        WhisperLanguage("ne", "Nepali", "नेपाली"),
        WhisperLanguage("no", "Norwegian", "Norsk"),
        WhisperLanguage("fa", "Persian", "فارسی"),
        WhisperLanguage("pl", "Polish", "Polski", supportsParakeet = true),
        WhisperLanguage("pt", "Portuguese", "Português", supportsParakeet = true),
        WhisperLanguage("ro", "Romanian", "Română", supportsParakeet = true),
        WhisperLanguage("ru", "Russian", "Русский", supportsParakeet = true),
        WhisperLanguage("sr", "Serbian", "Српски"),
        WhisperLanguage("sk", "Slovak", "Slovenčina", supportsParakeet = true),
        WhisperLanguage("sl", "Slovenian", "Slovenščina", supportsParakeet = true),
        WhisperLanguage("es", "Spanish", "Español", supportsParakeet = true),
        WhisperLanguage("sw", "Swahili", "Kiswahili"),
        WhisperLanguage("sv", "Swedish", "Svenska", supportsParakeet = true),
        WhisperLanguage("tl", "Tagalog", "Tagalog"),
        WhisperLanguage("ta", "Tamil", "தமிழ்"),
        WhisperLanguage("th", "Thai", "ไทย"),
        WhisperLanguage("tr", "Turkish", "Türkçe"),
        WhisperLanguage("uk", "Ukrainian", "Українська", supportsParakeet = true),
        WhisperLanguage("ur", "Urdu", "اردو"),
        WhisperLanguage("vi", "Vietnamese", "Tiếng Việt"),
        WhisperLanguage("cy", "Welsh", "Cymraeg"),
    )

    val parakeetSupported: List<WhisperLanguage> = all.filter { it.supportsParakeet }

    private val byCode: Map<String, WhisperLanguage> = all.associateBy { it.code }

    fun getName(code: String): String? = byCode[code]?.englishName

    fun getLanguage(code: String): WhisperLanguage? = byCode[code]

    fun isParakeetSupported(code: String): Boolean = byCode[code]?.supportsParakeet == true
}
