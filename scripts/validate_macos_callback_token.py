#!/usr/bin/env python3
"""Validate a release callback token without printing credentials or response data."""

from __future__ import annotations

import plistlib
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class VerificationError(Exception):
    """A support-safe release verification failure."""


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


def is_safe_header_value(value: str) -> bool:
    return value.isascii() and all(
        0x21 <= ord(character) <= 0x7E for character in value
    )


def callback_params(callback_url: str) -> dict[str, str]:
    parsed = urllib.parse.urlsplit(callback_url)
    try:
        port = parsed.port
    except ValueError:
        raise VerificationError("The captured callback target is invalid.") from None
    if (
        parsed.scheme != "aidictation"
        or parsed.hostname != "auth-callback"
        or parsed.username
        or parsed.password
        or port
        or parsed.path not in ("", "/")
    ):
        raise VerificationError("The captured callback target is invalid.")

    required = ("access_token", "refresh_token", "token_type", "expires_in")
    query_items = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    if any(name in required for name, _ in query_items):
        raise VerificationError(
            "The captured callback must keep session fields in the fragment only."
        )

    params: dict[str, str] = {}
    for name, value in urllib.parse.parse_qsl(
        parsed.fragment,
        keep_blank_values=True,
    ):
        params[name] = value

    if any(not params.get(name) for name in required):
        raise VerificationError("The captured callback is missing required session fields.")
    if not is_safe_header_value(params["access_token"]):
        raise VerificationError("The captured callback contains an invalid access token.")
    if params["token_type"].lower() != "bearer":
        raise VerificationError("The captured callback token type is invalid.")
    return params


def auth_user_endpoint(secrets_path: Path) -> tuple[str, str]:
    with secrets_path.open("rb") as plist_file:
        secrets = plistlib.load(plist_file)

    base_value = secrets.get("SUPABASE_URL")
    anon_key = secrets.get("SUPABASE_ANON_KEY")
    if (
        not isinstance(base_value, str)
        or not isinstance(anon_key, str)
        or not anon_key
    ):
        raise VerificationError("The packaged authentication configuration is incomplete.")
    if not is_safe_header_value(anon_key):
        raise VerificationError("The packaged authentication configuration is invalid.")

    parsed = urllib.parse.urlsplit(base_value)
    try:
        port = parsed.port
    except ValueError:
        raise VerificationError(
            "The packaged authentication service URL is invalid."
        ) from None
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or port not in (None, 443)
        or parsed.query
        or parsed.fragment
    ):
        raise VerificationError("The packaged authentication service URL is invalid.")

    path = f"{parsed.path.rstrip('/')}/auth/v1/user"
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path, "", "")), anon_key


def verify(callback_path: Path, secrets_path: Path) -> None:
    callback_url = callback_path.read_text(encoding="utf-8").strip()
    params = callback_params(callback_url)
    endpoint, anon_key = auth_user_endpoint(secrets_path)

    try:
        request = urllib.request.Request(
            endpoint,
            headers={
                "Authorization": f"{params['token_type']} {params['access_token']}",
                "apikey": anon_key,
            },
            method="GET",
        )
        opener = urllib.request.build_opener(NoRedirectHandler())
        with opener.open(request, timeout=20) as response:
            status = response.status
    except urllib.error.HTTPError as error:
        status = error.code
    except (urllib.error.URLError, TimeoutError):
        raise VerificationError(
            "The packaged authentication service could not be reached."
        ) from None
    except Exception:
        raise VerificationError(
            "The packaged authentication request could not be completed safely."
        ) from None

    if status != 200:
        raise VerificationError(
            f"The callback token was rejected by the packaged authentication service "
            f"(HTTP {status})."
        )
    print("Callback token accepted by the packaged authentication service (HTTP 200).")


def self_test() -> None:
    params = callback_params(
        "aidictation://auth-callback#"
        "access_token=synthetic-access&refresh_token=synthetic-refresh&"
        "token_type=bearer&expires_in=3600"
    )
    assert params == {
        "access_token": "synthetic-access",
        "refresh_token": "synthetic-refresh",
        "token_type": "bearer",
        "expires_in": "3600",
    }

    rejected = (
        "aidictation://auth-callback#access_token=synthetic-access",
        "aidictation://auth-callback.evil#access_token=synthetic-access&"
        "refresh_token=synthetic-refresh&token_type=bearer&expires_in=3600",
        "aidictation://auth-callback#access_token=synthetic%0D%0Asecret&"
        "refresh_token=synthetic-refresh&token_type=bearer&expires_in=3600",
        "aidictation://auth-callback?access_token=query-access#"
        "access_token=synthetic-access&refresh_token=synthetic-refresh&"
        "token_type=bearer&expires_in=3600",
        "aidictation://auth-callback#access_token=synthetic-access&"
        "refresh_token=synthetic-refresh&token_type=unknown&expires_in=3600",
    )
    for candidate in rejected:
        try:
            callback_params(candidate)
        except VerificationError:
            continue
        raise AssertionError("A malformed synthetic callback was accepted.")
    print("Verified support-safe callback token validation inputs.")


def main() -> int:
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
            return 0
        if len(sys.argv) != 3:
            raise VerificationError(
                "Usage: validate_macos_callback_token.py <callback-path> <secrets-plist>"
            )
        verify(Path(sys.argv[1]), Path(sys.argv[2]))
        return 0
    except (OSError, plistlib.InvalidFileException, VerificationError) as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print("Callback token validation failed safely.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
