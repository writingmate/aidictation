#!/usr/bin/env python3

import unittest

from validate_client_config import ClientConfigurationError, validate_client_configuration


def release_config() -> dict[str, str]:
    return {
        "TRANSCRIPTION_API_KEY": "wm_live_key",
        "AIDICTATION_POST_PROCESSING_KEY": "wm_post_processing_key",
        "SUPABASE_URL": "https://example.supabase.co",
        "SUPABASE_ANON_KEY": "sb_publishable_example",
        "AUTH_WEB_URL": "https://aidictation.com/auth",
        "REVENUECAT_GOOGLE_API_KEY": "goog_public_sdk_key",
        "REVENUECAT_ENTITLEMENT_ID": "pro",
    }


class ValidateClientConfigurationTests(unittest.TestCase):
    def test_accepts_public_google_play_sdk_key(self) -> None:
        validate_client_configuration(release_config())

    def test_rejects_revenuecat_secret_key(self) -> None:
        config = release_config()
        config["REVENUECAT_GOOGLE_API_KEY"] = "sk_private_key"

        with self.assertRaisesRegex(ClientConfigurationError, "privileged RevenueCat"):
            validate_client_configuration(config)

    def test_rejects_revenuecat_oauth_credential(self) -> None:
        config = release_config()
        config["REVENUECAT_GOOGLE_API_KEY"] = "atk_private_credential"

        with self.assertRaisesRegex(ClientConfigurationError, "privileged RevenueCat"):
            validate_client_configuration(config)

    def test_rejects_non_google_sdk_key(self) -> None:
        config = release_config()
        config["REVENUECAT_GOOGLE_API_KEY"] = "appl_public_sdk_key"

        with self.assertRaisesRegex(ClientConfigurationError, "public Google Play SDK key"):
            validate_client_configuration(config)

    def test_rejects_revenuecat_test_store_key(self) -> None:
        config = release_config()
        config["REVENUECAT_GOOGLE_API_KEY"] = "test_simulated_store_key"

        with self.assertRaisesRegex(ClientConfigurationError, "Test Store"):
            validate_client_configuration(config)

    def test_requires_revenuecat_key_for_release(self) -> None:
        config = release_config()
        config["REVENUECAT_GOOGLE_API_KEY"] = ""

        with self.assertRaisesRegex(ClientConfigurationError, "REVENUECAT_GOOGLE_API_KEY"):
            validate_client_configuration(config)

    def test_rejects_unexpected_revenuecat_entitlement(self) -> None:
        config = release_config()
        config["REVENUECAT_ENTITLEMENT_ID"] = "premium"

        with self.assertRaisesRegex(ClientConfigurationError, "must be 'pro'"):
            validate_client_configuration(config)

    def test_requires_revenuecat_entitlement_for_release(self) -> None:
        config = release_config()
        config["REVENUECAT_ENTITLEMENT_ID"] = ""

        with self.assertRaisesRegex(ClientConfigurationError, "REVENUECAT_ENTITLEMENT_ID"):
            validate_client_configuration(config)


if __name__ == "__main__":
    unittest.main()
