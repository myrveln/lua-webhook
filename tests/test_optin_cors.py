#!/usr/bin/env python3

import os
import requests

import pytest


BASE_URL = os.getenv("BASE_URL", "http://localhost:8080/webhook").rstrip("/")
API_KEY = os.getenv("WEBHOOK_TEST_API_KEY", "")
OPTIN = os.getenv("WEBHOOK_TEST_OPTIN", "")

pytestmark = pytest.mark.skipif(
    OPTIN != "cors",
    reason="opt-in test: set WEBHOOK_TEST_OPTIN=cors and enable CORS in the server",
)


def _headers() -> dict:
    h: dict = {}
    if API_KEY:
        h["X-API-Key"] = API_KEY
    # Simulate a browser origin.
    h["Origin"] = "https://example.test"
    return h


@pytest.mark.integration
def test_cors_headers_present_when_enabled() -> None:
    # Requires WEBHOOK_CORS_ALLOW_ORIGIN to be set in the server.
    resp = requests.options(BASE_URL, headers=_headers(), timeout=5)
    assert resp.status_code == 204

    # With CORS enabled, server should emit allow-origin.
    allow_origin = resp.headers.get("Access-Control-Allow-Origin")
    assert allow_origin is not None and allow_origin != ""


@pytest.mark.integration
def test_cors_exposes_expected_headers() -> None:
    resp = requests.options(BASE_URL, headers=_headers(), timeout=5)
    assert resp.status_code == 204

    expose = resp.headers.get("Access-Control-Expose-Headers", "")
    # We document X-Next-Cursor and storage headers.
    assert "X-Next-Cursor" in expose
    assert "X-Storage-Used" in expose
