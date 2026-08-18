#!/usr/bin/env bash
# Unit tests that must pass before publishing a macOS release.
#
# The WhispermateTests bundle is host-free: it compiles the pure logic types on
# their own, so it needs no signing, no app launch, and runs in a couple of
# seconds. Add coverage by putting a new XCTestCase in Whishpermate/WhispermateTests
# and adding the type under test to the target's Compile Sources.
#
#   scripts/preflight_tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/../Whishpermate" && pwd)/Whispermate.xcodeproj"

echo "==> Running WhispermateTests"
xcodebuild test \
  -project "$PROJECT" \
  -scheme WhispermateTests \
  -destination 'platform=macOS' \
  | grep -E "Test Case .* (passed|failed)|Executed [0-9]+ tests|error:|\*\* TEST" \
  || {
    echo "preflight tests failed" >&2
    exit 1
  }

echo "preflight tests passed"
