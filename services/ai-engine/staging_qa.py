"""Private, time-limited Bedrock inference for staging QA."""

import asyncio
import hashlib
import logging
import os
import re
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from time import monotonic
from typing import Literal

from botocore.exceptions import (
    ClientError,
    ConnectTimeoutError,
    CredentialRetrievalError,
    EndpointConnectionError,
    NoCredentialsError,
    ParamValidationError,
    PartialCredentialsError,
    ReadTimeoutError,
    SSLError,
)
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, UUID4, ValidationError

from eval.prompt import parse_categories
from model import _severity

MODEL_ID = "openai.gpt-oss-20b-1:0"
REGION = "eu-central-1"
PRIVATE_ENDPOINT_URL = re.compile(
    r"https://vpce-[a-f0-9]+(?:-[a-z0-9]+)?\.bedrock-runtime\."
    rf"{REGION}\.vpce\.amazonaws\.com"
)
APPROVED_PROMPT_SHA256 = "813e670c456b1e1dd9863be0ca186b82f18bfea8049f231c9731d2ab132578a8"
MAX_REQUEST_BYTES = 8192
MAX_APPROVAL_WINDOW = timedelta(hours=1)
MAX_INFERENCE_SECONDS = 2

PROVIDER_FAILURE_KINDS = {
    "AccessDeniedException": "access_denied",
    "ModelAccessDeniedException": "access_denied",
    "ValidationException": "provider_validation",
    "ThrottlingException": "throttled",
    "ServiceQuotaExceededException": "throttled",
}

logger = logging.getLogger(__name__)
router = APIRouter()


class StagingQaRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str = Field(min_length=1, max_length=1024)
    trace_id: UUID4


class StagingQaResponse(BaseModel):
    flagged: bool
    severity: Literal["info", "warning", "critical"]
    categories: dict[str, float]
    model: str
    region: str
    trace_id: UUID4


def _test_approval() -> tuple[datetime, set[str] | None, str]:
    if (
        os.environ.get("OSRA_DEPLOYMENT_SCOPE") != "staging"
        or os.environ.get("OSRA_STAGING_QA_ANALYZER_ENABLED") != "1"
    ):
        raise HTTPException(status_code=404, detail="not_found")
    try:
        expires_at = datetime.fromisoformat(os.environ.get("OSRA_STAGING_QA_EXPIRES_AT", ""))
        # Deployment injects the exact approved bytes from the private task configuration.
        system_prompt = os.environ.get("OSRA_STAGING_QA_SYSTEM_PROMPT", "")
        prompt_digest = hashlib.sha256(system_prompt.encode("utf-8")).hexdigest()
    except ValueError:
        raise HTTPException(status_code=404, detail="not_found") from None
    now = datetime.now(timezone.utc)
    allow_pair_text = os.environ.get("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", "0")
    if (
        expires_at.utcoffset() != timedelta(0)
        or not now < expires_at <= now + MAX_APPROVAL_WINDOW
        or allow_pair_text not in ("0", "1")
        or prompt_digest != APPROVED_PROMPT_SHA256
    ):
        raise HTTPException(status_code=404, detail="not_found")
    if allow_pair_text == "1":
        # The private caller is the staging API, which binds requests to the synthetic pairing.
        return expires_at, None, system_prompt
    entries = os.environ.get("OSRA_STAGING_QA_FIXTURE_SHA256", "").split(",")
    digests = {entry.strip() for entry in entries}
    if len(entries) > 8 or not all(re.fullmatch(r"[0-9a-f]{64}", digest) for digest in digests):
        raise HTTPException(status_code=404, detail="not_found")
    return expires_at, digests, system_prompt


@lru_cache(maxsize=1)
def _bedrock_client():
    endpoint_url = os.environ.get("OSRA_STAGING_QA_BEDROCK_ENDPOINT_URL", "")
    if not PRIVATE_ENDPOINT_URL.fullmatch(endpoint_url):
        raise ValueError("Frankfurt Bedrock endpoint is invalid")

    import boto3
    from botocore.config import Config

    return boto3.Session().client(
        "bedrock-runtime",
        region_name=REGION,
        endpoint_url=endpoint_url,
        verify=True,
        config=Config(
            signature_version="v4",
            connect_timeout=0.35,
            read_timeout=1.5,
            retries={"total_max_attempts": 1, "mode": "standard"},
            proxies={},
        ),
    )


