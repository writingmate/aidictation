#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
EXPECTED_VERSION="${2:-}"
BROWSER_SCRIPT="${AIDICTATION_RELEASE_AUTH_BROWSER_SCRIPT:-/tmp/aidictation-release-browser/capture_release_auth_callback.mjs}"
CALLBACK_PATH="${AIDICTATION_RELEASE_AUTH_CALLBACK_PATH:-/tmp/aidictation-release-auth-callback}"
RESULT_PATH="${AIDICTATION_RELEASE_AUTH_RESULT_PATH:-/tmp/aidictation-release-auth-result.json}"
HANDLER_VERIFIER="${AIDICTATION_RELEASE_URL_HANDLER_VERIFIER:-scripts/verify_macos_url_handler.swift}"
TOKEN_VERIFIER="${AIDICTATION_RELEASE_CALLBACK_TOKEN_VERIFIER:-scripts/validate_macos_callback_token.py}"
LSREGISTER_PATH="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
USER_APPLICATIONS_DIR="${HOME}/Applications"
INSTALL_PREFIX="$USER_APPLICATIONS_DIR/AIDictationReleaseVerification."
INSTALL_ROOT=""
INSTALLED_APP=""

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
if [[ ! -f "$HANDLER_VERIFIER" || ! -f "$TOKEN_VERIFIER" || ! -x "$LSREGISTER_PATH" ]]; then
  echo "A macOS callback verifier is unavailable." >&2
  exit 1
fi

cleanup() {
  launchctl unsetenv AIDICTATION_RELEASE_AUTH_SMOKE >/dev/null 2>&1 || true
  launchctl unsetenv AIDICTATION_RELEASE_AUTH_RESULT >/dev/null 2>&1 || true
  pkill -x AIDictation >/dev/null 2>&1 || true
  rm -f "$CALLBACK_PATH" "$RESULT_PATH"
  if [[ -n "$INSTALL_ROOT" \
      && "$INSTALL_ROOT" == "$INSTALL_PREFIX"* \
      && "$(dirname "$INSTALL_ROOT")" == "$USER_APPLICATIONS_DIR" \
      && "$INSTALLED_APP" == "$INSTALL_ROOT/AIDictation.app" ]]; then
    "$LSREGISTER_PATH" -u "$INSTALLED_APP" >/dev/null 2>&1 || true
    if [[ -d "$INSTALL_ROOT" ]]; then
      rm -rf -- "$INSTALL_ROOT"
    fi
  fi
}
trap cleanup EXIT

python3 - "$APP_PATH/Contents/Info.plist" <<'PYEOF'
import plistlib
import sys

with open(sys.argv[1], "rb") as plist_file:
    info = plistlib.load(plist_file)

schemes = [
    scheme
    for url_type in info.get("CFBundleURLTypes", [])
    for scheme in url_type.get("CFBundleURLSchemes", [])
]
if schemes != ["aidictation"]:
    raise SystemExit("The release app does not declare exactly the aidictation callback scheme.")
PYEOF

mkdir -p "$USER_APPLICATIONS_DIR"
INSTALL_ROOT="$(mktemp -d "${INSTALL_PREFIX}XXXXXX")"
if [[ "$INSTALL_ROOT" != "$INSTALL_PREFIX"* ]]; then
  echo "The release verification install path is outside the user Applications directory." >&2
  exit 1
fi
INSTALLED_APP="$INSTALL_ROOT/AIDictation.app"
ditto "$APP_PATH" "$INSTALLED_APP"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
"$LSREGISTER_PATH" -f "$INSTALLED_APP"
swift "$HANDLER_VERIFIER" "$INSTALLED_APP" aidictation

export AIDICTATION_RELEASE_AUTH_CALLBACK_PATH="$CALLBACK_PATH"
node "$BROWSER_SCRIPT"
test -s "$CALLBACK_PATH"
python3 "$TOKEN_VERIFIER" \
  "$CALLBACK_PATH" \
  "$APP_PATH/Contents/Resources/Secrets.plist"

rm -f "$RESULT_PATH"
launchctl setenv AIDICTATION_RELEASE_AUTH_SMOKE 1
launchctl setenv AIDICTATION_RELEASE_AUTH_RESULT "$RESULT_PATH"
open -na "$INSTALLED_APP"

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
if ! open "$CALLBACK_URL" >/dev/null 2>&1; then
  echo "macOS could not deliver the browser callback to the registered release app." >&2
  exit 1
fi
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
    "callback_has_access_token": True,
    "callback_has_refresh_token": True,
    "callback_has_token_type": True,
    "callback_has_expires_in": True,
    "callback_session_established": True,
    "profile_request_started": True,
    "callback_failure_phase": "none",
    "callback_failure_category": "none",
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
