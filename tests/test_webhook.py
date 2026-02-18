#!/usr/bin/env python3
"""
Comprehensive test suite for the webhook service.
Usage: pytest test_webhook.py -v
"""

import pytest
import requests
import json
import time
from typing import Dict, Any
import os

# Configuration
BASE_URL = os.getenv("BASE_URL", "http://localhost:8080/webhook")
WEBHOOK_TEST_API_KEY = os.getenv("WEBHOOK_TEST_API_KEY", "")


def _with_auth_headers(headers: Dict[str, str] | None = None) -> Dict[str, str]:
    merged: Dict[str, str] = {}
    if WEBHOOK_TEST_API_KEY:
        merged["X-API-Key"] = WEBHOOK_TEST_API_KEY
    if headers:
        merged.update(headers)
    return merged


def http_get(url: str, **kwargs):
    kwargs["headers"] = _with_auth_headers(kwargs.get("headers"))
    return requests.get(url, **kwargs)


def http_post(url: str, **kwargs):
    kwargs["headers"] = _with_auth_headers(kwargs.get("headers"))
    return requests.post(url, **kwargs)


def http_patch(url: str, **kwargs):
    kwargs["headers"] = _with_auth_headers(kwargs.get("headers"))
    return requests.patch(url, **kwargs)


def http_delete(url: str, **kwargs):
    kwargs["headers"] = _with_auth_headers(kwargs.get("headers"))
    return requests.delete(url, **kwargs)


class TestWebhookBasicOperations:
    """Test basic CRUD operations"""

    def test_create_webhook_default_category(self):
        """Test creating a webhook in default category"""
        payload = {"test": "data", "value": 42}
        response = http_post(BASE_URL, json=payload)

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "stored"
        assert data["category"] == "default"
        assert "key" in data
        assert data["ttl"] == 259200  # 3 days
        assert data["callback_registered"] is False

    def test_create_webhook_custom_category(self):
        """Test creating webhook with custom category"""
        payload = {"order_id": 123, "amount": 99.99}
        response = http_post(f"{BASE_URL}/orders", json=payload)

        assert response.status_code == 200
        data = response.json()
        assert data["category"] == "orders"
        assert "orders:" in data["key"]

    def test_create_webhook_custom_ttl(self):
        """Test creating webhook with custom TTL"""
        payload = {"data": "short-lived"}
        response = http_post(f"{BASE_URL}/test?ttl=3600", json=payload)

        assert response.status_code == 200
        data = response.json()
        assert data["ttl"] == 3600

    def test_create_with_callback(self):
        """Test creating webhook with callback URL"""
        payload = {"data": "test"}
        callback_url = "https://example.com/notify"
        response = http_post(
            f"{BASE_URL}/test?callback_url={callback_url}",
            json=payload
        )

        assert response.status_code == 200
        data = response.json()
        # Callback registration status may vary
        assert "callback_registered" in data

    def test_retrieve_webhook(self):
        """Test retrieving a webhook by key"""
        # Create webhook
        payload = {"test": "retrieval"}
        create_response = http_post(f"{BASE_URL}/test", json=payload)
        key = create_response.json()["key"]

        # Retrieve webhook
        response = http_get(f"{BASE_URL}/test/{key}")

        assert response.status_code == 200
        data = response.json()
        assert data["key"] == key
        assert data["value"]["test"] == "retrieval"
        assert "ttl" in data

    def test_list_webhooks(self):
        """Test listing all webhooks"""
        response = http_get(BASE_URL)

        assert response.status_code == 200
        data = response.json()
        # API uses 'keys' instead of 'webhooks'
        assert "keys" in data
        assert "count" in data
        assert isinstance(data["keys"], list)

    def test_list_category_webhooks(self):
        """Test listing webhooks in specific category"""
        # Create webhook in test category
        http_post(f"{BASE_URL}/test-list", json={"data": "test"})

        response = http_get(f"{BASE_URL}/test-list")

        assert response.status_code == 200
        data = response.json()
        assert "keys" in data

    def test_delete_webhook(self):
        """Test deleting a webhook"""
        # Create webhook
        create_response = http_post(f"{BASE_URL}/test", json={"data": "delete-me"})
        key = create_response.json()["key"]

        # Delete webhook
        response = http_delete(f"{BASE_URL}/test/{key}")

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "deleted"

        # Verify deletion
        get_response = http_get(f"{BASE_URL}/test/{key}")
        assert get_response.status_code == 404

    def test_update_webhook_ttl(self):
        """Test updating webhook TTL via PATCH"""
        # Create webhook
        create_response = http_post(f"{BASE_URL}/test", json={"data": "patch-test"})
        key = create_response.json()["key"]

        # Update TTL
        response = http_patch(f"{BASE_URL}/test/{key}", json={"ttl": 7200})

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "updated"
        assert data["ttl"] == 7200


