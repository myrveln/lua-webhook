#!/usr/bin/env python3

import os

import pytest
import requests


BASE_URL = os.getenv("BASE_URL", "http://localhost:8080/webhook").rstrip("/")
API_KEY = os.getenv("WEBHOOK_TEST_API_KEY", "")
OPTIN = os.getenv("WEBHOOK_TEST_OPTIN", "")

pytestmark = pytest.mark.skipif(
    OPTIN != "rate_limit",
    reason="opt-in test: set WEBHOOK_TEST_OPTIN=rate_limit and enable rate limiting in the server",
)


def _headers() -> dict:
    h: dict = {}
    if API_KEY:
        h["X-API-Key"] = API_KEY
    return h


@pytest.mark.integration
def test_rate_limit_enforced() -> None:
    # Requires WEBHOOK_RATE_LIMIT_ENABLED=true with a low max.
    # Use a distinct endpoint category so we don't depend on existing state.
    url = f"{BASE_URL}/rl"

    # Burst a few requests; at least one should be 429.
    statuses = []
    for _ in range(10):
        r = requests.get(url, headers=_headers(), timeout=5)
        statuses.append(r.status_code)
        if r.status_code == 429:
            break

    assert 429 in statuses


@pytest.mark.integration
def test_rate_limit_metrics_exported() -> None:
    # Generate one 429 first.
    url = f"{BASE_URL}/rl-metrics"
    for _ in range(10):
        r = requests.get(url, headers=_headers(), timeout=5)
        if r.status_code == 429:
            break

    metrics = requests.get(f"{BASE_URL}/_metrics", headers=_headers(), timeout=5)
    assert metrics.status_code == 200
    body = metrics.text
    assert "webhook_rate_limited_total" in body
