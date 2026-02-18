#!/usr/bin/env python3
"""Authentication tests for the webhook service.

These tests assume the OpenResty service is running with:
- WEBHOOK_API_KEYS set to a comma-separated list of API keys
- WEBHOOK_AUTH_EXEMPT includes _stats (so healthchecks can work)

They validate:
- Missing key => 401
- Invalid key => 403
- Valid key => normal CRUD works
- Exempt endpoint (_stats) works without auth
"""

import os
import requests

import pytest


BASE_URL = os.getenv("BASE_URL", "http://localhost:8080/webhook")
API_KEY = os.getenv("WEBHOOK_TEST_API_KEY", "")


def _headers_bearer(key: str) -> dict:
    return {"Authorization": f"Bearer {key}"}


def _headers_x_api_key(key: str) -> dict:
    return {"X-API-Key": key}


@pytest.mark.integration
class TestWebhookAuthentication:
    def test_stats_endpoint_exempt(self):
        """If _stats is in WEBHOOK_AUTH_EXEMPT, it must work without a key."""
        response = requests.get(f"{BASE_URL}/_stats")
        assert response.status_code == 200

    def test_missing_api_key_is_401(self):
        response = requests.get(BASE_URL)
        assert response.status_code == 401
        data = response.json()
        assert data.get("error_code") == "AUTH_REQUIRED"

    def test_invalid_api_key_is_403(self):
        response = requests.get(BASE_URL, headers=_headers_x_api_key("definitely-wrong"))
        assert response.status_code == 403
        data = response.json()
        assert data.get("error_code") == "AUTH_INVALID"

    def test_valid_api_key_allows_crud(self):
        if not API_KEY:
            pytest.skip("WEBHOOK_TEST_API_KEY not set")  # pragma: no cover

        headers = _headers_x_api_key(API_KEY)

        # Create
        payload = {"auth": "ok"}
        create = requests.post(f"{BASE_URL}/auth", json=payload, headers=headers)
        assert create.status_code == 200
        key = create.json()["key"]

        # Retrieve
        get_resp = requests.get(f"{BASE_URL}/auth/{key}", headers=_headers_bearer(API_KEY))
        assert get_resp.status_code == 200
        assert get_resp.json()["value"]["auth"] == "ok"

        # Update TTL
        patch = requests.patch(f"{BASE_URL}/auth/{key}", json={"ttl": 3600}, headers=headers)
        assert patch.status_code == 200
        assert patch.json()["status"] == "updated"

        # Delete
        delete = requests.delete(f"{BASE_URL}/auth/{key}", headers=headers)
        assert delete.status_code == 200
        assert delete.json()["status"] == "deleted"

    def test_metrics_requires_auth_and_exports_auth_counters(self):
        if not API_KEY:
            pytest.skip("WEBHOOK_TEST_API_KEY not set")  # pragma: no cover

        # Generate a couple auth failures
        requests.get(BASE_URL)
        requests.get(BASE_URL, headers=_headers_x_api_key("definitely-wrong"))

        # Metrics endpoint should require auth (since we only exempt _stats in CI)
        no_auth = requests.get(f"{BASE_URL}/_metrics")
        assert no_auth.status_code == 401

        metrics = requests.get(f"{BASE_URL}/_metrics", headers=_headers_bearer(API_KEY))
        assert metrics.status_code == 200
        body = metrics.text
        assert "webhook_auth_missing_total" in body
        assert "webhook_auth_invalid_total" in body
