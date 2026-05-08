from __future__ import annotations

import os
import unittest
from unittest import mock

from fastapi import HTTPException

from server.auth import (
    BootstrapMisconfigured,
    check_mint_rate_limit,
    check_token_rate_limit,
    client_ip_for,
    generate_device_token,
    token_id_for,
    validate_bootstrap_token,
    validate_token,
)


class AuthTests(unittest.TestCase):
    def test_token_id_is_stable_and_short(self) -> None:
        token_id = token_id_for("test-token")
        self.assertEqual(token_id, token_id_for("test-token"))
        self.assertEqual(len(token_id), 8)

    def test_validate_token_accepts_configured_token(self) -> None:
        with mock.patch.dict(os.environ, {"BLINK_API_TOKENS": "alpha,beta"}):
            self.assertEqual(validate_token("beta"), token_id_for("beta"))

    def test_validate_token_rejects_unknown_token(self) -> None:
        with mock.patch.dict(os.environ, {"BLINK_API_TOKENS": "alpha,beta"}):
            with self.assertRaisesRegex(ValueError, "invalid bearer token"):
                validate_token("gamma")

    def test_validate_bootstrap_token_accepts_only_bootstrap_secret(self) -> None:
        with mock.patch.dict(os.environ, {"BLINK_BOOTSTRAP_TOKEN": "bootstrap"}):
            self.assertEqual(validate_bootstrap_token("bootstrap"), token_id_for("bootstrap"))
            with self.assertRaisesRegex(ValueError, "invalid bootstrap token"):
                validate_bootstrap_token("alpha")

    def test_generate_device_token_uses_expected_prefix(self) -> None:
        token = generate_device_token()
        self.assertTrue(token.startswith("tldr_dt_"))
        self.assertGreater(len(token), 40)

    def test_check_token_rate_limit_allows_configured_limit_per_window(self) -> None:
        token_id = token_id_for("alpha")
        with mock.patch.dict(os.environ, {"BLINK_TOKEN_RATE_LIMIT_PER_MINUTE": "2"}):
            check_token_rate_limit(token_id, now=1000)
            check_token_rate_limit(token_id, now=1001)
            with self.assertRaises(HTTPException) as ctx:
                check_token_rate_limit(token_id, now=1002)
        self.assertEqual(ctx.exception.status_code, 429)

    def test_check_token_rate_limit_resets_after_one_minute(self) -> None:
        token_id = token_id_for("beta")
        with mock.patch.dict(os.environ, {"BLINK_TOKEN_RATE_LIMIT_PER_MINUTE": "1"}):
            check_token_rate_limit(token_id, now=2000)
            check_token_rate_limit(token_id, now=2060)

    def test_check_mint_rate_limit_is_per_client(self) -> None:
        with mock.patch.dict(os.environ, {"BLINK_MINT_RATE_LIMIT_PER_MINUTE": "1"}):
            check_mint_rate_limit("127.0.0.1", now=3000)
            check_mint_rate_limit("127.0.0.2", now=3001)
            with self.assertRaises(HTTPException) as ctx:
                check_mint_rate_limit("127.0.0.1", now=3002)
        self.assertEqual(ctx.exception.status_code, 429)

    def test_validate_bootstrap_token_misconfigured_raises_typed_error(self) -> None:
        with mock.patch.dict(os.environ, {"BLINK_BOOTSTRAP_TOKEN": ""}):
            with self.assertRaises(BootstrapMisconfigured):
                validate_bootstrap_token("anything")

    def test_client_ip_for_ignores_xff_when_proxy_headers_untrusted(self) -> None:
        request = mock.Mock()
        request.headers = {"x-forwarded-for": "203.0.113.5, 10.0.0.1"}
        request.client = mock.Mock(host="10.0.0.99")
        with mock.patch.dict(os.environ, {"BLINK_TRUST_PROXY_HEADERS": "false"}, clear=False):
            self.assertEqual(client_ip_for(request), "10.0.0.99")

    def test_client_ip_for_uses_xff_first_hop_when_trusted(self) -> None:
        request = mock.Mock()
        request.headers = {"x-forwarded-for": "203.0.113.5, 10.0.0.1"}
        request.client = mock.Mock(host="10.0.0.99")
        with mock.patch.dict(os.environ, {"BLINK_TRUST_PROXY_HEADERS": "true"}, clear=False):
            self.assertEqual(client_ip_for(request), "203.0.113.5")


if __name__ == "__main__":
    unittest.main()
