import os
import time

import pytest
import requests


def _is_http_ready(url: str, *, timeout_s: float) -> bool:
    try:
        # Any HTTP response means the server is listening.
        requests.get(url, timeout=timeout_s)
        return True
    except requests.RequestException:  # pragma: no cover
        return False


@pytest.fixture(scope="session", autouse=True)
def wait_for_openresty() -> None:
    """Wait until the OpenResty container is accepting connections.

    Docker-compose `up -d` can return before the port is ready. This fixture
    reduces flakiness in CI and local runs by waiting briefly.

    We intentionally treat *any* HTTP response as ready, so this works for both
    auth and no-auth modes.
    """

    base_url = os.getenv("BASE_URL", "http://localhost:8080/webhook").rstrip("/")

    # `_stats` is commonly exempted from auth; but even if it isn't, any HTTP
    # status code means the service is alive.
    probe_urls = [
        f"{base_url}/_stats",
        base_url,
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
        f"OpenResty did not become ready in time. Tried: {', '.join(probe_urls)}"
    )  # pragma: no cover
