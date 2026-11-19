"""Disable the Mac user's current keys when its fixed authorization expires.

The event cannot select a user or supply a clock/deadline. Only the protected
IAM user tag is consulted. No credential material is read, and the only write
is UpdateAccessKey(Status="Inactive"). This does not revoke STS sessions.
"""

from datetime import datetime, timezone
import json
import re

USER_NAME = "osra-codex-mac"
DEADLINE_TAG = "osra:access-expires-at"
ISO_TIMESTAMP = re.compile(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})\Z"
)


def _pages(method, result_key):
    """Read every IAM page; reject incomplete or looping pagination."""
    marker = None
    markers = set()
    while True:
        arguments = {"UserName": USER_NAME}
        if marker is not None:
            arguments["Marker"] = marker
        response = method(**arguments)
        items = response[result_key]
        if not isinstance(items, list):
            raise ValueError("Invalid response")
        yield from items
        if not response.get("IsTruncated", False):
            return
        marker = response.get("Marker")
        if not isinstance(marker, str) or not marker or marker in markers:
            raise ValueError("Invalid pagination")
        markers.add(marker)


def _future_deadline(iam, now, counts):
    """Only a valid future tag permits skipping deactivation."""
    try:
        values = [tag["Value"] for tag in _pages(iam.list_user_tags, "Tags")
                  if isinstance(tag.get("Key"), str) and tag["Key"].lower() == DEADLINE_TAG]
        if len(values) != 1 or not isinstance(values[0], str) or not ISO_TIMESTAMP.fullmatch(values[0]):
            counts["invalid_deadline"] += 1
            return False
        deadline = datetime.fromisoformat(values[0].replace("Z", "+00:00"))
        current = now()
        if current.tzinfo is None or current.utcoffset() is None:
            raise ValueError("Invalid clock")
        return deadline > current
    except Exception:
        # Never log provider exceptions or response bodies. Read failures are
        # not permission to retain access; attempt deactivation and alarm.
        counts["errors"] += 1
        return False


def enforce_expiry(iam, now=lambda: datetime.now(timezone.utc)):
    """Enforce against an injected IAM client; return safe counts/status only."""
    counts = {"keys_seen": 0, "keys_disabled": 0, "keys_inactive": 0, "keys_absent": 0,
              "invalid_deadline": 0, "errors": 0}
    if _future_deadline(iam, now, counts):
        return {"status": "future_deadline", **counts}
    try:
        for key in _pages(iam.list_access_keys, "AccessKeyMetadata"):
            counts["keys_seen"] += 1
            try:
                if key.get("Status") == "Inactive":
                    counts["keys_inactive"] += 1
                    continue
                # An authorized renewal may have happened since the initial
                # read. Recheck before each write; IAM has no atomic tag+key
                # operation, so concurrent renewal remains an operational gate.
                if _future_deadline(iam, now, counts):
                    return {"status": "future_deadline", **counts}
                key_id = key["AccessKeyId"]
                if not isinstance(key_id, str) or not key_id:
                    raise ValueError("Invalid key metadata")
                iam.update_access_key(UserName=USER_NAME, AccessKeyId=key_id, Status="Inactive")
                counts["keys_disabled"] += 1
            except Exception as error:
                # A rotation may delete a listed key before this write. That
                # key no longer grants access; still process all remaining keys.
                response = getattr(error, "response", None)
                detail = response.get("Error") if isinstance(response, dict) else None
                if isinstance(detail, dict) and detail.get("Code") == "NoSuchEntity":
                    counts["keys_absent"] += 1
                else:
                    counts["errors"] += 1
                # A failed key must not prevent an attempt on the other key.
    except Exception:
        counts["errors"] += 1
    return {"status": "incomplete" if counts["errors"] else "disabled", **counts}


def handler(event, context):
    """Scheduled entry point; ignore all caller-supplied event fields."""
    try:
        import boto3
        from botocore.config import Config

        iam = boto3.client("iam", config=Config(
            connect_timeout=3, read_timeout=3,
            retries={"mode": "standard", "total_max_attempts": 2},
        ))
        result = enforce_expiry(iam)
    except Exception:
        result = {"status": "incomplete", "keys_seen": 0, "keys_disabled": 0,
                  "keys_inactive": 0, "keys_absent": 0, "invalid_deadline": 0, "errors": 1}
    print(json.dumps(result, sort_keys=True))
    if result["errors"] or result["invalid_deadline"]:
        # Lambda's Errors alarm sees the failure. Suppress the SDK exception
        # chain: status/count JSON above is the only diagnostic detail emitted.
        raise RuntimeError("Authorization expiry enforcement incomplete") from None
    return result
