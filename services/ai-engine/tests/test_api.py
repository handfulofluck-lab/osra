"""Smoke tests for the FastAPI app; skipped when fastapi is not installed."""

import pytest

pytest.importorskip("fastapi")

from fastapi.testclient import TestClient

from app import app


@pytest.fixture(scope="module")
def client():
    """Shared TestClient for the app."""
    return TestClient(app)


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"ok": True}


def test_analyze_flags_harmful_text(client):
    response = client.post(
        "/analyze",
        json={"text": "kill yourself", "context": "message", "child_age": 13},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["flagged"] is True
    assert body["severity"] == "critical"
    assert body["categories"]["self_harm"] > 0.6


def test_analyze_passes_innocent_text(client):
    response = client.post("/analyze", json={"text": "math homework"})
    assert response.status_code == 200
    body = response.json()
    assert body["flagged"] is False
    assert body["severity"] == "info"
