"""ADR-0033: the Amazon Bedrock scorer — how a candidate production model is measured on the set.

ADR-0033 decides that a real child's message is scored only by a model on Amazon Bedrock, inside the
EU, and that *which* model is decided by this set: the cheapest candidate that passes the Phase 4 gate
on the held-out `test` split twice, with hard-negative false alarms at or below 0.05 per language. This
module is that measurement. It sends the same prompt and reads the same JSON as `deepseek_scorer.py`
(both import `eval/prompt.py`), so the two tables compare like with like.

It still lives in `eval/` and scores synthetic messages only. The production service (the ai-engine on
Fargate, its IAM role, the data-retention setting) is a separate change, and it waits for the three
decisions ADR-0033 leaves to Karim.

Three rules from the ADR are enforced here rather than trusted to whoever runs it:

- **EU only.** A model ID with a global or non-EU geographic prefix, an ARN, or a region outside the EU
  is refused before any request is made (`check_route`).
- **A refusal is flagged, never safe.** A model that declines a grooming message, read as "safe", would
  reproduce the 0 % Arabic recall the ADR exists to end. So a refused, filtered or unreadable answer
  scores 1.0 in every harmful category, and is counted, so a reader can see how much recall came from it.
- **The cost is measured, not estimated.** Every call adds the tokens Bedrock reports to the run's usage,
  and with `BEDROCK_PRICE_IN`/`BEDROCK_PRICE_OUT` set (US$ per 1M tokens) the run states its cost per
  1,000 scans.

The client is boto3's `bedrock-runtime` Converse API, so every candidate — Amazon, Anthropic, Mistral,
Qwen, OpenAI, DeepSeek — goes through one code path.
"""

import atexit
import json
import os
from typing import Any, Callable, Dict, Iterable, List, Optional

from eval.banks import HARMFUL_CATEGORIES
from eval.prompt import REFUSED_KEY, SYSTEM_PROMPT, cache_key, parse_categories

DEFAULT_REGION = "eu-central-1"  # production's region (ADR-0030)
DEFAULT_CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".bedrock-cache.json")
MAX_OUTPUT_TOKENS = 200

#: EU member-state regions Bedrock serves (ADR-0033 decision 1). London and Zurich are not in the EU.
EU_REGIONS = frozenset({"eu-central-1", "eu-north-1", "eu-west-1", "eu-west-3", "eu-south-1", "eu-south-2"})

#: The first segment of an in-region model ID is its provider. Anything else must be the `eu.` profile.
IN_REGION_PROVIDERS = frozenset({"amazon", "anthropic", "mistral", "qwen", "openai", "deepseek", "meta", "cohere"})

#: Converse stop reasons that mean the model did not give its own answer to the message.
REFUSAL_STOP_REASONS = frozenset({"content_filtered", "guardrail_intervened", "refusal"})


class BedrockUnavailable(RuntimeError):
    """The route is not allowed, or Bedrock refused in a way that retrying will not fix."""


def check_route(model_id: str, region: str) -> None:
    """Refuse any route ADR-0033 rules out, before a single request is made."""
    if region not in EU_REGIONS:
        raise BedrockUnavailable(
            f"region {region!r} is not an EU region; ADR-0033 allows only {', '.join(sorted(EU_REGIONS))}"
        )
    if not model_id or model_id.startswith("arn:"):
        raise BedrockUnavailable(
            f"model {model_id!r}: pass a model ID or an eu. inference profile ID, not an ARN"
        )
    head = model_id.split(".", 1)[0]
    if head == "eu" or head in IN_REGION_PROVIDERS:
        return
    raise BedrockUnavailable(
        f"model {model_id!r} uses the {head!r} route; ADR-0033 allows in-region IDs and the eu. profile only"
    )


def refused_probs() -> Dict[str, float]:
    """What a refused or unreadable answer scores: flagged in every harmful category, and marked."""
    probs = {c: 1.0 for c in HARMFUL_CATEGORIES}
    probs["safe"] = 0.0
    probs[REFUSED_KEY] = 1.0
    return probs


