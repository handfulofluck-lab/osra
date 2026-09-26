"""FamilyShield AI engine — text analysis model.

Loads a fine-tuned DistilBERT multi-label classifier from MODEL_PATH (lazy
singleton). When the model files or torch/transformers are unavailable
(dev mode), falls back to a deterministic keyword/regex classifier that
returns the same response shape.
"""

import os
import re

CATEGORIES = [
    "cyberbullying",
    "self_harm",
    "grooming",
    "violence",
    "sexual_content",
    "substance_use",
    "hate_speech",
    "safe",
]

# Lazy singleton state: None = not attempted, False = unavailable (dev mode),
# (model, tokenizer) tuple = loaded.
_pipeline = None

# Regex rules layer: (category, compiled pattern, weight, human-readable name).
_RULES = [
    (
        "self_harm",
        re.compile(
            r"\b(kill (yourself|urself)|kys|commit (suicide|sewercide)|end (your|it) (life|all)"
            r"|hurt(ing)? yourself|cut(ting)? yourself|self[- ]?harm(ed|ing)?"
            r"|want(ing)? to die|wanna die|better off (dead|without (you|me))"
            r"|no reason to live|end it all)\b",
            re.IGNORECASE,
        ),
        3.5,
        "self-harm phrase",
    ),
    (
        "grooming",
        re.compile(
            r"\b(don'?t|do not)\s+(tell|let)\s+(your|ur)\s*(parents?|mom|dad|mother|father"
            r"|anyone|anybody|nobody)",
            re.IGNORECASE,
        ),
        2.0,
        "secrecy from parents",
    ),
    (
        "grooming",
        re.compile(
            r"\b(our|a|the|this|my)\s+(little\s+)?secret\b|\bkeep\s+(it|this)\s+(a\s+)?secret\b"
            r"|\bjust\s+between\s+us\b|\bsecret\s+between\s+us\b",
            re.IGNORECASE,
        ),
        2.0,
        "secret-keeping",
    ),
    (
        "grooming",
        re.compile(
            r"\bsend\b[^.!?\n]{0,25}\b(pic|pics|photo|photos|picture|pictures|selfie|selfies"
            r"|nude|nudes|video|videos)\b|\btrade\s+(pics|photos)\b",
            re.IGNORECASE,
        ),
        2.0,
        "image request",
    ),
    (
        "grooming",
        re.compile(
            r"\b(meet|meet up|hang out)\b[^.!?\n]{0,40}\b(alone|in person|after dark|tonight|midnight)\b",
            re.IGNORECASE,
        ),
        2.0,
        "meeting request (alone/night)",
    ),
    (
        "grooming",
        re.compile(r"\bmeet\s+(me\s+)?(at|near|behind)\b", re.IGNORECASE),
        1.2,
        "meeting request",
    ),
    (
        "grooming",
        re.compile(
            r"(\+?1[\s.\-]?)?\(?\d{3}\)?[\s.\-]\d{3}[\s.\-]\d{4}\b|\b\d{10}\b"
        ),
        1.2,
        "phone number",
    ),
    (
        "substance_use",
        re.compile(
            r"\b(weed\w*|marijuana|cannabis|\b420\b|juul|vape\w*|nicotine|ecstasy|molly|mdma"
            r"|cocaine|heroin|meth\w*|fentanyl|oxycodone|xanax|adderall|shrooms|edible\w*"
            r"|get(ting)?\s+high|drug\w*|\bpills?\b)\b",
            re.IGNORECASE,
        ),
        1.5,
        "substance mention",
    ),
    (
        "hate_speech",
        re.compile(
            r"\b(faggot\w*|fag|nigger\w*|nigga\w*|retard\w*|spic\w*|kike\w*|chink\w*"
            r"|wetback\w*|dyke\w*|tranny\w*|coon|gook\w*)\b",
            re.IGNORECASE,
        ),
        2.5,
        "slur",
    ),
    (
        "violence",
        re.compile(
            r"\b(kill (him|her|them|you all|everyone)|beat (him|her|them|you) up|beat up"
            r"|stab(bed|bing)?|shoot(ing)?\s+(him|her|them|you|up|everyone)|\bgun\b|\bknife\b"
            r"|\bknives\b|school shooting|bring(ing)? (a )?(gun|knife|weapon)"
            r"|punch(ing)? (him|her|them|you)|i'?m gonna (kill|hurt|beat)"
            r"|gonna (kill|hurt|beat) (you|him|her|them)|hurt (you|him|her|them))\b",
            re.IGNORECASE,
        ),
        2.0,
        "violence threat",
    ),
    (
        "cyberbullying",
        re.compile(
            r"\b(ugly|loser|freak|pathetic|worthless|fatty|dumbass|nobody likes you"
            r"|everyone hates you|no one loves you|i hate you|go die"
            r"|you'?re\s+(so\s+)?(stupid|dumb|pathetic|ugly|worthless))\b",
            re.IGNORECASE,
        ),
        1.2,
        "harassment insult",
    ),
    (
        "sexual_content",
        re.compile(
            r"\b(nude\w*|naked|sex\w*|porn\w*|nsfw|dick\s?pics?|boobs?|topless"
            r"|hook(ing)? up|make out)\b",
            re.IGNORECASE,
        ),
        1.5,
        "sexual content",
    ),
]


