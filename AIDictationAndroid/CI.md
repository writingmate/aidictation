# Android CI

The `.github/workflows/android-build.yml` pipeline builds the
`AIDictationAndroid` Gradle project on every push/PR that touches the
Android source tree.

## Required repository secrets

These are written into `local.properties` on the runner before Gradle
runs, matching the local-developer layout described in
`local.properties.template`.

### Authentication (API keys)

| Secret | Purpose |
|---|---|
| `TRANSCRIPTION_API_KEY` | OpenAI/Groq audio transcription key |
| `TRANSCRIPTION_ENDPOINT` | Optional override, defaults to OpenAI whisper endpoint |
| `TRANSCRIPTION_MODEL` | Optional override, defaults to `whisper-1` |
| `GROQ_API_KEY` | LLM key (word suggestions, cleanup) |
| `GROQ_ENDPOINT` | Optional override, defaults to Groq chat completions |
| `GROQ_MODEL` | Optional override, defaults to `openai/gpt-oss-20b` |

### Release signing (only needed for the `release` job on `main`)

| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.keystore` of the upload keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Maps to `KEYSTORE_PASSWORD` in `local.properties` |
| `ANDROID_KEY_ALIAS` | Maps to `KEY_ALIAS` in `local.properties` (default `release`) |
| `ANDROID_KEY_PASSWORD` | Maps to `KEY_PASSWORD` in `local.properties` |

## Adding secrets

```
gh secret set TRANSCRIPTION_API_KEY --repo writingmate/aidictation
gh secret set GROQ_API_KEY         --repo writingmate/aidictation
base64 -w0 release.keystore | gh secret set ANDROID_KEYSTORE_BASE64 --repo writingmate/aidictation
gh secret set ANDROID_KEYSTORE_PASSWORD --repo writingmate/aidictation
gh secret set ANDROID_KEY_ALIAS         --repo writingmate/aidictation
gh secret set ANDROID_KEY_PASSWORD      --repo writingmate/aidictation
```
