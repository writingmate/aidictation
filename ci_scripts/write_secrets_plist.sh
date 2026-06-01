#!/bin/sh
set -eu

dst="${1:?usage: write_secrets_plist.sh <destination> [local-source]}"
local_source="${2:-}"

mkdir -p "$(dirname "$dst")"

if [ "${AIDICTATION_FORCE_ENV_SECRETS:-0}" != "1" ] && [ -n "$local_source" ] && [ -f "$local_source" ]; then
  cp "$local_source" "$dst"
  echo "Secrets.plist copied from local source"
  exit 0
fi

cat > "$dst" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST

value_from_env() {
  for name in "$@"; do
    eval "value=\${$name:-}"
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 0
}

secret_count=0

put_secret() {
  key="$1"
  value="$2"
  if [ -z "$value" ]; then
    return 0
  fi

  /usr/bin/plutil -replace "$key" -string "$value" "$dst" 2>/dev/null \
    || /usr/bin/plutil -insert "$key" -string "$value" "$dst"
  secret_count=$((secret_count + 1))
}

put_secret "AUTH_WEB_URL" "$(value_from_env AUTH_WEB_URL)"
put_secret "SUPABASE_URL" "$(value_from_env SUPABASE_URL)"
put_secret "SUPABASE_ANON_KEY" "$(value_from_env SUPABASE_ANON_KEY)"
put_secret "CustomTranscriptionEndpoint" "$(value_from_env CustomTranscriptionEndpoint CUSTOM_TRANSCRIPTION_ENDPOINT)"
put_secret "CustomTranscriptionRealtimeEndpoint" "$(value_from_env CustomTranscriptionRealtimeEndpoint CUSTOM_TRANSCRIPTION_REALTIME_ENDPOINT)"
put_secret "CustomTranscriptionModel" "$(value_from_env CustomTranscriptionModel CUSTOM_TRANSCRIPTION_MODEL)"
put_secret "CustomTranscriptionRealtimeModel" "$(value_from_env CustomTranscriptionRealtimeModel CUSTOM_TRANSCRIPTION_REALTIME_MODEL)"
put_secret "CustomTranscriptionKey" "$(value_from_env CustomTranscriptionKey CUSTOM_TRANSCRIPTION_KEY)"
put_secret "CustomTranscriptionTransport" "$(value_from_env CustomTranscriptionTransport CUSTOM_TRANSCRIPTION_TRANSPORT)"
put_secret "OpenAITranscriptionKey" "$(value_from_env OpenAITranscriptionKey OPENAI_TRANSCRIPTION_KEY OPENAI_API_KEY)"
put_secret "AIDictationPostProcessingEndpoint" "$(value_from_env AIDictationPostProcessingEndpoint AIDICTATION_POST_PROCESSING_ENDPOINT)"
put_secret "AIDictationPostProcessingKey" "$(value_from_env AIDictationPostProcessingKey AIDICTATION_POST_PROCESSING_KEY)"
put_secret "GroqTranscriptionKey" "$(value_from_env GroqTranscriptionKey GROQ_TRANSCRIPTION_KEY)"
put_secret "GroqLLMKey" "$(value_from_env GroqLLMKey GROQ_LLM_KEY)"
sentry_dsn="$(value_from_env SENTRY_DSN SentryDSN)"
put_secret "SENTRY_DSN" "$sentry_dsn"
put_secret "SentryDSN" "$sentry_dsn"
put_secret "STRIPE_PAYMENT_LINK" "$(value_from_env STRIPE_PAYMENT_LINK)"
put_secret "STRIPE_PAYMENT_LINK_MONTHLY" "$(value_from_env STRIPE_PAYMENT_LINK_MONTHLY)"
put_secret "STRIPE_PAYMENT_LINK_ANNUAL" "$(value_from_env STRIPE_PAYMENT_LINK_ANNUAL)"
put_secret "STRIPE_PAYMENT_LINK_LIFETIME" "$(value_from_env STRIPE_PAYMENT_LINK_LIFETIME)"

if [ "$secret_count" -eq 0 ]; then
  if [ "${AIDICTATION_REQUIRE_SECRETS:-0}" = "1" ]; then
    echo "error: Secrets.plist could not be generated. Configure Xcode Cloud environment variables or unset AIDICTATION_REQUIRE_SECRETS." >&2
    exit 1
  fi
  echo "warning: Secrets.plist generated without configured values"
else
  echo "Secrets.plist generated from environment variables (${secret_count} keys, values redacted)"
fi
