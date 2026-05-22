package com.whispermate.aidictation.domain.model

data class WhisperLanguage(
    val code: String,
    val englishName: String,
    val nativeName: String,
    val supportsParakeet: Boolean = false,
    val offlineWerPercent: Double? = null
)

object WhisperLanguages {
    val all: List<WhisperLanguage> = listOf(
        WhisperLanguage("af", "Afrikaans", "Afrikaans"),
        WhisperLanguage("ar", "Arabic", "العربية"),
        WhisperLanguage("hy", "Armenian", "Հայերեն"),
        WhisperLanguage("az", "Azerbaijani", "Azərbaycan"),
        WhisperLanguage("be", "Belarusian", "Беларуская"),
        WhisperLanguage("bs", "Bosnian", "Bosanski"),
        WhisperLanguage("bg", "Bulgarian", "Български", supportsParakeet = true, offlineWerPercent = 12.64),
        WhisperLanguage("ca", "Catalan", "Català"),
        WhisperLanguage("zh", "Chinese", "中文"),
        WhisperLanguage("yue", "Cantonese", "粵語"),
        WhisperLanguage("hr", "Croatian", "Hrvatski", supportsParakeet = true, offlineWerPercent = 12.46),
        WhisperLanguage("cs", "Czech", "Čeština", supportsParakeet = true, offlineWerPercent = 11.01),
        WhisperLanguage("da", "Danish", "Dansk", supportsParakeet = true, offlineWerPercent = 18.41),
        WhisperLanguage("nl", "Dutch", "Nederlands", supportsParakeet = true, offlineWerPercent = 7.48),
        WhisperLanguage("en", "English", "English", supportsParakeet = true, offlineWerPercent = 4.85),
        WhisperLanguage("en-GB", "English - British", "English - British", supportsParakeet = true, offlineWerPercent = 4.85),
        WhisperLanguage("et", "Estonian", "Eesti", supportsParakeet = true, offlineWerPercent = 17.73),
        WhisperLanguage("fi", "Finnish", "Suomi", supportsParakeet = true, offlineWerPercent = 13.21),
        WhisperLanguage("fr", "French", "Français", supportsParakeet = true, offlineWerPercent = 5.15),
        WhisperLanguage("gl", "Galician", "Galego"),
        WhisperLanguage("de", "German", "Deutsch", supportsParakeet = true, offlineWerPercent = 5.04),
        WhisperLanguage("el", "Greek", "Ελληνικά", supportsParakeet = true, offlineWerPercent = 20.70),
        WhisperLanguage("he", "Hebrew", "עברית"),
        WhisperLanguage("hi", "Hindi", "हिन्दी"),
        WhisperLanguage("hi-Latn", "Hinglish", "Hinglish"),
        WhisperLanguage("hu", "Hungarian", "Magyar", supportsParakeet = true, offlineWerPercent = 15.72),
        WhisperLanguage("is", "Icelandic", "Íslenska"),
        WhisperLanguage("id", "Indonesian", "Bahasa Indonesia"),
        WhisperLanguage("it", "Italian", "Italiano", supportsParakeet = true, offlineWerPercent = 3.00),
        WhisperLanguage("ja", "Japanese", "日本語"),
        WhisperLanguage("kn", "Kannada", "ಕನ್ನಡ"),
        WhisperLanguage("kk", "Kazakh", "Қазақ"),
        WhisperLanguage("ko", "Korean", "한국어"),
        WhisperLanguage("lv", "Latvian", "Latviešu", supportsParakeet = true, offlineWerPercent = 22.84),
        WhisperLanguage("lt", "Lithuanian", "Lietuvių", supportsParakeet = true, offlineWerPercent = 20.35),
        WhisperLanguage("mk", "Macedonian", "Македонски"),
        WhisperLanguage("mt", "Maltese", "Malti", supportsParakeet = true, offlineWerPercent = 20.46),
        WhisperLanguage("ms", "Malay", "Bahasa Melayu"),
        WhisperLanguage("mr", "Marathi", "मराठी"),
        WhisperLanguage("mi", "Maori", "Te Reo Māori"),
        WhisperLanguage("ne", "Nepali", "नेपाली"),
        WhisperLanguage("no", "Norwegian", "Norsk"),
        WhisperLanguage("fa", "Persian", "فارسی"),
        WhisperLanguage("pl", "Polish", "Polski", supportsParakeet = true, offlineWerPercent = 7.31),
        WhisperLanguage("pt", "Portuguese", "Português", supportsParakeet = true, offlineWerPercent = 4.76),
        WhisperLanguage("ro", "Romanian", "Română", supportsParakeet = true, offlineWerPercent = 12.44),
        WhisperLanguage("ru", "Russian", "Русский", supportsParakeet = true, offlineWerPercent = 5.51),
        WhisperLanguage("sr", "Serbian", "Српски"),
        WhisperLanguage("sk", "Slovak", "Slovenčina", supportsParakeet = true, offlineWerPercent = 8.82),
        WhisperLanguage("sl", "Slovenian", "Slovenščina", supportsParakeet = true, offlineWerPercent = 24.03),
        WhisperLanguage("es", "Spanish", "Español", supportsParakeet = true, offlineWerPercent = 3.45),
        WhisperLanguage("sw", "Swahili", "Kiswahili"),
        WhisperLanguage("sv", "Swedish", "Svenska", supportsParakeet = true, offlineWerPercent = 15.08),
        WhisperLanguage("tl", "Tagalog", "Tagalog"),
        WhisperLanguage("ta", "Tamil", "தமிழ்"),
        WhisperLanguage("th", "Thai", "ไทย"),
        WhisperLanguage("tr", "Turkish", "Türkçe"),
        WhisperLanguage("uk", "Ukrainian", "Українська", supportsParakeet = true, offlineWerPercent = 6.79),
        WhisperLanguage("ur", "Urdu", "اردو"),
        WhisperLanguage("vi", "Vietnamese", "Tiếng Việt"),
        WhisperLanguage("cy", "Welsh", "Cymraeg"),
    )

    val parakeetSupported: List<WhisperLanguage> = all.filter { it.supportsParakeet }

    private val byCode: Map<String, WhisperLanguage> = all.associateBy { it.code }

    fun getName(code: String): String? = byCode[code]?.englishName

    fun getLanguage(code: String): WhisperLanguage? = byCode[code]

    fun isParakeetSupported(code: String): Boolean = byCode[code]?.supportsParakeet == true

    fun requiresCloudTranscription(code: String): Boolean =
        (byCode[code]?.offlineWerPercent ?: 0.0) > 15.0

    fun isReliableOffline(code: String): Boolean =
        isParakeetSupported(code) && !requiresCloudTranscription(code)
}
