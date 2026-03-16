#!/usr/bin/env python3

import os

import pytest
import requests


BASE_URL = os.getenv("BASE_URL", "http://localhost:8080/webhook").rstrip("/")
API_KEY = os.getenv("WEBHOOK_TEST_API_KEY", "")
OPTIN = os.getenv("WEBHOOK_TEST_OPTIN", "")

pytestmark = pytest.mark.skipif(
    OPTIN != "callback_allowlist",
    reason="opt-in test: set WEBHOOK_TEST_OPTIN=callback_allowlist and set WEBHOOK_CALLBACK_URL_ALLOWLIST in the server",
)


def _headers() -> dict:
    h: dict = {}
    if API_KEY:
        h["X-API-Key"] = API_KEY
    return h


@pytest.mark.integration
def test_callback_allowlist_accepts_allowed_host() -> None:
    # Requires WEBHOOK_CALLBACK_URL_ALLOWLIST to include example.com.
    r = requests.post(
        f"{BASE_URL}/cb-allow?callback_url=https://example.com/notify",
        json={"ok": True},
        headers=_headers(),
        timeout=5,
    )
    assert r.status_code == 200


@pytest.mark.integration
def test_callback_allowlist_rejects_other_host() -> None:
    r = requests.post(
        f"{BASE_URL}/cb-allow?callback_url=https://evil.com/notify",
        json={"ok": True},
        headers=_headers(),
        timeout=5,
    )
    assert r.status_code == 400
    assert r.json().get("error_code") == "INVALID_CALLBACK_URL"
