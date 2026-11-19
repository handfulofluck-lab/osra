"""Pure IAM fakes: never import boto3, contact AWS or inspect host credentials."""

from datetime import datetime, timezone
from contextlib import redirect_stdout
from io import StringIO
import importlib.util
import json
from pathlib import Path
import sys
from types import ModuleType
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "functions" / "agent_access_expiry.py"
spec = importlib.util.spec_from_file_location("agent_access_expiry", SOURCE)
expiry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(expiry)
NOW = datetime(2026, 11, 30, 12, tzinfo=timezone.utc)


class FakeIam:
    def __init__(self, deadline="2026-11-30T12:00:00Z", keys=None):
        self.tags = [] if deadline is None else [{"Key": expiry.DEADLINE_TAG, "Value": deadline}]
        self.keys = keys if keys is not None else [
            {"AccessKeyId": "fixture-current-one", "Status": "Active"},
            {"AccessKeyId": "fixture-rotated-two", "Status": "Active"},
        ]
        self.calls = []
        self.fail_tags = False
        self.fail_update = set()

    def list_user_tags(self, **kwargs):
        self.calls.append(("tags", kwargs))
        if self.fail_tags:
            raise RuntimeError("fixture-private-provider-detail")
        return {"Tags": self.tags}

    def list_access_keys(self, **kwargs):
        self.calls.append(("list", kwargs))
        return {"AccessKeyMetadata": self.keys}

    def update_access_key(self, **kwargs):
        self.calls.append(("update", kwargs))
        if kwargs["AccessKeyId"] in self.fail_update:
            raise RuntimeError("fixture-private-provider-detail")