def _env_float(name: str) -> Optional[float]:
    raw = os.environ.get(name, "").strip()
    return float(raw) if raw else None


class BedrockScorer:
    """A callable scorer: text in, probability per category out. Cached, metered, EU-only."""

    def __init__(
        self,
        model_id: Optional[str] = None,
        region: Optional[str] = None,
        client: Any = None,
        cache_path: Optional[str] = DEFAULT_CACHE_PATH,
        extra_fields: Optional[Dict[str, Any]] = None,
        price_in: Optional[float] = None,
        price_out: Optional[float] = None,
        log: Optional[Callable[[str], None]] = print,
        prompt: Optional[str] = None,
    ):
        self.model_id = (model_id or os.environ.get("BEDROCK_MODEL_ID", "")).strip()
        self.region = (region or os.environ.get("BEDROCK_REGION", DEFAULT_REGION)).strip()
        if not self.model_id:
            raise BedrockUnavailable(
                "BEDROCK_MODEL_ID is not set. Name a candidate from ADR-0033, for example "
                "eu.amazon.nova-micro-v1:0, and run the ai-eval-bedrock workflow."
            )
        check_route(self.model_id, self.region)
        if extra_fields is None:
            raw = os.environ.get("BEDROCK_EXTRA_FIELDS", "").strip()
            extra_fields = json.loads(raw) if raw else {}
        self.extra_fields = extra_fields
        self.price_in = price_in if price_in is not None else _env_float("BEDROCK_PRICE_IN")
        self.price_out = price_out if price_out is not None else _env_float("BEDROCK_PRICE_OUT")
        # A second, independent run of the same rows (ADR-0033 asks for two on `test`) must not be
        # answered from the first run's cache.
        if os.environ.get("BEDROCK_NO_CACHE", "") == "1":
            cache_path = None
        self.cache_path = cache_path
        self._client = client if client is not None else self._make_client()
        self._log = log or (lambda _m: None)
        self.prompt = prompt or SYSTEM_PROMPT
        self._cache: Dict[str, Dict[str, float]] = self._load_cache()
        self.calls = 0
        self.hits = 0
        self.refusals = 0
        self.input_tokens = 0
        self.output_tokens = 0
        atexit.register(self.save_cache)

    def _make_client(self):
        # Imported here so the test suite, and every other scorer, runs without boto3 installed.
        import boto3
        from botocore.config import Config

        config = Config(
            region_name=self.region,
            connect_timeout=10,
            read_timeout=30,
            retries={"max_attempts": 4, "mode": "standard"},  # throttles and 5xx, with backoff
        )
        return boto3.client("bedrock-runtime", config=config)

    # ── cache ────────────────────────────────────────────────────────────────────────────────

    def _load_cache(self) -> Dict[str, Dict[str, float]]:
        if not self.cache_path or not os.path.exists(self.cache_path):
            return {}
        try:
            with open(self.cache_path, encoding="utf-8") as handle:
                data = json.load(handle)
            return data if isinstance(data, dict) else {}
        except (ValueError, OSError):
            return {}  # a corrupt cache is a cache miss, not a failed run

    def save_cache(self) -> None:
        if not self.cache_path or not self._cache:
            return
        try:
            with open(self.cache_path, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(self._cache, handle, ensure_ascii=False, sort_keys=True)
        except OSError as exc:  # pragma: no cover - disk problem, not logic
            self._log(f"[bedrock] could not write the cache ({exc}); the run continues uncached")

    # ── the call ─────────────────────────────────────────────────────────────────────────────

    def request(self, text: str) -> Dict[str, Any]:
        """The Converse request for one message, as sent."""
        anthropic = ".anthropic." in f".{self.model_id}"
        inference: Dict[str, Any] = {"maxTokens": MAX_OUTPUT_TOKENS}
        fields: Dict[str, Any] = {}
        if anthropic:
            # Current Claude models think by default and bill it as output; a classifier does not need it.
            # They also reject sampling parameters, so none is sent.
            fields["thinking"] = {"type": "disabled"}
        else:
            inference["temperature"] = 0
        fields.update(self.extra_fields)
        body: Dict[str, Any] = {
            "modelId": self.model_id,
            "system": [{"text": self.prompt}],
            "messages": [{"role": "user", "content": [{"text": text}]}],
            "inferenceConfig": inference,
        }
        if fields:
            body["additionalModelRequestFields"] = fields
        return body

    def _converse(self, text: str) -> Dict[str, Any]:
        try:
            return self._client.converse(**self.request(text))
        except Exception as exc:  # botocore's ClientError, without importing botocore here
            code = (getattr(exc, "response", None) or {}).get("Error", {}).get("Code", "")
            if code == "AccessDeniedException":
                raise BedrockUnavailable(
                    f"access denied for {self.model_id} in {self.region}: the role may not call it, or the "
                    "model's terms have not been accepted in this account (ADR-0033, Karim's decision 1)"
                ) from exc
            if code in ("ValidationException", "ResourceNotFoundException"):
                raise BedrockUnavailable(f"{self.model_id} in {self.region} was refused: {exc}") from exc
            raise

    def __call__(self, text: str) -> Dict[str, float]:
        key = cache_key(self.model_id, text, self.prompt)
        cached = self._cache.get(key)
        if cached is not None:
            self.hits += 1
            if cached.get(REFUSED_KEY):
                self.refusals += 1
            return cached
        reply = self._converse(text)
        self.calls += 1
        usage = reply.get("usage") or {}
        self.input_tokens += int(usage.get("inputTokens", 0))
        self.output_tokens += int(usage.get("outputTokens", 0))
        content = (reply.get("output") or {}).get("message", {}).get("content") or []
        answer = "".join(block["text"] for block in content if isinstance(block, dict) and "text" in block)
        try:
            if reply.get("stopReason") in REFUSAL_STOP_REASONS:
                raise ValueError(f"stop reason {reply.get('stopReason')!r}")
            probs = parse_categories(answer)
        except ValueError:
            probs = refused_probs()
        if probs.get(REFUSED_KEY):
            self.refusals += 1
        self._cache[key] = probs
        if self.calls % 25 == 0:
            self.save_cache()
        return probs

    def score_many(self, texts: Iterable[str], progress_every: int = 100) -> List[Dict[str, float]]:
        results: List[Dict[str, float]] = []
        for index, text in enumerate(texts, start=1):
            results.append(self(text))
            if index % progress_every == 0:
                self.save_cache()
                self._log(f"[bedrock] {index} rows · {self.calls} calls · {self.hits} cache hits")
        self.save_cache()
        return results

    def usage(self) -> Dict[str, Any]:
        """What the run cost in tokens, and in dollars when the prices were given."""
        summary: Dict[str, Any] = {
            "model_id": self.model_id,
            "region": self.region,
            "calls": self.calls,
            "cache_hits": self.hits,
            "refused_or_unreadable": self.refusals,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
        }
        if self.calls:
            summary["input_tokens_per_scan"] = round(self.input_tokens / self.calls, 1)
            summary["output_tokens_per_scan"] = round(self.output_tokens / self.calls, 1)
            if self.price_in is not None and self.price_out is not None:
                per_scan = (self.input_tokens * self.price_in + self.output_tokens * self.price_out) / 1e6 / self.calls
                summary["usd_per_1000_scans"] = round(per_scan * 1000, 4)
        return summary


_DEFAULT: Optional[BedrockScorer] = None


def default_scorer() -> BedrockScorer:
    """One scorer per process, so the cache and the client are not rebuilt per row."""
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = BedrockScorer()
    return _DEFAULT
