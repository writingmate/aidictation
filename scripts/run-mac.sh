#!/bin/sh
# Build the macOS Debug app and (re)launch it.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/Whishpermate/Whispermate.xcodeproj"
SCHEME="Whispermate"

echo "Building $SCHEME (Debug)..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug build -quiet

SETTINGS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -showBuildSettings 2>/dev/null)
DIR=$(echo "$SETTINGS" | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')
NAME=$(echo "$SETTINGS" | awk -F' = ' '/ FULL_PRODUCT_NAME =/{print $2; exit}')
APP="$DIR/$NAME"

echo "Stopping any running instance..."
pkill -f "AIDictation.app/Contents/MacOS" 2>/dev/null || true
sleep 1

echo "Launching $APP"
open "$APP"
