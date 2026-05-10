from __future__ import annotations

import json
import unittest

from server.cache import ThreadCache


class FakeRedis:
    def __init__(self) -> None:
        self.values: dict[str, str] = {}
        self.setex_calls: list[tuple[str, int, str]] = []

    def get(self, key: str) -> str | None:
        return self.values.get(key)

    def setex(self, key: str, ttl: int, value: str) -> None:
        self.values[key] = value
        self.setex_calls.append((key, ttl, value))


class ThreadCacheTests(unittest.TestCase):
    def test_thread_json_round_trip_and_ttl(self) -> None:
        redis = FakeRedis()
        cache = ThreadCache(client=redis, ttl_seconds=600, enabled=True)
        payload = {
            "schema_version": 1,
            "root_request_id": "root",
            "turns": [{"role": "model", "tldr": "Done"}],
        }

        cache.set_thread(token_id="tok", root_request_id="root", payload=payload)

        self.assertEqual(cache.get_thread(token_id="tok", root_request_id="root"), payload)
        self.assertEqual(redis.setex_calls[0][0], "tldr:v1:thread:tok:root")
        self.assertEqual(redis.setex_calls[0][1], 600)

    def test_disabled_cache_is_a_miss_and_noops_set(self) -> None:
        redis = FakeRedis()
        cache = ThreadCache(client=redis, ttl_seconds=600, enabled=False)

        cache.set_thread(token_id="tok", root_request_id="root", payload={"turns": []})

        self.assertIsNone(cache.get_thread(token_id="tok", root_request_id="root"))
        self.assertEqual(redis.setex_calls, [])

    def test_corrupt_json_is_a_miss(self) -> None:
        redis = FakeRedis()
        cache = ThreadCache(client=redis, ttl_seconds=600, enabled=True)
        redis.values["tldr:v1:thread:tok:root"] = "{not json"

        self.assertIsNone(cache.get_thread(token_id="tok", root_request_id="root"))

    def test_root_alias_round_trip_and_refresh(self) -> None:
        redis = FakeRedis()
        cache = ThreadCache(client=redis, ttl_seconds=600, enabled=True)

        cache.set_root_alias(
            token_id="tok",
            request_id="reroll-1",
            root_request_id="root",
        )
        cache.set_root_alias(
            token_id="tok",
            request_id="reroll-1",
            root_request_id="root",
        )

        self.assertEqual(cache.resolve_root(token_id="tok", request_id="reroll-1"), "root")
        self.assertEqual(len(redis.setex_calls), 2)
        self.assertTrue(all(call[1] == 600 for call in redis.setex_calls))
        self.assertEqual(json.loads(json.dumps(redis.values)), redis.values)


if __name__ == "__main__":
    unittest.main()
