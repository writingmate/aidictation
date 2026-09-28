#!/usr/bin/env bash
set -euo pipefail

AIDICTATION_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AIDICTATION_PROJECT="$AIDICTATION_REPO_ROOT/Whishpermate/Whispermate.xcodeproj"
AIDICTATION_SCHEME="Whispermate"
AIDICTATION_DEV_BUNDLE_ID="${AIDICTATION_DEV_BUNDLE_ID:-com.whispermate.macos.dev}"
AIDICTATION_DEV_PRODUCT_NAME="${AIDICTATION_DEV_PRODUCT_NAME:-AIDictationDev}"
AIDICTATION_DEV_DISPLAY_NAME="${AIDICTATION_DEV_DISPLAY_NAME:-AI Dictation Dev}"
AIDICTATION_DEV_URL_SCHEME="${AIDICTATION_DEV_URL_SCHEME:-aidictation-dev}"
AIDICTATION_WORKTREE_ID="$(printf '%s' "$AIDICTATION_REPO_ROOT" | cksum | awk '{print $1}')"
AIDICTATION_DERIVED_DATA="${AIDICTATION_DEV_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/AIDictationDev-$AIDICTATION_WORKTREE_ID}"
AIDICTATION_APP="$AIDICTATION_DERIVED_DATA/Build/Products/Debug/$AIDICTATION_DEV_PRODUCT_NAME.app"
AIDICTATION_LOCAL_SECRETS="$AIDICTATION_REPO_ROOT/Whishpermate/Whispermate/Secrets.plist"

if [[ ! -f "$AIDICTATION_LOCAL_SECRETS" ]]; then
  AIDICTATION_GIT_COMMON_DIR="$(git -C "$AIDICTATION_REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$AIDICTATION_GIT_COMMON_DIR" ]]; then
    AIDICTATION_PRIMARY_CHECKOUT="$(dirname "$AIDICTATION_GIT_COMMON_DIR")"
    AIDICTATION_PRIMARY_SECRETS="$AIDICTATION_PRIMARY_CHECKOUT/Whishpermate/Whispermate/Secrets.plist"
    if [[ -f "$AIDICTATION_PRIMARY_SECRETS" ]]; then
      AIDICTATION_LOCAL_SECRETS="$AIDICTATION_PRIMARY_SECRETS"
    fi
  fi
fi

AIDICTATION_BUILD_ONLY=0
if [[ "${1:-}" == "--build-only" ]]; then
  AIDICTATION_BUILD_ONLY=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: scripts/run_macos_dev.sh [--build-only]" >&2
  exit 64
fi

xcodebuild \
  -project "$AIDICTATION_PROJECT" \
  -scheme "$AIDICTATION_SCHEME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -quiet \
  -derivedDataPath "$AIDICTATION_DERIVED_DATA" \
  AIDICTATION_MACOS_BUNDLE_ID="$AIDICTATION_DEV_BUNDLE_ID" \
  AIDICTATION_MACOS_PRODUCT_NAME="$AIDICTATION_DEV_PRODUCT_NAME" \
  AIDICTATION_DISPLAY_NAME="$AIDICTATION_DEV_DISPLAY_NAME" \
  AIDICTATION_URL_SCHEME="$AIDICTATION_DEV_URL_SCHEME" \
  AIDICTATION_LOCAL_SECRETS_PLIST="$AIDICTATION_LOCAL_SECRETS" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$AIDICTATION_APP" ]]; then
  echo "Developer app was not produced at $AIDICTATION_APP" >&2
  exit 1
fi

if [[ "$AIDICTATION_BUILD_ONLY" == "1" ]]; then
  echo "$AIDICTATION_APP"
  exit 0
fi

# Every worktree builds its own copy, but they all share one bundle ID. When
# System Settings or a permission flow relaunches the app by bundle ID, macOS
# can pick any registered copy. Install to one fixed path and unregister the
# rest so there is only ever one dev app.
AIDICTATION_INSTALLED_APP="${AIDICTATION_DEV_INSTALL_PATH:-$HOME/Applications/$AIDICTATION_DEV_PRODUCT_NAME.app}"
AIDICTATION_LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

while IFS= read -r AIDICTATION_DEV_PID; do
  [[ -n "$AIDICTATION_DEV_PID" ]] && kill "$AIDICTATION_DEV_PID" 2>/dev/null || true
done < <(pgrep -f "$AIDICTATION_DEV_PRODUCT_NAME.app/Contents/MacOS/$AIDICTATION_DEV_PRODUCT_NAME" || true)
sleep 1

mkdir -p "$(dirname "$AIDICTATION_INSTALLED_APP")"
rm -rf "$AIDICTATION_INSTALLED_APP"
ditto "$AIDICTATION_APP" "$AIDICTATION_INSTALLED_APP"

while IFS= read -r AIDICTATION_STALE_APP; do
  [[ -n "$AIDICTATION_STALE_APP" && "$AIDICTATION_STALE_APP" != "$AIDICTATION_INSTALLED_APP" ]] || continue
  "$AIDICTATION_LSREGISTER" -u "$AIDICTATION_STALE_APP" 2>/dev/null || true
done < <("$AIDICTATION_LSREGISTER" -dump 2>/dev/null \
  | sed -n "s|^path: *\(.*/$AIDICTATION_DEV_PRODUCT_NAME\.app\) (0x[0-9a-f]*)$|\1|p" \
  | sort -u)
# Xcode registers each build product with LaunchServices, so a copy left in
# any worktree's DerivedData can come back as a relaunch target. Remove them;
# every worktree rebuilds its product on the next run of this script.
for AIDICTATION_BUILT_APP in "$HOME"/Library/Developer/Xcode/DerivedData/AIDictationDev-*/Build/Products/Debug/"$AIDICTATION_DEV_PRODUCT_NAME".app; do
  [[ -d "$AIDICTATION_BUILT_APP" ]] || continue
  "$AIDICTATION_LSREGISTER" -u "$AIDICTATION_BUILT_APP" 2>/dev/null || true
  rm -rf "$AIDICTATION_BUILT_APP"
done
"$AIDICTATION_LSREGISTER" -f "$AIDICTATION_INSTALLED_APP"

open "$AIDICTATION_INSTALLED_APP"
sleep 1

AIDICTATION_APP="$AIDICTATION_INSTALLED_APP"
AIDICTATION_RUNNING_PID="$(pgrep -f "$AIDICTATION_APP/Contents/MacOS/$AIDICTATION_DEV_PRODUCT_NAME" | head -n 1 || true)"
if [[ -z "$AIDICTATION_RUNNING_PID" ]]; then
  echo "Developer app exited during launch." >&2
  exit 1
fi

echo "Running $AIDICTATION_DEV_DISPLAY_NAME (PID $AIDICTATION_RUNNING_PID)"
echo "Bundle ID: $AIDICTATION_DEV_BUNDLE_ID"
echo "App: $AIDICTATION_APP"
