import com.github.triplet.gradle.androidpublisher.ReleaseStatus
import java.net.URI
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.hilt)
    alias(libs.plugins.ksp)
    alias(libs.plugins.gradle.play.publisher)
}

// Load local.properties
val localProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        load(localPropertiesFile.inputStream())
    }
}

val emptyConfigSentinel = "__AIDICTATION_EMPTY__"

// Origin serving both the sign-in page and the auth/profile API.
val AUTH_BACKEND_HOST = "aidictation.com"
val AUTH_BACKEND_ORIGIN = "https://$AUTH_BACKEND_HOST"

fun configValue(name: String, defaultValue: String = ""): String {
    val candidates = listOf(
        providers.gradleProperty(name).orNull,
        providers.environmentVariable(name).orNull,
        localProperties.getProperty(name)
    )
    candidates.forEach { candidate ->
        if (candidate == emptyConfigSentinel) return ""
        if (!candidate.isNullOrBlank()) return candidate
    }
    return defaultValue
}

fun buildConfigString(value: String): String {
    val escaped = buildString {
        value.forEach { character ->
            when (character) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> {
                    if (character.code < 0x20) {
                        append("\\u%04x".format(character.code))
                    } else {
                        append(character)
                    }
                }
            }
        }
    }
    return "\"$escaped\""
}

fun normalizedTranscriptionModel(value: String): String {
    return value.takeUnless {
        it.isBlank() || it.lowercase().contains("gpt-4o-transcribe")
    } ?: "openai/gpt-transcribe"
}

fun normalizedAuthWebUrl(value: String): String {
    val trimmed = value.trim().ifBlank { AUTH_BACKEND_ORIGIN + "/auth" }
    val uri = runCatching { URI(trimmed) }.getOrNull() ?: return trimmed
    val isLegacyAuthPage = uri.host?.lowercase() in setOf(
        "voicesinmyhead.co",
        "www.voicesinmyhead.co"
    ) && uri.path?.trimEnd('/') == "/auth"
    return if (isLegacyAuthPage) AUTH_BACKEND_ORIGIN + "/auth" else trimmed
}

// The sign-in page and the auth API are the same origin. AUTH_WEB_URL is
// rewritten to it above, so the API base has to default to it as well —
// otherwise a build with no SUPABASE_URL collects a session from one backend
// and sends it to another, which rejects it and drops the user to signed-out.
fun normalizedAuthApiUrl(value: String, authWebUrl: String): String {
    val trimmed = value.trim().ifBlank { AUTH_BACKEND_ORIGIN }
    val apiHost = runCatching { URI(trimmed).host?.lowercase() }.getOrNull()
    val authHost = runCatching { URI(authWebUrl).host?.lowercase() }.getOrNull()
    if (apiHost != null && authHost != null && apiHost != authHost &&
        (apiHost == AUTH_BACKEND_HOST || authHost == AUTH_BACKEND_HOST)
    ) {
        throw org.gradle.api.GradleException(
            "AUTH_WEB_URL host ($authHost) and SUPABASE_URL host ($apiHost) point at " +
                "different backends; sessions minted by one are rejected by the other."
        )
    }
    return trimmed
}

fun productionPaymentLink(value: String): String {
    val uri = runCatching { URI(value) }.getOrNull() ?: return ""
    val lowered = value.lowercase()
    val hasPlaceholder = listOf("your_", "replace_me", "placeholder", "example.com", "changeme")
        .any(lowered::contains)
    return value.takeIf {
        uri.scheme == "https" &&
            uri.host == "buy.stripe.com" &&
            !uri.path.isNullOrBlank() &&
            !uri.path.lowercase().startsWith("/test_") &&
            !hasPlaceholder
    }.orEmpty()
}

fun playReleaseStatus(value: String): ReleaseStatus {
    return when (value.trim().lowercase().replace("-", "_")) {
        "", "completed" -> ReleaseStatus.COMPLETED
        "draft" -> ReleaseStatus.DRAFT
        "halted" -> ReleaseStatus.HALTED
        "inprogress", "in_progress" -> ReleaseStatus.IN_PROGRESS
        else -> throw org.gradle.api.GradleException(
            "Unsupported PLAY_RELEASE_STATUS '$value'. Use completed, draft, halted, or inProgress."
        )
    }
}

