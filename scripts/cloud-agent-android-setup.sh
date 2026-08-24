#!/usr/bin/env bash
# Idempotent Cloud Agent setup for the AIDictationAndroid Gradle project.
#
# Prepares a Linux (x86_64 Debian/Ubuntu) machine to build and test the Android
# app the same way `.github/workflows/android-build.yml` does: JDK 17, the
# Android SDK (platform-tools, platforms;android-36, build-tools;35.0.0), and a
# generated local.properties. Safe to run repeatedly; every step is guarded so a
# warm snapshot re-runs it as a fast no-op.
#
# The macOS/iOS (Xcode) and Windows (.NET desktop) targets cannot be built on
# Linux, so this environment scopes to the Android client.
set -euo pipefail

JDK_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
ANDROID_SDK_DIR="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
CMDLINE_TOOLS_VERSION="14742923"
ANDROID_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/AIDictationAndroid"

log() { printf '\n=== %s ===\n' "$*"; }

# 1. JDK 17 (matches the Android CI toolchain; AGP 8.10 requires JDK 17+).
if [ ! -x "$JDK_HOME/bin/java" ]; then
  log "Installing JDK 17"
  sudo apt-get update -qq
  sudo apt-get install -y -qq openjdk-17-jdk-headless unzip wget
else
  log "JDK 17 already present"
fi

# 2. Android SDK command-line tools + required packages.
if [ ! -x "$ANDROID_SDK_DIR/cmdline-tools/latest/bin/sdkmanager" ]; then
  log "Installing Android command-line tools"
  mkdir -p "$ANDROID_SDK_DIR/cmdline-tools"
  tmp_zip="$(mktemp --suffix=.zip)"
  wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" -O "$tmp_zip"
  rm -rf "$ANDROID_SDK_DIR/cmdline-tools/latest" "$ANDROID_SDK_DIR/cmdline-tools/cmdline-tools"
  unzip -q "$tmp_zip" -d "$ANDROID_SDK_DIR/cmdline-tools"
  mv "$ANDROID_SDK_DIR/cmdline-tools/cmdline-tools" "$ANDROID_SDK_DIR/cmdline-tools/latest"
  rm -f "$tmp_zip"
else
  log "Android command-line tools already present"
fi

export ANDROID_HOME="$ANDROID_SDK_DIR"
export ANDROID_SDK_ROOT="$ANDROID_SDK_DIR"
export JAVA_HOME="$JDK_HOME"
SDKMANAGER="$ANDROID_SDK_DIR/cmdline-tools/latest/bin/sdkmanager"

log "Accepting SDK licenses and installing SDK packages"
yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
"$SDKMANAGER" "platform-tools" "platforms;android-36" "build-tools;35.0.0" >/dev/null

# 3. Point Gradle at JDK 17 regardless of the machine's default `java`.
mkdir -p "$HOME/.gradle"
if ! grep -qs "^org.gradle.java.home=" "$HOME/.gradle/gradle.properties" 2>/dev/null; then
  log "Pinning Gradle to JDK 17"
  echo "org.gradle.java.home=$JDK_HOME" >> "$HOME/.gradle/gradle.properties"
fi

# 4. Generate local.properties (git-ignored) from CI-provided env vars when set,
#    otherwise fall back to the public defaults used for unconfigured debug
#    builds. Never overwrites an existing developer-provided file.
LOCAL_PROPS="$ANDROID_PROJECT_DIR/local.properties"
if [ ! -f "$LOCAL_PROPS" ]; then
  log "Writing local.properties"
  cat > "$LOCAL_PROPS" <<EOF
sdk.dir=$ANDROID_SDK_DIR
TRANSCRIPTION_API_KEY=${TRANSCRIPTION_API_KEY:-}
TRANSCRIPTION_ENDPOINT=${TRANSCRIPTION_ENDPOINT:-https://writingmate.ai/api/openai/v1/audio/transcriptions}
TRANSCRIPTION_MODEL=${TRANSCRIPTION_MODEL:-groq/whisper-large-v3-turbo}
PARAKEET_RUNTIME=
PACKAGE_OFFLINE_MODELS=false
AIDICTATION_POST_PROCESSING_KEY=${AIDICTATION_POST_PROCESSING_KEY:-}
AIDICTATION_POST_PROCESSING_ENDPOINT=${AIDICTATION_POST_PROCESSING_ENDPOINT:-https://writingmate.ai/api/openai/v1/chat/completions}
AIDICTATION_POST_PROCESSING_MODEL=${AIDICTATION_POST_PROCESSING_MODEL:-openai/gpt-oss-20b}
SUPABASE_URL=${SUPABASE_URL:-}
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY:-}
AUTH_WEB_URL=${AUTH_WEB_URL:-https://aidictation.com/auth}
EOF
else
  log "local.properties already present; leaving it untouched"
fi

# 5. Warm the Gradle wrapper distribution and dependency cache so the first
#    interactive build is fast. Resolves dependencies without building.
log "Warming Gradle"
( cd "$ANDROID_PROJECT_DIR" && chmod +x gradlew && ./gradlew --no-daemon help >/dev/null )

log "Android environment ready"
