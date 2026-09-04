# Sentry crash and high-value error reporting

AI Dictation reports crashes and a small set of handled failures to existing
chatlabs Sentry projects. Do not create new projects.

| Platform | Sentry project | DSN source |
|---|---|---|
| macOS | `ai-dictation-macos` | `Secrets.plist` keys `SENTRY_DSN_MACOS`, `SENTRY_DSN`, or `SentryDSN`. Fallback is the `ai-dictation-macos` DSN. |
| iOS | `apple-ios` | `Secrets.plist` keys `SENTRY_DSN_IOS`, `SENTRY_DSN`, or `SentryDSN`. Fallback is the `apple-ios` DSN. |
| Windows | `ai-dictation-windows` | `SENTRY_DSN` environment / MSBuild `AssemblyMetadata`, then `BuildConfig.SentryDsn`. Fallback is the `ai-dictation-windows` DSN. |
| Android | `ai-dictation-android` | `SENTRY_DSN` from Gradle properties, environment, or `local.properties` (`BuildConfig.SENTRY_DSN`). Fallback is the `ai-dictation-android` DSN. |

Client DSNs are expected to ship in the app. Override them only when pointing a
local or CI build at a different project.

## Environment / CI variables

| Variable | Used by |
|---|---|
| `SENTRY_DSN` | All platforms (generic override) |
| `SENTRY_DSN_MACOS` | Apple `Secrets.plist` generation for macOS |
| `SENTRY_DSN_IOS` | Apple `Secrets.plist` generation for iOS |
| `SentryDSN` | Alternate Apple secrets key (legacy) |

`ci_scripts/write_secrets_plist.sh` writes the Apple keys from those env vars.
Android CI can set `SENTRY_DSN` in `local.properties` the same way as other
build-config secrets. Windows CI can set `SENTRY_DSN` as an MSBuild / env value.

## What is captured

- Uncaught crashes / unhandled exceptions on every platform
- Light tracing (`tracesSampleRate = 0.05`). No session replay or profiling.
- High-value handled failures, tagged with `platform` and `feature`:
  - `transcription`: finalize / recognition failures ("Transcription stopped")
  - `auth`: sign-in and session stickiness failures
  - `text_insert`: paste / accessibility insert failures (especially Windows)

`DebugLog.error` does not report to Sentry. Only explicit `CrashReporter` /
`SentryTelemetry` / `HighValueErrorSink` calls at those sites do. On Windows,
InsertTest and RecoveryContract compile production services through a no-op
`HighValueErrorSink` so they do not need the Sentry package.

Release names come from the app version / build number. Environment is `debug`
in debug builds and `production` otherwise.

## How to verify

1. Build a debug app for the platform under test with its DSN present
   (fallback DSNs are enough).
2. Force a handled failure, or temporarily add a test `captureMessage` /
   `captureException` on launch.
3. Confirm the event in the matching project:
   - macOS → https://chatlabs.sentry.io/projects/ai-dictation-macos/
   - Windows → https://chatlabs.sentry.io/projects/ai-dictation-windows/
   - Android → https://chatlabs.sentry.io/projects/ai-dictation-android/
   - iOS → https://chatlabs.sentry.io/projects/apple-ios/
4. Check tags: `platform` is `macos` / `ios` / `windows` / `android`, and
   high-value events include `feature=transcription|auth|text_insert`.
5. Confirm the release string matches the app version you just built.

Do not add Crashlytics. Sentry is the only crash reporter.