val packageOfflineModels = configValue("PACKAGE_OFFLINE_MODELS", "false").toBooleanStrictOrNull() ?: false
val parakeetOnDemandModelUrl = configValue(
    "PARAKEET_ON_DEMAND_MODEL_URL",
    "https://github.com/writingmate/aidictation/releases/download/android-parakeet-assets-v3/AIDictation-Parakeet-Assets-v3.zip"
)
val parakeetOnDemandModelSha256 = configValue(
    "PARAKEET_ON_DEMAND_MODEL_SHA256",
    "b0ba6367c660c9fb5b9cc711ae35dc4bb96b8ebee199a58a7e8b680acc169824"
)
val stripePaymentLink = productionPaymentLink(configValue("STRIPE_PAYMENT_LINK"))
val stripePaymentLinkMonthly = productionPaymentLink(configValue("STRIPE_PAYMENT_LINK_MONTHLY"))
    .ifBlank { stripePaymentLink }
val stripePaymentLinkAnnual = productionPaymentLink(configValue("STRIPE_PAYMENT_LINK_ANNUAL"))
val stripePaymentLinkLifetime = productionPaymentLink(configValue("STRIPE_PAYMENT_LINK_LIFETIME"))
val transcriptionModel = normalizedTranscriptionModel(configValue("TRANSCRIPTION_MODEL"))
val authWebUrl = normalizedAuthWebUrl(configValue("AUTH_WEB_URL"))
val authApiUrl = normalizedAuthApiUrl(configValue("SUPABASE_URL"), authWebUrl)
// The Cloudflare backend authenticates from the bearer token alone and ignores
// this header, but the client treats a blank value as "auth not configured".
val authApiKey = configValue("SUPABASE_ANON_KEY").ifBlank {
    if (runCatching { URI(authApiUrl).host?.lowercase() }.getOrNull() == AUTH_BACKEND_HOST) {
        "public-anon-key"
    } else {
        ""
    }
}

