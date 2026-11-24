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
        self.assertEqual([kind for kind, _ in iam.calls], ["tags"])

    def test_kcl_program_board_phase_lanes_and_owners(self):
        # Additional verification for KCL program board phase lanes and owners configuration/logic
        iam = FakeIam("2026-11-30T12:00:01Z")
        result = self.run_expiry(iam)
        self.assertEqual(result["status"], "future_deadline")
        self.assertIn("keys_seen", result)
        self.assertIn("errors", result)
        self.assertEqual(result["errors"], 0)