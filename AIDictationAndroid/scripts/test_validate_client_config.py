#!/usr/bin/env python3
"""Regression checks for Android browser/native authentication configuration."""

from __future__ import annotations

import unittest
from pathlib import Path

from validate_client_config import (
    ClientConfigurationError,
    validate_auth_backend_agreement,
    validate_client_configuration,
)


class AuthBackendAgreementTests(unittest.TestCase):
    def test_accepts_canonical_browser_and_api_origin(self) -> None:
        validate_auth_backend_agreement(
            "https://aidictation.com/auth",
            "https://aidictation.com",
        )

    def test_rejects_the_split_shipped_in_android_0_0_32(self) -> None:
        with self.assertRaisesRegex(
            ClientConfigurationError,
            "sessions minted by one are rejected by the other",
        ):
            validate_auth_backend_agreement(
                "https://aidictation.com/auth",
                "https://legacy-project.supabase.co",
            )

    def test_release_configuration_accepts_the_canonical_backend(self) -> None:
        validate_client_configuration(
            {
                "TRANSCRIPTION_API_KEY": "test-transcription-key",
                "AIDICTATION_POST_PROCESSING_KEY": "test-cleanup-key",
                "SUPABASE_URL": "https://aidictation.com",
                "SUPABASE_ANON_KEY": "public-anon-key",
                "AUTH_WEB_URL": "https://aidictation.com/auth",
                "GOOGLE_WEB_CLIENT_ID": "123-native-test.apps.googleusercontent.com",
            }
        )

    def test_release_rejects_missing_native_google_configuration(self) -> None:
        with self.assertRaisesRegex(ClientConfigurationError, "GOOGLE_WEB_CLIENT_ID"):
            validate_client_configuration(
                {
                    "TRANSCRIPTION_API_KEY": "test-transcription-key",
                    "AIDICTATION_POST_PROCESSING_KEY": "test-cleanup-key",
                    "SUPABASE_URL": "https://aidictation.com",
                    "SUPABASE_ANON_KEY": "public-anon-key",
                    "AUTH_WEB_URL": "https://aidictation.com/auth",
                }
            )


class ReleaseWorkflowPinTests(unittest.TestCase):
    def test_play_build_receives_native_google_client_like_the_apk_build(self) -> None:
        repository_root = Path(__file__).resolve().parents[2]
        for name in ("android-build.yml", "android-play-release.yml"):
            workflow = (repository_root / ".github/workflows" / name).read_text()
            with self.subTest(workflow=name):
                self.assertIn("GOOGLE_WEB_CLIENT_ID: ${{ secrets.GOOGLE_WEB_CLIENT_ID }}", workflow)
                self.assertIn("GOOGLE_WEB_CLIENT_ID=${GOOGLE_WEB_CLIENT_ID}", workflow)

    @staticmethod
    def workflow_level_env(workflow: str) -> dict[str, str]:
        lines = workflow.splitlines()
        env_start = lines.index("env:") + 1
        jobs_start = lines.index("jobs:")
        values: dict[str, str] = {}
        for line in lines[env_start:jobs_start]:
            if not line.startswith("  ") or line.startswith("    "):
                continue
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or ":" not in stripped:
                continue
            name, value = stripped.split(":", 1)
            values[name] = value.strip().strip("'\"")
        return values

    def test_android_workflows_pin_the_canonical_auth_backend(self) -> None:
        repository_root = Path(__file__).resolve().parents[2]
        workflow_paths = (
            repository_root / ".github/workflows/android-build.yml",
            repository_root / ".github/workflows/android-play-release.yml",
        )
        required_env = {
            "SUPABASE_URL": "https://aidictation.com",
            "SUPABASE_ANON_KEY": "public-anon-key",
            "AUTH_WEB_URL": "https://aidictation.com/auth",
        }
        forbidden_lines = (
            "SUPABASE_URL: ${{ secrets.SUPABASE_URL }}",
            "SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_ANON_KEY }}",
            "AUTH_WEB_URL: ${{ secrets.AUTH_WEB_URL }}",
        )

        for workflow_path in workflow_paths:
            workflow = workflow_path.read_text(encoding="utf-8")
            with self.subTest(workflow=workflow_path.name):
                workflow_env = self.workflow_level_env(workflow)
                for name, value in required_env.items():
                    self.assertEqual(workflow_env.get(name), value)
                for line in forbidden_lines:
                    self.assertNotIn(line, workflow)


if __name__ == "__main__":
    unittest.main()