def _load_model():
    """Lazily load the fine-tuned DistilBERT classifier from MODEL_PATH (singleton)."""
    global _pipeline
    if _pipeline is not None:
        return _pipeline or None
    model_path = os.environ.get("MODEL_PATH", "").strip()
    if not model_path or not os.path.isdir(model_path):
        _pipeline = False
        return None
    try:
        # Lazy imports: dev machines (e.g. Python 3.13) may lack torch/transformers.
        import torch  # noqa: F401
        from transformers import AutoModelForSequenceClassification, AutoTokenizer
    except ImportError:
        _pipeline = False
        return None
    try:
        tokenizer = AutoTokenizer.from_pretrained(model_path)
        model = AutoModelForSequenceClassification.from_pretrained(model_path)
        model.eval()
        _pipeline = (model, tokenizer)
    except Exception:
        _pipeline = False  # unreadable checkpoint -> deterministic fallback
        return None
    return _pipeline


def _model_probabilities(model, tokenizer, text):
    """Run DistilBERT inference and return multi-label probabilities for the 8 categories."""
    import torch

    inputs = tokenizer(text, return_tensors="pt", truncation=True, max_length=512)
    with torch.no_grad():
        logits = model(**inputs).logits[0]
    probs = torch.sigmoid(logits).tolist()
    return {cat: float(p) for cat, p in zip(CATEGORIES, probs)}


def _rules_scores(text):
    """Score text against the regex rules layer, returning per-category scores and rule names."""
    scores = {cat: 0.0 for cat in CATEGORIES}
    matched = []
    for category, pattern, weight, name in _RULES:
        if pattern.search(text):
            scores[category] += weight
            matched.append(name)
    return scores, matched


def _rule_probability(score):
    """Convert a rules-layer score to a probability via a saturating function."""
    return min(0.99, score / (score + 0.6)) if score > 0 else 0.0


def _fallback_probabilities(rule_scores):
    """Deterministic keyword/regex scoring used when the model is unavailable (dev mode)."""
    probs = {}
    for cat in CATEGORIES:
        probs[cat] = round(_rule_probability(rule_scores[cat]), 4)
    top_harmful = max(probs[cat] for cat in CATEGORIES if cat != "safe")
    probs["safe"] = 0.98 if top_harmful == 0 else round(1.0 - top_harmful, 4)
    return probs


def _merge_model_and_rules(probs, rule_scores):
    """Combine model probabilities with rules-layer boosts (rules can only raise scores)."""
    merged = {cat: float(probs.get(cat, 0.0)) for cat in CATEGORIES}
    for cat in CATEGORIES:
        if rule_scores[cat] > 0:
            merged[cat] = round(min(0.99, max(merged[cat], _rule_probability(rule_scores[cat]))), 4)
    return merged


def _severity(top_prob):
    """Map the top category probability to a severity level and flagged flag."""
    if top_prob >= 0.85:
        return "critical", True
    if top_prob >= 0.6:
        return "warning", True
    return "info", False


def analyze_text(text, context="message", child_age=None):
    """Analyze text and return categories, severity, flagged and an explanation."""
    # NOTE: context and child_age are accepted per API contract; the current
    # model and rules layer do not yet differentiate by either (simplest
    # interpretation of spec §4.3).
    probs = None
    pipeline = _load_model()
    if pipeline:
        try:
            probs = _model_probabilities(pipeline[0], pipeline[1], text)
        except Exception:
            probs = None  # fall back to keyword/regex classification
    rule_scores, matched_rules = _rules_scores(text or "")
    if probs is None:
        probs = _fallback_probabilities(rule_scores)
    else:
        probs = _merge_model_and_rules(probs, rule_scores)
    top_harmful = max(probs[cat] for cat in CATEGORIES if cat != "safe")
    severity, flagged = _severity(top_harmful)
    top2 = sorted(probs.items(), key=lambda kv: (-kv[1], kv[0]))[:2]
    (c1, p1), (c2, p2) = top2
    explanation = f"Top categories: {c1} ({p1:.2f}) and {c2} ({p2:.2f})."
    if matched_rules:
        explanation += " Rules matched: " + ", ".join(matched_rules) + "."
    return {
        "categories": probs,
        "severity": severity,
        "flagged": flagged,
        "explanation": explanation,
    }
