# Xcode Cloud

Xcode Cloud runs `ci_pre_xcodebuild.sh` before the archive build. The script creates the ignored development file `Whishpermate/Whispermate/Secrets.plist` from Xcode Cloud environment variables, without printing secret values.

Set these secret variables in Xcode Cloud for deployable builds:

- `AUTH_WEB_URL`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `CUSTOM_TRANSCRIPTION_ENDPOINT`
- `CUSTOM_TRANSCRIPTION_REALTIME_ENDPOINT` when `CUSTOM_TRANSCRIPTION_TRANSPORT=realtime`
- `CUSTOM_TRANSCRIPTION_MODEL`
- `CUSTOM_TRANSCRIPTION_KEY`
- `AIDICTATION_POST_PROCESSING_ENDPOINT`
- `AIDICTATION_POST_PROCESSING_KEY`

Optional:

- `OPENAI_TRANSCRIPTION_KEY` or `OPENAI_API_KEY`
- `CUSTOM_TRANSCRIPTION_REALTIME_MODEL`
- `CUSTOM_TRANSCRIPTION_TRANSPORT=batch|realtime`
- `STRIPE_PAYMENT_LINK`
- `STRIPE_PAYMENT_LINK_MONTHLY`
- `STRIPE_PAYMENT_LINK_ANNUAL`
- `STRIPE_PAYMENT_LINK_LIFETIME`
- `AIDICTATION_REQUIRE_SECRETS=1`

Local builds still use `Whishpermate/Whispermate/Secrets.plist` when it exists.

## GitHub Actions App Store Connect Upload

The `iOS App Store Connect` workflow archives and uploads the iOS app on every push to `main`. Configure these repository secrets before enabling the workflow:

- `APP_STORE_CONNECT_API_KEY_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_KEY_ID`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64` or `APP_STORE_CONNECT_API_KEY_P8`

Use the same app configuration secrets listed above for Xcode Cloud. The workflow sets the iOS build number from the GitHub Actions run number.
