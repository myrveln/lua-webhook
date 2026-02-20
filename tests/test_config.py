#!/usr/bin/env python3
"""Configuration override tests for lua-webhook.

These tests validate the *module override* mechanism in webhook.lua.

They assume a second OpenResty instance is running (see docker-compose.yml):
- Service: openresty_config
- Port: 8081
- WEBHOOK_CONFIG_MODULE=webhook_config_test
"""

import os
import time
import json

import pytest
import requests


BASE_URL_CONFIG = os.getenv("BASE_URL_CONFIG", "http://localhost:8081/webhook").rstrip("/")
CONFIG_API_KEY = os.getenv("WEBHOOK_TEST_CONFIG_API_KEY", "test-config-key")

EXPECTED_DEFAULT_CATEGORY = os.getenv("WEBHOOK_TEST_CONFIG_EXPECTED_CATEGORY", "cfg")
EXPECTED_DEFAULT_TTL = int(os.getenv("WEBHOOK_TEST_CONFIG_EXPECTED_TTL", "4242"))
EXPECTED_MAX_BODY_SIZE = int(os.getenv("WEBHOOK_TEST_CONFIG_EXPECTED_MAX_BODY_SIZE", "256"))
EXPECTED_TOTAL_PAYLOAD_LIMIT = int(os.getenv("WEBHOOK_TEST_CONFIG_EXPECTED_TOTAL_PAYLOAD_LIMIT", "360"))


def _headers_x_api_key(key: str) -> dict:
    return {"X-API-Key": key}


def _headers_json_and_key(key: str) -> dict:
    h = _headers_x_api_key(key)
    h["Content-Type"] = "application/json"
    return h


def _get_stats() -> dict:
    resp = requests.get(f"{BASE_URL_CONFIG}/_stats")
    assert resp.status_code == 200
    return resp.json()


def _list_keys() -> list[str]:
    resp = requests.get(BASE_URL_CONFIG, headers=_headers_x_api_key(CONFIG_API_KEY))
    assert resp.status_code == 200
    data = resp.json()
    items = data.get("keys") or []
    assert isinstance(items, list)

    out: list[str] = []
    for item in items:
        if isinstance(item, str) and item:
            out.append(item)
        elif isinstance(item, dict):
            k = item.get("key")
            if isinstance(k, str) and k:
                out.append(k)
    return out


def test__list_keys_accepts_string_items(monkeypatch: pytest.MonkeyPatch) -> None:
    class _Resp:
        status_code = 200

        def json(self):
            return {"keys": ["k1", {"key": "k2"}]}

    monkeypatch.setattr(requests, "get", lambda *args, **kwargs: _Resp())
    assert _list_keys() == ["k1", "k2"]


def _delete_keys(keys: list[str]) -> None:
    if not keys:
        return
    resp = requests.delete(
        f"{BASE_URL_CONFIG}/{EXPECTED_DEFAULT_CATEGORY}/_batch",
        headers=_headers_x_api_key(CONFIG_API_KEY),
        json={"keys": keys},
    )
    # If the server rejected the request, show detail.
    assert resp.status_code == 200, resp.text


def test__delete_keys_empty_is_noop(monkeypatch: pytest.MonkeyPatch) -> None:
    called = {"delete": False}

    def _mark_called(*args, **kwargs):
        called["delete"] = True

    monkeypatch.setattr(requests, "delete", _mark_called)
    _delete_keys([])
    assert called["delete"] is False


def _compact_json(obj: dict) -> str:
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def _payload_body_with_pad(pad_len: int) -> str:
    return _compact_json({"pad": "x" * pad_len})


@pytest.fixture(autouse=True)
def cleanup_config_storage() -> None:
    """Keep config tests deterministic by deleting any keys they created.

    The config-enabled OpenResty instance shares a Valkey with other services,
    so we isolate via PREFIX in the module and still clean up between tests.
    """

    keys = _list_keys()
    if keys:
        _delete_keys(keys)

    # Force a stats read to ensure total_size is recalculated/updated.
    _get_stats()


def _is_http_ready(url: str, *, timeout_s: float) -> bool:
    try:
        requests.get(url, timeout=timeout_s)
        return True
    except requests.RequestException:  # pragma: no cover
        return False


