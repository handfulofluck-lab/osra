"""Plan 4.1: the hosted DeepSeek scorer — **evaluation only, for now**.

`EVAL.md` publishes the finding this exists to answer: the rules layer in `model.py` scores **0.00 on
all seven Arabic categories**, because it is a list of English regular expressions. A multilingual
model is the candidate replacement; this module is how we measure whether it actually is one, on the
labelled set, in both languages, before anything in production depends on it.

**Why it lives in `eval/` and not beside `model.py`.** A hosted scorer sends the text it is given to a
third party. In evaluation that text is synthetic, written by us, about imaginary children. In
production it would be a real child's messages. Those are different decisions, and this placement
makes the second one a deliberate change to `model.py` rather than a configuration flag somebody flips.
`deepseek.py` moving out of `eval/` is the moment to have that conversation (`docs/ROADMAP.md` 4.1 and
4.4, and ADR-0028's UAE stack).

The client is the OpenAI-compatible chat-completions shape, which DeepSeek serves. It is written to be
boring on purpose: a strict JSON contract, a retry on 429/5xx only, and a disk cache keyed by
`(model, prompt, text)` so that re-running the evaluation bills nothing for rows it has already scored —
and so that changing the prompt re-scores them, because a score is the model's answer to *that* prompt.
"""

import atexit
import hashlib
import json
import os
import re
import time
from typing import Callable, Dict, Iterable, List, Optional

import httpx

from eval.banks import HARMFUL_CATEGORIES

DEFAULT_BASE_URL = "https://api.deepseek.com"
DEFAULT_MODEL = "deepseek-chat"
DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".deepseek-cache.json")

#: Categories the model is asked for, plus `safe`. Kept in one place so a change to the taxonomy is one
#: edit and the prompt, the parser and the cache key cannot drift apart.
CATEGORIES = HARMFUL_CATEGORIES + ["safe"]

SYSTEM_PROMPT = (
    "You are a child-safety classifier. You will be given one message, in English or Arabic, that a "
    "child or teenager received or sent. Return a single JSON object and nothing else — no prose, no "
    "code fences — of the form:\n"
    '{"categories": {'
    + ", ".join(f'"{c}": <number 0..1>' for c in CATEGORIES)
    + "}}\n"
    "Each number is your probability that the message belongs to that category. The categories are: "
    "cyberbullying (targeted humiliation, exclusion, mockery between peers), self_harm (hopelessness, "
    "goodbye messages, concealing injury, being a burden), grooming (an adult or older teen building "
    "secrecy, isolation, gifts, meetings, or asking for images), violence (a threat or an arranged "
    "fight), sexual_content (pressure for images, age-inappropriate sexual talk), substance_use "
    "(offers, group pressure, concealment of use), hate_speech (group-targeted slurs or dehumanising "
    "speech), safe (ordinary conversation). Judge the intent, not the vocabulary: a message can be "
    "harmful without containing any word from a list. Return JSON only."
)


class DeepSeekUnavailable(RuntimeError):
    """The key is missing, or the service refused in a way that retrying will not fix."""


def _cache_key(model: str, text: str, prompt: str = SYSTEM_PROMPT) -> str:
    """The cache key: model, prompt and text — because the score is a function of all three.

    Keyed on `(model, text)`, a cache entry answers "what did this model say about this text", which is
    the wrong question once the prompt changes: the *prompt* is what tells the model what to look for, so
    editing it can change every score while leaving every key valid. A re-run after a prompt edit would
    then serve the previous prompt's answers and the numbers in `EVAL.md` would describe a prompt that no
    longer exists — silently, because a cache hit looks exactly like a cheap success.

    The prompt enters as its own digest rather than as text, so the key stays a fixed size whatever the
    prompt grows to, and two prompts cannot be confused by a separator appearing inside one.
    """
    prompt_digest = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
    return hashlib.sha256(f"{model}\x00{prompt_digest}\x00{text}".encode("utf-8")).hexdigest()


def _strip_fences(content: str) -> str:
    """Models wrap JSON in ``` fences often enough that it is not worth failing a 1,000-row run on."""
    text = content.strip()
    match = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.DOTALL)
    return match.group(1) if match else text


def parse_categories(content: str) -> Dict[str, float]:
    """Turn the model's reply into a probability per category, or raise if it is unusable.

    Missing categories are 0.0 rather than an error: a model that answers six of eight has still read
    the message, and a run of 1,000 rows should not die on one omission. Values are clamped to 0..1 and
    a non-numeric value is an error — silently treating `"high"` as 0.0 would report a miss as a model
    failure rather than a prompt problem.
    """
    payload = json.loads(_strip_fences(content))
    categories = payload.get("categories") if isinstance(payload, dict) else None
    if not isinstance(categories, dict):
        raise ValueError(f"reply has no 'categories' object: {content[:200]!r}")
    probs: Dict[str, float] = {}
    for name in CATEGORIES:
        value = categories.get(name, 0.0)
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            raise ValueError(f"category {name!r} is not a number: {value!r}")
        probs[name] = round(min(1.0, max(0.0, float(value))), 4)
    if "safe" not in categories:
        top_harmful = max(probs[c] for c in HARMFUL_CATEGORIES)
        probs["safe"] = round(max(0.0, 1.0 - top_harmful), 4)
    return probs


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