def _infer(
    text: str,
    trace_id: str,
    system_prompt: str,
    expires_at: datetime,
    deadline: float,
) -> dict[str, float]:
    client = _bedrock_client()
    # Role credentials may take time to load. Re-check the deadline before sending any text.
    if datetime.now(timezone.utc) >= expires_at or monotonic() >= deadline:
        raise TimeoutError("staging QA inference deadline elapsed")
    reply = client.converse(
        modelId=MODEL_ID,
        system=[{"text": system_prompt}],
        messages=[{"role": "user", "content": [{"text": text}]}],
        inferenceConfig={"maxTokens": 1000, "temperature": 0},
        additionalModelRequestFields={"reasoning_effort": "low"},
        requestMetadata={"osraQaTraceId": trace_id},
    )
    if reply["ResponseMetadata"]["HTTPStatusCode"] != 200 or reply["stopReason"] != "end_turn":
        raise ValueError("Bedrock did not complete the classifier reply")
    message = reply["output"]["message"]
    if message["role"] != "assistant":
        raise ValueError("Bedrock did not return an assistant message")
    answer = "".join(block["text"] for block in message["content"] if "text" in block)
    return parse_categories(answer, strict=True)


def _failure_kind(error: Exception) -> str:
    """Keep provider messages, request bodies, and unrecognized codes out of logs."""
    if isinstance(error, ClientError):
        code = error.response.get("Error", {}).get("Code")
        return PROVIDER_FAILURE_KINDS.get(code, "provider_error") if isinstance(code, str) else "provider_error"
    if isinstance(error, ParamValidationError):
        return "sdk_validation"
    if isinstance(error, (NoCredentialsError, PartialCredentialsError, CredentialRetrievalError)):
        return "credentials"
    if isinstance(error, (ConnectTimeoutError, ReadTimeoutError, EndpointConnectionError, SSLError)):
        return "transport"
    if isinstance(error, TimeoutError):
        return "deadline"
    if isinstance(error, (KeyError, TypeError, ValueError)):
        return "invalid_result"
    return "unexpected"


@router.post("/analyze/staging-qa", response_model=StagingQaResponse, include_in_schema=False)
async def analyze_staging_qa(request: Request) -> StagingQaResponse:
    expires_at, digests, system_prompt = _test_approval()
    # FastAPI's default validation error can echo an invalid request field. Validate privately.
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > MAX_REQUEST_BYTES:
            raise HTTPException(status_code=413, detail="request_too_large")
        body.extend(chunk)
    try:
        data = StagingQaRequest.model_validate_json(body)
        text_bytes = data.text.encode("utf-8")
    except (ValidationError, UnicodeEncodeError):
        raise HTTPException(status_code=422, detail="invalid_request") from None
    if len(text_bytes) > 1024:
        raise HTTPException(status_code=422, detail="invalid_request")
    if digests is not None and hashlib.sha256(text_bytes).hexdigest() not in digests:
        raise HTTPException(status_code=403, detail="fixture_not_approved")

    trace_id = str(data.trace_id)
    started = monotonic()
    deadline = started + MAX_INFERENCE_SECONDS
    try:
        categories = await asyncio.wait_for(
            asyncio.to_thread(_infer, data.text, trace_id, system_prompt, expires_at, deadline),
            timeout=MAX_INFERENCE_SECONDS,
        )
        if datetime.now(timezone.utc) >= expires_at or monotonic() >= deadline:
            raise TimeoutError
    except Exception as error:
        # The route is a fallback boundary. Provider errors may contain the request or reply.
        logger.warning(
            "staging QA model unavailable trace_id=%s model=%s region=%s latency_ms=%d failure_kind=%s",
            trace_id, MODEL_ID, REGION, (monotonic() - started) * 1000, _failure_kind(error),
        )
        raise HTTPException(status_code=502, detail="model_unavailable") from None

    severity, flagged = _severity(max(score for category, score in categories.items() if category != "safe"))
    logger.info(
        "staging QA model completed trace_id=%s model=%s region=%s latency_ms=%d",
        trace_id, MODEL_ID, REGION, (monotonic() - started) * 1000,
    )
    return StagingQaResponse(
        flagged=flagged,
        severity=severity,
        categories=categories,
        model=MODEL_ID,
        region=REGION,
        trace_id=data.trace_id,
    )
