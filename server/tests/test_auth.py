from __future__ import annotations

import os
import unittest
from unittest import mock

from server.auth import token_id_for, validate_token


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


if __name__ == "__main__":
    unittest.main()
