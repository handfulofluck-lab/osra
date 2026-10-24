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
from typing import Callable, Dict, Iterable, List, Optional

import httpx

from eval.prompt import CATEGORIES, SYSTEM_PROMPT, cache_key, parse_categories, strip_fences  # noqa: F401

DEFAULT_BASE_URL = "https://api.deepseek.com"
DEFAULT_MODEL = "deepseek-chat"
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
        self._sleep = sleep
        self._log = log or (lambda _m: None)
        # The prompt is instance state, not a module constant, so the key and the request cannot disagree
        # about which prompt produced a cached score — and so a test can prove a changed prompt misses.
        self.prompt = prompt or SYSTEM_PROMPT
        self._cache: Dict[str, Dict[str, float]] = self._load_cache()
        self.calls = 0  # network calls actually made, for the run summary
        self.hits = 0
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
            "temperature": 0,
            "max_tokens": 200,
        }
        headers = {"authorization": f"Bearer {self.api_key}", "content-type": "application/json"}
        url = f"{self.base_url}/chat/completions"
        client = self._client or httpx.Client(timeout=self.timeout)
        owns_client = self._client is None
        last_error: Optional[Exception] = None
        try:
            for attempt in range(3):
                try:
                    response = client.post(url, json=body, headers=headers)
                except httpx.HTTPError as exc:
                    last_error = exc
                else:
                    if response.status_code == 200:
                        payload = response.json()
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
        finally:
            if owns_client:
                client.close()

    def __call__(self, text: str) -> Dict[str, float]:
        key = _cache_key(self.model, text, self.prompt)
        cached = self._cache.get(key)
        if cached is not None:
            self.hits += 1
            return cached
        content = self._post(text)
        probs = parse_categories(content)
        self._cache[key] = probs
        self.calls += 1
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


_DEFAULT: Optional[DeepSeekScorer] = None


def default_scorer() -> DeepSeekScorer:
    """One scorer per process, so the cache and the HTTP client are not rebuilt per row."""
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = DeepSeekScorer()
    return _DEFAULT