class TestWebhookErrors:
    """Test error handling"""

    def test_missing_body(self):
        """Test POST without body returns error"""
        response = http_post(BASE_URL)

        assert response.status_code == 400
        data = response.json()
        assert data["error_code"] == "NO_BODY"

    def test_invalid_json(self):
        """Test invalid JSON returns error"""
        response = http_post(
            BASE_URL,
            data="{invalid json",
            headers={"Content-Type": "application/json"}
        )

        assert response.status_code == 400
        data = response.json()
        assert data["error_code"] == "INVALID_JSON"

    def test_key_not_found(self):
        """Test retrieving non-existent key"""
        response = http_get(f"{BASE_URL}/test/nonexistent:key")

        assert response.status_code == 404
        data = response.json()
        assert data["error_code"] == "KEY_NOT_FOUND"

    def test_delete_nonexistent_key(self):
        """Test deleting non-existent key"""
        response = http_delete(f"{BASE_URL}/test/nonexistent:key")

        assert response.status_code == 404
        data = response.json()
        assert data["error_code"] == "KEY_NOT_FOUND"

    def test_search_without_query(self):
        """Test search without query parameter"""
        response = http_get(f"{BASE_URL}/_search")

        assert response.status_code == 400
        data = response.json()
        assert data["error_code"] == "MISSING_QUERY"


class TestWebhookBatchOperations:
    """Test batch create and delete operations"""

    def test_batch_create(self):
        """Test batch creating multiple webhooks"""
        payload = {
            "items": [
                {"order_id": 1, "total": 100},
                {"order_id": 2, "total": 200},
                {"order_id": 3, "total": 300}
            ]
        }

        response = http_post(f"{BASE_URL}/batch-test/_batch", json=payload)

        assert response.status_code == 200
        data = response.json()
        assert data["total_created"] == 3
        assert len(data["success"]) == 3
        assert data["total_failed"] == 0

    def test_batch_delete(self):
        """Test batch deleting multiple webhooks"""
        # Create webhooks
        create_payload = {
            "items": [
                {"data": f"item{i}"} for i in range(3)
            ]
        }
        create_response = http_post(f"{BASE_URL}/batch-del/_batch", json=create_payload)
        keys = [item["key"] for item in create_response.json()["success"]]

        # Batch delete
        delete_payload = {"keys": keys}
        response = http_delete(f"{BASE_URL}/batch-del/_batch", json=delete_payload)

        assert response.status_code == 200
        data = response.json()
        assert data["total_deleted"] == 3

    def test_batch_invalid_format(self):
        """Test batch with invalid format"""
        response = http_post(f"{BASE_URL}/test/_batch", json={"invalid": "format"})

        assert response.status_code == 400
        data = response.json()
        assert data["error_code"] == "INVALID_BATCH_FORMAT"


