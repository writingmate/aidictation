# Android CI

The `.github/workflows/android-build.yml` pipeline builds the
`AIDictationAndroid` Gradle project on every push/PR that touches the
Android source tree. A push to `main`, an `android-v*` tag, or a manual
workflow dispatch also runs the signed release job and publishes APK/AAB
assets to a GitHub Release named `android-v<versionName>`.

## Required repository secrets

These are written into `local.properties` on the runner before Gradle
runs, matching the local-developer layout described in
`local.properties.template`.

### Authentication (API keys)

| Secret | Purpose |
|---|---|
| `TRANSCRIPTION_API_KEY` | Writingmate transcription key. Sent as `Authorization: Bearer …`. |
| `TRANSCRIPTION_ENDPOINT` | Optional override. Defaults to `https://writingmate.ai/api/openai/v1/audio/transcriptions` (matches the Mac app's `.custom` provider). |
| `TRANSCRIPTION_MODEL` | Optional override. Defaults to `groq/whisper-large-v3-turbo`. |
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
```
