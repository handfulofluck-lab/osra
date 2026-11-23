"""Private Frankfurt transport and receipt validation for the OSRA staging checkpoints."""

import json
import math
import os
import re
from datetime import datetime, timezone
from functools import lru_cache
from time import monotonic

import boto3
from botocore.config import Config
from botocore.exceptions import ConnectTimeoutError, ReadTimeoutError

REGION = "eu-central-1"
PRIVATE_RUNTIME = re.compile(r"https://vpce-[a-f0-9]+(?:-[a-z0-9]+)?\.runtime\.sagemaker\.eu-central-1\.vpce\.amazonaws\.com")
ENDPOINTS = {"v9": "osra-staging-own-v9", "v9b": "osra-staging-own-v9b"}
LANGUAGES = {"v9": {"en", "id", "ms", "tr", "ur"}, "v9b": {"ar", "fr"}}
# These are the native checkpoint labels pinned by #997. No Bedrock vocabulary or cutoff applies.
LABELS = ("cyberbullying", "self_harm", "grooming", "violence", "sexual_content", "substance_use", "hate_speech")
MAX_REPLY_BYTES = 8192


@lru_cache(maxsize=1)
def _client():
    url = os.environ.get("OSRA_STAGING_QA_SAGEMAKER_ENDPOINT_URL", "")
    if not PRIVATE_RUNTIME.fullmatch(url):
        raise ValueError("Invalid private staging runtime")
    return boto3.Session().client(
        "sagemaker-runtime", region_name=REGION, endpoint_url=url, verify=True,
        config=Config(signature_version="v4", connect_timeout=0.35, read_timeout=1.5,
                      retries={"total_max_attempts": 1, "mode": "standard"}, proxies={}),
    )


def _pins():
    pins = {}
    for version in ENDPOINTS:
        prefix = f"OSRA_STAGING_QA_{version.upper()}_"
        model = os.environ.get(prefix + "MODEL_SHA256", "")
        thresholds = os.environ.get(prefix + "THRESHOLDS_SHA256", "")
        if not all(re.fullmatch(r"[a-f0-9]{64}", value) for value in (model, thresholds)):
            raise ValueError("Missing approved checkpoint pins")
        pins[version] = model, thresholds
    return pins


def _unique(pairs):
    fields = dict(pairs)
    if len(fields) != len(pairs):
        raise ValueError("Duplicate model reply field")
    return fields


def _invoke(version, text, trace, language, expires, deadline):
    client = _client()
    request = {"text": text, "trace_id": trace}
    if language is not None:
        request["lang"] = language
    # Credential discovery may block. Never send a second checkpoint request after expiry.
    if datetime.now(timezone.utc) >= expires or monotonic() >= deadline:
        raise TimeoutError
    try:
        response = client.invoke_endpoint(
            EndpointName=ENDPOINTS[version], ContentType="application/json", Accept="application/json",
            Body=json.dumps(request, ensure_ascii=False).encode(),
        )
        body = response["Body"]
        try:
            if response["ResponseMetadata"]["HTTPStatusCode"] != 200 or response.get("ContentType", "").split(";")[0] != "application/json":
                raise ValueError("Invalid checkpoint response")
            raw = body.read(MAX_REPLY_BYTES + 1)
        finally:
            body.close()
    except (ConnectTimeoutError, ReadTimeoutError) as error:
        raise TimeoutError from error
    if len(raw) > MAX_REPLY_BYTES:
        raise ValueError("Oversized checkpoint response")
    if monotonic() >= deadline or datetime.now(timezone.utc) >= expires:
        raise TimeoutError
    result = json.loads(raw, object_pairs_hook=_unique)
    if not isinstance(result, dict) or result.get("trace_id") != trace:
        raise ValueError("Unmatched checkpoint response")
    return result


def _validated(reply, version, pins, expected_language=None):
    fields = {"trace_id", "model", "language", "model_sha256", "thresholds_sha256", "probs", "flagged_categories", "verdict"}
    if set(reply) != fields or reply["model"] != version or (reply["model_sha256"], reply["thresholds_sha256"]) != pins[version]:
        raise ValueError("Unverified checkpoint")
    language = reply["language"]
    if language not in LANGUAGES[version] | {"uncertain"} or (expected_language is not None and language != expected_language):
        raise ValueError("Unexpected checkpoint language")
    probs, flagged = reply["probs"], reply["flagged_categories"]
    if not isinstance(probs, dict) or set(probs) != set(LABELS) or not all(
        type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1 for value in probs.values()
    ):
        raise ValueError("Invalid checkpoint probabilities")
    if not isinstance(flagged, list) or any(label not in LABELS for label in flagged) or len(set(flagged)) != len(flagged):
        raise ValueError("Invalid checkpoint flags")
    if reply["verdict"] != ("flagged" if flagged else "safe"):
        raise ValueError("Inconsistent checkpoint verdict")
    return {"model": version, "language": language, "categories": probs, "flagged_categories": flagged}


def score_own(text, trace, expires, deadline):
    """The serving code owns language and calibration. A failed uncertain comparison has no verdict."""
    pins = _pins()
    first = _invoke("v9", text, trace, None, expires, deadline)
    if set(first) == {"trace_id", "route", "language"}:
        if first["route"] != "v9b" or first["language"] not in LANGUAGES["v9b"]:
            raise ValueError("Unsupported checkpoint route")
        second = _invoke("v9b", text, trace, first["language"], expires, deadline)
        return _validated(second, "v9b", pins, first["language"])
    primary = _validated(first, "v9", pins)
    if primary["language"] != "uncertain":
        return primary
    second = _invoke("v9b", text, trace, "uncertain", expires, deadline)
    secondary = _validated(second, "v9b", pins, "uncertain")
    category_scores = {label: max(primary["categories"][label], secondary["categories"][label]) for label in LABELS}
    flagged = [label for label in LABELS if label in primary["flagged_categories"] or label in secondary["flagged_categories"]]
    return {"model": "v9+v9b", "language": "uncertain", "categories": category_scores, "flagged_categories": flagged}