@pytest.fixture(scope="session", autouse=True)
def wait_for_openresty_config() -> None:
    """Wait until the config-enabled OpenResty container is accepting connections."""

    probe_urls = [
        f"{BASE_URL_CONFIG}/_stats",  # exempt by test module
        BASE_URL_CONFIG,
    ]

    deadline = time.monotonic() + float(os.getenv("WEBHOOK_TEST_STARTUP_TIMEOUT_S", "20"))
    sleep_s = 0.1

    while time.monotonic() < deadline:
        for probe_url in probe_urls:
            if _is_http_ready(probe_url, timeout_s=0.5):
                return

        time.sleep(sleep_s)  # pragma: no cover
        sleep_s = min(sleep_s * 1.5, 1.0)  # pragma: no cover

    raise RuntimeError(
        f"Config OpenResty did not become ready in time. Tried: {', '.join(probe_urls)}"
    )  # pragma: no cover


@pytest.mark.integration
class TestWebhookConfigModule:
    def test_stats_is_exempt_without_auth(self):
        """AUTH_EXEMPT in the module should allow _stats without a key."""
        resp = requests.get(f"{BASE_URL_CONFIG}/_stats")
        assert resp.status_code == 200

    def test_auth_is_enabled_via_module(self):
        """API_KEYS in the module should require auth on non-exempt endpoints."""
        no_auth = requests.get(BASE_URL_CONFIG)
        assert no_auth.status_code == 401

        ok = requests.get(BASE_URL_CONFIG, headers=_headers_x_api_key(CONFIG_API_KEY))
        assert ok.status_code == 200

    def test_default_category_is_overridden(self):
        """DEFAULT_CATEGORY from the module should affect POST /webhook (no category)."""
        resp = requests.post(
            BASE_URL_CONFIG,
            json={"config": "category"},
            headers=_headers_x_api_key(CONFIG_API_KEY),
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["category"] == EXPECTED_DEFAULT_CATEGORY

    def test_default_ttl_is_overridden(self):
        """DEFAULT_TTL from the module should affect POST without an explicit ttl."""
        resp = requests.post(
            BASE_URL_CONFIG,
            json={"config": "ttl"},
            headers=_headers_x_api_key(CONFIG_API_KEY),
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["ttl"] == EXPECTED_DEFAULT_TTL

    def test_max_body_size_is_enforced(self):
        """MAX_BODY_SIZE from the module should reject oversized bodies."""
        body = _payload_body_with_pad(EXPECTED_MAX_BODY_SIZE + 50)
        assert len(body.encode("utf-8")) > EXPECTED_MAX_BODY_SIZE

        resp = requests.post(
            BASE_URL_CONFIG,
            headers=_headers_json_and_key(CONFIG_API_KEY),
            data=body,
        )
        assert resp.status_code == 413
        data = resp.json()
        assert data.get("error_code") == "PAYLOAD_TOO_LARGE"

    def test_total_payload_limit_is_enforced(self):
        """TOTAL_PAYLOAD_LIMIT should reject requests when storage would exceed the limit."""

        # Sanity: ensure we start clean.
        stats = _get_stats()
        assert stats.get("storage_limit_bytes") == EXPECTED_TOTAL_PAYLOAD_LIMIT
        assert int(stats.get("total_size_bytes") or 0) == 0

        # Find a body size that will succeed once but fail on the second request.
        pad_len = 1
        # Keep some headroom for JSON syntax characters.
        max_pad = max(1, EXPECTED_MAX_BODY_SIZE - 16)
        for candidate in range(max_pad, 0, -1):
            candidate_body = _payload_body_with_pad(candidate)
            candidate_len = len(candidate_body.encode("utf-8"))
            if candidate_len <= EXPECTED_MAX_BODY_SIZE and candidate_len < EXPECTED_TOTAL_PAYLOAD_LIMIT:
                if (candidate_len * 2) > EXPECTED_TOTAL_PAYLOAD_LIMIT:
                    pad_len = candidate
                    break

        body = _payload_body_with_pad(pad_len)
        body_len = len(body.encode("utf-8"))
        assert body_len <= EXPECTED_MAX_BODY_SIZE
        assert body_len < EXPECTED_TOTAL_PAYLOAD_LIMIT
        assert (body_len * 2) > EXPECTED_TOTAL_PAYLOAD_LIMIT

        first = requests.post(
            BASE_URL_CONFIG,
            headers=_headers_json_and_key(CONFIG_API_KEY),
            data=body,
        )
        assert first.status_code == 200, first.text

        second = requests.post(
            BASE_URL_CONFIG,
            headers=_headers_json_and_key(CONFIG_API_KEY),
            data=body,
        )
        assert second.status_code == 413
        data = second.json()
        assert data.get("error_code") == "STORAGE_LIMIT_EXCEEDED"
