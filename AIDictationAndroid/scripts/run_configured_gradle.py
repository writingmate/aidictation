#!/usr/bin/env python3
"""Run Android Gradle tasks with mobile-safe values from a macOS Secrets.plist.

Values are passed only to the Gradle child process. This script never writes a
secret-bearing local.properties file and never prints secret values.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from urllib.parse import urlparse

from validate_client_config import (
    AUTH_CONFIG_NAMES,
    ClientConfigurationError as ConfigurationError,
    looks_like_placeholder,
    validate_client_configuration,
)


ANDROID_PROJECT_DIR = Path(__file__).resolve().parents[1]
CANONICAL_AUTH_URL = "https://aidictation.com/auth"
EMPTY_CONFIG_SENTINEL = "__AIDICTATION_EMPTY__"

PLIST_CONFIG_MAP = {
    "TRANSCRIPTION_API_KEY": "CustomTranscriptionKey",
    "TRANSCRIPTION_ENDPOINT": "CustomTranscriptionEndpoint",
    "TRANSCRIPTION_MODEL": "CustomTranscriptionModel",
    "AIDICTATION_POST_PROCESSING_KEY": "AIDictationPostProcessingKey",
    "AIDICTATION_POST_PROCESSING_ENDPOINT": "AIDictationPostProcessingEndpoint",
    "AIDICTATION_POST_PROCESSING_MODEL": "AIDictationPostProcessingModel",
    "SUPABASE_URL": "SUPABASE_URL",
    "SUPABASE_ANON_KEY": "SUPABASE_ANON_KEY",
    "AUTH_WEB_URL": "AUTH_WEB_URL",
}

PAYMENT_CONFIG_NAMES = (
    "STRIPE_PAYMENT_LINK",
    "STRIPE_PAYMENT_LINK_MONTHLY",
    "STRIPE_PAYMENT_LINK_ANNUAL",
    "STRIPE_PAYMENT_LINK_LIFETIME",
)

DEFAULTS = {
    "TRANSCRIPTION_ENDPOINT": "https://writingmate.ai/api/openai/v1/audio/transcriptions",
    "TRANSCRIPTION_MODEL": "groq/whisper-large-v3-turbo",
    "AIDICTATION_POST_PROCESSING_ENDPOINT": "https://writingmate.ai/api/openai/v1/chat/completions",
    "AIDICTATION_POST_PROCESSING_MODEL": "openai/gpt-oss-20b",
}

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run Gradle with Android client configuration loaded in memory."
    )
    parser.add_argument(
        "--secrets-plist",
        default=os.environ.get("AIDICTATION_SECRETS_PLIST", ""),
        help="Path to the macOS Secrets.plist (or set AIDICTATION_SECRETS_PLIST).",
    )
    parser.add_argument(
        "--sdk-dir",
        default=os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT", ""),
        help="Android SDK path (or set ANDROID_HOME/ANDROID_SDK_ROOT).",
    )
    parser.add_argument(
        "--java-home",
        default=os.environ.get("JAVA_HOME", ""),
        help="JDK 17 path (or set JAVA_HOME).",
    )
    parser.add_argument(
        "gradle_args",
        nargs=argparse.REMAINDER,
        help="Gradle tasks and options; defaults to assembleDebug.",
    )
    return parser.parse_args()


def require_file(raw_path: str, label: str) -> Path:
    if not raw_path.strip():
        raise ConfigurationError(f"{label} path is required.")
    path = Path(raw_path).expanduser().resolve()
    if not path.is_file():
        raise ConfigurationError(f"{label} was not found at {path}.")
    return path


def require_directory(raw_path: str, label: str) -> Path:
    if not raw_path.strip():
        raise ConfigurationError(f"{label} path is required.")
    path = Path(raw_path).expanduser().resolve()
    if not path.is_dir():
        raise ConfigurationError(f"{label} was not found at {path}.")
    return path


def load_plist(path: Path) -> dict[str, str]:
    try:
        with path.open("rb") as stream:
            raw = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ConfigurationError(f"Could not read {path} as a property list.") from error

    if not isinstance(raw, dict):
        raise ConfigurationError("The property list root must be a dictionary.")
    return {
        str(key): str(value).strip()
        for key, value in raw.items()
        if isinstance(value, (str, int, float)) and str(value).strip()
    }


def canonical_auth_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.hostname in {"voicesinmyhead.co", "www.voicesinmyhead.co"} and parsed.path.rstrip("/") == "/auth":
        return CANONICAL_AUTH_URL
    return value


def valid_payment_link(value: str) -> bool:
    parsed = urlparse(value)
    path = parsed.path.lower()
    return (
        parsed.scheme == "https"
        and parsed.hostname == "buy.stripe.com"
        and bool(path.strip("/"))
        and not path.startswith("/test_")
        and not looks_like_placeholder(value)
    )


def resolved_configuration(plist: dict[str, str]) -> tuple[dict[str, str], int, int]:
    config = {
        target: plist.get(source, "")
        for target, source in PLIST_CONFIG_MAP.items()
    }
    config.update({name: value for name, value in DEFAULTS.items() if not config.get(name)})
    if "gpt-4o-transcribe" in config["TRANSCRIPTION_MODEL"]:
        config["TRANSCRIPTION_MODEL"] = DEFAULTS["TRANSCRIPTION_MODEL"]

    explicit_auth = {name: os.environ.get(name, "").strip() for name in AUTH_CONFIG_NAMES}
    if any(explicit_auth.values()):
        missing = [name for name, value in explicit_auth.items() if not value]
        if missing:
            raise ConfigurationError(
                "Auth environment overrides must provide SUPABASE_URL, "
                "SUPABASE_ANON_KEY, and AUTH_WEB_URL together."
            )
        config.update(explicit_auth)

    for name in PLIST_CONFIG_MAP:
        if name not in AUTH_CONFIG_NAMES and os.environ.get(name, "").strip():
            config[name] = os.environ[name].strip()

    config["AUTH_WEB_URL"] = canonical_auth_url(config.get("AUTH_WEB_URL", ""))

    required = (
        "TRANSCRIPTION_API_KEY",
        "TRANSCRIPTION_ENDPOINT",
        "TRANSCRIPTION_MODEL",
        "AIDICTATION_POST_PROCESSING_KEY",
        "AIDICTATION_POST_PROCESSING_ENDPOINT",
        "AIDICTATION_POST_PROCESSING_MODEL",
        *AUTH_CONFIG_NAMES,
    )
    validate_client_configuration(config, required_names=required)

    accepted_payment_links = 0
    skipped_payment_links = 0
    for name in PAYMENT_CONFIG_NAMES:
        # An explicit empty environment value also prevents an old
        # local.properties entry from re-enabling an unsafe checkout link.
        config[name] = EMPTY_CONFIG_SENTINEL
        explicit = os.environ.get(name, "").strip()
        candidate = explicit or plist.get(name, "")
        if not candidate:
            continue
        if valid_payment_link(candidate):
            config[name] = candidate
            accepted_payment_links += 1
        else:
            skipped_payment_links += 1

    return config, accepted_payment_links, skipped_payment_links


def main() -> int:
    args = parse_args()
    try:
        secrets_path = require_file(args.secrets_plist, "Secrets.plist")
        sdk_dir = require_directory(args.sdk_dir, "Android SDK")
        java_home = require_directory(args.java_home, "JDK")
        plist = load_plist(secrets_path)
        config, accepted_links, skipped_links = resolved_configuration(plist)
    except ConfigurationError as error:
        print(f"Configuration error: {error}", file=sys.stderr)
        return 2

    gradle_args = list(args.gradle_args)
    if gradle_args and gradle_args[0] == "--":
        gradle_args.pop(0)
    if not gradle_args:
        gradle_args = ["assembleDebug"]
    if "--no-daemon" not in gradle_args:
        gradle_args.insert(0, "--no-daemon")

    child_env = os.environ.copy()
    for name in (*PLIST_CONFIG_MAP, *PAYMENT_CONFIG_NAMES):
        child_env.pop(name, None)
    child_env.update(config)
    child_env["ANDROID_HOME"] = str(sdk_dir)
    child_env["ANDROID_SDK_ROOT"] = str(sdk_dir)
    child_env["JAVA_HOME"] = str(java_home)

    print(f"Configuration source: {secrets_path}")
    print("Configured: cloud transcription, text cleanup, and sign-in")
    if accepted_links or skipped_links:
        print(
            "Billing links: "
            f"{accepted_links} production-looking accepted, {skipped_links} unsafe or placeholder skipped"
        )
    sys.stdout.flush()

    completed = subprocess.run(
        [str(ANDROID_PROJECT_DIR / "gradlew"), *gradle_args],
        cwd=ANDROID_PROJECT_DIR,
        env=child_env,
        check=False,
    )
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
