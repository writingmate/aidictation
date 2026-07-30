#!/usr/bin/env python3
"""Validate the exact transcription config bundled into a release build.

This script intentionally reads the decoded Secrets.plist that the macOS
release workflow installs into the app target. It fails fast on stale model
values and sends a real audio sample through the configured transcription
endpoint before the release artifact is published.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any
from urllib import error, parse, request


EXPECTED_WRITINGMATE_MODEL = "groq/whisper-large-v3-turbo"
RELEASE_VALIDATOR_USER_AGENT = "AIDictation-Release-Validator/1.0"
STALE_TRANSCRIPTION_MODELS = {
    "gpt-4o-transcribe",
    "gpt-4o-mini-transcribe",
}


def fail(message: str) -> None:
    print(f"release config validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_plist(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as file:
            value = plistlib.load(file)
    except Exception as exc:  # noqa: BLE001
        fail(f"could not read {path}: {exc}")

    if not isinstance(value, dict):
        fail(f"{path} is not a plist dictionary")
    return value


def required_string(config: dict[str, Any], key: str) -> str:
    value = config.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"Secrets.plist is missing non-empty {key}")
    return value.strip()


def validate_model(endpoint: str, model: str) -> None:
    normalized = model.strip()
    if normalized in STALE_TRANSCRIPTION_MODELS:
        fail(
            f"CustomTranscriptionModel={normalized} is a stale OpenAI model "
            "and cannot be sent to the shipped Writingmate/Groq transcription path"
        )

    host = parse.urlparse(endpoint).netloc.lower()
    if ("writingmate" in host or "aidictation" in host) and normalized != EXPECTED_WRITINGMATE_MODEL:
        fail(
            f"Writingmate transcription endpoint must ship with "
            f"CustomTranscriptionModel={EXPECTED_WRITINGMATE_MODEL}, got {normalized}"
        )


def generate_speech_sample(output: Path) -> None:
    if not shutil.which("say"):
        fail("macOS 'say' command is required for release transcription validation")
    if not shutil.which("afconvert"):
        fail("macOS 'afconvert' command is required for release transcription validation")

    with tempfile.TemporaryDirectory(prefix="aidictation-release-audio-") as tmp:
        aiff = Path(tmp) / "sample.aiff"
        subprocess.run(
            [
                "say",
                "-v",
                "Samantha",
                "-o",
                str(aiff),
                "AIDictation release smoke test.",
            ],
            check=True,
        )
        subprocess.run(
            ["afconvert", "-f", "m4af", "-d", "aac", str(aiff), str(output)],
            check=True,
        )

    if not output.exists() or output.stat().st_size < 1_000:
        fail("generated transcription smoke audio is empty")


def multipart_body(fields: dict[str, str], file_path: Path) -> tuple[bytes, str]:
    boundary = f"----aidictation-{uuid.uuid4().hex}"
    chunks: list[bytes] = []

    def add(value: str) -> None:
        chunks.append(value.encode("utf-8"))

    for name, value in fields.items():
        add(f"--{boundary}\r\n")
        add(f'Content-Disposition: form-data; name="{name}"\r\n\r\n')
        add(f"{value}\r\n")

    add(f"--{boundary}\r\n")
    add('Content-Disposition: form-data; name="file"; filename="release-smoke.m4a"\r\n')
    add("Content-Type: audio/m4a\r\n\r\n")
    chunks.append(file_path.read_bytes())
    add("\r\n")
    add(f"--{boundary}--\r\n")
    return b"".join(chunks), boundary


def http_json(url: str, headers: dict[str, str], payload: dict[str, Any]) -> Any:
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(
        url,
        data=data,
        headers={
            **headers,
            "Content-Type": "application/json",
            "User-Agent": RELEASE_VALIDATOR_USER_AGENT,
        },
        method="POST",
    )
    try:
        with request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        fail(f"HTTP {exc.code} from {parse.urlparse(url).netloc}: {body[:500]}")


def http_get_json(url: str, headers: dict[str, str]) -> Any:
    req = request.Request(
        url,
        headers={**headers, "User-Agent": RELEASE_VALIDATOR_USER_AGENT},
        method="GET",
    )
    try:
        with request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        fail(f"HTTP {exc.code} from {parse.urlparse(url).netloc}: {body[:500]}")


def transcribe(endpoint: str, api_key: str, model: str, audio: Path, label: str) -> str:
    body, boundary = multipart_body(
        {
            "model": model,
            "temperature": "0",
            "response_format": "text",
        },
        audio,
    )
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "User-Agent": RELEASE_VALIDATOR_USER_AGENT,
    }
    req = request.Request(endpoint, data=body, headers=headers, method="POST")
    try:
        with request.urlopen(req, timeout=60) as response:
            raw = response.read()
            status = response.status
    except error.HTTPError as exc:
        body_text = exc.read().decode("utf-8", errors="replace")
        fail(f"{label} transcription returned HTTP {exc.code}: {body_text[:800]}")
    except Exception as exc:  # noqa: BLE001
        fail(f"{label} transcription request failed: {exc}")

    text = raw.decode("utf-8", errors="replace").strip()
    if not text:
        fail(f"{label} transcription returned empty text")

    lowered = text.lower()
    if "release" not in lowered and "smoke" not in lowered and "aidictation" not in lowered:
        fail(f"{label} transcription returned unexpected text: {text[:200]!r}")

    print(f"{label} transcription ok: HTTP {status}, {len(text)} chars")
    return text


def validate_authenticated_user(config: dict[str, Any], endpoint: str, api_key: str, model: str, audio: Path) -> None:
    email = os.environ.get("AIDICTATION_RELEASE_TEST_EMAIL", "").strip()
    password = os.environ.get("AIDICTATION_RELEASE_TEST_PASSWORD", "").strip()
    if not email or not password:
        fail("AIDICTATION_RELEASE_TEST_EMAIL and AIDICTATION_RELEASE_TEST_PASSWORD are required")

    supabase_url = required_string(config, "SUPABASE_URL").rstrip("/")
    anon_key = required_string(config, "SUPABASE_ANON_KEY")
    token_url = f"{supabase_url}/auth/v1/token?grant_type=password"
    token = http_json(
        token_url,
        {"apikey": anon_key},
        {"email": email, "password": password},
    )

    access_token = token.get("access_token")
    user_id = (token.get("user") or {}).get("id")
    if not access_token or not user_id:
        fail("Supabase test login did not return an access token and user id")

    query = parse.urlencode(
        {
            "select": "user_id,email,monthly_word_count,subscription_status",
            "user_id": f"eq.{user_id}",
        }
    )
    profile_url = f"{supabase_url}/rest/v1/profiles?{query}"
    profiles = http_get_json(
        profile_url,
        {
            "apikey": anon_key,
            "Authorization": f"Bearer {access_token}",
        },
    )
    if not isinstance(profiles, list) or not profiles:
        fail("authenticated release test user has no profile row")

    profile = profiles[0]
    monthly_count = int(profile.get("monthly_word_count") or 0)
    subscription_status = str(profile.get("subscription_status") or "free")
    if subscription_status not in {"pro", "lifetime"} and monthly_count >= 10_000:
        fail("authenticated release test user is at or above the free word limit")

    print(f"auth session ok: profile found, tier={subscription_status}, monthly_words={monthly_count}")
    transcribe(endpoint, api_key, model, audio, "auth-user cloud")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--secrets", required=True, type=Path)
    parser.add_argument("--config-only", action="store_true")
    parser.add_argument("--require-auth", action="store_true")
    args = parser.parse_args()

    config = load_plist(args.secrets)
    endpoint = required_string(config, "CustomTranscriptionEndpoint")
    model = required_string(config, "CustomTranscriptionModel")
    api_key = required_string(config, "CustomTranscriptionKey")

    validate_model(endpoint, model)
    print(
        "config ok: "
        f"endpoint={parse.urlparse(endpoint).netloc}, model={model}, "
        f"transport={config.get('CustomTranscriptionTransport') or 'batch'}"
    )

    if args.config_only:
        return

    with tempfile.TemporaryDirectory(prefix="aidictation-release-smoke-") as tmp:
        audio = Path(tmp) / "release-smoke.m4a"
        generate_speech_sample(audio)
        transcribe(endpoint, api_key, model, audio, "non-auth cloud")
        if args.require_auth:
            validate_authenticated_user(config, endpoint, api_key, model, audio)


if __name__ == "__main__":
    main()
