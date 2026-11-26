"""Plan 4.1: the hosted DeepSeek scorer — **evaluation only, for now**.

`EVAL.md` publishes the finding this exists to answer: the rules layer in `model.py` scores **0.00 on
all seven Arabic categories**, because it is a list of English regular expressions. A multilingual
model is the candidate replacement; this module is how we measure whether it actually is one, on the
labelled set, in both languages, before anything in production depends on it.

**Why it lives in `eval/` and not beside `model.py`.** A hosted scorer sends the text it is given to a
third party. In evaluation that text is synthetic, written by us, about imaginary children. In
production it would be a real child's messages. Those are different decisions, and this placement
makes the second one a deliberate change to `model.py` rather than a configuration flag somebody flips.
That conversation is ADR-0033: a real child's message is scored only on Amazon Bedrock inside the EU,
so this module stays in `eval/` and scores synthetic messages only (its Bedrock counterpart is
`bedrock_scorer.py`).

The client is the OpenAI-compatible chat-completions shape, which DeepSeek serves. It is written to be
boring on purpose: a strict JSON contract, a retry on 429/5xx only, and a disk cache keyed by
`(model, prompt, text)` so that re-running the evaluation bills nothing for rows it has already scored —
and so that changing the prompt re-scores them, because a score is the model's answer to *that* prompt.
"""

import atexit
import json
import os
import time
from typing import Any, Callable, Dict, Iterable, List, Optional

import httpx

from eval.prompt import (  # noqa: F401
    CATEGORIES,
    REFUSED_KEY,
    SYSTEM_PROMPT,
    cache_key,
    parse_categories,
    refused_probs,
    strip_fences,
)

DEFAULT_BASE_URL = "https://api.deepseek.com"
# #918: the exact current API id for "DeepSeek 4.1 Flash" — `deepseek-flash`, model version
# DeepSeek-V4.1-Flash-1017 (api-docs.deepseek.com/quick_start/pricing, read 18 Nov 2026). The old
# `deepseek-chat` alias still resolves, but the id a run reports has to be the one that was called.
DEFAULT_MODEL = "deepseek-flash"
DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".deepseek-cache.json")

# The prompt, the JSON contract and the cache key are shared with `bedrock_scorer.py` (ADR-0033), so
# both scorers answer the same question. The old names stay importable from here.
_cache_key = cache_key
_strip_fences = strip_fences


class DeepSeekUnavailable(RuntimeError):
    """The key is missing, or the service refused in a way that retrying will not fix."""


