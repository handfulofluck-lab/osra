"""Private CPU inference service for OSRA's own multi-label classifiers (v9b + v9).

Serves the exact staging QA analyzer request/response contract (`StagingQaRequest` /
`StagingQaResponse` in `staging_qa.py`), routing Arabic (`ar`) and French (`fr`) to `v9b`
and English/Indonesian/Malay/Turkish/Urdu (`en`, `id`, `ms`, `tr`, `ur`) to `v9` using
the pinned per-language thresholds in `serving-v9-v9b.json`.

Hard invariants (matching K31's `v9b_adapter.py` contract in PR #997):
  * No rules fallback: if a checkpoint fails to load, fails digest verification, or raises
    during inference, raise `AdapterUnavailable` and return HTTP 502 (`model_unavailable`).
  * No silent `safe`: malformed, NaN, out-of-range, duplicate, or incomplete scorer outputs
    raise `AdapterUnavailable` and return HTTP 502.
  * No message text in logs or validation errors: request parsing catches `ValidationError`
    privately and logs only `trace_id`, `model`, `lang`, `region`, and `latency_ms`.
  * Server-side S3 fetch only: checkpoints are loaded from a verified local directory or
    downloaded server-side from S3 with a mandatory pinned archive SHA-256 and safe
    extraction (no symlinks, no path traversal).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import math
import os
import re
import shutil
import tarfile
import tempfile
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from time import monotonic
from typing import Callable, Literal, Mapping, Sequence

from fastapi import APIRouter, FastAPI, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, UUID4, ValidationError

from staging_own_model import APPROVED_PROMPT_SHA256, consented_staging_scoring, is_in_process_cpu_call

LABELS: tuple[str, ...] = (
    "cyberbullying",
    "self_harm",
    "grooming",
    "violence",
    "sexual_content",
    "substance_use",
    "hate_speech",
)

MANIFEST_FILES: tuple[str, ...] = (
    "model.safetensors",
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "sentencepiece.bpe.model",
    "special_tokens_map.json",
)

DEFAULT_SERVING_CONFIG_PATH = Path(__file__).resolve().parent / "serving-v9-v9b.json"
# Canonical LF SHA-256 of serving-v9-v9b.json (Windows CRLF copy on PC is 12cccbf4e1700d82...).
SERVING_CONFIG_SHA256 = "b6ee77c288a403a6cafa8676fd9e4b8aaa1ce692f8e81b54160f69090b33025b"

REGION_DEFAULT = "eu-central-1"
MAX_REQUEST_BYTES = 8192
MAX_TEXT_BYTES = 1024
MAX_APPROVAL_WINDOW = timedelta(hours=1)
DEFAULT_INFERENCE_TIMEOUT_SECONDS = 5.0
STAGING_OWN_MODEL_INFERENCE_TIMEOUT_SECONDS = 8.0
CRITICAL_SEVERITY_THRESHOLD = 0.85

# Urdu-specific Arabic-script letters not used in standard Arabic.
_URDU_ONLY_RE = re.compile(r"[\u0679\u067e\u0686\u0688\u0691\u0698\u06a9\u06af\u06ba\u06be\u06c1\u06c2\u06c3\u06cc\u06d2]")
_ARABIC_SCRIPT_RE = re.compile(r"[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]")
_TURKISH_DIACRITIC_RE = re.compile(r"[\u011e\u011f\u0130\u0131\u015e\u015f]")
_TURKISH_WORD_RE = re.compile(
    r"\b(?:çok|bir|gün|güzel|için|değil|nasıl|merhaba|teşekkür|şimdi|veya|bugün)\b",
    re.IGNORECASE,
)
_FRENCH_DIACRITIC_RE = re.compile(r"[\u00e0\u00e2\u00e6\u00e7\u00e8\u00e9\u00ea\u00eb\u00ee\u00ef\u00f4\u0153\u00f9\u00fb\u00c0\u00c2\u00c6\u00c7\u00c8\u00c9\u00ca\u00cb\u00ce\u00cf\u00d4\u0152\u00d9\u00db]")
_FRENCH_WORD_RE = re.compile(
    r"\b(?:bonjour|merci|salut|avec|pour|dans|mais|nous|vous|suis|c['’]est|j['’]ai|t['’]es|pas|tr[eè]s|rien|jamais)\b",
    re.IGNORECASE,
)

logger = logging.getLogger(__name__)
router = APIRouter()


class AdapterUnavailable(RuntimeError):
    """Raised whenever the own-model service cannot score honestly.

    Callers must treat this as an error (HTTP 502/503) — never fall back to rules and
    never invent a `safe` verdict.
    """


class OwnModelQaRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str = Field(min_length=1, max_length=1024)
    trace_id: UUID4
    lang: Literal["en", "ar", "fr", "id", "ms", "tr", "ur"] | None = None


class OwnModelQaResponse(BaseModel):
    """Drop-in superset of `StagingQaResponse` with digest and language audit fields."""

    flagged: bool
    severity: Literal["info", "warning", "critical"]
    categories: dict[str, float]
    flagged_categories: list[str]
    model: str
    region: str
    lang: str
    model_sha256: str
    thresholds_sha256: str
    trace_id: UUID4


@dataclass(frozen=True)
class ServingConfig:
    model_by_lang: dict[str, str]
    thresholds: dict[str, dict[str, float]]
    labels: tuple[str, ...]
    max_len: int
    activation: str
    sha256: str


@dataclass(frozen=True)
class LoadedModel:
    tag: str
    model_name: str
    model_sha256: str
    scorer: Callable[[str], Mapping[str, float]]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_labels(id2label: Mapping[str | int, str]) -> None:
    try:
        ordered = [id2label[key] for key in sorted(id2label, key=lambda k: int(k))]
    except (TypeError, ValueError) as exc:
        raise AdapterUnavailable("checkpoint id2label keys must be integers") from exc
    if tuple(ordered) != LABELS:
        raise AdapterUnavailable(
            f"checkpoint labels do not match the verified seven: expected {list(LABELS)}, found {ordered}"
        )


def manifest_of(model_dir: Path) -> dict[str, str]:
    model_dir = Path(model_dir)
    missing = [name for name in MANIFEST_FILES if not (model_dir / name).is_file()]
    if missing:
        raise AdapterUnavailable(f"checkpoint is missing {missing}")
    return {name: sha256_file(model_dir / name) for name in MANIFEST_FILES}


def verify_manifest(model_dir: Path, expected: Mapping[str, str]) -> dict[str, str]:
    missing_pins = [name for name in MANIFEST_FILES if name not in expected]
    if missing_pins:
        raise AdapterUnavailable(f"manifest does not pin {missing_pins}")
    actual = manifest_of(model_dir)
    mismatched = [name for name in MANIFEST_FILES if actual[name] != expected[name]]
    if mismatched:
        raise AdapterUnavailable(
            "checkpoint digests do not match the pin: "
            + ", ".join(f"{name} {actual[name]} != {expected[name]}" for name in mismatched)
        )
    return actual


def load_serving_config(
    path: Path = DEFAULT_SERVING_CONFIG_PATH,
    expected_sha256: str | None = SERVING_CONFIG_SHA256,
) -> ServingConfig:
    path = Path(path)
    if not path.is_file():
        raise AdapterUnavailable(f"serving config not found: {path.name}")
    raw_bytes = path.read_bytes().replace(b"\r\n", b"\n")
    actual_sha = hashlib.sha256(raw_bytes).hexdigest()
    if expected_sha256 is not None and actual_sha != expected_sha256:
        raise AdapterUnavailable(
            f"serving config digest mismatch for {path.name}: expected {expected_sha256}, found {actual_sha}"
        )
    try:
        raw = json.loads(raw_bytes.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AdapterUnavailable(f"serving config is not readable JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise AdapterUnavailable("serving config must be a JSON object")

    labels = raw.get("labels")
    if not isinstance(labels, list) or tuple(labels) != LABELS:
        raise AdapterUnavailable(f"serving config labels must match {list(LABELS)}")
    activation = raw.get("activation")
    if activation != "sigmoid":
        raise AdapterUnavailable("serving config activation must be 'sigmoid'")
    max_len = raw.get("max_len")
    if isinstance(max_len, bool) or not isinstance(max_len, int) or not 16 <= max_len <= 512:
        raise AdapterUnavailable("serving config max_len must be an integer in [16, 512]")

    model_by_lang_raw = raw.get("model_by_lang")
    thresholds_raw = raw.get("thresholds")
    if not isinstance(model_by_lang_raw, dict) or not model_by_lang_raw:
        raise AdapterUnavailable("serving config model_by_lang must be a non-empty map")
    if not isinstance(thresholds_raw, dict) or not thresholds_raw:
        raise AdapterUnavailable("serving config thresholds must be a non-empty map")

    model_by_lang: dict[str, str] = {}
    for lang, tag in model_by_lang_raw.items():
        if not isinstance(lang, str) or tag not in ("v9", "v9b"):
            raise AdapterUnavailable(f"unsupported model tag for language {lang!r}")
        model_by_lang[lang] = tag

    thresholds: dict[str, dict[str, float]] = {}
    for lang, mapping in thresholds_raw.items():
        if not isinstance(mapping, dict):
            raise AdapterUnavailable(f"thresholds for {lang!r} must be a map")
        if set(mapping) != set(LABELS):
            raise AdapterUnavailable(f"thresholds for {lang!r} must name exactly {list(LABELS)}")
        resolved: dict[str, float] = {}
        for label in LABELS:
            value = mapping[label]
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise AdapterUnavailable(f"threshold for {lang}/{label} is not numeric")
            fval = float(value)
            if not math.isfinite(fval) or not 0.0 <= fval <= 1.0:
                raise AdapterUnavailable(f"threshold for {lang}/{label} is outside [0, 1]")
            resolved[label] = fval
        thresholds[str(lang)] = resolved

    if set(model_by_lang) != set(thresholds):
        raise AdapterUnavailable("serving config model_by_lang and thresholds languages do not match")

    return ServingConfig(
        model_by_lang=model_by_lang,
        thresholds=thresholds,
        labels=LABELS,
        max_len=max_len,
        activation=activation,
        sha256=actual_sha,
    )


def detect_language(text: str) -> str:
    """Deterministic lightweight router when caller omits `lang`.

    Routes Arabic (`ar`) and French (`fr`) to `v9b`; Urdu Nastaliq (`ur`), Turkish (`tr`),
    and Latin-script languages (`en`, `id`, `ms`) route to `v9`.
    """
    if _ARABIC_SCRIPT_RE.search(text):
        if _URDU_ONLY_RE.search(text):
            return "ur"
        return "ar"
    if _TURKISH_DIACRITIC_RE.search(text) or _TURKISH_WORD_RE.search(text):
        return "tr"
    if _FRENCH_DIACRITIC_RE.search(text) or _FRENCH_WORD_RE.search(text):
        return "fr"
    return "en"


def validate_probs(raw_probs: Mapping[str, float]) -> dict[str, float]:
    """Validate that scorer output covers exactly LABELS with finite probabilities in [0, 1]."""
    if not isinstance(raw_probs, Mapping):
        raise AdapterUnavailable(f"scorer returned {type(raw_probs).__name__}, expected mapping")
    if set(raw_probs) != set(LABELS):
        raise AdapterUnavailable("scorer probabilities do not cover the verified seven labels")
    cleaned: dict[str, float] = {}
    for label in LABELS:
        value = raw_probs[label]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise AdapterUnavailable(f"score for {label} is not numeric")
        score = float(value)
        if not math.isfinite(score) or not 0.0 <= score <= 1.0:
            raise AdapterUnavailable(f"score for {label} is outside [0, 1]")
        cleaned[label] = score
    return cleaned


def apply_thresholds(probs: Mapping[str, float], thresholds: Mapping[str, float]) -> tuple[str, ...]:
    cleaned = validate_probs(probs)
    if set(thresholds) != set(LABELS):
        raise AdapterUnavailable("thresholds do not cover the verified seven labels")
    return tuple(label for label in LABELS if cleaned[label] >= float(thresholds[label]))


def severity_for_flagged(probs: Mapping[str, float], flagged: Sequence[str]) -> Literal["info", "warning", "critical"]:
    if not flagged:
        return "info"
    top_flagged = max(float(probs[label]) for label in flagged)
    if top_flagged >= CRITICAL_SEVERITY_THRESHOLD:
        return "critical"
    return "warning"


def _safe_extract_tar_gz(archive_path: Path, dest_dir: Path) -> None:
    """Extract a model archive safely: no path traversal, no symlinks, no special files."""
    dest_root = dest_dir.resolve()
    dest_root.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_path, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                raise AdapterUnavailable("model archive contains unsupported link or special file")
            member_path = Path(member.name)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise AdapterUnavailable("model archive contains unsafe path traversal")
            target = (dest_root / member_path).resolve()
            if target != dest_root and dest_root not in target.parents:
                raise AdapterUnavailable("model archive member escapes destination directory")
        for member in members:
            target = (dest_root / member.name).resolve()
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                extracted = tar.extractfile(member)
                if extracted is None:
                    raise AdapterUnavailable("model archive member could not be read")
                with extracted, open(target, "wb") as out:
                    shutil.copyfileobj(extracted, out)


def _locate_checkpoint_root(root: Path) -> Path:
    """Find the directory containing MANIFEST_FILES (either root itself or one nested dir)."""
    if all((root / name).is_file() for name in MANIFEST_FILES):
        return root
    for child in sorted(root.iterdir()):
        if child.is_dir() and all((child / name).is_file() for name in MANIFEST_FILES):
            return child
    raise AdapterUnavailable("extracted archive does not contain the verified six checkpoint files")


def ensure_model_dir(
    tag: str,
    *,
    local_dir: str | None = None,
    s3_bucket: str | None = None,
    s3_key: str | None = None,
    archive_sha256: str | None = None,
    cache_dir: str | None = None,
    s3_region: str = REGION_DEFAULT,
    s3_client=None,
) -> Path:
    """Resolve a model directory from local disk or server-side S3 download with pinned SHA-256."""
    if local_dir:
        path = Path(local_dir)
        manifest_of(path)
        return path

    if not s3_bucket or not s3_key:
        raise AdapterUnavailable(f"no local directory or S3 source configured for model {tag}")
    if not archive_sha256 or not re.fullmatch(r"[0-9a-f]{64}", archive_sha256):
        raise AdapterUnavailable(f"pinned archive SHA-256 is required for S3 model {tag}")

    base_cache = Path(cache_dir or (Path(tempfile.gettempdir()) / "osra-own-models"))
    target_dir = base_cache / tag / archive_sha256[:16]
    marker = target_dir / ".verified_archive_sha256"
    if marker.is_file() and marker.read_text(encoding="utf-8").strip() == archive_sha256:
        return _locate_checkpoint_root(target_dir)

    base_cache.mkdir(parents=True, exist_ok=True)
    tmp_dir = Path(tempfile.mkdtemp(prefix=f"osra-{tag}-", dir=str(base_cache)))
    try:
        archive_path = tmp_dir / "model.tar.gz"
        client = s3_client
        if client is None:
            import boto3
            from botocore.config import Config

            client = boto3.Session().client(
                "s3",
                region_name=s3_region,
                verify=True,
                config=Config(retries={"total_max_attempts": 3, "mode": "standard"}),
            )
        client.download_file(s3_bucket, s3_key, str(archive_path))
        actual_sha = sha256_file(archive_path)
        if actual_sha != archive_sha256:
            raise AdapterUnavailable(
                f"S3 archive digest mismatch for {tag}: expected {archive_sha256}, found {actual_sha}"
            )
        extract_dir = tmp_dir / "unpacked"
        _safe_extract_tar_gz(archive_path, extract_dir)
        ckpt_dir = _locate_checkpoint_root(extract_dir)
        archive_path.unlink(missing_ok=True)
        if target_dir.exists():
            shutil.rmtree(target_dir)
        target_dir.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(ckpt_dir), str(target_dir))
        marker.write_text(archive_sha256, encoding="utf-8")
        return target_dir
    except AdapterUnavailable:
        raise
    except Exception as exc:
        raise AdapterUnavailable(f"failed to fetch model {tag} from S3: {type(exc).__name__}") from exc
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def load_hf_cpu_model(
    tag: str,
    model_dir: Path,
    *,
    max_len: int = 128,
    expected_manifest: Mapping[str, str] | None = None,
    cpu_threads: int = 2,
) -> LoadedModel:
    """Load an XLMRoberta multi-label checkpoint on CPU with strict manifest and label checks."""
    model_dir = Path(model_dir)
    if expected_manifest is not None:
        actual_manifest = verify_manifest(model_dir, expected_manifest)
    else:
        actual_manifest = manifest_of(model_dir)

    config_path = model_dir / "config.json"
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AdapterUnavailable(f"config.json is not readable JSON: {exc}") from exc
    id2label = config.get("id2label")
    if not isinstance(id2label, dict) or not id2label:
        raise AdapterUnavailable("config.json carries no id2label map")
    verify_labels(id2label)

    try:
        import torch
        from transformers import AutoModelForSequenceClassification, AutoTokenizer
    except ImportError as exc:
        raise AdapterUnavailable(f"CPU inference runtime not installed: {exc}") from exc

    try:
        if cpu_threads > 0:
            torch.set_num_threads(cpu_threads)
        tokenizer = AutoTokenizer.from_pretrained(str(model_dir), local_files_only=True)
        model = AutoModelForSequenceClassification.from_pretrained(
            str(model_dir), local_files_only=True
        )
        model.eval()
    except Exception as exc:
        raise AdapterUnavailable(f"checkpoint {tag} did not load: {type(exc).__name__}") from exc

    def _score(text: str) -> dict[str, float]:
        with torch.no_grad():
            encoded = tokenizer(
                text,
                return_tensors="pt",
                truncation=True,
                max_length=max_len,
            )
            logits = model(**encoded).logits[0]
            probs = torch.sigmoid(logits).cpu().tolist()
        if not isinstance(probs, list) or len(probs) != len(LABELS):
            raise AdapterUnavailable("model returned unexpected logit shape")
        return {label: float(probs[idx]) for idx, label in enumerate(LABELS)}

    return LoadedModel(
        tag=tag,
        model_name=f"osra-own-{tag}",
        model_sha256=actual_manifest["model.safetensors"],
        scorer=_score,
    )


class OwnModelRegistry:
    """Thread-safe holder for the serving config and the loaded `v9b` / `v9` CPU models."""

    def __init__(
        self,
        *,
        config: ServingConfig | None = None,
        models: Mapping[str, LoadedModel] | None = None,
    ) -> None:
        self._lock = threading.Lock()
        self._config = config
        self._models: dict[str, LoadedModel] = dict(models or {})

    def get_config(self) -> ServingConfig:
        with self._lock:
            if self._config is None:
                cfg_path = Path(
                    os.environ.get("OSRA_OWN_MODEL_SERVING_CONFIG", str(DEFAULT_SERVING_CONFIG_PATH))
                )
                expected_sha = os.environ.get("OSRA_OWN_MODEL_SERVING_CONFIG_SHA256", SERVING_CONFIG_SHA256)
                self._config = load_serving_config(cfg_path, expected_sha256=expected_sha or None)
            return self._config

    def get_model(self, tag: str) -> LoadedModel:
        with self._lock:
            if tag in self._models:
                return self._models[tag]
        cfg = self.get_config()
        upper = tag.upper()
        local_dir = os.environ.get(f"OSRA_OWN_MODEL_{upper}_DIR")
        s3_bucket = os.environ.get("OSRA_OWN_MODEL_S3_BUCKET")
        s3_key = os.environ.get(f"OSRA_OWN_MODEL_{upper}_S3_KEY")
        archive_sha = os.environ.get(f"OSRA_OWN_MODEL_{upper}_ARCHIVE_SHA256")
        cache_dir = os.environ.get("OSRA_OWN_MODEL_CACHE_DIR")
        s3_region = os.environ.get("OSRA_OWN_MODEL_REGION", REGION_DEFAULT)
        manifest_raw = os.environ.get(f"OSRA_OWN_MODEL_{upper}_MANIFEST_JSON")
        expected_manifest = None
        if manifest_raw:
            try:
                expected_manifest = json.loads(manifest_raw)
            except json.JSONDecodeError as exc:
                raise AdapterUnavailable(f"invalid manifest JSON for {tag}") from exc
        threads_raw = os.environ.get("OSRA_OWN_MODEL_CPU_THREADS", "2")
        try:
            cpu_threads = int(threads_raw)
        except ValueError:
            cpu_threads = 2

        model_dir = ensure_model_dir(
            tag,
            local_dir=local_dir,
            s3_bucket=s3_bucket,
            s3_key=s3_key,
            archive_sha256=archive_sha,
            cache_dir=cache_dir,
            s3_region=s3_region,
        )
        loaded = load_hf_cpu_model(
            tag,
            model_dir,
            max_len=cfg.max_len,
            expected_manifest=expected_manifest,
            cpu_threads=cpu_threads,
        )
        with self._lock:
            self._models[tag] = loaded
        return loaded

    def score(self, text: str, lang: str | None = None) -> tuple[str, LoadedModel, dict[str, float], tuple[str, ...], str]:
        if not isinstance(text, str) or not text.strip():
            raise AdapterUnavailable("no text to score")
        cfg = self.get_config()
        resolved_lang = lang if lang is not None else detect_language(text)
        if resolved_lang not in cfg.model_by_lang or resolved_lang not in cfg.thresholds:
            raise AdapterUnavailable(f"unsupported language {resolved_lang!r}")
        tag = cfg.model_by_lang[resolved_lang]
        loaded = self.get_model(tag)
        try:
            raw_probs = loaded.scorer(text)
        except AdapterUnavailable:
            raise
        except Exception as exc:
            raise AdapterUnavailable(f"scoring failed: {type(exc).__name__}") from exc
        probs = validate_probs(raw_probs)
        flagged = apply_thresholds(probs, cfg.thresholds[resolved_lang])
        return resolved_lang, loaded, probs, flagged, cfg.sha256

    def loaded_summary(self) -> dict[str, str]:
        with self._lock:
            return {tag: model.model_sha256 for tag, model in self._models.items()}

    def preload_models(self, tags: Sequence[str]) -> dict[str, str]:
        """Eagerly load and verify each requested model tag into resident memory."""
        for tag in tags:
            self.get_model(tag)
        return self.loaded_summary()

    def clear(self) -> None:
        with self._lock:
            self._config = None
            self._models.clear()


_registry = OwnModelRegistry()


def get_registry() -> OwnModelRegistry:
    return _registry


def required_preload_tags(env: Mapping[str, str] | None = None) -> tuple[str, ...]:
    source = os.environ if env is None else env
    raw = (source.get("OSRA_OWN_MODEL_PRELOAD_TAGS") or "").strip()
    if not raw:
        return ()
    return tuple(tag.strip() for tag in raw.split(",") if tag.strip())


def warmup_own_models_from_env() -> dict[str, str]:
    """Startup warm-up hook: preloads configured tags in staging when own-model is enabled."""
    if (
        os.environ.get("OSRA_DEPLOYMENT_SCOPE") != "staging"
        or os.environ.get("OSRA_STAGING_QA_OWN_MODEL_ENABLED") != "1"
    ):
        return {}
    tags = required_preload_tags()
    if not tags:
        return {}
    return get_registry().preload_models(tags)


def _own_model_approval(*, in_process: bool) -> tuple[datetime | None, set[str] | None]:
    """Keep the fixture gate for legacy calls and allow consented traffic through the collector."""
    enabled = (
        os.environ.get("OSRA_STAGING_QA_OWN_MODEL_ENABLED") == "1"
        or os.environ.get("OSRA_STAGING_QA_ANALYZER_ENABLED") == "1"
    )
    if os.environ.get("OSRA_DEPLOYMENT_SCOPE") != "staging" or not enabled:
        raise HTTPException(status_code=404, detail="not_found")
    if consented_staging_scoring(APPROVED_PROMPT_SHA256):
        if not in_process:
            raise HTTPException(status_code=404, detail="not_found")
        return None, None
    try:
        expires_at = datetime.fromisoformat(os.environ.get("OSRA_STAGING_QA_EXPIRES_AT", ""))
    except ValueError:
        raise HTTPException(status_code=404, detail="not_found") from None
    now = datetime.now(timezone.utc)
    allow_pair_text = os.environ.get("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", "0")
    if (
        expires_at.utcoffset() != timedelta(0)
        or not now < expires_at <= now + MAX_APPROVAL_WINDOW
        or allow_pair_text not in ("0", "1")
    ):
        raise HTTPException(status_code=404, detail="not_found")
    if allow_pair_text == "1":
        return expires_at, None
    entries = os.environ.get("OSRA_STAGING_QA_FIXTURE_SHA256", "").split(",")
    digests = {entry.strip() for entry in entries}
    if len(entries) > 8 or not all(re.fullmatch(r"[0-9a-f]{64}", digest) for digest in digests):
        raise HTTPException(status_code=404, detail="not_found")
    return expires_at, digests


@router.get("/health/own-model", include_in_schema=False)
def health_own_model() -> dict:
    if os.environ.get("OSRA_DEPLOYMENT_SCOPE") != "staging":
        raise HTTPException(status_code=404, detail="not_found")
    try:
        cfg = get_registry().get_config()
    except AdapterUnavailable:
        raise HTTPException(status_code=503, detail="model_unavailable") from None
    loaded = get_registry().loaded_summary()
    required = required_preload_tags()
    if required and not all(tag in loaded for tag in required):
        raise HTTPException(status_code=503, detail="model_not_ready")
    return {
        "ok": True,
        "thresholds_sha256": cfg.sha256,
        "languages": sorted(cfg.model_by_lang),
        "loaded_models": loaded,
    }


def effective_inference_timeout_seconds(env: Mapping[str, str] | None = None) -> float:
    """Resolve the per-call CPU timeout, capped at the approved ceiling (8 s staging own-model, 5 s default).

    Shorter overrides are preserved; longer overrides are clamped to the ceiling.
    Approval expiry always takes precedence over this timeout (`analyze_staging_qa_own`).
    """
    source = os.environ if env is None else env
    ceiling = (
        STAGING_OWN_MODEL_INFERENCE_TIMEOUT_SECONDS
        if (
            source.get("OSRA_DEPLOYMENT_SCOPE") == "staging"
            and source.get("OSRA_STAGING_QA_OWN_MODEL_ENABLED") == "1"
        )
        else DEFAULT_INFERENCE_TIMEOUT_SECONDS
    )
    raw = source.get("OSRA_OWN_MODEL_TIMEOUT_SECONDS")
    if raw:
        try:
            parsed = float(raw)
            if math.isfinite(parsed) and parsed > 0:
                return min(parsed, ceiling)
        except ValueError:
            pass
    return ceiling


@router.post("/analyze/staging-qa/own", response_model=OwnModelQaResponse, include_in_schema=False)
async def analyze_staging_qa_own(request: Request) -> OwnModelQaResponse:
    expires_at, digests = _own_model_approval(in_process=is_in_process_cpu_call(request.scope))
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > MAX_REQUEST_BYTES:
            raise HTTPException(status_code=413, detail="request_too_large")
        body.extend(chunk)
    try:
        data = OwnModelQaRequest.model_validate_json(body)
        text_bytes = data.text.encode("utf-8")
    except (ValidationError, UnicodeEncodeError):
        raise HTTPException(status_code=422, detail="invalid_request") from None
    if len(text_bytes) > MAX_TEXT_BYTES or not data.text.strip():
        raise HTTPException(status_code=422, detail="invalid_request")
    if digests is not None and hashlib.sha256(text_bytes).hexdigest() not in digests:
        raise HTTPException(status_code=403, detail="fixture_not_approved")

    trace_id = str(data.trace_id)
    region = os.environ.get("OSRA_OWN_MODEL_REGION", REGION_DEFAULT)
    timeout_seconds = effective_inference_timeout_seconds()
    if expires_at is not None:
        remaining_approval = (expires_at - datetime.now(timezone.utc)).total_seconds()
        timeout_seconds = min(timeout_seconds, remaining_approval)

    started = monotonic()
    try:
        if timeout_seconds <= 0:
            raise TimeoutError("staging QA approval expired")
        resolved_lang, loaded, probs, flagged, thresholds_sha = await asyncio.wait_for(
            asyncio.to_thread(get_registry().score, data.text, data.lang),
            timeout=timeout_seconds,
        )
        if expires_at is not None and datetime.now(timezone.utc) >= expires_at:
            raise TimeoutError("staging QA approval expired")
    except TimeoutError:
        logger.warning(
            "staging QA own model timeout count=1 trace_id=%s region=%s latency_ms=%d",
            trace_id,
            region,
            (monotonic() - started) * 1000,
        )
        raise HTTPException(status_code=502, detail="model_unavailable") from None
    except Exception:
        logger.warning(
            "staging QA own model unavailable trace_id=%s region=%s latency_ms=%d",
            trace_id,
            region,
            (monotonic() - started) * 1000,
        )
        raise HTTPException(status_code=502, detail="model_unavailable") from None

    top_harmful = max(probs[label] for label in LABELS)
    categories = {label: round(probs[label], 6) for label in LABELS}
    categories["safe"] = round(max(0.0, 1.0 - top_harmful), 6)
    severity = severity_for_flagged(probs, flagged)
    logger.info(
        "staging QA own model completed trace_id=%s model=%s lang=%s region=%s latency_ms=%d",
        trace_id,
        loaded.model_name,
        resolved_lang,
        region,
        (monotonic() - started) * 1000,
    )
    return OwnModelQaResponse(
        flagged=bool(flagged),
        severity=severity,
        categories=categories,
        flagged_categories=list(flagged),
        model=loaded.model_name,
        region=region,
        lang=resolved_lang,
        model_sha256=loaded.model_sha256,
        thresholds_sha256=thresholds_sha,
        trace_id=data.trace_id,
    )


def create_standalone_app() -> FastAPI:
    """Standalone FastAPI app when deployed as a dedicated own-model CPU container."""
    standalone = FastAPI(title="OSRA Own-Model CPU Service", version="0.1.0")
    standalone.include_router(router)
    standalone.add_api_route("/health", health_own_model, methods=["GET"], include_in_schema=False)
    standalone.add_api_route(
        "/analyze/staging-qa",
        analyze_staging_qa_own,
        methods=["POST"],
        response_model=OwnModelQaResponse,
        include_in_schema=False,
    )
    return standalone


own_model_app = create_standalone_app()
