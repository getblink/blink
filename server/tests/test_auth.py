from __future__ import annotations

import os
import unittest
from unittest import mock

from fastapi import HTTPException

from server.auth import check_token_rate_limit, token_id_for, validate_token


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

    def test_check_token_rate_limit_allows_configured_limit_per_window(self) -> None:
        token_id = token_id_for("alpha")
        with mock.patch.dict(os.environ, {"TLDR_TOKEN_RATE_LIMIT_PER_MINUTE": "2"}):
            check_token_rate_limit(token_id, now=1000)
            check_token_rate_limit(token_id, now=1001)
            with self.assertRaises(HTTPException) as ctx:
                check_token_rate_limit(token_id, now=1002)
        self.assertEqual(ctx.exception.status_code, 429)

    def test_check_token_rate_limit_resets_after_one_minute(self) -> None:
        token_id = token_id_for("beta")
        with mock.patch.dict(os.environ, {"TLDR_TOKEN_RATE_LIMIT_PER_MINUTE": "1"}):
            check_token_rate_limit(token_id, now=2000)
            check_token_rate_limit(token_id, now=2060)


if __name__ == "__main__":
    unittest.main()
