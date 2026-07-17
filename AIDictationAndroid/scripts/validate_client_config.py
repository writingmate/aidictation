#!/usr/bin/env python3
"""Validate Android client configuration without displaying its values."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
from collections.abc import Mapping, Sequence
from urllib.parse import urlparse


AUTH_CONFIG_NAMES = ("SUPABASE_URL", "SUPABASE_ANON_KEY", "AUTH_WEB_URL")
RELEASE_REQUIRED_NAMES = (
    "TRANSCRIPTION_API_KEY",
    "AIDICTATION_POST_PROCESSING_KEY",
    *AUTH_CONFIG_NAMES,
    "REVENUECAT_GOOGLE_API_KEY",
)
URL_CONFIG_NAMES = (
    "TRANSCRIPTION_ENDPOINT",
    "AIDICTATION_POST_PROCESSING_ENDPOINT",
    "SUPABASE_URL",
    "AUTH_WEB_URL",
)


class ClientConfigurationError(RuntimeError):
    pass


def decode_jwt_payload(token: str) -> dict[str, object] | None:
    parts = token.split(".")
    if len(parts) != 3:
        return None
    try:
        padded = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded).decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def looks_like_placeholder(value: str) -> bool:
    lowered = value.lower()
    return any(
        marker in lowered
        for marker in ("your_", "replace_me", "placeholder", "example.com", "changeme")
    )


def validate_https_url(name: str, value: str) -> None:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ClientConfigurationError(f"{name} must be a complete HTTPS URL.")


def validate_public_supabase_key(url: str, key: str) -> None:
    if key.startswith("sb_secret_"):
        raise ClientConfigurationError("SUPABASE_ANON_KEY contains a server secret key.")

    payload = decode_jwt_payload(key)
    if payload is None:
        return

    role = str(payload.get("role", "")).lower()
    if role in {"service_role", "supabase_admin"}:
        raise ClientConfigurationError("SUPABASE_ANON_KEY contains a privileged server key.")

    host = urlparse(url).hostname or ""
    expected_ref = host.split(".", 1)[0] if host.endswith(".supabase.co") else ""
    token_ref = str(payload.get("ref", ""))
    if expected_ref and token_ref and token_ref != expected_ref:
        raise ClientConfigurationError("The Supabase URL and public key belong to different projects.")


def validate_public_revenuecat_google_key(key: str) -> None:
    if key.startswith(("sk_", "atk_")):
        raise ClientConfigurationError(
            "REVENUECAT_GOOGLE_API_KEY contains a privileged RevenueCat credential."
        )
    if key.startswith("test_"):
        raise ClientConfigurationError(
            "REVENUECAT_GOOGLE_API_KEY must not use a RevenueCat Test Store key in a release."
        )
    if not key.startswith("goog_") or len(key) <= len("goog_"):
        raise ClientConfigurationError(
            "REVENUECAT_GOOGLE_API_KEY must be the public Google Play SDK key (goog_…)."
        )


def validate_client_configuration(
    config: Mapping[str, str],
    required_names: Sequence[str] = RELEASE_REQUIRED_NAMES,
) -> None:
    values = {name: str(value).strip() for name, value in config.items()}

    missing = [name for name in required_names if not values.get(name)]
    if missing:
        raise ClientConfigurationError("Missing required client configuration: " + ", ".join(missing))

    auth_count = sum(bool(values.get(name)) for name in AUTH_CONFIG_NAMES)
    if auth_count not in {0, len(AUTH_CONFIG_NAMES)}:
        raise ClientConfigurationError(
            "SUPABASE_URL, SUPABASE_ANON_KEY, and AUTH_WEB_URL must be configured together."
        )

    placeholders = [
        name for name, value in values.items()
        if value and looks_like_placeholder(value)
    ]
    if placeholders:
        raise ClientConfigurationError("Placeholder values found for: " + ", ".join(placeholders))

    for name in URL_CONFIG_NAMES:
        if values.get(name):
            validate_https_url(name, values[name])

    if auth_count == len(AUTH_CONFIG_NAMES):
        validate_public_supabase_key(values["SUPABASE_URL"], values["SUPABASE_ANON_KEY"])

    revenuecat_key = values.get("REVENUECAT_GOOGLE_API_KEY", "")
    if revenuecat_key:
        validate_public_revenuecat_google_key(revenuecat_key)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate Android client environment variables without printing their values."
    )
    parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="Allow an unconfigured debug build while still rejecting partial or unsafe auth.",
    )
    args = parser.parse_args()

    config_names = set(RELEASE_REQUIRED_NAMES) | set(URL_CONFIG_NAMES)
    config = {name: os.environ.get(name, "") for name in config_names}
    required_names: Sequence[str] = () if args.allow_missing else RELEASE_REQUIRED_NAMES
    try:
        validate_client_configuration(config, required_names=required_names)
    except ClientConfigurationError as error:
        print(f"Configuration error: {error}", file=sys.stderr)
        return 2

    print("Android client configuration validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
