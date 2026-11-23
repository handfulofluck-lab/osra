"""Unit and contract tests for `own_model_service.py` (dual v9b + v9 CPU service).

Planted-fault mutants covered by this suite (AGENTS.md §3):
  * M1 (fallback to rules): catching `AdapterUnavailable` and calling `model.analyze_text`
    -> breaks `test_scorer_failure_returns_502_never_falls_back_to_rules`.
  * M2 (silent safe on malformed output): defaulting missing/NaN/out-of-range scores to 0.0
    -> breaks `test_malformed_scorer_outputs_return_502_never_safe`.
  * M3 (flat 0.5 threshold instead of per-language `serving-v9-v9b.json`): ignoring
    language-specific thresholds -> breaks `test_per_language_thresholds_are_applied`.
  * M4 (single-model routing): routing `ar`/`fr` to `v9` or `en`/`tr`/`ur` to `v9b`
    -> breaks `test_language_routing_selects_v9b_for_ar_fr_and_v9_for_others`.
  * M5 (echoing input text on 422 / log leak): letting FastAPI's default validator echo
    invalid payloads or logging `data.text` -> breaks `test_validation_errors_and_logs_never_echo_text`.
  * M6 (unpinned S3 archive or tar traversal): accepting S3 fetch without `archive_sha256`
    or extracting `../escape` -> breaks `test_s3_fetch_requires_pinned_sha256` and
    `test_safe_extract_rejects_path_traversal_and_symlinks`.
"""

from __future__ import annotations

import hashlib
import io
import json
import logging
import math
import tarfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

import model as rules_model
import own_model_service as svc
from app import app

APPROVED_TEXT = "Synthetic staging fixture"
ARABIC_TEXT = "مرحبا كيف حالك اليوم"
URDU_TEXT = "تم کہاں جا رہے ہو بھائی"
FRENCH_TEXT = "Bonjour, comment ça va aujourd'hui?"
TURKISH_TEXT = "Bugün çok güzel bir gün geçiriyoruz"
PATH = "/analyze/staging-qa/own"

V9B_LOCAL_DIR = Path(r"C:\KARIM\ocl-study\gen\score\models\v9b\unpacked")
V9B_WEIGHTS_SHA256 = "158ca1f02c9840680e3aec82ab7f84d39e6cdd98481e5ff968ddf4ccca5f1d81"


def _zero_probs(**overrides: float) -> dict[str, float]:
    probs = {label: 0.01 for label in svc.LABELS}
    probs.update(overrides)
    return probs


def _make_stub_registry(
    v9b_scorer=None,
    v9_scorer=None,
) -> svc.OwnModelRegistry:
    cfg = svc.load_serving_config()
    models: dict[str, svc.LoadedModel] = {}
    if v9b_scorer is not None:
        models["v9b"] = svc.LoadedModel(
            tag="v9b",
            model_name="osra-own-v9b",
            model_sha256="b" * 64,
            scorer=v9b_scorer,
        )
    if v9_scorer is not None:
        models["v9"] = svc.LoadedModel(
            tag="v9",
            model_name="osra-own-v9",
            model_sha256="a" * 64,
            scorer=v9_scorer,
        )
    return svc.OwnModelRegistry(config=cfg, models=models)


