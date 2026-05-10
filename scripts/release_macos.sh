#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/release_macos.sh [--tag vX.Y.Z] [--publish] [--notes /absolute/path/release_notes.md]

Behavior:
  - Builds and exports a signed Release archive for AIDictation.
  - Creates a draggable AIDictation-<tag>.dmg with create-dmg.
  - Notarizes and staples the app and DMG.
  - Optionally publishes/updates the GitHub release.

Environment:
  Optional defaults:
    NOTARY_PROFILE      default: AIDictation-notary
    GH_REPO             default: writingmate/aidictation
    DMG_SIGN_IDENTITY   default: Developer ID Application
    RELEASE_ARCHS       default: arm64 x86_64

  Optional credential bootstrap (via 1Password):
    APPLE_ID
    TEAM_ID
    OP_NOTARY_PASSWORD_REF
USAGE
}

fatal() {
  echo "error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fatal "Missing required tool: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG=""
PUBLISH=0
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || fatal "--tag requires a value"
      TAG="$2"
      shift 2
      ;;
    --publish)
      PUBLISH=1
      shift
      ;;
    --notes)
      [[ $# -ge 2 ]] || fatal "--notes requires a value"
      NOTES_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fatal "Unknown argument: $1"
      ;;
  esac
done

if [[ -n "$NOTES_FILE" ]]; then
  [[ "$NOTES_FILE" = /* ]] || fatal "--notes must be an absolute path"
  [[ -f "$NOTES_FILE" ]] || fatal "Notes file not found: $NOTES_FILE"
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-AIDictation-notary}"
GH_REPO="${GH_REPO:-writingmate/aidictation}"
DMG_SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-Developer ID Application}"
RELEASE_ARCHS="${RELEASE_ARCHS:-arm64 x86_64}"

require_tool git
require_tool xcodebuild
require_tool xcrun
require_tool hdiutil
require_tool codesign
require_tool create-dmg
if [[ -n "${OP_NOTARY_PASSWORD_REF:-}" ]]; then
  require_tool op
fi
if [[ "$PUBLISH" -eq 1 ]]; then
  require_tool gh
fi

cd "$REPO_ROOT"

if [[ -z "$TAG" ]]; then
  mapfile -t HEAD_TAGS < <(git tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)
  [[ "${#HEAD_TAGS[@]}" -eq 1 ]] || fatal "Tag required. Provide --tag or ensure exactly one semver tag exists on HEAD."
  TAG="${HEAD_TAGS[0]}"
fi

[[ "$TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fatal "Tag must match vX.Y.Z format: $TAG"
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"
VERSION="${MAJOR}.${MINOR}.${PATCH}"
BUILD_NUMBER="${PATCH}"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fatal "Tag not found locally: $TAG"
TAG_COMMIT="$(git rev-list -n 1 "$TAG")"
HEAD_COMMIT="$(git rev-parse HEAD)"
[[ "$TAG_COMMIT" = "$HEAD_COMMIT" ]] || fatal "Tag $TAG does not point to HEAD."

if [[ -n "${OP_NOTARY_PASSWORD_REF:-}" ]]; then
  [[ -n "${APPLE_ID:-}" ]] || fatal "APPLE_ID is required when OP_NOTARY_PASSWORD_REF is set"
  [[ -n "${TEAM_ID:-}" ]] || fatal "TEAM_ID is required when OP_NOTARY_PASSWORD_REF is set"

  NOTARY_PASSWORD="$(op read "$OP_NOTARY_PASSWORD_REF")"
  [[ -n "$NOTARY_PASSWORD" ]] || fatal "op read returned empty password"

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$NOTARY_PASSWORD" \
    --validate >/dev/null
fi

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
  || fatal "Cannot access notary profile: $NOTARY_PROFILE"

APP_NAME="AIDictation"
PROJECT_DIR="$REPO_ROOT/Whishpermate"
PROJECT_FILE="$PROJECT_DIR/Whispermate.xcodeproj"
SCHEME="Whispermate"

RELEASE_DIR="$PROJECT_DIR/build/release-$TAG"
ARCHIVE_PATH="$RELEASE_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$RELEASE_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$TAG.dmg"
DMG_STAGING_DIR="$RELEASE_DIR/dmg-staging"
APP_ZIP="$RELEASE_DIR/$APP_NAME-$VERSION.zip"
EXPORT_OPTIONS="$RELEASE_DIR/exportOptions.plist"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

echo "==> Building archive for $TAG (version $VERSION, build $BUILD_NUMBER)"
ARCHIVE_CMD=(
  xcodebuild
  -project "$PROJECT_FILE"
  -scheme "$SCHEME"
  -configuration Release
  -archivePath "$ARCHIVE_PATH"
  ARCHS="$RELEASE_ARCHS"
  ONLY_ACTIVE_ARCH=NO
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
if [[ -n "${TEAM_ID:-}" ]]; then
  ARCHIVE_CMD+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi
ARCHIVE_CMD+=(archive)
"${ARCHIVE_CMD[@]}"

if [[ -n "${TEAM_ID:-}" ]]; then
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST
else
  cat > "$EXPORT_OPTIONS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
PLIST
fi

echo "==> Exporting signed app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR"

[[ -d "$APP_PATH" ]] || fatal "Exported app not found at $APP_PATH"

echo "==> Validating universal app architecture"
"$SCRIPT_DIR/validate_macos_universal_app.sh" "$APP_PATH"

echo "==> Notarizing app bundle"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
rm -f "$APP_ZIP"

echo "==> Creating draggable DMG with create-dmg $DMG_PATH"
rm -rf "$DMG_STAGING_DIR" "$DMG_PATH"
mkdir -p "$DMG_STAGING_DIR"
ditto "$APP_PATH" "$DMG_STAGING_DIR/$APP_NAME.app"

APP_SIZE_MB="$(du -sm "$APP_PATH" | awk '{ print $1 }')"
DMG_SIZE_MB=$((APP_SIZE_MB + 128))
if [[ "$DMG_SIZE_MB" -lt 256 ]]; then
  DMG_SIZE_MB=256
fi

create-dmg \
  --volname "$APP_NAME" \
  --window-pos 360 180 \
  --window-size 520 320 \
  --text-size 13 \
  --icon-size 112 \
  --icon "$APP_NAME.app" 150 160 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 370 160 \
  --no-internet-enable \
  --format UDZO \
  --filesystem HFS+ \
  --hdiutil-retries 10 \
  --disk-image-size "$DMG_SIZE_MB" \
  "$DMG_PATH" \
  "$DMG_STAGING_DIR"

rm -rf "$DMG_STAGING_DIR"

echo "==> Signing DMG"
codesign --force --sign "$DMG_SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

PUBLISH_STATUS="not requested"
RELEASE_URL=""

if [[ "$PUBLISH" -eq 1 ]]; then
  echo "==> Publishing release $TAG to $GH_REPO"
  git push origin "$TAG"

  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG_PATH" --repo "$GH_REPO" --clobber
    if [[ -n "$NOTES_FILE" ]]; then
      gh release edit "$TAG" --repo "$GH_REPO" --notes-file "$NOTES_FILE"
    fi
    PUBLISH_STATUS="updated"
  else
    CREATE_CMD=(gh release create "$TAG" "$DMG_PATH" --repo "$GH_REPO" --title "AIDictation $TAG")
    if [[ -n "$NOTES_FILE" ]]; then
      CREATE_CMD+=(--notes-file "$NOTES_FILE")
    else
      CREATE_CMD+=(--generate-notes)
    fi
    "${CREATE_CMD[@]}"
    PUBLISH_STATUS="created"
  fi

  RELEASE_URL="$(gh release view "$TAG" --repo "$GH_REPO" --json url -q .url)"
fi

echo
echo "Release complete:"
echo "  tag:            $TAG"
echo "  version:        $VERSION"
echo "  dmg:            $DMG_PATH"
echo "  publish_status: $PUBLISH_STATUS"
if [[ -n "$RELEASE_URL" ]]; then
  echo "  release_url:    $RELEASE_URL"
fi
