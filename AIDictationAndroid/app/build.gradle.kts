import com.github.triplet.gradle.androidpublisher.ReleaseStatus
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

fun configValue(name: String, defaultValue: String = ""): String {
    return providers.gradleProperty(name).orNull
        ?: providers.environmentVariable(name).orNull
        ?: localProperties.getProperty(name, defaultValue)
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

android {
    namespace = "com.whispermate.aidictation"
    compileSdk = 35

    signingConfigs {
        create("release") {
            storeFile = rootProject.file("release.keystore")
            storePassword = localProperties.getProperty("KEYSTORE_PASSWORD", "")
            keyAlias = localProperties.getProperty("KEY_ALIAS", "release")
            keyPassword = localProperties.getProperty("KEY_PASSWORD", "")
        }
    }

    defaultConfig {
        applicationId = "com.aidictation.app"
        minSdk = 26
        targetSdk = 35
        versionCode = configValue("VERSION_CODE", "1017").toInt()
        versionName = configValue("VERSION_NAME", "0.0.20")

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // API keys from local.properties (do not commit). Defaults mirror the Mac
        // app, which ships with Writingmate AI as the default transcription provider
        // routing Groq Whisper through the Writingmate proxy unless a custom
        // endpoint is set in local.properties.
        buildConfigField("String", "TRANSCRIPTION_API_KEY", "\"${configValue("TRANSCRIPTION_API_KEY", "")}\"")
        buildConfigField("String", "TRANSCRIPTION_ENDPOINT", "\"${configValue("TRANSCRIPTION_ENDPOINT", "https://writingmate.ai/api/openai/v1/audio/transcriptions")}\"")
        buildConfigField("String", "TRANSCRIPTION_MODEL", "\"${configValue("TRANSCRIPTION_MODEL", "groq/whisper-large-v3-turbo")}\"")
        buildConfigField("String", "PARAKEET_RUNTIME", "\"${configValue("PARAKEET_RUNTIME", "")}\"")
        buildConfigField("boolean", "PACKAGE_OFFLINE_MODELS", packageOfflineModels.toString())
        buildConfigField("String", "PARAKEET_ON_DEMAND_MODEL_URL", "\"$parakeetOnDemandModelUrl\"")
        buildConfigField("String", "PARAKEET_ON_DEMAND_MODEL_SHA256", "\"$parakeetOnDemandModelSha256\"")

        // Writingmate post-processing, matching the macOS app's
        // AIDictationPostProcessing* secrets.
        buildConfigField("String", "AIDICTATION_POST_PROCESSING_KEY", "\"${configValue("AIDICTATION_POST_PROCESSING_KEY", "")}\"")
        buildConfigField("String", "AIDICTATION_POST_PROCESSING_ENDPOINT", "\"${configValue("AIDICTATION_POST_PROCESSING_ENDPOINT", "https://writingmate.ai/api/openai/v1/chat/completions")}\"")
        buildConfigField("String", "AIDICTATION_POST_PROCESSING_MODEL", "\"${configValue("AIDICTATION_POST_PROCESSING_MODEL", "openai/gpt-oss-20b")}\"")

        // Auth, usage, and purchase links. Android uses the same web auth and
        // Stripe checkout flow as the macOS app; empty values leave those entry
        // points disabled in local builds.
        buildConfigField("String", "SUPABASE_URL", "\"${configValue("SUPABASE_URL", "")}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${configValue("SUPABASE_ANON_KEY", "")}\"")
        buildConfigField("String", "AUTH_WEB_URL", "\"${configValue("AUTH_WEB_URL", "https://voicesinmyhead.co/auth")}\"")
        buildConfigField("String", "STRIPE_PAYMENT_LINK", "\"${configValue("STRIPE_PAYMENT_LINK", "")}\"")
        buildConfigField("String", "STRIPE_PAYMENT_LINK_MONTHLY", "\"${configValue("STRIPE_PAYMENT_LINK_MONTHLY", configValue("STRIPE_PAYMENT_LINK", ""))}\"")
        buildConfigField("String", "STRIPE_PAYMENT_LINK_ANNUAL", "\"${configValue("STRIPE_PAYMENT_LINK_ANNUAL", "")}\"")
        buildConfigField("String", "STRIPE_PAYMENT_LINK_LIFETIME", "\"${configValue("STRIPE_PAYMENT_LINK_LIFETIME", "")}\"")
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
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging)
    implementation(libs.moshi)
    ksp(libs.moshi.kotlin)

    // Coroutines
    implementation(libs.coroutines.core)
    implementation(libs.coroutines.android)

    // Security
    implementation(libs.security.crypto)

    // ONNX Runtime for Silero VAD
    implementation(libs.onnx.runtime)
    implementation(libs.play.asset.delivery)
    implementation(libs.litert)

    // Debug
    debugImplementation(libs.androidx.ui.tooling)
}
