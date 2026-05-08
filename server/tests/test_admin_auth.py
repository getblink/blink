from __future__ import annotations

import os
import unittest
from unittest import mock

from fastapi.testclient import TestClient

from server.main import app


class AdminAuthTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = mock.patch.dict(
            os.environ,
            {
                "BLINK_ADMIN_TOKEN": "admin-secret",
                "BLINK_BOOTSTRAP_TOKEN": "bootstrap-secret",
            },
            clear=False,
        )
        self.env.start()
        self.client = TestClient(app)

    def tearDown(self) -> None:
        self.env.stop()

    def test_admin_endpoint_accepts_admin_token(self) -> None:
        store = mock.Mock()
        store.list_beta_signups.return_value = ([], None)
        with mock.patch("server.main._telemetry_store", return_value=store):
            response = self.client.get(
                "/v1/admin/beta-signups",
                headers={"Authorization": "Bearer admin-secret"},
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"items": [], "next_cursor": None})

    def test_admin_endpoint_rejects_device_token(self) -> None:
        response = self.client.get(
            "/v1/admin/beta-signups",
            headers={"Authorization": "Bearer tldr_dt_fake-device-token"},
        )
        self.assertEqual(response.status_code, 401)

    def test_admin_endpoint_rejects_bootstrap_token(self) -> None:
        response = self.client.get(
            "/v1/admin/beta-signups",
            headers={"Authorization": "Bearer bootstrap-secret"},
        )
        self.assertEqual(response.status_code, 401)

    def test_admin_endpoint_rejects_missing_or_malformed_auth(self) -> None:
        missing = self.client.get("/v1/admin/beta-signups")
        malformed = self.client.get(
            "/v1/admin/beta-signups",
            headers={"Authorization": "Basic admin-secret"},
        )
        self.assertEqual(missing.status_code, 401)
        self.assertEqual(malformed.status_code, 401)


if __name__ == "__main__":
    unittest.main()
