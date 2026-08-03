#!/usr/bin/env python3
"""Validate a release callback token without printing credentials or response data."""

from __future__ import annotations

import base64
import json
import platform
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


# Match the shipped app's browser-like URLSession transport and the headers
# added by the pinned Supabase Swift 2.46.0 Auth client.
NATIVE_TRANSPORT_HEADERS = {
    "Accept": "application/json",
    "User-Agent": "AIDictation-macOS-Release-Verification/1.0",
}
NATIVE_SDK_HEADERS = {
    "X-Client-Info": "supabase-swift/2.46.0",
    "X-Supabase-Api-Version": "2024-01-01",
    "X-Supabase-Client-Platform": "macOS",
}
if macos_version := platform.mac_ver()[0]:
    NATIVE_SDK_HEADERS["X-Supabase-Client-Platform-Version"] = macos_version


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


def https_origin(value: str) -> tuple[str, str, int] | None:
    parsed = urllib.parse.urlsplit(value)
    try:
        port = parsed.port
    except ValueError:
        return None
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
    ):
        return None
    return "https", parsed.hostname.lower(), port if port is not None else 443


def auth_backend_origins_match(auth_web_url: str, supabase_url: str) -> bool:
    auth_origin = https_origin(auth_web_url)
    return auth_origin is not None and auth_origin == https_origin(supabase_url)


def auth_user_endpoint(secrets_path: Path) -> tuple[str, str, bool]:
    with secrets_path.open("rb") as plist_file:
        secrets = plistlib.load(plist_file)

    base_value = secrets.get("SUPABASE_URL")
    anon_key = secrets.get("SUPABASE_ANON_KEY")
    auth_web_value = secrets.get("AUTH_WEB_URL")
    if (
        not isinstance(base_value, str)
        or not isinstance(anon_key, str)
        or not isinstance(auth_web_value, str)
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
    endpoint = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))
    return endpoint, anon_key, auth_backend_origins_match(auth_web_value, base_value)


def request_headers(
    params: dict[str, str],
    anon_key: str,
) -> dict[str, str]:
    return {
        "Authorization": f"{params['token_type']} {params['access_token']}",
        "apikey": anon_key,
    }


def has_native_request_contract(headers: dict[str, str]) -> bool:
    required = {**NATIVE_TRANSPORT_HEADERS, **NATIVE_SDK_HEADERS}
    return (
        all(headers.get(name) == value for name, value in required.items())
        and headers.get("Authorization", "").lower().startswith("bearer ")
        and bool(headers.get("apikey"))
    )


def request_status(endpoint: str, headers: dict[str, str]) -> int | None:
    try:
        request = urllib.request.Request(endpoint, headers=headers, method="GET")
        opener = urllib.request.build_opener(NoRedirectHandler())
        with opener.open(request, timeout=20) as response:
            return response.status
    except urllib.error.HTTPError as error:
        status = error.code
        error.close()
        return status
    except (urllib.error.URLError, TimeoutError):
        return None
    except Exception:
        raise VerificationError(
            "The packaged authentication request could not be completed safely."
        ) from None


def report_status(label: str, status: int | None) -> None:
    if status is None:
        print(f"{label}: unavailable.")
    else:
        print(f"{label}: HTTP {status}.")


def jwt_issuer_matches_auth_service(access_token: str, endpoint: str) -> bool:
    try:
        segments = access_token.split(".")
        if len(segments) != 3 or not segments[1] or len(segments[1]) > 32_768:
            return False
        payload_segment = segments[1]
        payload_segment += "=" * (-len(payload_segment) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_segment))
        issuer = payload.get("iss") if isinstance(payload, dict) else None
        expected_issuer = endpoint.removesuffix("/user").rstrip("/")
        return isinstance(issuer, str) and issuer.rstrip("/") == expected_issuer
    except Exception:
        return False


def verify(callback_path: Path, secrets_path: Path) -> None:
    callback_url = callback_path.read_text(encoding="utf-8").strip()
    params = callback_params(callback_url)
    endpoint, anon_key, origins_match = auth_user_endpoint(secrets_path)

    print(
        "Browser and packaged authentication service origins match: "
        f"{'true' if origins_match else 'false'}."
    )
    if not origins_match:
        raise VerificationError(
            "The browser and packaged authentication services do not share an origin."
        )

    issuer_matches = jwt_issuer_matches_auth_service(params["access_token"], endpoint)
    print(
        "Callback JWT issuer matches packaged authentication service: "
        f"{'true' if issuer_matches else 'false'}."
    )

    baseline_headers = request_headers(params, anon_key)
    transport_headers = {**baseline_headers, **NATIVE_TRANSPORT_HEADERS}
    native_headers = {**transport_headers, **NATIVE_SDK_HEADERS}
    if not has_native_request_contract(native_headers):
        raise VerificationError(
            "The native-parity authentication request contract is incomplete."
        )

    baseline_status = request_status(endpoint, baseline_headers)
    transport_status = request_status(endpoint, transport_headers)
    native_status = request_status(endpoint, native_headers)

    report_status("Baseline packaged authentication request", baseline_status)
    report_status("App-like transport authentication request", transport_status)
    report_status("Native-parity packaged authentication request", native_status)

    if native_status is None:
        raise VerificationError(
            "The packaged authentication service could not be reached."
        )
    if native_status != 200:
        raise VerificationError(
            "The callback token was rejected by the native-parity packaged "
            f"authentication request (HTTP {native_status})."
        )
    print(
        "Callback token accepted by the native-parity packaged authentication "
        "request (HTTP 200)."
    )


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

    baseline_headers = request_headers(params, "synthetic-anon-key")
    native_headers = {
        **baseline_headers,
        **NATIVE_TRANSPORT_HEADERS,
        **NATIVE_SDK_HEADERS,
    }
    assert has_native_request_contract(native_headers)
    for required_name in (*NATIVE_TRANSPORT_HEADERS, *NATIVE_SDK_HEADERS):
        incomplete_headers = native_headers.copy()
        incomplete_headers.pop(required_name)
        assert not has_native_request_contract(incomplete_headers)

    def synthetic_jwt(issuer: str) -> str:
        encoded_payload = base64.urlsafe_b64encode(
            json.dumps({"iss": issuer}).encode("utf-8")
        ).decode("ascii").rstrip("=")
        return f"synthetic.{encoded_payload}.signature"

    endpoint = "https://aidictation.example/auth/v1/user"
    assert jwt_issuer_matches_auth_service(
        synthetic_jwt("https://aidictation.example/auth/v1"), endpoint
    )
    assert not jwt_issuer_matches_auth_service(
        synthetic_jwt("https://other.example/auth/v1"), endpoint
    )
    assert auth_backend_origins_match(
        "https://aidictation.example/auth",
        "https://aidictation.example",
    )
    assert not auth_backend_origins_match(
        "https://login.aidictation.example/auth",
        "https://aidictation.example",
    )
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
