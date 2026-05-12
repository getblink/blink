from __future__ import annotations

import os
import unittest
from typing import Any
from unittest import mock

from fastapi.testclient import TestClient

from server import auth
from server import main as server_main
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
        referrer_signup_id: str | None = None,
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
                "referrer_signup_id": referrer_signup_id,
                "created_at": f"2026-05-08T02:{len(self.rows):02d}:00+00:00",
            }
        )
        return True

    def get_beta_signup_by_id(self, signup_id: str) -> dict[str, Any] | None:
        for row in self.rows:
            if row["id"] == signup_id:
                return {
                    "id": row["id"],
                    "email_normalized": row["email_normalized"],
                    "email_original": row["email_original"],
                    "ip_hash": row["ip_hash"],
                }
        return None

    def get_beta_signup_id_for_email(self, email_normalized: str) -> str | None:
        for row in self.rows:
            if row["email_normalized"] == email_normalized:
                return row["id"]
        return None

    def count_beta_referrals(self, signup_id: str) -> int:
        return sum(
            1 for row in self.rows if row.get("referrer_signup_id") == signup_id
        )


class BetaSignupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = mock.patch.dict(
            os.environ,
            {
                "BLINK_BOOTSTRAP_TOKEN": "bootstrap-secret",
                "BLINK_IP_HASH_SALT": "test-salt",
                "BLINK_SIGNUP_RATE_LIMIT_PER_MINUTE": "5",
                "BLINK_SIGNUP_RATE_LIMIT_PER_DAY": "50",
                "BLINK_SIGNUP_STATS_RATE_LIMIT_PER_MINUTE": "60",
                "BLINK_TRUST_PROXY_HEADERS": "1",
            },
            clear=False,
        )
        self.env.start()
        auth._SIGNUP_RATE_LIMIT_MINUTE_BUCKETS.clear()
        auth._SIGNUP_RATE_LIMIT_DAY_BUCKETS.clear()
        auth._SIGNUP_STATS_RATE_LIMIT_MINUTE_BUCKETS.clear()
        self.store = FakeSignupStore()
        self.store_patch = mock.patch("server.main._telemetry_store", return_value=self.store)
        self.store_patch.start()
        self.client = TestClient(app)

    def tearDown(self) -> None:
        self.store_patch.stop()
        self.env.stop()
        auth._SIGNUP_RATE_LIMIT_MINUTE_BUCKETS.clear()
        auth._SIGNUP_RATE_LIMIT_DAY_BUCKETS.clear()
        auth._SIGNUP_STATS_RATE_LIMIT_MINUTE_BUCKETS.clear()

    def test_signup_records_normalized_email(self) -> None:
        response = self.client.post(
            "/v1/beta-signup",
            json={"email": "  Person@Example.COM  ", "source": "site"},
            headers={"user-agent": "unit-test"},
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["ok"])
        self.assertFalse(body["already_signed_up"])
        self.assertEqual(len(body["signup_id"]), 32)
        self.assertEqual(len(self.store.rows), 1)
        row = self.store.rows[0]
        self.assertEqual(body["signup_id"], row["id"])
        self.assertEqual(row["email_normalized"], "person@example.com")
        self.assertEqual(row["email_original"], "Person@Example.COM")
        self.assertEqual(row["source"], "site")
        self.assertEqual(row["user_agent"], "unit-test")
        self.assertEqual(len(row["ip_hash"]), 64)

    def test_signup_is_idempotent_by_normalized_email(self) -> None:
        first = self.client.post("/v1/beta-signup", json={"email": "A@B.co"})
        second = self.client.post("/v1/beta-signup", json={"email": "  a@b.CO  "})
        self.assertEqual(first.status_code, 200)
        self.assertTrue(first.json()["ok"])
        self.assertFalse(first.json()["already_signed_up"])
        self.assertEqual(second.status_code, 200)
        second_body = second.json()
        self.assertTrue(second_body["ok"])
        self.assertTrue(second_body["already_signed_up"])
        # Duplicate response now surfaces the original signup_id so the same
        # browser can still show the referral share row.
        self.assertEqual(second_body["signup_id"], first.json()["signup_id"])
        self.assertEqual(len(self.store.rows), 1)

    def test_discord_webhook_fires_on_new_signup_only(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"BLINK_DISCORD_SIGNUP_WEBHOOK_URL": "https://discord.example/hook"},
            clear=False,
        ):
            calls: list[dict[str, Any]] = []

            async def fake_notify(**kwargs: Any) -> None:
                calls.append(kwargs)

            with mock.patch.object(server_main, "_notify_discord_signup", fake_notify):
                first = self.client.post(
                    "/v1/beta-signup",
                    json={"email": "fan@example.com", "source": "site"},
                )
                second = self.client.post(
                    "/v1/beta-signup",
                    json={"email": "fan@example.com"},
                )

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertTrue(second.json()["already_signed_up"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["email_original"], "fan@example.com")
        self.assertEqual(calls[0]["source"], "site")
        self.assertEqual(len(calls[0]["signup_id"]), 32)

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

    def test_duplicate_from_foreign_ip_omits_signup_id(self) -> None:
        first = self.client.post(
            "/v1/beta-signup",
            json={"email": "victim@example.com"},
            headers={"x-forwarded-for": "10.0.0.1"},
        )
        self.assertIn("signup_id", first.json())
        second = self.client.post(
            "/v1/beta-signup",
            json={"email": "victim@example.com"},
            headers={"x-forwarded-for": "10.0.0.99"},
        )
        body = second.json()
        self.assertTrue(body["already_signed_up"])
        self.assertNotIn("signup_id", body)

    def test_referral_persists_when_ref_valid(self) -> None:
        first = self.client.post(
            "/v1/beta-signup",
            json={"email": "alice@example.com"},
            headers={"x-forwarded-for": "10.0.0.1"},
        )
        self.assertEqual(first.status_code, 200)
        referrer_id = first.json()["signup_id"]
        second = self.client.post(
            "/v1/beta-signup",
            json={"email": "bob@example.com", "ref": referrer_id},
            headers={"x-forwarded-for": "10.0.0.2"},
        )
        self.assertEqual(second.status_code, 200)
        self.assertEqual(self.store.rows[1]["referrer_signup_id"], referrer_id)

    def test_referral_with_invalid_ref_is_dropped_silently(self) -> None:
        bad_refs = ["", "not-hex", "a" * 31, "a" * 33, "g" * 32]
        for ref in bad_refs:
            self.store.rows.clear()
            auth._SIGNUP_RATE_LIMIT_MINUTE_BUCKETS.clear()
            response = self.client.post(
                "/v1/beta-signup",
                json={"email": f"u-{ref or 'empty'}@example.com", "ref": ref},
            )
            self.assertEqual(response.status_code, 200)
            self.assertIsNone(self.store.rows[0]["referrer_signup_id"])

    def test_referral_with_unknown_ref_is_dropped(self) -> None:
        response = self.client.post(
            "/v1/beta-signup",
            json={"email": "solo@example.com", "ref": "0" * 32},
        )
        self.assertEqual(response.status_code, 200)
        self.assertIsNone(self.store.rows[0]["referrer_signup_id"])

    def test_self_referral_by_email_is_dropped(self) -> None:
        first = self.client.post(
            "/v1/beta-signup",
            json={"email": "self@example.com"},
            headers={"x-forwarded-for": "10.0.0.1"},
        )
        referrer_id = first.json()["signup_id"]
        second = self.client.post(
            "/v1/beta-signup",
            json={"email": "  Self@Example.com  ", "ref": referrer_id},
            headers={"x-forwarded-for": "10.0.0.2"},
        )
        self.assertEqual(second.status_code, 200)
        # Same email -> duplicate row; ref must not have been applied to the
        # original row, which still has referrer_signup_id == None.
        self.assertEqual(len(self.store.rows), 1)
        self.assertIsNone(self.store.rows[0]["referrer_signup_id"])

    def test_same_ip_referral_is_allowed(self) -> None:
        # Shared IPs (households, offices, campus Wi-Fi) are common, so we
        # do not treat a matching ip_hash as self-referral. Only the email
        # guard fires.
        first = self.client.post(
            "/v1/beta-signup",
            json={"email": "first@example.com"},
            headers={"x-forwarded-for": "10.0.0.42"},
        )
        referrer_id = first.json()["signup_id"]
        second = self.client.post(
            "/v1/beta-signup",
            json={"email": "second@example.com", "ref": referrer_id},
            headers={"x-forwarded-for": "10.0.0.42"},
        )
        self.assertEqual(second.status_code, 200)
        self.assertEqual(self.store.rows[1]["email_normalized"], "second@example.com")
        self.assertEqual(self.store.rows[1]["referrer_signup_id"], referrer_id)

    def test_discord_webhook_includes_referrer_when_ref_valid(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"BLINK_DISCORD_SIGNUP_WEBHOOK_URL": "https://discord.example/hook"},
            clear=False,
        ):
            calls: list[dict[str, Any]] = []

            async def fake_notify(**kwargs: Any) -> None:
                calls.append(kwargs)

            with mock.patch.object(server_main, "_notify_discord_signup", fake_notify):
                first = self.client.post(
                    "/v1/beta-signup",
                    json={"email": "ref@example.com"},
                    headers={"x-forwarded-for": "10.0.0.1"},
                )
                referrer_id = first.json()["signup_id"]
                self.client.post(
                    "/v1/beta-signup",
                    json={"email": "invited@example.com", "ref": referrer_id},
                    headers={"x-forwarded-for": "10.0.0.2"},
                )
        self.assertEqual(len(calls), 2)
        self.assertIsNone(calls[0].get("referrer_signup_id"))
        self.assertEqual(calls[1]["referrer_signup_id"], referrer_id)
        self.assertEqual(calls[1]["referrer_email"], "ref@example.com")

    def test_stats_endpoint_returns_referral_count(self) -> None:
        first = self.client.post(
            "/v1/beta-signup",
            json={"email": "host@example.com"},
            headers={"x-forwarded-for": "10.0.0.1"},
        )
        host_id = first.json()["signup_id"]
        for i, ip in enumerate(["10.0.0.2", "10.0.0.3"]):
            self.client.post(
                "/v1/beta-signup",
                json={"email": f"guest{i}@example.com", "ref": host_id},
                headers={"x-forwarded-for": ip},
            )
        response = self.client.get(f"/v1/beta-signup/{host_id}/stats")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["ok"])
        self.assertEqual(body["referrals"], 2)

    def test_stats_endpoint_returns_404_for_unknown_id(self) -> None:
        response = self.client.get(f"/v1/beta-signup/{'a' * 32}/stats")
        self.assertEqual(response.status_code, 404)

    def test_stats_endpoint_rejects_malformed_id(self) -> None:
        response = self.client.get("/v1/beta-signup/not-a-hex/stats")
        self.assertEqual(response.status_code, 404)

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

if __name__ == "__main__":
    unittest.main()