android {
    namespace = "com.whispermate.aidictation"
    compileSdk = 36

    signingConfigs {
        create("release") {
            storeFile = rootProject.file("release.keystore")
            storePassword = configValue("KEYSTORE_PASSWORD")
            keyAlias = configValue("KEY_ALIAS", "release")
            keyPassword = configValue("KEY_PASSWORD")
        }
    }

    defaultConfig {
        applicationId = "com.aidictation.app"
        minSdk = 26
        targetSdk = 36
        versionCode = configValue("VERSION_CODE", "1037").toInt()
        versionName = configValue("VERSION_NAME", "0.0.39")

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // API keys from local.properties (do not commit). Defaults mirror the Mac
        // app, which ships with Writingmate AI as the default transcription provider
        // routing Groq Whisper through the Writingmate proxy unless a custom
        // endpoint is set in local.properties.
        buildConfigField("String", "TRANSCRIPTION_API_KEY", buildConfigString(configValue("TRANSCRIPTION_API_KEY")))
        buildConfigField("String", "TRANSCRIPTION_ENDPOINT", buildConfigString(configValue("TRANSCRIPTION_ENDPOINT", "https://writingmate.ai/api/openai/v1/audio/transcriptions")))
        buildConfigField("String", "TRANSCRIPTION_MODEL", buildConfigString(transcriptionModel))
        buildConfigField("String", "PARAKEET_RUNTIME", buildConfigString(configValue("PARAKEET_RUNTIME")))
        buildConfigField("boolean", "PACKAGE_OFFLINE_MODELS", packageOfflineModels.toString())
        buildConfigField("String", "PARAKEET_ON_DEMAND_MODEL_URL", buildConfigString(parakeetOnDemandModelUrl))
        buildConfigField("String", "PARAKEET_ON_DEMAND_MODEL_SHA256", buildConfigString(parakeetOnDemandModelSha256))

        // Writingmate post-processing, matching the macOS app's
        // AIDictationPostProcessing* secrets.
        buildConfigField("String", "AIDICTATION_POST_PROCESSING_KEY", buildConfigString(configValue("AIDICTATION_POST_PROCESSING_KEY")))
        buildConfigField("String", "AIDICTATION_POST_PROCESSING_ENDPOINT", buildConfigString(configValue("AIDICTATION_POST_PROCESSING_ENDPOINT", "https://writingmate.ai/api/openai/v1/chat/completions")))
        buildConfigField("String", "AIDICTATION_POST_PROCESSING_MODEL", buildConfigString(configValue("AIDICTATION_POST_PROCESSING_MODEL", "openai/gpt-oss-20b")))

        // Auth, usage, and purchase links. Android uses the same web auth and
        // Stripe checkout flow as the macOS app; empty values leave those entry
        // points disabled in local builds.
        buildConfigField("String", "SUPABASE_URL", buildConfigString(authApiUrl))
        buildConfigField("String", "SUPABASE_ANON_KEY", buildConfigString(authApiKey))
        buildConfigField("String", "AUTH_WEB_URL", buildConfigString(authWebUrl))
        // Native Google sign-in (Credential Manager). The web (server) OAuth client ID
        // that the auth backend's Google provider is configured with; blank hides the
        // "Continue with Google" entry point.
        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", buildConfigString(configValue("GOOGLE_WEB_CLIENT_ID")))
        buildConfigField("String", "STRIPE_PAYMENT_LINK", buildConfigString(stripePaymentLink))
        buildConfigField("String", "STRIPE_PAYMENT_LINK_MONTHLY", buildConfigString(stripePaymentLinkMonthly))
        buildConfigField("String", "STRIPE_PAYMENT_LINK_ANNUAL", buildConfigString(stripePaymentLinkAnnual))
        buildConfigField("String", "STRIPE_PAYMENT_LINK_LIFETIME", buildConfigString(stripePaymentLinkLifetime))
        buildConfigField(
            "String",
            "SENTRY_DSN",
            buildConfigString(
                configValue(
                    "SENTRY_DSN",
                    "https://83e30144be9d9cdf212136edc6962f26@o4505732389470208.ingest.us.sentry.io/4512029576921088"
                )
            )
        )
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    androidResources {
        noCompress += listOf("onnx", "tflite", "txt", "json")
    }

    if (packageOfflineModels) {
        sourceSets.getByName("main").assets.srcDir(rootProject.file("parakeetpack/src/main/assets"))
    } else {
        // Play-delivered on-device model pack for Parakeet.
        assetPacks.add(":parakeetpack")
    }
}

play {
    val credentialsPath = configValue("PLAY_SERVICE_ACCOUNT_CREDENTIALS", "")
    val releaseNameOverride = configValue("PLAY_RELEASE_NAME", "")
    if (credentialsPath.isNotBlank()) {
        serviceAccountCredentials.set(file(credentialsPath))
    }
    track.set(configValue("PLAY_TRACK", "internal"))
    defaultToAppBundles.set(true)
    releaseStatus.set(playReleaseStatus(configValue("PLAY_RELEASE_STATUS", "completed")))
    releaseName.set(
        releaseNameOverride.ifBlank {
            "AIDictation Android ${android.defaultConfig.versionName} (${android.defaultConfig.versionCode})"
        }
    )
}

dependencies {
    // Core Android
    implementation(libs.androidx.core.ktx)
    implementation(libs.coil.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)

    // Compose
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.navigation.compose)

    // Hilt
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.hilt.navigation.compose)

    // Room
    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)

    // DataStore
    implementation(libs.datastore.preferences)

    // Networking
    implementation(libs.retrofit)
    implementation(libs.retrofit.moshi)
    implementation(libs.androidx.credentials)
    implementation(libs.androidx.credentials.play.services.auth)
    implementation(libs.google.identity.googleid)
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging)
    implementation(libs.moshi)
    ksp(libs.moshi.kotlin)

    // Coroutines
    implementation(libs.coroutines.core)
    implementation(libs.coroutines.android)

    // Security
    implementation(libs.security.crypto)

    // Crash reporting
    implementation(libs.sentry.android)

    // ONNX Runtime for Silero VAD
    implementation(libs.onnx.runtime)
    implementation(libs.play.asset.delivery)
    implementation(libs.litert)

    // Debug
    debugImplementation(libs.androidx.ui.tooling)

    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("androidx.test:core-ktx:1.6.1")
    testImplementation("androidx.room:room-testing:2.6.1")
    testImplementation("org.robolectric:robolectric:4.13")
}
