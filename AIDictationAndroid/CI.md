# Android CI

The `.github/workflows/android-build.yml` pipeline builds the
`AIDictationAndroid` Gradle project on every push/PR that touches the
Android source tree. A push to `main`, an `android-v*` tag, or a manual
workflow dispatch also runs the signed release job and publishes APK/AAB
assets to a GitHub Release named `android-v<versionName>`.

The GitHub release job does not rely on Git LFS bandwidth for Parakeet
weights. It checks out source with LFS disabled, downloads
`AIDictation-Parakeet-Assets-v3.zip` from the
`android-parakeet-assets-v3` GitHub Release for the Play asset pack, builds
a small sideload APK that downloads Parakeet only when the user enables
on-device transcription, and builds the Play AAB with the `parakeet_v3_pack`
asset pack.

`.github/workflows/android-play-dev.yml` is a manual dev-release workflow
that publishes the signed release AAB to a Google Play testing track
(`internal` by default). It is intended for Play Store tester installs,
including the on-demand `parakeet_v3_pack` asset pack. The workflow assigns
dev builds `versionCode = 1000 + GITHUB_RUN_NUMBER` so repeated internal
uploads do not collide with the checked-in production version.

## Required repository secrets

These are written into `local.properties` on the runner before Gradle
runs, matching the local-developer layout described in
`local.properties.template`.

### Authentication (API keys)

| Secret | Purpose |
|---|---|
| `TRANSCRIPTION_API_KEY` | Writingmate transcription key. Sent as `Authorization: Bearer …`. |
| `TRANSCRIPTION_ENDPOINT` | Optional override. Defaults to `https://writingmate.ai/api/openai/v1/audio/transcriptions` (matches the Mac app's `.custom` provider). |
| `TRANSCRIPTION_MODEL` | Optional override. Defaults to `groq/whisper-large-v3-turbo`. The workflow normalizes stale `gpt-4o-transcribe` values from secrets to this Android-supported model. |
| `PARAKEET_RUNTIME` | Local prototype runtime. Leave empty for cloud releases; the app's Settings switch enables ONNX Parakeet at runtime after downloading weights. |
| `PACKAGE_OFFLINE_MODELS` | Local-debug sideload mode. Release APKs leave this `false` and download Parakeet from inside the app only when requested. |
| `PARAKEET_ON_DEMAND_MODEL_URL` | Optional override for the in-app Parakeet archive download URL. Defaults to the `android-parakeet-assets-v3` GitHub Release asset. |
| `PARAKEET_ON_DEMAND_MODEL_SHA256` | Optional override for the in-app Parakeet archive checksum. |
| `AIDICTATION_POST_PROCESSING_KEY` | Writingmate post-processing key for suggestions, commands, and cleanup. |
| `AIDICTATION_POST_PROCESSING_ENDPOINT` | Optional override. Defaults to `https://writingmate.ai/api/openai/v1/chat/completions`. |
| `AIDICTATION_POST_PROCESSING_MODEL` | Optional override. Defaults to `openai/gpt-oss-20b`. |
| `SECRETS_PLIST` | Optional. Base64-encoded Mac `Secrets.plist` — the same secret used by `release-macos.yml`. When present, the workflow extracts `CustomTranscription*` and `AIDictationPostProcessing*` so both platforms ship with the same Writingmate credentials. |

### Release signing (only needed for the `release` job on `main`)

| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.keystore` of the upload keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Maps to `KEYSTORE_PASSWORD` in `local.properties` |
| `ANDROID_KEY_ALIAS` | Maps to `KEY_ALIAS` in `local.properties` (default `release`) |
| `ANDROID_KEY_PASSWORD` | Maps to `KEY_PASSWORD` in `local.properties` |

### Google Play dev releases

| Secret | Purpose |
|---|---|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64` | Preferred. Base64-encoded Google Play service account JSON. |
| `ANDROID_PUBLISHER_CREDENTIALS` | Optional fallback. Raw Google Play service account JSON used by Gradle Play Publisher. |

Before the workflow can publish, create the app once in Play Console and
upload the first signed AAB manually if the package has never been uploaded.
Then enable the Android Publisher API, link the Play Console account to the
Google Cloud project, and grant the service account release access to this app.

## Adding secrets

```
# Either: dedicated Android secret
gh secret set TRANSCRIPTION_API_KEY --repo writingmate/aidictation

# Or: reuse the Mac Secrets.plist (base64-encoded) — Writingmate
# transcription and post-processing keys are pulled automatically.
base64 -w0 Secrets.plist | gh secret set SECRETS_PLIST --repo writingmate/aidictation

gh secret set AIDICTATION_POST_PROCESSING_KEY --repo writingmate/aidictation
base64 -w0 release.keystore | gh secret set ANDROID_KEYSTORE_BASE64 --repo writingmate/aidictation
gh secret set ANDROID_KEYSTORE_PASSWORD --repo writingmate/aidictation
gh secret set ANDROID_KEY_ALIAS         --repo writingmate/aidictation
gh secret set ANDROID_KEY_PASSWORD      --repo writingmate/aidictation

base64 -w0 google-play-service-account.json | gh secret set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 --repo writingmate/aidictation
```
