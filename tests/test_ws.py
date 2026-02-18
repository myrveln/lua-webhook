#!/usr/bin/env python3
"""WebSocket endpoint tests.

These tests validate the real WebSocket stream at:
  GET /webhook/_ws

The server streams the same JSON events it publishes to Valkey/Redis pub/sub
channel `webhook:events`.

No pytest-asyncio plugin is required; tests use asyncio.run().
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Dict
from urllib.parse import urlparse

import pytest
import requests
import websockets


BASE_URL = os.getenv("BASE_URL", "http://localhost:8080/webhook")
WEBHOOK_TEST_API_KEY = os.getenv("WEBHOOK_TEST_API_KEY", "")


def _auth_headers(headers: Dict[str, str] | None = None) -> Dict[str, str]:
    merged: Dict[str, str] = {}
    if WEBHOOK_TEST_API_KEY:
        merged["X-API-Key"] = WEBHOOK_TEST_API_KEY
    if headers:
        merged.update(headers)
    return merged


def _ws_url() -> str:
    parsed = urlparse(BASE_URL)
    ws_scheme = "wss" if parsed.scheme == "https" else "ws"
    base_path = (parsed.path or "/webhook").rstrip("/")
    return f"{ws_scheme}://{parsed.netloc}{base_path}/_ws"


async def _recv_json(ws: websockets.WebSocketClientProtocol, timeout_s: float = 5.0) -> dict:
    raw = await asyncio.wait_for(ws.recv(), timeout=timeout_s)
    return json.loads(raw)


async def _connect_ws_with_retry(
    ws_url: str,
    headers: Dict[str, str],
    timeout_s: float = 10.0,
) -> websockets.WebSocketClientProtocol:
    deadline = asyncio.get_running_loop().time() + timeout_s
    last_err: Exception | None = None
    while asyncio.get_running_loop().time() < deadline:
        try:
            # Some environments set HTTP(S)_PROXY even for localhost; ensure we
            # don't accidentally go through a proxy for integration tests.
            try:
                return await websockets.connect(ws_url, additional_headers=headers, proxy=None)
            except TypeError:
                # Older websockets versions don't support the proxy kwarg.
                return await websockets.connect(ws_url, additional_headers=headers)
        except Exception as exc:
            last_err = exc
            await asyncio.sleep(0.1)
    raise AssertionError(f"Failed to connect to WebSocket within {timeout_s}s: {last_err}")


@pytest.mark.integration
def test_websocket_receives_created_event() -> None:
    ws_url = _ws_url()
    http_headers = _auth_headers()
    ws_headers = _auth_headers()

    async def _run() -> None:
        ws = await _connect_ws_with_retry(ws_url, ws_headers)
        async with ws:
            ready = await _recv_json(ws)
            assert ready.get("type") == "webhook.ws_ready"

            def _create_noise() -> str:
                resp = requests.post(
                    f"{BASE_URL}/ws",
                    json={"ws": "noise"},
                    headers=http_headers,
                    timeout=5,
                )
                assert resp.status_code == 200
                return resp.json()["key"]

            def _delete(key: str) -> None:
                resp = requests.delete(f"{BASE_URL}/ws/{key}", headers=http_headers, timeout=5)
                assert resp.status_code == 200

            def _create() -> requests.Response:
                return requests.post(
                    f"{BASE_URL}/ws",
                    json={"ws": "created"},
                    headers=http_headers,
                    timeout=5,
                )

            loop = asyncio.get_running_loop()
            noise_key: str = await loop.run_in_executor(None, _create_noise)
            await loop.run_in_executor(None, _delete, noise_key)
            resp: requests.Response = await loop.run_in_executor(None, _create)
            assert resp.status_code == 200
            created_key = resp.json()["key"]

            deadline = loop.time() + 5.0
            while True:
                remaining = deadline - loop.time()
                if remaining <= 0:
                    raise AssertionError("Timed out waiting for webhook.created over WebSocket")  # pragma: no cover

                event = await _recv_json(ws, timeout_s=min(remaining, 5.0))
                if event.get("type") != "webhook.created":
                    continue
                if event.get("data", {}).get("key") != created_key:
                    continue
                assert event.get("data", {}).get("category") == "ws"
                break

    asyncio.run(_run())


def test__auth_headers_merges_dict() -> None:
    hdrs = _auth_headers({"X-Extra": "1"})
    assert hdrs.get("X-Extra") == "1"


def test__connect_ws_with_retry_falls_back_on_typeerror(monkeypatch) -> None:
    # Deliberately omit the `proxy` kwarg from this stub so the first call
    # (which passes `proxy=None`) raises a TypeError.
    async def fake_connect(url: str, additional_headers: Dict[str, str]):
        return object()

    monkeypatch.setattr(websockets, "connect", fake_connect)

    async def _run() -> None:
        ws = await _connect_ws_with_retry("ws://example.invalid", {}, timeout_s=0.01)
        assert ws is not None

    asyncio.run(_run())


def test__connect_ws_with_retry_times_out(monkeypatch) -> None:
    async def fake_connect(*args, **kwargs):
        raise RuntimeError("nope")

    async def fake_sleep(_seconds: float):
        return None

    monkeypatch.setattr(websockets, "connect", fake_connect)
    monkeypatch.setattr(asyncio, "sleep", fake_sleep)

    async def _run() -> None:
        with pytest.raises(AssertionError):
            await _connect_ws_with_retry("ws://example.invalid", {}, timeout_s=0.01)

    asyncio.run(_run())