class DeepSeekScorer:
    """A callable scorer: text in, probability per category out. Cached, retried, and cheap to re-run."""

    def __init__(
        self,
        api_key: Optional[str] = None,
        model: Optional[str] = None,
        base_url: Optional[str] = None,
        cache_path: Optional[str] = DEFAULT_CACHE_PATH,
        timeout: float = DEFAULT_TIMEOUT_SECONDS,
        client: Optional[httpx.Client] = None,
        sleep: Callable[[float], None] = time.sleep,
        log: Optional[Callable[[str], None]] = print,
        prompt: Optional[str] = None,
        thinking: bool = False,
    ):
        self.api_key = (api_key or os.environ.get("DEEPSEEK_API_KEY", "")).strip()
        if not self.api_key:
            raise DeepSeekUnavailable(
                "DEEPSEEK_API_KEY is not set. It is a repository secret: run the ai-eval-deepseek "
                "workflow, or export your own key in this shell for a local run. The rules layer runs "
                "without it."
            )
        self.model = model or os.environ.get("DEEPSEEK_MODEL", DEFAULT_MODEL)
        self.base_url = (base_url or os.environ.get("DEEPSEEK_BASE_URL", DEFAULT_BASE_URL)).rstrip("/")
        self.cache_path = cache_path
        self.timeout = timeout
        self._client = client
        # One client for the process, not one per row: a fresh `httpx.Client` per call pays a TLS
        # handshake every time. Measured on this machine, that was ~3.8 s of overhead on top of a
        # ~1.8 s call — invisible in a unit test, and 28 hours across a 26,824-row run.
        self._own_client = None
        self._sleep = sleep
        self._log = log or (lambda _m: None)
        # The prompt is instance state, not a module constant, so the key and the request cannot disagree
        # about which prompt produced a cached score — and so a test can prove a changed prompt misses.
        self.prompt = prompt or SYSTEM_PROMPT
        # #918: thinking mode is ON by default on this model, and while it is on the service **ignores**
        # `temperature`. "Prompt v3 unchanged, temperature 0" is therefore only a real instruction with
        # thinking off, so off is the default here and `thinking=True` is an explicit choice that the
        # run has to state — it is not the same comparison.
        self.thinking = thinking
        self._cache: Dict[str, Dict[str, float]] = self._load_cache()
        self.calls = 0  # network calls actually made, for the run summary
        self.hits = 0
        # Per-call accounting for the row log (#918): what the last call cost and how long it took.
        self.input_tokens = 0
        self.output_tokens = 0
        self.last_tokens_in = 0
        self.last_tokens_out = 0
        self.last_latency_ms = 0
        self.refusals = 0
        # Flush on the way out as well as every 25 calls: a run killed by a timeout or a `SystemExit`
        # still leaves what it paid for on disk, which is what makes the next run cheap.
        atexit.register(self.save_cache)

    # ── cache ────────────────────────────────────────────────────────────────────────────────

    def _load_cache(self) -> Dict[str, Dict[str, float]]:
        if not self.cache_path or not os.path.exists(self.cache_path):
            return {}
        try:
            with open(self.cache_path, encoding="utf-8") as handle:
                data = json.load(handle)
            return data if isinstance(data, dict) else {}
        except (ValueError, OSError):
            # A corrupt cache is a cache miss, not a failed run: the worst case is paying twice.
            return {}

    def save_cache(self) -> None:
        if not self.cache_path or not self._cache:
            return
        try:
            with open(self.cache_path, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(self._cache, handle, ensure_ascii=False, sort_keys=True)
        except OSError as exc:  # pragma: no cover - disk problem, not logic
            self._log(f"[deepseek] could not write the cache ({exc}); the run continues uncached")

    # ── the call ─────────────────────────────────────────────────────────────────────────────

    def _post(self, text: str) -> str:
        body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": self.prompt},
                {"role": "user", "content": text},
            ],
            "response_format": {"type": "json_object"},
            "max_tokens": 200,
            # The switch the docs name for the OpenAI format. Thinking is on by default upstream.
            "thinking": {"type": "enabled" if self.thinking else "disabled"},
        }
        if not self.thinking:
            # Only non-thinking mode honours it: with thinking on the service accepts `temperature` and
            # ignores it, so sending it would describe a setting the run does not actually have.
            body["temperature"] = 0
        headers = {"authorization": f"Bearer {self.api_key}", "content-type": "application/json"}
        url = f"{self.base_url}/chat/completions"
        if self._client is not None:
            client = self._client
        else:
            if self._own_client is None:
                self._own_client = httpx.Client(timeout=self.timeout)
                atexit.register(self._own_client.close)
            client = self._own_client
        for attempt in range(3):
            started = time.monotonic()
            try:
                response = client.post(url, json=body, headers=headers)
            except httpx.HTTPError as exc:
                last_error = exc
            else:
                if response.status_code == 200:
                    payload = response.json()
                    self.last_latency_ms = int((time.monotonic() - started) * 1000)
                    usage = payload.get("usage") or {}
                    self.last_tokens_in = int(usage.get("prompt_tokens", 0) or 0)
                    self.last_tokens_out = int(usage.get("completion_tokens", 0) or 0)
                    try:
                        return payload["choices"][0]["message"]["content"]
                    except (KeyError, IndexError, TypeError) as exc:
                        raise DeepSeekUnavailable(f"unexpected reply shape: {payload!r:.300}") from exc
                if response.status_code in (401, 403):
                    raise DeepSeekUnavailable(
                        f"the key was refused ({response.status_code}); check DEEPSEEK_API_KEY"
                    )
                if response.status_code == 400:
                    raise DeepSeekUnavailable(f"the request was refused: {response.text[:300]}")
                if response.status_code != 429 and response.status_code < 500:
                    raise DeepSeekUnavailable(
                        f"unexpected status {response.status_code}: {response.text[:300]}"
                    )
                last_error = DeepSeekUnavailable(f"status {response.status_code}")
            self._sleep(2 ** attempt)  # 1s, 2s, 4s — only on 429/5xx or a transport error
        raise DeepSeekUnavailable(f"gave up after 3 attempts: {last_error}")

    def __call__(self, text: str) -> Dict[str, float]:
        # F1 (Antigravity's #923 review): `thinking` changes the request body, so it is part of what the
        # score *is*. Without it a thinking-on run would be served thinking-off answers from the disk
        # cache. The `thinking=False` form keeps the old key, so existing caches stay valid.
        key = _cache_key(self.model if not self.thinking else f"{self.model}+thinking", text, self.prompt)
        cached = self._cache.get(key)
        if cached is not None:
            self.hits += 1
            # A hit is not a call: nothing was billed and nothing was waited for. The row log records
            # zeros for those rows, so a run's cost is read from `usage()`, never summed from the log.
            self.last_tokens_in = 0
            self.last_tokens_out = 0
            self.last_latency_ms = 0
            if cached.get(REFUSED_KEY):
                self.refusals += 1
            return cached
        content = self._post(text)
        try:
            probs = parse_categories(content)
        except ValueError:
            # A refusal or an unreadable answer is a datapoint, not a crash — and #918's row log has a
            # column for exactly it. A run of a thousand rows must not die on the one where the model
            # declined. `bedrock_scorer.py` does the same.
            probs = refused_probs()
        self._cache[key] = probs
        self.calls += 1
        self.input_tokens += self.last_tokens_in
        self.output_tokens += self.last_tokens_out
        if probs.get(REFUSED_KEY):
            self.refusals += 1
        # Save as we go: an interrupted run must keep what it has already paid for. Every 25 rows is
        # often enough that a crash costs at most 25 calls, and rare enough that the write is invisible.
        if self.calls % 25 == 0:
            self.save_cache()
        return probs

    def score_many(self, texts: Iterable[str], progress_every: int = 100) -> List[Dict[str, float]]:
        """Score a list, saving the cache periodically so an interrupted run keeps what it paid for."""
        results: List[Dict[str, float]] = []
        for index, text in enumerate(texts, start=1):
            results.append(self(text))
            if index % progress_every == 0:
                self.save_cache()
                self._log(f"[deepseek] {index} rows · {self.calls} calls · {self.hits} cache hits")
        self.save_cache()
        return results

    def usage(self) -> Dict[str, Any]:
        """What the run cost in tokens — the same shape `bedrock_scorer.usage()` reports, so the two
        runs can be put side by side. Prices are not baked in: DeepSeek's per-million rates differ
        between peak and off-peak hours, so a dollar figure needs the time the call was made, and the
        caller passes the rate it was billed at (see `deepseek_rows.py`)."""
        summary: Dict[str, Any] = {
            "model": self.model,
            "thinking": self.thinking,
            "calls": self.calls,
            "cache_hits": self.hits,
            "refused_or_unreadable": self.refusals,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
        }
        if self.calls:
            summary["input_tokens_per_scan"] = round(self.input_tokens / self.calls, 1)
            summary["output_tokens_per_scan"] = round(self.output_tokens / self.calls, 1)
        return summary


_DEFAULT: Optional[DeepSeekScorer] = None


def default_scorer() -> DeepSeekScorer:
    """One scorer per process, so the cache and the HTTP client are not rebuilt per row."""
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = DeepSeekScorer()
    return _DEFAULT
