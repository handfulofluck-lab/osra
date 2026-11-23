"""Tests for `v9b_service`. No checkpoint, no network: the adapter is injected as a stub.

Each test names the mutant it kills, and the two that matter most are the refusals the analyzer's current provider
gets wrong: an unavailable model must not answer with a verdict, and a bad scorer response must not come back `safe`.
"""
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from v9b_adapter import LABELS, AdapterUnavailable, Scored  # noqa: E402
from v9b_service import create_app  # noqa: E402


class _StubAdapter:
    def __init__(self, outcome):
        self._outcome = outcome
        self.calls = []

    def score(self, text, lang):
        self.calls.append((text, lang))
        if isinstance(self._outcome, Exception):
            raise self._outcome
        return self._outcome


def _scored(probs=None, flagged=("grooming",)) -> Scored:
    values = probs or {label: 0.02 for label in LABELS}
    return Scored(
        probs=values,
        flagged_categories=tuple(flagged),
        verdict="flagged" if flagged else "safe",
        model_sha256="a" * 64,
        thresholds_sha256="b" * 64,
    )


def test_health_reports_ready_when_the_adapter_loaded():
    client = TestClient(create_app(adapter=_StubAdapter(_scored())))
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["labels"] == list(LABELS)


def test_health_reports_unavailable_without_answering_scores():
    # Mutant: start the app with a stub that returns a default verdict when the model is missing -> the
    # "unavailable" status disappears and a downstream caller cannot tell a model failure from a safe text.
    class _Unavailable:
        def score(self, text, lang):
            raise AdapterUnavailable("checkpoint digests do not match the pin")

    client = TestClient(create_app(adapter=_Unavailable()))
    health = client.get("/health")
    assert health.status_code == 503
    assert health.json()["loaded"] is False

    scored = client.post("/score", json={"text": "hello", "lang": "en"})  # still refused after the failed warm-up
    assert scored.status_code == 503
    assert scored.json()["error"] == "adapter_unavailable"
    assert "verdict" not in scored.json()


def test_score_returns_the_adapter_result_unchanged():
    stub = _StubAdapter(_scored())
    client = TestClient(create_app(adapter=stub))
    response = client.post("/score", json={"text": "the teacher said there is a test", "lang": "en"})
    assert response.status_code == 200
    body = response.json()
    assert body["verdict"] == "flagged"
    assert list(body["probs"]) == list(LABELS)
    assert body["model_sha256"] == "a" * 64 and body["thresholds_sha256"] == "b" * 64
    # The first call is the start-up warm-up; the request must be the last one, with its arguments unchanged.
    assert stub.calls[-1] == ("the teacher said there is a test", "en")


class _FailsAfterWarmup:
    """Ready at start-up, failing on the next call: the only shape that reaches the /score error branch.

    A stub that raises immediately is caught by the start-up warm-up, so /score returns 503 before it ever runs the
    handler's try/except — and a mutant that turns a scoring failure into a `safe` verdict then passes unnoticed.
    """

    def __init__(self):
        self.calls = 0

    def score(self, text, lang):
        self.calls += 1
        if self.calls > 1:
            raise AdapterUnavailable("score is not a probability in [0, 1]")
        return _scored()


def test_a_scorer_failure_is_an_error_not_a_safe_verdict():
    # The failure mode this service exists to prevent: catching AdapterUnavailable and answering "safe" turns a
    # broken model into a clean bill of health for every text.
    client = TestClient(create_app(adapter=_FailsAfterWarmup()))
    response = client.post("/score", json={"text": "anything", "lang": "en"})
    assert response.status_code == 503
    body = response.json()
    assert "verdict" not in body and "probs" not in body
    assert body["error"] == "adapter_unavailable"


def test_empty_text_and_missing_language_are_refused_at_the_edge():
    client = TestClient(create_app(adapter=_StubAdapter(_scored())))
    assert client.post("/score", json={"text": "", "lang": "en"}).status_code == 422
    assert client.post("/score", json={"text": "hi"}).status_code == 422


def test_the_service_refuses_to_start_without_the_environment(monkeypatch):
    # A deployment that boots without its pins would serve whatever checkpoint happened to be on disk.
    for name in ("V9B_MODEL_DIR", "V9B_THRESHOLDS", "V9B_THRESHOLDS_SHA256", "V9B_MANIFEST"):
        monkeypatch.delenv(name, raising=False)
    client = TestClient(create_app())
    health = client.get("/health")
    assert health.status_code == 503
    assert health.json()["loaded"] is False
    assert "V9B_MODEL_DIR" in (health.json()["reason"] or "")
