# Xcode Cloud

Xcode Cloud runs `ci_pre_xcodebuild.sh` before the archive build. The script creates the ignored development file `Whishpermate/Whispermate/Secrets.plist` from Xcode Cloud environment variables, without printing secret values.

Set these secret variables in Xcode Cloud for deployable builds:

- `AUTH_WEB_URL`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `CUSTOM_TRANSCRIPTION_ENDPOINT`
- `CUSTOM_TRANSCRIPTION_MODEL`
- `CUSTOM_TRANSCRIPTION_KEY`
- `AIDICTATION_POST_PROCESSING_ENDPOINT`
- `AIDICTATION_POST_PROCESSING_KEY`

Optional:

- `STRIPE_PAYMENT_LINK`
- `STRIPE_PAYMENT_LINK_MONTHLY`
- `STRIPE_PAYMENT_LINK_ANNUAL`
- `STRIPE_PAYMENT_LINK_LIFETIME`
- `AIDICTATION_REQUIRE_SECRETS=1`

Local builds still use `Whishpermate/Whispermate/Secrets.plist` when it exists.
