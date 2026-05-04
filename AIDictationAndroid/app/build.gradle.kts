import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.hilt)
    alias(libs.plugins.ksp)
}

// Load local.properties
val localProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        load(localPropertiesFile.inputStream())
    }
}

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
        applicationId = "com.whispermate.aidictation"
        minSdk = 26
        targetSdk = 35
        versionCode = 4
        versionName = "0.0.4"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // API keys from local.properties (do not commit). Defaults mirror the Mac
        // app, which ships with Writingmate AI as the default transcription provider
        // routing Groq Whisper through the Writingmate proxy unless a custom
        // endpoint is set in local.properties.
        buildConfigField("String", "TRANSCRIPTION_API_KEY", "\"${localProperties.getProperty("TRANSCRIPTION_API_KEY", "")}\"")
        buildConfigField("String", "TRANSCRIPTION_ENDPOINT", "\"${localProperties.getProperty("TRANSCRIPTION_ENDPOINT", "https://writingmate.ai/api/openai/v1/audio/transcriptions")}\"")
        buildConfigField("String", "TRANSCRIPTION_MODEL", "\"${localProperties.getProperty("TRANSCRIPTION_MODEL", "groq/whisper-large-v3-turbo")}\"")

        // Writingmate post-processing, matching the macOS app's
        // AIDictationPostProcessing* secrets.
        buildConfigField("String", "AIDICTATION_POST_PROCESSING_KEY", "\"${localProperties.getProperty("AIDICTATION_POST_PROCESSING_KEY", "")}\"")
        buildConfigField("String", "AIDICTATION_POST_PROCESSING_ENDPOINT", "\"${localProperties.getProperty("AIDICTATION_POST_PROCESSING_ENDPOINT", "https://writingmate.ai/api/openai/v1/chat/completions")}\"")
        buildConfigField("String", "AIDICTATION_POST_PROCESSING_MODEL", "\"${localProperties.getProperty("AIDICTATION_POST_PROCESSING_MODEL", "openai/gpt-oss-20b")}\"")

        // Auth, usage, and purchase links. Android uses the same web auth and
        // Stripe checkout flow as the macOS app; empty values leave those entry
        // points disabled in local builds.
        buildConfigField("String", "SUPABASE_URL", "\"${localProperties.getProperty("SUPABASE_URL", "")}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${localProperties.getProperty("SUPABASE_ANON_KEY", "")}\"")
        buildConfigField("String", "AUTH_WEB_URL", "\"${localProperties.getProperty("AUTH_WEB_URL", "https://voicesinmyhead.co/auth")}\"")
        buildConfigField("String", "STRIPE_PAYMENT_LINK", "\"${localProperties.getProperty("STRIPE_PAYMENT_LINK", "")}\"")
        buildConfigField("String", "STRIPE_PAYMENT_LINK_MONTHLY", "\"${localProperties.getProperty("STRIPE_PAYMENT_LINK_MONTHLY", localProperties.getProperty("STRIPE_PAYMENT_LINK", ""))}\"")
        buildConfigField("String", "STRIPE_PAYMENT_LINK_ANNUAL", "\"${localProperties.getProperty("STRIPE_PAYMENT_LINK_ANNUAL", "")}\"")
        buildConfigField("String", "STRIPE_PAYMENT_LINK_LIFETIME", "\"${localProperties.getProperty("STRIPE_PAYMENT_LINK_LIFETIME", "")}\"")
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

    // Play-delivered on-device model pack for Parakeet.
    assetPacks.add(":parakeetpack")
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

    // Debug
    debugImplementation(libs.androidx.ui.tooling)
}