class AccessExpiryTests(unittest.TestCase):
    def run_expiry(self, iam):
        result = expiry.enforce_expiry(iam, now=lambda: NOW)
        self.assertEqual(set(result), {"status", "keys_seen", "keys_disabled", "keys_inactive", "keys_absent", "invalid_deadline", "errors"})
        for kind, arguments in iam.calls:
            self.assertEqual(arguments["UserName"], "osra-codex-mac")
            if kind == "update":
                self.assertEqual(arguments["Status"], "Inactive")
        self.assertNotIn("fixture-private-provider-detail", str(result))
        self.assertNotIn("fixture-current-one", str(result))
        return result

    def test_exact_deadline_disables_every_current_key_including_rotated_key(self):
        # Mutants: treat equality as a future deadline, or save/disable one original ID.
        iam = FakeIam()
        result = self.run_expiry(iam)
        self.assertEqual(result["keys_disabled"], 2)
        self.assertEqual(result["status"], "disabled")
        self.assertEqual({args["AccessKeyId"] for kind, args in iam.calls if kind == "update"},
                         {"fixture-current-one", "fixture-rotated-two"})

    def test_only_valid_future_deadline_skips_key_list_and_writes(self):
        iam = FakeIam("2026-11-30T12:00:01Z")
        self.assertEqual(self.run_expiry(iam)["status"], "future_deadline")
        self.assertEqual([kind for kind, _ in iam.calls], ["tags"])

    def test_tag_key_read_follows_iam_user_case_semantics(self):
        iam = FakeIam()
        iam.tags = [{"Key": "OSRA:ACCESS-EXPIRES-AT", "Value": "2026-11-30T12:00:01Z"}]
        self.assertEqual(self.run_expiry(iam)["status"], "future_deadline")
        self.assertFalse(any(kind == "update" for kind, _ in iam.calls))

    def test_missing_invalid_undated_or_duplicate_deadline_fails_closed(self):
        for deadline in [None, "", "invalid", "2026-11-30", "2026-12-01T12:00:00", "2026-99-30T12:00:00Z"]:
            with self.subTest(deadline=deadline):
                self.assertEqual(self.run_expiry(FakeIam(deadline))["keys_disabled"], 2)
        iam = FakeIam()
        iam.tags *= 2
        self.assertEqual(self.run_expiry(iam)["keys_disabled"], 2)

    def test_unreadable_deadline_still_attempts_all_keys_and_reports_failure(self):
        iam = FakeIam()
        iam.fail_tags = True
        result = self.run_expiry(iam)
        self.assertEqual(result["keys_disabled"], 2)
        self.assertEqual(result["status"], "incomplete")

    def test_one_write_failure_does_not_skip_other_key(self):
        iam = FakeIam()
        iam.fail_update.add("fixture-current-one")
        result = self.run_expiry(iam)
        self.assertEqual(result["keys_seen"], 2)
        self.assertEqual(result["keys_disabled"], 1)
        self.assertEqual(result["errors"], 1)
        self.assertEqual(result["status"], "incomplete")

    def test_key_deleted_by_concurrent_rotation_is_absent_and_other_key_is_disabled(self):
        iam = FakeIam()
        original = iam.update_access_key
        class NoSuchEntity(Exception):
            response = {"Error": {"Code": "NoSuchEntity", "Message": "fixture-private-provider-detail"}}
        def rotated(**kwargs):
            if kwargs["AccessKeyId"] == "fixture-current-one":
                raise NoSuchEntity("fixture-private-provider-detail")
            return original(**kwargs)
        iam.update_access_key = rotated
        result = self.run_expiry(iam)
        self.assertEqual(result["keys_absent"], 1)
        self.assertEqual(result["keys_disabled"], 1)
        self.assertEqual(result["errors"], 0)

    def test_inactive_keys_are_idempotent_and_no_key_is_activated(self):
        iam = FakeIam(keys=[{"AccessKeyId": "fixture-inactive", "Status": "Inactive"}])
        result = self.run_expiry(iam)
        self.assertEqual(result["keys_inactive"], 1)
        self.assertEqual(result["keys_disabled"], 0)
        self.assertFalse(any(kind == "update" for kind, _ in iam.calls))

    def test_renewal_between_initial_read_and_write_is_rechecked(self):
        iam = FakeIam()
        original = iam.list_access_keys
        def renewed(**kwargs):
            iam.tags = [{"Key": expiry.DEADLINE_TAG, "Value": "2026-12-01T12:00:00Z"}]
            return original(**kwargs)
        iam.list_access_keys = renewed
        self.assertEqual(self.run_expiry(iam)["status"], "future_deadline")
        self.assertFalse(any(kind == "update" for kind, _ in iam.calls))

    def test_pagination_reads_later_deadline_and_all_key_pages(self):
        iam = FakeIam()
        def tags(**kwargs):
            iam.calls.append(("tags", kwargs))
            if "Marker" not in kwargs:
                return {"Tags": [], "IsTruncated": True, "Marker": "tag-page"}
            return {"Tags": iam.tags}
        def keys(**kwargs):
            iam.calls.append(("list", kwargs))
            if "Marker" not in kwargs:
                return {"AccessKeyMetadata": iam.keys[:1], "IsTruncated": True, "Marker": "key-page"}
            return {"AccessKeyMetadata": iam.keys[1:]}
        iam.list_user_tags = tags
        iam.list_access_keys = keys
        self.assertEqual(self.run_expiry(iam)["keys_disabled"], 2)

    def test_failed_key_listing_reports_incomplete_without_dumping_exception(self):
        iam = FakeIam()
        def failed(**kwargs):
            raise RuntimeError("fixture-private-provider-detail")
        iam.list_access_keys = failed
        result = self.run_expiry(iam)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["keys_disabled"], 0)

    def test_malformed_pagination_is_reported_and_does_not_loop(self):
        iam = FakeIam()
        def broken(**kwargs):
            return {"Tags": [], "IsTruncated": True}
        iam.list_user_tags = broken
        result = self.run_expiry(iam)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["keys_disabled"], 2)

    def test_offset_deadline_is_compared_as_an_instant(self):
        # This is the exact deadline, not four extra hours of authorization.
        self.assertEqual(self.run_expiry(FakeIam("2026-11-30T16:00:00+04:00"))["keys_disabled"], 2)

    def test_handler_ignores_event_target_and_logs_only_counts_and_status(self):
        iam = FakeIam()
        iam.fail_update.add("fixture-current-one")
        boto3 = ModuleType("boto3")
        config = ModuleType("botocore.config")
        config.Config = lambda **kwargs: kwargs
        def client(service, **kwargs):
            self.assertEqual(service, "iam")
            return iam
        boto3.client = client
        output = StringIO()
        original = expiry.enforce_expiry
        with patch.dict(sys.modules, {"boto3": boto3, "botocore.config": config}), \
                patch.object(expiry, "enforce_expiry", lambda client: original(client, now=lambda: NOW)), \
                redirect_stdout(output):
            with self.assertRaisesRegex(RuntimeError, "^Authorization expiry enforcement incomplete$") as raised:
                expiry.handler({"UserName": "fixture-other-user", "deadline": "2099-01-01T00:00:00Z"}, None)
        result = json.loads(output.getvalue())
        self.assertTrue(raised.exception.__suppress_context__)
        self.assertIsNone(raised.exception.__cause__)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["keys_seen"], 2)
        for text in ["fixture-current-one", "fixture-other-user", "fixture-private-provider-detail", "osra-codex-mac"]:
            self.assertNotIn(text, output.getvalue())


if __name__ == "__main__":
    unittest.main()
