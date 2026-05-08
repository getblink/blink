from __future__ import annotations

import os
import unittest
from typing import Any
from unittest import mock

from fastapi.testclient import TestClient

from server import auth
from server.main import app


class FakeSignupStore:
    def __init__(self) -> None:
        self.rows: list[dict[str, Any]] = []

    def record_beta_signup(
        self,
        *,
        signup_id: str,
        email_normalized: str,
        email_original: str,
        source: str | None,
        user_agent: str | None,
        ip_hash: str,
    ) -> bool:
        if any(row["email_normalized"] == email_normalized for row in self.rows):
            return False
        self.rows.append(
            {
                "id": signup_id,
                "email_normalized": email_normalized,
                "email_original": email_original,
                "source": source,
                "user_agent": user_agent,
                "ip_hash": ip_hash,
                "created_at": f"2026-05-08T02:{len(self.rows):02d}:00+00:00",
            }
        )
        return True

    def list_beta_signups(
        self,
        *,
        limit: int,
        cursor: str | None,
        verbose: bool = False,
    ) -> tuple[list[dict[str, Any]], str | None]:
        start = 0
        if cursor:
            ids = [row["id"] for row in self.rows]
            start = ids.index(cursor) + 1 if cursor in ids else len(self.rows)
        selected = self.rows[start : start + limit]
        next_cursor = selected[-1]["id"] if len(self.rows) > start + limit and selected else None
        items: list[dict[str, Any]] = []
        for row in selected:
            item = {
                "id": row["id"],
                "email_original": row["email_original"],
                "source": row["source"],
                "created_at": row["created_at"],
            }
            if verbose:
                item["ip_hash"] = row["ip_hash"]
                item["user_agent"] = row["user_agent"]
            items.append(item)
        return items, next_cursor


class BetaSignupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = mock.patch.dict(
            os.environ,
            {
                "BLINK_ADMIN_TOKEN": "admin-secret",
                "BLINK_BOOTSTRAP_TOKEN": "bootstrap-secret",
                "BLINK_IP_HASH_SALT": "test-salt",
                "BLINK_SIGNUP_RATE_LIMIT_PER_MINUTE": "5",
                "BLINK_SIGNUP_RATE_LIMIT_PER_DAY": "50",
            },
            clear=False,
        )
        self.env.start()
        auth._SIGNUP_RATE_LIMIT_MINUTE_BUCKETS.clear()
        auth._SIGNUP_RATE_LIMIT_DAY_BUCKETS.clear()
        self.store = FakeSignupStore()
        self.store_patch = mock.patch("server.main._telemetry_store", return_value=self.store)
        self.store_patch.start()
        self.client = TestClient(app)

    def tearDown(self) -> None:
        self.store_patch.stop()
        self.env.stop()
        auth._SIGNUP_RATE_LIMIT_MINUTE_BUCKETS.clear()
        auth._SIGNUP_RATE_LIMIT_DAY_BUCKETS.clear()

    def test_signup_records_normalized_email(self) -> None:
        response = self.client.post(
            "/v1/beta-signup",
            json={"email": "  Person@Example.COM  ", "source": "site"},
            headers={"user-agent": "unit-test"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"ok": True})
        self.assertEqual(len(self.store.rows), 1)
        row = self.store.rows[0]
        self.assertEqual(row["email_normalized"], "person@example.com")
        self.assertEqual(row["email_original"], "Person@Example.COM")
        self.assertEqual(row["source"], "site")
        self.assertEqual(row["user_agent"], "unit-test")
        self.assertEqual(len(row["ip_hash"]), 64)

    def test_signup_is_idempotent_by_normalized_email(self) -> None:
        first = self.client.post("/v1/beta-signup", json={"email": "A@B.co"})
        second = self.client.post("/v1/beta-signup", json={"email": "  a@b.CO  "})
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertEqual(len(self.store.rows), 1)

    def test_honeypot_silently_succeeds_without_writing(self) -> None:
        response = self.client.post(
            "/v1/beta-signup",
            json={"email": "person@example.com", "hp": "filled"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"ok": True})
        self.assertEqual(self.store.rows, [])

    def test_invalid_email_returns_422(self) -> None:
        response = self.client.post("/v1/beta-signup", json={"email": "nope"})
        self.assertEqual(response.status_code, 422)

    def test_email_length_cap_returns_422(self) -> None:
        response = self.client.post(
            "/v1/beta-signup",
            json={"email": ("a" * 315) + "@example.com"},
        )
        self.assertEqual(response.status_code, 422)

    def test_rate_limit_trips_after_five_signups_from_same_ip(self) -> None:
        responses = [
            self.client.post("/v1/beta-signup", json={"email": f"{i}@example.com"})
            for i in range(6)
        ]
        self.assertEqual([response.status_code for response in responses[:5]], [200] * 5)
        self.assertEqual(responses[5].status_code, 429)

    def test_cors_preflight_allows_landing_page_origin(self) -> None:
        response = self.client.options(
            "/v1/beta-signup",
            headers={
                "Origin": "https://useblink.dev",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "content-type",
            },
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.headers["access-control-allow-origin"],
            "https://useblink.dev",
        )

    def test_admin_lists_rows_and_hides_private_fields_by_default(self) -> None:
        self.client.post(
            "/v1/beta-signup",
            json={"email": "person@example.com", "source": "site"},
            headers={"user-agent": "unit-test"},
        )
        response = self.client.get(
            "/v1/admin/beta-signups",
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(response.status_code, 200)
        item = response.json()["items"][0]
        self.assertEqual(item["email_original"], "person@example.com")
        self.assertNotIn("ip_hash", item)
        self.assertNotIn("user_agent", item)

    def test_admin_verbose_can_include_private_operational_fields(self) -> None:
        self.client.post("/v1/beta-signup", json={"email": "person@example.com"})
        response = self.client.get(
            "/v1/admin/beta-signups?verbose=1",
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(response.status_code, 200)
        item = response.json()["items"][0]
        self.assertIn("ip_hash", item)
        self.assertIn("user_agent", item)

    def test_pagination_uses_cursor(self) -> None:
        for i in range(3):
            self.client.post("/v1/beta-signup", json={"email": f"{i}@example.com"})

        first = self.client.get(
            "/v1/admin/beta-signups?limit=2",
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(first.status_code, 200)
        first_body = first.json()
        self.assertEqual(len(first_body["items"]), 2)
        self.assertIsNotNone(first_body["next_cursor"])

        second = self.client.get(
            f"/v1/admin/beta-signups?limit=2&cursor={first_body['next_cursor']}",
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(second.status_code, 200)
        self.assertEqual(len(second.json()["items"]), 1)


if __name__ == "__main__":
    unittest.main()
