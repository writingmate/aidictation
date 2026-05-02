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
        versionCode = 3
        versionName = "0.0.3"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // API keys from local.properties (do not commit). Defaults mirror the Mac
        // app, which ships with Writingmate AI as the default transcription provider
        // routing to groq/whisper-large-v3-turbo so a fresh install points at
        // Writingmate unless a custom endpoint is set in local.properties.
        buildConfigField("String", "TRANSCRIPTION_API_KEY", "\"${localProperties.getProperty("TRANSCRIPTION_API_KEY", "")}\"")
        buildConfigField("String", "TRANSCRIPTION_ENDPOINT", "\"${localProperties.getProperty("TRANSCRIPTION_ENDPOINT", "https://writingmate.ai/api/openai/v1/audio/transcriptions")}\"")
        buildConfigField("String", "TRANSCRIPTION_MODEL", "\"${localProperties.getProperty("TRANSCRIPTION_MODEL", "groq/whisper-large-v3-turbo")}\"")

        // LLM API for post-processing (Mac app defaults to Groq here).
        buildConfigField("String", "GROQ_API_KEY", "\"${localProperties.getProperty("GROQ_API_KEY", "")}\"")
        buildConfigField("String", "GROQ_ENDPOINT", "\"${localProperties.getProperty("GROQ_ENDPOINT", "https://api.groq.com/openai/v1/chat/completions")}\"")
        buildConfigField("String", "GROQ_MODEL", "\"${localProperties.getProperty("GROQ_MODEL", "openai/gpt-oss-20b")}\"")
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

    // Debug
    debugImplementation(libs.androidx.ui.tooling)
}