@pytest.fixture
def armed_env(monkeypatch):
    digests = ",".join(
        hashlib.sha256(t.encode("utf-8")).hexdigest()
        for t in (APPROVED_TEXT, ARABIC_TEXT, URDU_TEXT, FRENCH_TEXT, TURKISH_TEXT)
    )
    monkeypatch.setenv("OSRA_DEPLOYMENT_SCOPE", "staging")
    monkeypatch.setenv("OSRA_STAGING_QA_OWN_MODEL_ENABLED", "1")
    monkeypatch.setenv("OSRA_STAGING_QA_FIXTURE_SHA256", digests)
    monkeypatch.setenv(
        "OSRA_STAGING_QA_EXPIRES_AT",
        (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat(),
    )
    monkeypatch.setenv("OSRA_OWN_MODEL_REGION", "eu-central-1")


def _payload(text: str = APPROVED_TEXT, **extra) -> dict:
    return {"text": text, "trace_id": str(uuid4()), **extra}


def test_serving_config_matches_pinned_sha256_and_contract():
    cfg = svc.load_serving_config()
    assert cfg.sha256 == svc.SERVING_CONFIG_SHA256
    assert cfg.labels == svc.LABELS
    assert cfg.max_len == 128
    assert cfg.activation == "sigmoid"
    assert cfg.model_by_lang["ar"] == "v9b"
    assert cfg.model_by_lang["fr"] == "v9b"
    for lang in ("en", "id", "ms", "tr", "ur"):
        assert cfg.model_by_lang[lang] == "v9"


def test_serving_config_rejects_digest_mismatch(tmp_path):
    tampered = tmp_path / "serving.json"
    tampered.write_text(svc.DEFAULT_SERVING_CONFIG_PATH.read_text(encoding="utf-8") + " ", encoding="utf-8")
    with pytest.raises(svc.AdapterUnavailable, match="digest mismatch"):
        svc.load_serving_config(tampered, expected_sha256=svc.SERVING_CONFIG_SHA256)


@pytest.mark.parametrize("name,value", [
    ("OSRA_DEPLOYMENT_SCOPE", "production"),
    ("OSRA_STAGING_QA_OWN_MODEL_ENABLED", "0"),
    ("OSRA_STAGING_QA_FIXTURE_SHA256", "*"),
    ("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", "yes"),
    ("OSRA_STAGING_QA_EXPIRES_AT", "2020-01-01T00:00:00Z"),
    ("OSRA_STAGING_QA_EXPIRES_AT", "2035-01-01T00:00:00Z"),
])
def test_staging_approval_gate_returns_404_when_unarmed(armed_env, monkeypatch, name, value):
    monkeypatch.setenv(name, value)
    monkeypatch.delenv("OSRA_STAGING_QA_ANALYZER_ENABLED", raising=False)
    reg = _make_stub_registry(v9b_scorer=lambda _: _zero_probs(), v9_scorer=lambda _: _zero_probs())
    monkeypatch.setattr(svc, "_registry", reg)

    res = TestClient(app).post(PATH, json=_payload())
    assert res.status_code == 404
    assert res.json() == {"detail": "not_found"}


def test_language_routing_selects_v9b_for_ar_fr_and_v9_for_others(armed_env, monkeypatch):
    # Mutant M4: routing ar/fr to v9 or en/id/ms/tr/ur to v9b breaks this test.
    calls: list[tuple[str, str]] = []

    def score_v9b(text: str):
        calls.append(("v9b", text))
        return _zero_probs()

    def score_v9(text: str):
        calls.append(("v9", text))
        return _zero_probs()

    monkeypatch.setattr(svc, "_registry", _make_stub_registry(v9b_scorer=score_v9b, v9_scorer=score_v9))
    client = TestClient(app)

    expected = [
        (ARABIC_TEXT, None, "ar", "osra-own-v9b", "v9b"),
        (FRENCH_TEXT, None, "fr", "osra-own-v9b", "v9b"),
        (URDU_TEXT, None, "ur", "osra-own-v9", "v9"),
        (TURKISH_TEXT, None, "tr", "osra-own-v9", "v9"),
        (APPROVED_TEXT, None, "en", "osra-own-v9", "v9"),
        (APPROVED_TEXT, "id", "id", "osra-own-v9", "v9"),
        (APPROVED_TEXT, "ms", "ms", "osra-own-v9", "v9"),
    ]
    for text, explicit_lang, exp_lang, exp_model, exp_tag in expected:
        calls.clear()
        body = _payload(text) if explicit_lang is None else _payload(text, lang=explicit_lang)
        res = client.post(PATH, json=body)
        assert res.status_code == 200, res.text
        data = res.json()
        assert data["lang"] == exp_lang
        assert data["model"] == exp_model
        assert data["region"] == "eu-central-1"
        assert data["thresholds_sha256"] == svc.SERVING_CONFIG_SHA256
        assert set(data["categories"]) == set(svc.LABELS) | {"safe"}
        assert calls == [(exp_tag, text)]


def test_per_language_thresholds_are_applied(armed_env, monkeypatch):
    # Mutant M3: using a flat 0.5 threshold flags en cyberbullying=0.95 (must stay safe since en cutoff=0.98)
    # and ar hate_speech=0.90 (must stay safe since ar cutoff=0.93).
    monkeypatch.setenv("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", "1")
    client = TestClient(app)

    # English cyberbullying at 0.95 < 0.98 -> NOT flagged.
    monkeypatch.setattr(
        svc,
        "_registry",
        _make_stub_registry(v9_scorer=lambda _: _zero_probs(cyberbullying=0.95)),
    )
    res_en_safe = client.post(PATH, json=_payload("benign teasing", lang="en"))
    assert res_en_safe.status_code == 200
    assert res_en_safe.json()["flagged"] is False
    assert res_en_safe.json()["severity"] == "info"
    assert res_en_safe.json()["flagged_categories"] == []

    # English cyberbullying at 0.985 >= 0.98 -> FLAGGED critical.
    monkeypatch.setattr(
        svc,
        "_registry",
        _make_stub_registry(v9_scorer=lambda _: _zero_probs(cyberbullying=0.985)),
    )
    res_en_flag = client.post(PATH, json=_payload("severe bullying", lang="en"))
    assert res_en_flag.status_code == 200
    assert res_en_flag.json()["flagged"] is True
    assert res_en_flag.json()["severity"] == "critical"
    assert res_en_flag.json()["flagged_categories"] == ["cyberbullying"]

    # Arabic cyberbullying at 0.55 >= 0.50 -> FLAGGED warning (< 0.85).
    monkeypatch.setattr(
        svc,
        "_registry",
        _make_stub_registry(v9b_scorer=lambda _: _zero_probs(cyberbullying=0.55)),
    )
    res_ar_flag = client.post(PATH, json=_payload(ARABIC_TEXT, lang="ar"))
    assert res_ar_flag.status_code == 200
    assert res_ar_flag.json()["flagged"] is True
    assert res_ar_flag.json()["severity"] == "warning"
    assert res_ar_flag.json()["flagged_categories"] == ["cyberbullying"]

    # Arabic hate_speech at 0.90 < 0.93 -> NOT flagged.
    monkeypatch.setattr(
        svc,
        "_registry",
        _make_stub_registry(v9b_scorer=lambda _: _zero_probs(hate_speech=0.90)),
    )
    res_ar_safe = client.post(PATH, json=_payload(ARABIC_TEXT, lang="ar"))
    assert res_ar_safe.status_code == 200
    assert res_ar_safe.json()["flagged"] is False
    assert res_ar_safe.json()["severity"] == "info"


def test_scorer_failure_returns_502_never_falls_back_to_rules(armed_env, monkeypatch):
    # Mutant M1: falling back to `model.analyze_text` on load/score failure breaks this test.
    def boom(_text: str):
        raise svc.AdapterUnavailable("simulated checkpoint outage")

    def forbid_rules(*args, **kwargs):
        raise AssertionError("rules fallback must never be called by own_model_service")

    monkeypatch.setattr(rules_model, "analyze_text", forbid_rules)
    monkeypatch.setattr(svc, "_registry", _make_stub_registry(v9_scorer=boom))

    res = TestClient(app).post(PATH, json=_payload())
    assert res.status_code == 502
    assert res.json() == {"detail": "model_unavailable"}


@pytest.mark.parametrize("bad_output", [
    {},
    {"cyberbullying": 0.9},  # missing 6 labels
    {**_zero_probs(), "extra_label": 0.1},
    {**_zero_probs(), "violence": float("nan")},
    {**_zero_probs(), "violence": 1.2},
    {**_zero_probs(), "violence": -0.01},
    {**_zero_probs(), "violence": True},
    "not-a-dict",
])
def test_malformed_scorer_outputs_return_502_never_safe(armed_env, monkeypatch, bad_output):
    # Mutant M2: defaulting malformed/NaN/missing scores to 0.0 / safe breaks this test.
    monkeypatch.setattr(svc, "_registry", _make_stub_registry(v9_scorer=lambda _: bad_output))

    res = TestClient(app).post(PATH, json=_payload())
    assert res.status_code == 502
    assert res.json() == {"detail": "model_unavailable"}


def test_validation_errors_and_logs_never_echo_text(armed_env, monkeypatch, caplog):
    # Mutant M5: echoing input text in 422 responses or INFO/WARNING logs breaks this test.
    child_probe_text = "unique-child-message-sentinel-98231"
    monkeypatch.setenv("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", "1")
    monkeypatch.setattr(svc, "_registry", _make_stub_registry(v9_scorer=lambda _: _zero_probs()))
    client = TestClient(app)

    # Extra unknown field -> 422 without echoing text.
    res_bad = client.post(PATH, json={"text": child_probe_text, "trace_id": str(uuid4()), "extra": 1})
    assert res_bad.status_code == 422
    assert res_bad.json() == {"detail": "invalid_request"}
    assert child_probe_text not in res_bad.text

    # Unknown explicit lang -> 422 without echoing text.
    res_lang = client.post(PATH, json={"text": child_probe_text, "trace_id": str(uuid4()), "lang": "de"})
    assert res_lang.status_code == 422
    assert child_probe_text not in res_lang.text

    # Valid call -> logs must not contain the message text.
    with caplog.at_level(logging.INFO, logger=svc.__name__):
        res_ok = client.post(PATH, json={"text": child_probe_text, "trace_id": str(uuid4())})
    assert res_ok.status_code == 200
    assert child_probe_text not in caplog.text


def test_standalone_app_exposes_staging_qa_contract(armed_env, monkeypatch):
    monkeypatch.setattr(svc, "_registry", _make_stub_registry(v9_scorer=lambda _: _zero_probs()))
    client = TestClient(svc.own_model_app)

    health = client.get("/health")
    assert health.status_code == 200
    assert health.json()["ok"] is True
    assert health.json()["thresholds_sha256"] == svc.SERVING_CONFIG_SHA256

    res = client.post("/analyze/staging-qa", json=_payload())
    assert res.status_code == 200
    assert res.json()["model"] == "osra-own-v9"


def test_s3_fetch_requires_pinned_sha256(tmp_path):
    # Mutant M6: allowing an unpinned S3 download breaks this test.
    with pytest.raises(svc.AdapterUnavailable, match="pinned archive SHA-256 is required"):
        svc.ensure_model_dir(
            "v9",
            s3_bucket="example-bucket",
            s3_key="output/v9/model.tar.gz",
            archive_sha256=None,
            cache_dir=str(tmp_path),
        )


def test_s3_fetch_downloads_verifies_sha_and_extracts(tmp_path):
    archive_bytes = io.BytesIO()
    with tarfile.open(fileobj=archive_bytes, mode="w:gz") as tar:
        for fname in svc.MANIFEST_FILES:
            data = json.dumps({"id2label": {str(i): lbl for i, lbl in enumerate(svc.LABELS)}}).encode("utf-8") if fname == "config.json" else b"stub"
            info = tarfile.TarInfo(name=fname)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    payload_bytes = archive_bytes.getvalue()
    expected_sha = hashlib.sha256(payload_bytes).hexdigest()

    class StubS3:
        def __init__(self):
            self.calls = 0

        def download_file(self, bucket, key, filename):
            self.calls += 1
            assert bucket == "test-bucket"
            assert key == "output/v9/model.tar.gz"
            Path(filename).write_bytes(payload_bytes)

    s3 = StubS3()
    model_dir = svc.ensure_model_dir(
        "v9",
        s3_bucket="test-bucket",
        s3_key="output/v9/model.tar.gz",
        archive_sha256=expected_sha,
        cache_dir=str(tmp_path),
        s3_client=s3,
    )
    assert s3.calls == 1
    assert all((model_dir / fname).is_file() for fname in svc.MANIFEST_FILES)

    # Second call hits local verified cache without re-downloading.
    cached_dir = svc.ensure_model_dir(
        "v9",
        s3_bucket="test-bucket",
        s3_key="output/v9/model.tar.gz",
        archive_sha256=expected_sha,
        cache_dir=str(tmp_path),
        s3_client=s3,
    )
    assert cached_dir == model_dir
    assert s3.calls == 1

    # Mismatched archive SHA must fail loudly.
    with pytest.raises(svc.AdapterUnavailable, match="digest mismatch"):
        svc.ensure_model_dir(
            "v9",
            s3_bucket="test-bucket",
            s3_key="output/v9/model.tar.gz",
            archive_sha256="0" * 64,
            cache_dir=str(tmp_path),
            s3_client=s3,
        )


def test_safe_extract_rejects_path_traversal_and_symlinks(tmp_path):
    # Mutant M6: raw tar.extractall without member validation breaks this test.
    evil_tar = tmp_path / "evil.tar.gz"
    with tarfile.open(evil_tar, "w:gz") as tar:
        info = tarfile.TarInfo(name="../escape.txt")
        info.size = 4
        tar.addfile(info, io.BytesIO(b"evil"))
    with pytest.raises(svc.AdapterUnavailable, match="unsafe path traversal"):
        svc._safe_extract_tar_gz(evil_tar, tmp_path / "out")

    link_tar = tmp_path / "link.tar.gz"
    with tarfile.open(link_tar, "w:gz") as tar:
        info = tarfile.TarInfo(name="config.json")
        info.type = tarfile.SYMTYPE
        info.linkname = "/etc/passwd"
        tar.addfile(info)
    with pytest.raises(svc.AdapterUnavailable, match="unsupported link"):
        svc._safe_extract_tar_gz(link_tar, tmp_path / "out2")


def _has_local_v9b_and_torch() -> bool:
    if not V9B_LOCAL_DIR.is_dir():
        return False
    try:
        import torch  # noqa: F401
        import transformers  # noqa: F401
    except ImportError:
        return False
    return True


@pytest.mark.skipif(not _has_local_v9b_and_torch(), reason="local v9b checkpoint or torch/transformers absent")
def test_live_v9b_checkpoint_cpu_smoke():
    manifest = svc.manifest_of(V9B_LOCAL_DIR)
    loaded = svc.load_hf_cpu_model("v9b", V9B_LOCAL_DIR, expected_manifest=manifest)
    assert loaded.model_sha256 == V9B_WEIGHTS_SHA256
    reg = svc.OwnModelRegistry(config=svc.load_serving_config(), models={"v9b": loaded})
    lang, model_obj, probs, flagged, cfg_sha = reg.score(ARABIC_TEXT, lang="ar")
    assert lang == "ar"
    assert model_obj.model_name == "osra-own-v9b"
    assert cfg_sha == svc.SERVING_CONFIG_SHA256
    assert set(probs) == set(svc.LABELS)
    assert all(0.0 <= v <= 1.0 and math.isfinite(v) for v in probs.values())
    assert flagged == ()
