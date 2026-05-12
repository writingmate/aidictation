# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.kts.

# Keep Moshi adapters
-keepclassmembers class * {
    @com.squareup.moshi.FromJson <methods>;
    @com.squareup.moshi.ToJson <methods>;
}

# Keep Retrofit interfaces
-keepattributes Signature
-keepattributes Exceptions

# Keep Room entities
-keep class com.whispermate.aidictation.data.local.entity.** { *; }

# Keep domain models
-keep class com.whispermate.aidictation.domain.model.** { *; }

# Keep ONNX Runtime classes
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }

# LiteRT JNI looks up exception/status classes by their original names.
-keep class com.google.ai.edge.litert.** { *; }
-keepclassmembers class com.google.ai.edge.litert.** { *; }

# Tink (via androidx.security.crypto) references errorprone annotations at
# compile time; they're not shipped at runtime, so tell R8 to ignore them.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn com.google.crypto.tink.**
-keep class com.google.crypto.tink.** { *; }
