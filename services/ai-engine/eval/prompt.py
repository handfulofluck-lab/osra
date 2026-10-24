"""The one prompt every hosted scorer sends, and the one parser for what comes back (ADR-0033).

ADR-0033 chooses the production model by measuring candidates on this set. A comparison means
something only if every candidate saw the same instructions and was read the same way. So the prompt,
the JSON contract and the cache key live here, and `deepseek_scorer.py` and `bedrock_scorer.py` both
import them. A change to the prompt therefore re-scores every scorer: the cache key carries the
prompt's digest.
"""

import hashlib
import json
import re
from typing import Dict

from eval.banks import HARMFUL_CATEGORIES

#: Categories the model is asked for, plus `safe`. Kept in one place so a change to the taxonomy is one
#: edit and the prompt, the parser and the cache key cannot drift apart.
CATEGORIES = HARMFUL_CATEGORIES + ["safe"]

#: Marks a score that is not the model's own answer — a refusal, a filtered reply, or one that could not be
#: read. It travels with the probabilities so the harness can count it; no category reads it.
REFUSED_KEY = "_refused"

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


def cache_key(model: str, text: str, prompt: str = SYSTEM_PROMPT) -> str:
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


def strip_fences(content: str) -> str:
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
    payload = json.loads(strip_fences(content))
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
