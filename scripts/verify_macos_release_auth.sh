#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
EXPECTED_VERSION="${2:-}"
BROWSER_SCRIPT="${AIDICTATION_RELEASE_AUTH_BROWSER_SCRIPT:-/tmp/aidictation-release-browser/capture_release_auth_callback.mjs}"
CALLBACK_PATH="${AIDICTATION_RELEASE_AUTH_CALLBACK_PATH:-/tmp/aidictation-release-auth-callback}"
RESULT_PATH="${AIDICTATION_RELEASE_AUTH_RESULT_PATH:-/tmp/aidictation-release-auth-result.json}"

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "A signed AIDictation.app path is required." >&2
  exit 1
fi
if [[ -z "$EXPECTED_VERSION" ]]; then
  echo "The expected release version is required." >&2
  exit 1
fi
if [[ ! -f "$BROWSER_SCRIPT" ]]; then
  echo "The live browser verifier is not installed at $BROWSER_SCRIPT." >&2
  exit 1
fi

cleanup() {
  launchctl unsetenv AIDICTATION_RELEASE_AUTH_SMOKE >/dev/null 2>&1 || true
  launchctl unsetenv AIDICTATION_RELEASE_AUTH_RESULT >/dev/null 2>&1 || true
  pkill -x AIDictation >/dev/null 2>&1 || true
  rm -f "$CALLBACK_PATH" "$RESULT_PATH"
}
trap cleanup EXIT

export AIDICTATION_RELEASE_AUTH_CALLBACK_PATH="$CALLBACK_PATH"
node "$BROWSER_SCRIPT"
test -s "$CALLBACK_PATH"

rm -f "$RESULT_PATH"
launchctl setenv AIDICTATION_RELEASE_AUTH_SMOKE 1
launchctl setenv AIDICTATION_RELEASE_AUTH_RESULT "$RESULT_PATH"
open -na "$APP_PATH"

for attempt in {1..20}; do
  if pgrep -x AIDictation >/dev/null; then
    break
  fi
  if [[ "$attempt" -eq 20 ]]; then
    echo "AIDictation did not launch for release authentication verification." >&2
    exit 1
  fi
  sleep 1
done

CALLBACK_URL="$(<"$CALLBACK_PATH")"
open "$CALLBACK_URL"
unset CALLBACK_URL
rm -f "$CALLBACK_PATH"

for attempt in {1..60}; do
  if [[ -s "$RESULT_PATH" ]]; then
    break
  fi
  if [[ "$attempt" -eq 60 ]]; then
    echo "AIDictation did not report account state after the live browser callback." >&2
    exit 1
  fi
  sleep 1
done

python3 - "$RESULT_PATH" "$EXPECTED_VERSION" <<'PYEOF'
import json
import sys

result_path, expected_version = sys.argv[1:]
with open(result_path, encoding="utf-8") as result_file:
    result = json.load(result_file)

expected = {
    "version": expected_version,
    "authenticated": True,
    "profile_loaded": True,
    "subscription_status": "lifetime",
    "subscription_tier": "lifetime",
    "has_reached_limit": False,
    "words_remaining_unlimited": True,
    "auth_error_present": False,
}
mismatches = {
    key: {"expected": value, "actual": result.get(key)}
    for key, value in expected.items()
    if result.get(key) != value
}
if mismatches:
    raise SystemExit(f"release app account verification failed: {mismatches}")
print(
    "Live browser callback loaded the lifetime profile with unlimited access "
    f"in AIDictation v{expected_version}."
)
PYEOF
