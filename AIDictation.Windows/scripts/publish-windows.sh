#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$WINDOWS_DIR/.." && pwd)"
DOTNET_BIN="${DOTNET_BIN:-dotnet}"
PROJECT="$WINDOWS_DIR/AIDictation/AIDictation.csproj"
OUTPUT_DIR="${1:-$WINDOWS_DIR/artifacts/win-x64}"

"$DOTNET_BIN" publish "$PROJECT" \
  --configuration Release \
  --runtime win-x64 \
  --self-contained true \
  --output "$OUTPUT_DIR" \
  -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true

test -s "$OUTPUT_DIR/AIDictation.exe"
echo "Windows artifact: $OUTPUT_DIR/AIDictation.exe"
