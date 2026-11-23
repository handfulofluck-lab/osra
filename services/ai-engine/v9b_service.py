"""HTTP surface for the offline v9b adapter: `/health` and `/score`.

Why this is thin on purpose: everything that decides *whether* a text is harmful lives in `v9b_adapter.py`, and that
module refuses to answer at all when its checkpoint, thresholds or scorer output are not exactly what was pinned. This
service adds nothing to that decision — no rule merge, no default verdict, no retry that hides a bad load. Its whole job
is to carry `{text, lang}` in and `{probs, flagged_categories, verdict, digests}` out.

Two failure modes it deliberately does **not** paper over, because the analyzer's current provider shows both:

  * a checkpoint that will not load must surface as an error, never as a rules-derived verdict;
  * a malformed scorer response must surface as an error, never as `safe`.

Both arrive here as `AdapterUnavailable` and become a `503` with a fixed reason string. A caller that wants a fallback
can decide that itself; this service will not decide it silently.

Configuration (all required — the service refuses to start without them, so a deployment cannot run against a guessed
model):

  V9B_MODEL_DIR          directory holding the unpacked checkpoint
  V9B_THRESHOLDS         per-language thresholds JSON (the frozen `compare-v9b.json` shape)
  V9B_THRESHOLDS_SHA256  expected digest of that file
  V9B_MANIFEST           JSON object of the six checkpoint file digests, or a path to a JSON file holding it
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from v9b_adapter import LABELS, AdapterUnavailable, V9bAdapter


class ScoreRequest(BaseModel):
    text: str = Field(min_length=1)
    lang: str = Field(min_length=1)


def _manifest_from_env() -> dict[str, str]:
    raw = os.environ.get("V9B_MANIFEST", "").strip()
    if not raw:
        raise RuntimeError("V9B_MANIFEST is required: the six checkpoint digests must be pinned")
    if raw.startswith("{"):
        manifest = json.loads(raw)
    else:
        manifest = json.loads(Path(raw).read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or not manifest:
        raise RuntimeError("V9B_MANIFEST must be a non-empty object of file -> sha256")
    return {str(key): str(value) for key, value in manifest.items()}


def create_app(adapter: V9bAdapter | None = None) -> FastAPI:
    """`adapter` is injectable so the tests never need a 1.86 GB checkpoint."""

    app = FastAPI(title="OSRA own-model v9b CPU service", version="1")
    state: dict[str, object] = {"adapter": adapter, "load_error": None, "warmup_error": None}

    if adapter is None:
        try:
            state["adapter"] = V9bAdapter.load(
                Path(os.environ["V9B_MODEL_DIR"]),
                Path(os.environ["V9B_THRESHOLDS"]),
                os.environ["V9B_THRESHOLDS_SHA256"],
                expected_manifest=_manifest_from_env(),
            )
        except (KeyError, RuntimeError, AdapterUnavailable, OSError, json.JSONDecodeError) as exc:
            # Recorded, not fatal: `/health` must be able to report *why* the service cannot score, and a process
            # that cannot start tells the deployer nothing about which input was wrong.
            state["load_error"] = f"{type(exc).__name__}: {exc}"

    # A warm-up score, once, before the first request: it proves the adapter can actually answer, not merely that an
    # object exists, and it pays the torch warm-up cost outside a caller's request. A load that "succeeds" and then
    # cannot score is the state a `/health` that only checks `is not None` reports as ready.
    if state["adapter"] is not None:
        try:
            state["adapter"].score("warm-up", "en")  # type: ignore[union-attr]
        except AdapterUnavailable as exc:
            state["warmup_error"] = str(exc)

    @app.get("/health")
    def health() -> JSONResponse:
        loaded = state["adapter"] is not None and state["warmup_error"] is None
        body = {
            "status": "ready" if loaded else "unavailable",
            "loaded": loaded,
            "labels": list(LABELS),
            "reason": state["load_error"] or state["warmup_error"],
        }
        return JSONResponse(body, status_code=200 if loaded else 503)

    @app.post("/score")
    def score(request: ScoreRequest) -> JSONResponse:
        adapter_now = state["adapter"]
        if adapter_now is None or state["warmup_error"] is not None:
            return JSONResponse(
                {"error": "adapter_unavailable", "reason": state["load_error"]},
                status_code=503,
            )
        try:
            scored = adapter_now.score(request.text, request.lang)  # type: ignore[union-attr]
        except AdapterUnavailable as exc:
            # Fixed shape, fixed status: the caller sees *that* the path is unavailable, not a verdict. The reason
            # is the adapter's, which never contains scorer-chosen text (osra-security#67).
            return JSONResponse({"error": "adapter_unavailable", "reason": str(exc)}, status_code=503)
        return JSONResponse(scored.to_dict())

    return app


app = create_app()
