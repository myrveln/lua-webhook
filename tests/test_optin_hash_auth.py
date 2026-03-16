#!/usr/bin/env python3

import os

import pytest
import requests


BASE_URL = os.getenv("BASE_URL", "http://localhost:8080/webhook").rstrip("/")
PLAIN_KEY = os.getenv("WEBHOOK_TEST_API_KEY", "")
OPTIN = os.getenv("WEBHOOK_TEST_OPTIN", "")

pytestmark = pytest.mark.skipif(
    OPTIN != "hash_auth",
    reason="opt-in test: set WEBHOOK_TEST_OPTIN=hash_auth and enable WEBHOOK_API_KEY_HASHES in the server",
)


def _headers() -> dict:
    return {"X-API-Key": PLAIN_KEY}


@pytest.mark.integration
def test_hashed_api_key_allows_access() -> None:
    # Requires the server to be configured with WEBHOOK_API_KEY_HASHES
    # matching WEBHOOK_TEST_API_KEY, and with WEBHOOK_API_KEYS unset.
    if not PLAIN_KEY:
        pytest.skip("WEBHOOK_TEST_API_KEY not set")

    r = requests.get(BASE_URL, headers=_headers(), timeout=5)
    assert r.status_code == 200


@pytest.mark.integration
def test_hashed_api_key_rejects_wrong_key() -> None:
    r = requests.get(BASE_URL, headers={"X-API-Key": "definitely-wrong"}, timeout=5)
    assert r.status_code == 403
