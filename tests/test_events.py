#!/usr/bin/env python3
"""Event publishing tests.

The service publishes JSON events to the Valkey/Redis Pub/Sub channel
`webhook:events`. Clients can consume this channel directly, and the WebSocket
endpoint (`GET /webhook/_ws`) bridges the same channel to WS clients.

These tests validate the Pub/Sub publishing behavior.
"""

from __future__ import annotations

import json
import os
import time
from typing import Dict

import pytest
import redis
import requests


BASE_URL = os.getenv("BASE_URL", "http://localhost:8080/webhook")
WEBHOOK_TEST_API_KEY = os.getenv("WEBHOOK_TEST_API_KEY", "")

REDIS_HOST = os.getenv("VALKEY_HOST") or os.getenv("REDIS_HOST") or "127.0.0.1"
REDIS_PORT = int(os.getenv("VALKEY_PORT") or os.getenv("REDIS_PORT") or "6379")


def _auth_headers(headers: Dict[str, str] | None = None) -> Dict[str, str]:
    merged: Dict[str, str] = {}
    if WEBHOOK_TEST_API_KEY:
        merged["X-API-Key"] = WEBHOOK_TEST_API_KEY
    if headers:
        merged.update(headers)
    return merged


class _FakePubSub:
    def __init__(self, messages: list[dict | None]):
        self._messages = list(messages)

    def get_message(self, *args, **kwargs):
        if self._messages:
            return self._messages.pop(0)
        return None


def _wait_for_event(pubsub: redis.client.PubSub, timeout_s: float = 5.0) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        msg = pubsub.get_message(ignore_subscribe_messages=True, timeout=1.0)
        if not msg:
            continue
        if msg.get("type") != "message":
            continue
        raw = msg.get("data")
        if isinstance(raw, (bytes, bytearray)):
            raw = raw.decode("utf-8", errors="replace")
        try:
            return json.loads(raw)
        except Exception:
            continue
    raise AssertionError(f"No event received within {timeout_s}s")


def _wait_for_subscribed(pubsub: redis.client.PubSub, channel: str, timeout_s: float = 5.0) -> None:
    """Ensure SUBSCRIBE has been processed before we publish.

    redis-py sends SUBSCRIBE asynchronously; without waiting, tests can race and
    miss the first message.
    """

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        msg = pubsub.get_message(ignore_subscribe_messages=False, timeout=1.0)
        if not msg:
            continue
        if msg.get("type") == "subscribe":
            subscribed_channel = msg.get("channel")
            if isinstance(subscribed_channel, (bytes, bytearray)):
                subscribed_channel = subscribed_channel.decode("utf-8", errors="replace")
            if subscribed_channel == channel:
                return
    raise AssertionError(f"Did not observe subscribe confirmation for {channel} within {timeout_s}s")


@pytest.mark.integration
class TestWebhookEventPublishing:
    def test_create_publishes_event(self):
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=False)
        pubsub = r.pubsub()
        pubsub.subscribe("webhook:events")
        _wait_for_subscribed(pubsub, "webhook:events")

        try:
            payload = {"event_test": "created"}
            resp = requests.post(
                f"{BASE_URL}/events",
                json=payload,
                headers=_auth_headers({"X-Test-Header": "1"}),
            )
            assert resp.status_code == 200
            key = resp.json()["key"]

            event = _wait_for_event(pubsub)
            assert event["type"] == "webhook.created"
            assert event["data"]["category"] == "events"
            assert event["data"]["key"] == key
            assert "timestamp" in event
        finally:
            try:
                pubsub.close()
            except Exception:  # pragma: no cover
                pass  # pragma: no cover

    def test_delete_publishes_event(self):
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=False)
        pubsub = r.pubsub()
        pubsub.subscribe("webhook:events")
        _wait_for_subscribed(pubsub, "webhook:events")

        try:
            # Create then delete
            create = requests.post(
                f"{BASE_URL}/events",
                json={"event_test": "delete"},
                headers=_auth_headers(),
            )
            assert create.status_code == 200
            key = create.json()["key"]

            delete = requests.delete(f"{BASE_URL}/events/{key}", headers=_auth_headers())
            assert delete.status_code == 200

            # There may be a created event first; consume until we see deleted.
            deadline = time.time() + 5.0
            while True:
                if time.time() > deadline:
                    raise AssertionError("No webhook.deleted event received")  # pragma: no cover
                event = _wait_for_event(pubsub, timeout_s=1.0)
                if event.get("type") == "webhook.deleted" and event.get("data", {}).get("key") == key:
                    assert event["data"]["category"] == "events"
                    break
        finally:
            try:
                pubsub.close()
            except Exception:  # pragma: no cover
                pass  # pragma: no cover


def test__auth_headers_merges_dict() -> None:
    hdrs = _auth_headers({"X-Extra": "1"})
    assert hdrs.get("X-Extra") == "1"


def test__wait_for_event_skips_and_parses() -> None:
    pubsub = _FakePubSub(
        [
            None,
            {"type": "subscribe"},
            {"type": "message", "data": b"{\"ok\": true}"},
        ]
    )
    event = _wait_for_event(pubsub, timeout_s=0.1)
    assert event == {"ok": True}


def test__wait_for_event_bad_json_then_raises() -> None:
    pubsub = _FakePubSub(
        [
            {"type": "message", "data": b"{not-json"},
        ]
    )
    with pytest.raises(AssertionError):
        _wait_for_event(pubsub, timeout_s=0.01)


def test__wait_for_subscribed_raises_when_missing() -> None:
    pubsub = _FakePubSub([None, None, None])
    with pytest.raises(AssertionError):
        _wait_for_subscribed(pubsub, "webhook:events", timeout_s=0.01)
