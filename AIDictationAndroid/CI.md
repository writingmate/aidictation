# Android CI

The `.github/workflows/android-build.yml` pipeline builds the
`AIDictationAndroid` Gradle project on pushes to `main`, Android release
tags, and PRs into `main` that touch the Android source tree or Android
release workflows. Only an `android-v<versionName>` tag runs the signed
release job and publishes APK/AAB assets to a GitHub Release.

The GitHub release job does not rely on Git LFS bandwidth for Parakeet
weights. It checks out source with LFS disabled, downloads
`AIDictation-Parakeet-Assets-v3.zip` from the
`android-parakeet-assets-v3` GitHub Release for the Play asset pack, builds
a small sideload APK that downloads Parakeet only when the user enables
on-device transcription, and builds the Play AAB with the `parakeet_v3_pack`
asset pack.

`.github/workflows/android-play-release.yml` publishes the signed release
AAB to Google Play from the same `android-v<versionName>` tag. Tag pushes are
hard-coded to upload a completed release to the `internal` track; repository
variables cannot redirect a tag to production. The workflow uses the checked-in
`versionName` and `versionCode`, and rejects tags that do not point at a commit
reachable from `origin/main`.

The tag-triggered Android build uploads private GitHub Actions artifacts and
creates or updates only a draft GitHub release. After the internal artifact has
passed Android 16 device checks and Play pre-launch verification, manually run
the Play release workflow for the same tag with `publish_mode=promote`,
`promote_from_track=internal`, and `play_track=production`. Production uploads
are rejected; production is promotion-only. Set `publish_github_release=true`
to publish the checksummed draft GitHub release only after the Play promotion
succeeds.

Google Play version codes are monotonic across every track. Because an earlier
internal upload used version code `1007`, Android release version codes must be
greater than `1007`.

The Play Console package name is `com.aidictation.app`. The Kotlin/Android
namespace remains `com.whispermate.aidictation`, but `applicationId` must stay
aligned with `com.aidictation.app` for Play uploads.

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
| `SUPABASE_URL` | Optional dedicated Android override for Supabase auth/profile requests. |
| `SUPABASE_ANON_KEY` | Optional dedicated Android override for the Supabase anon key. |
| `AUTH_WEB_URL` | Optional dedicated Android override for the hosted auth page. Defaults to `https://aidictation.com/auth`. |
| `STRIPE_PAYMENT_LINK` | Optional default Stripe checkout link. |
| `STRIPE_PAYMENT_LINK_MONTHLY` | Optional monthly checkout link. |
| `STRIPE_PAYMENT_LINK_ANNUAL` | Optional annual checkout link. |
| `STRIPE_PAYMENT_LINK_LIFETIME` | Optional lifetime checkout link. |
| `SECRETS_PLIST` | Optional. Base64-encoded Mac `Secrets.plist` — the same secret used by `release-macos.yml`. When present, the workflow extracts `CustomTranscription*`, `AIDictationPostProcessing*`, `SUPABASE_*`, `AUTH_WEB_URL`, and `STRIPE_PAYMENT_LINK*` so both platforms ship with the same Writingmate auth and billing configuration. |

### Release signing (only needed for tagged Android releases)

| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.keystore` of the upload keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Maps to `KEYSTORE_PASSWORD` in `local.properties` |
| `ANDROID_KEY_ALIAS` | Maps to `KEY_ALIAS` in `local.properties` (default `release`) |
| `ANDROID_KEY_PASSWORD` | Maps to `KEY_PASSWORD` in `local.properties` |

### Google Play releases

| Secret | Purpose |
|---|---|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64` | Preferred. Base64-encoded Google Play service account JSON. |
| `ANDROID_PUBLISHER_CREDENTIALS` | Optional fallback. Raw Google Play service account JSON used by Gradle Play Publisher. |

Before the workflow can publish, create the app once in Play Console and
upload the first signed AAB manually if the package has never been uploaded.
Then enable the Android Publisher API, link the Play Console account to the
Google Cloud project, and grant the service account release access to this app.
Production releases can still be held by Google review or Play Console managed
publishing settings.

## Adding secrets

```
# Either: dedicated Android secret
gh secret set TRANSCRIPTION_API_KEY --repo writingmate/aidictation

# Or: reuse the Mac Secrets.plist (base64-encoded) — Writingmate,
# Supabase auth, and Stripe values are pulled automatically.
base64 -w0 Secrets.plist | gh secret set SECRETS_PLIST --repo writingmate/aidictation

gh secret set AIDICTATION_POST_PROCESSING_KEY --repo writingmate/aidictation
gh secret set SUPABASE_URL --repo writingmate/aidictation
gh secret set SUPABASE_ANON_KEY --repo writingmate/aidictation
gh secret set AUTH_WEB_URL --repo writingmate/aidictation
gh secret set STRIPE_PAYMENT_LINK_MONTHLY --repo writingmate/aidictation
base64 -w0 release.keystore | gh secret set ANDROID_KEYSTORE_BASE64 --repo writingmate/aidictation
gh secret set ANDROID_KEYSTORE_PASSWORD --repo writingmate/aidictation
gh secret set ANDROID_KEY_ALIAS         --repo writingmate/aidictation
gh secret set ANDROID_KEY_PASSWORD      --repo writingmate/aidictation

base64 -w0 google-play-service-account.json | gh secret set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 --repo writingmate/aidictation
```
