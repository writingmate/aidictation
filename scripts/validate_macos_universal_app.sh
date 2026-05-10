#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/validate_macos_universal_app.sh /path/to/AIDictation.app

Checks every Mach-O binary inside the app bundle and fails if any binary is
missing a required architecture. Override with REQUIRED_ARCHS if needed.
USAGE
}

fatal() {
  echo "error: $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

APP_PATH="${1:-}"
[[ -n "$APP_PATH" ]] || fatal "App path is required"
[[ -d "$APP_PATH/Contents" ]] || fatal "Not a macOS app bundle: $APP_PATH"

command -v file >/dev/null 2>&1 || fatal "Missing required tool: file"
command -v lipo >/dev/null 2>&1 || fatal "Missing required tool: lipo"

IFS=' ' read -r -a REQUIRED <<< "${REQUIRED_ARCHS:-arm64 x86_64}"
[[ "${#REQUIRED[@]}" -gt 0 ]] || fatal "REQUIRED_ARCHS must not be empty"

checked=0
failures=0

while IFS= read -r -d '' file_path; do
  file_info="$(file -b "$file_path" || true)"
  [[ "$file_info" == *Mach-O* ]] || continue

  rel_path="${file_path#$APP_PATH/}"
  archs="$(lipo -archs "$file_path" 2>/dev/null || true)"
  if [[ -z "$archs" ]]; then
    echo "architecture-check-failed: $rel_path (lipo could not read architectures)" >&2
    failures=$((failures + 1))
    continue
  fi

  checked=$((checked + 1))
  file_failures=0

  for required_arch in "${REQUIRED[@]}"; do
    case " $archs " in
      *" $required_arch "*) ;;
      *)
        echo "architecture-missing: $rel_path lacks $required_arch (has: $archs)" >&2
        failures=$((failures + 1))
        file_failures=$((file_failures + 1))
        ;;
    esac
  done

  if [[ "$file_failures" -eq 0 ]]; then
    echo "architecture-ok: $rel_path [$archs]"
  fi
done < <(find "$APP_PATH/Contents" -type f -print0)

[[ "$checked" -gt 0 ]] || fatal "No Mach-O binaries found in $APP_PATH"

if [[ "$failures" -gt 0 ]]; then
  fatal "$failures architecture validation failure(s) in $APP_PATH"
fi

echo "Validated $checked Mach-O binaries include required architectures: ${REQUIRED[*]}"