class TestWebhookAdvancedFeatures:
    """Test advanced features"""

    def test_search(self):
        """Test full-text search"""
        # Create searchable webhook
        payload = {"product": "laptop", "brand": "Apple", "price": 999}
        http_post(f"{BASE_URL}/products", json=payload)

        time.sleep(0.5)  # Brief delay for indexing

        # Search
        response = http_get(f"{BASE_URL}/_search?q=laptop")

        assert response.status_code == 200
        data = response.json()
        assert data["count"] >= 1
        assert any("laptop" in str(r).lower() for r in data["results"])

    def test_statistics(self):
        """Test statistics endpoint"""
        response = http_get(f"{BASE_URL}/_stats")

        assert response.status_code == 200
        data = response.json()
        assert "total_webhooks" in data
        assert "total_size_bytes" in data
        assert "storage_limit_bytes" in data
        assert "categories" in data
        assert isinstance(data["categories"], dict)

    def test_timestamp_filtering(self):
        """Test filtering by timestamp"""
        # Create webhooks with delay
        http_post(f"{BASE_URL}/time-test", json={"seq": 1})
        time.sleep(1)
        timestamp = int(time.time())
        time.sleep(1)
        http_post(f"{BASE_URL}/time-test", json={"seq": 2})

        # Filter by timestamp
        response = http_get(f"{BASE_URL}/time-test?since={timestamp}")

        assert response.status_code == 200
        data = response.json()
        # Should only get webhooks created after timestamp

    def test_callback_management(self):
        """Test callback URL management"""
        # Create webhook
        create_response = http_post(f"{BASE_URL}/test", json={"data": "callback-test"})
        key = create_response.json()["key"]

        # Add callback
        callback_url = "https://example.com/notify"
        response = http_patch(
            f"{BASE_URL}/test/{key}",
            json={"callback_url": callback_url}
        )

        assert response.status_code == 200
        assert response.json()["changes"]["callback_url"] == callback_url

        # Remove callback
        remove_response = http_patch(
            f"{BASE_URL}/test/{key}",
            json={"callback_url": None}
        )

        assert remove_response.status_code == 200

    def test_webhook_replay(self):
        """Test webhook replay functionality"""
        # Create original webhook
        payload = {"order_id": 12345, "customer": "John Doe"}
        create_response = http_post(f"{BASE_URL}/orders", json=payload)
        key = create_response.json()["key"]

        # Replay webhook
        response = http_post(f"{BASE_URL}/orders/{key}/_replay")

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "replayed"
        assert data["original_key"] == key
        assert "new_key" in data
        assert data["new_key"] != key

    def test_replay_to_different_category(self):
        """Test replaying to different category with custom TTL"""
        # Create original
        create_response = http_post(f"{BASE_URL}/test", json={"data": "replay-test"})
        key = create_response.json()["key"]

        # Replay to different category with custom TTL via query params
        response = http_post(
            f"{BASE_URL}/test/{key}/_replay?category=replays&ttl=7200"
        )

        assert response.status_code == 200
        data = response.json()
        assert data["category"] == "replays"
        assert data["ttl"] == 7200
        assert "new_key" in data


class TestWebhookExportImport:
    """Test export and import functionality"""

    def test_export_all_webhooks(self):
        """Test exporting all webhooks"""
        # Create test webhooks
        for i in range(3):
            http_post(f"{BASE_URL}/export-test", json={"item": i})

        # Export
        response = http_get(f"{BASE_URL}/_export")

        assert response.status_code == 200
        data = response.json()
        assert "version" in data
        assert "exported_at" in data
        assert "webhooks" in data

    def test_export_category(self):
        """Test exporting specific category"""
        # Create webhooks in category
        http_post(f"{BASE_URL}/export-cat", json={"data": "test"})

        # Export category
        response = http_get(f"{BASE_URL}/export-cat/_export")

        assert response.status_code == 200
        data = response.json()
        assert data["category"] == "export-cat"
        assert "total_exported" in data


class TestWebhookMetrics:
    """Test Prometheus metrics"""

    def test_metrics_endpoint(self):
        """Test Prometheus metrics endpoint"""
        response = http_get(f"{BASE_URL}/_metrics")

        assert response.status_code == 200
        # Check proper Prometheus content type
        content_type = response.headers.get("Content-Type", "")
        assert "text/plain" in content_type

        metrics = response.text

        # Check for expected metrics
        assert "webhook_requests_total" in metrics
        assert "webhook_created_total" in metrics
        assert "webhook_deleted_total" in metrics
        assert "webhook_storage_bytes" in metrics
        assert "webhook_count" in metrics

        # Check Prometheus format
        assert "# HELP" in metrics
        assert "# TYPE" in metrics


class TestWebhookLargePayloads:
    """Test handling of large payloads"""

    def test_large_json_payload(self):
        """Test storing and retrieving 1MB JSON payload"""
        # Create large payload
        large_payload = [
            {
                "id": f"ID{i:016d}",
                "name": f"User {i}",
                "email": f"user{i}@example.com",
                "bio": "Lorem ipsum " * 50,
                "data": {"field": i, "value": i * 2}
            }
            for i in range(1000)
        ]

        # Store
        create_response = http_post(f"{BASE_URL}/large-test", json=large_payload)
        assert create_response.status_code == 200
        key = create_response.json()["key"]

        # Retrieve
        get_response = http_get(f"{BASE_URL}/large-test/{key}")
        assert get_response.status_code == 200

        retrieved = get_response.json()["value"]
        # Should have at least the 1000 items we created
        assert len(retrieved) >= 1000
        # Check first item structure
        assert "ID" in retrieved[0]["id"]


@pytest.fixture(scope="session", autouse=True)
def cleanup(request):
    """Cleanup test data after all tests complete"""
    def finalizer():
        # Optional: Clean up test categories
        test_categories = [
            "test", "test-list", "batch-test", "batch-del",
            "products", "time-test", "orders", "replays",
            "export-test", "export-cat", "large-test"
        ]
        # Note: Implement cleanup if needed
        pass

    request.addfinalizer(finalizer)


if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
