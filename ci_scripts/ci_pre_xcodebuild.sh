#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
secrets_dst="${repo_root}/Whishpermate/Whispermate/Secrets.plist"

if [ "${AIDICTATION_FORCE_ENV_SECRETS:-0}" != "1" ] && [ -f "$secrets_dst" ]; then
  echo "Using existing Secrets.plist"
  exit 0
fi

"${repo_root}/ci_scripts/write_secrets_plist.sh" "$secrets_dst"
