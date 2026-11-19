"""Provider-free, source-derived partial deadline checks; not an AWS IAM simulator."""

from datetime import datetime, timedelta, timezone
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEADLINE = "2026-12-01T12:00:00Z"
MAC = "osra-codex-mac"


def _content(source, kind, name, field):
    match = re.search(r'resource "' + kind + '" "' + name + r'" \{.*?\n  ' + field + r'\s*= (jsonencode\(\{.*?\n  \}\))\n\}', source, re.S)
    if match is None:
        raise AssertionError("Expected policy expression was not found")
    return match.group(1)


def evaluate(deadline=DEADLINE):
    terraform = shutil.which("terraform")
    if not terraform:
        raise RuntimeError("Terraform is required for provider-free deadline tests")
    guardrails = (ROOT / "agent_guardrails.tf").read_text()
    scp = _content(guardrails, "aws_organizations_policy", "agent_cannot_erase_evidence", "content")
    existing_locals = guardrails[guardrails.index("locals {"):guardrails.index('resource "aws_organizations_policy"')]
    deadline_path = ROOT / "mac_authorization_deadline.tf"
    # The fail-first baseline has neither an inline user guard nor the new SCP
    # statement. Represent the absent user policy as no denies, then exercise
    # both real old/new policy documents with identical fictional requests.
    if deadline_path.exists():
        source = deadline_path.read_text()
        deadline_locals = source[source.index("locals {"):source.index('resource "aws_iam_user_policy"')]
        user = _content(source, "aws_iam_user_policy", "mac_authorization_deadline", "policy")
    else:
        deadline_locals = ""
        user = 'jsonencode({Version="2012-10-17",Statement=[]})'
    fixture = 'variable "production_account_id" { default = "fixture-production-account" }\n'
    fixture += 'variable "mac_access_expires_at" { default = ' + json.dumps(deadline) + ' }\n'
    module = fixture + existing_locals + deadline_locals + '\nlocals {\nuser=' + user + '\nscp=' + scp + '\n}\n'
    with tempfile.TemporaryDirectory(prefix=".osra-deadline-test-", dir=ROOT) as directory:
        Path(directory, "main.tf").write_text(module)
        result = subprocess.run(
            [terraform, "-chdir=" + directory, "console", "-no-color"],
            input='jsonencode({user=jsondecode(local.user),scp=jsondecode(local.scp)})\n',
            env={"PATH": os.environ.get("PATH", os.defpath), "AWS_CONFIG_FILE": os.devnull,
                 "AWS_SHARED_CREDENTIALS_FILE": os.devnull, "AWS_EC2_METADATA_DISABLED": "true"},
            capture_output=True, text=True, check=False, timeout=20,
        )
    if result.returncode:
        raise AssertionError("Provider-free deadline policy evaluation failed")
    values = []
    for line in result.stdout.splitlines():
        try:
            value = json.loads(line)
            value = json.loads(value) if isinstance(value, str) else value
            if isinstance(value, dict) and {"user", "scp"} <= value.keys():
                values.append(value)
        except ValueError:
            pass
    if len(values) != 1:
        raise AssertionError("Expected one deadline policy value")
    return values[0]


def _values(value):
    return value if isinstance(value, list) else [value]


def denied(document, instant, source_identity=None, action="ec2:DescribeInstances", principal=None, principal_tags=None):
    context = {"aws:SourceIdentity": source_identity,
               "aws:PrincipalArn": principal or "arn:aws:iam::fixture-production-account:role/fictional-role"}
    # Deliberately irrelevant to literal date conditions: changing a tag alone
    # cannot renew a permission that has an already installed fixed deadline.
    context.update(principal_tags or {})
    for statement in document["Statement"]:
        if statement["Effect"] != "Deny" or not any(fnmatch.fnmatchcase(action, item) for item in _values(statement["Action"])):
            continue
        if statement.get("Resource") != "*":
            raise AssertionError("This bounded evaluator expects account-wide actions under test")
        matches = True
        for operator, terms in statement.get("Condition", {}).items():
            for key, expected in terms.items():
                if operator == "DateGreaterThanEquals" and key == "aws:CurrentTime":
                    matches &= instant >= datetime.fromisoformat(expected.replace("Z", "+00:00"))
                elif operator == "DateGreaterThan" and key == "aws:CurrentTime":
                    matches &= instant > datetime.fromisoformat(expected.replace("Z", "+00:00"))
                elif operator == "StringEquals":
                    matches &= context.get(key) in _values(expected)
                elif operator == "ArnNotLike":
                    matches &= not any(fnmatch.fnmatchcase(context.get(key, ""), pattern) for pattern in _values(expected))
                else:
                    raise AssertionError("Unexpected condition in the bounded deadline evaluator")
        if matches:
            return True
    return False


class AuthorizationDeadlineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.documents = evaluate()
        cls.at = datetime(2026, 12, 1, 12, tzinfo=timezone.utc)

    def test_user_is_denied_at_equality_and_after_but_not_before(self):
        # Mutants: remove the direct guard or change the equality cutoff.
        for offset, expected in [(-1, False), (0, True), (1, True)]:
            with self.subTest(offset=offset):
                self.assertEqual(denied(self.documents["user"], self.at + timedelta(microseconds=offset)), expected)

    def test_scp_targets_mac_source_identity_only_at_equality_and_after(self):
        # Missing identity is intentionally NOT covered: reviewed trust and
        # caller integration remain prerequisites, not evidence from this row.
        for identity in [MAC, "osra-staging-deployer", "fictional-other", None]:
            for offset in [-1, 0, 1]:
                with self.subTest(identity=identity, offset=offset):
                    self.assertEqual(denied(self.documents["scp"], self.at + timedelta(microseconds=offset), identity), identity == MAC and offset >= 0)

    def test_tag_only_change_cannot_renew_already_installed_guards(self):
        future_tag = {"aws:PrincipalTag/osra:access-expires-at": "2026-12-02T12:00:00Z"}
        for policy in ["user", "scp"]:
            self.assertTrue(denied(self.documents[policy], self.at, MAC, principal_tags=future_tag))
        renewed = evaluate("2026-12-02T12:00:00Z")
        self.assertFalse(denied(renewed["user"], self.at))
        self.assertFalse(denied(renewed["scp"], self.at, MAC))

    def test_existing_scp_denies_and_conditions_are_unchanged(self):
        previous = [statement for statement in self.documents["scp"]["Statement"] if statement["Sid"] != "MacAuthorizationExpired"]
        digest = hashlib.sha256(json.dumps(previous, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.assertEqual(digest, "cda9ff5a8f9bae4cc4c21275799bae19c4a36f44b35583e76191e496a2a47c6d")
        for action in ["cloudtrail:StopLogging", "rds:DeleteDBSnapshot"]:
            for identity in [MAC, "osra-staging-deployer", None]:
                for offset in [-1, 0, 1]:
                    self.assertTrue(denied(self.documents["scp"], self.at + timedelta(seconds=offset), identity, action=action))
        owner = "arn:aws:iam::fixture-production-account:role/aws-reserved/sso.amazonaws.com/fixture-region/fixture-owner"
        self.assertFalse(denied(self.documents["scp"], self.at, principal=owner, action="cloudtrail:StopLogging"))

    def test_guard_is_literal_deny_only_and_existing_size_limits_stay(self):
        user = self.documents["user"]
        self.assertEqual(len(user["Statement"]), 1)
        for document in [user, self.documents["scp"]]:
            statement = next(s for s in document["Statement"] if s["Sid"] == "MacAuthorizationExpired")
            self.assertEqual((statement["Effect"], statement["Action"], statement["Resource"]), ("Deny", "*", "*"))
            self.assertEqual(statement["Condition"]["DateGreaterThanEquals"], {"aws:CurrentTime": DEADLINE})
            self.assertNotIn("${", json.dumps(statement["Condition"]["DateGreaterThanEquals"]))
        self.assertLess(len(json.dumps(user, separators=(",", ":"))), 2048)
        self.assertLess(len(json.dumps(self.documents["scp"], separators=(",", ":"))), 5120)

    def test_only_existing_mac_user_and_production_attachment_are_bound(self):
        source = (ROOT / "mac_authorization_deadline.tf").read_text()
        self.assertRegex(source, r'user\s*= aws_iam_user.codex_mac.name')
        guardrails = (ROOT / "agent_guardrails.tf").read_text()
        attachment = re.search(r'resource "aws_organizations_policy_attachment" "agent_cannot_erase_evidence_production" \{(.*?)\n\}', guardrails, re.S).group(1)
        self.assertRegex(attachment, r'policy_id\s*= aws_organizations_policy.agent_cannot_erase_evidence.id')
        self.assertRegex(attachment, r'target_id\s*= var.production_account_id')
        mac = (ROOT / "mac_agent.tf").read_text()
        self.assertIn('"osra:access-expires-at" = var.mac_access_expires_at', mac)
        attachments = (ROOT / 'mac_phase1_readonly.tf').read_text()
        self.assertIn('aws_iam_user_policy.mac_authorization_deadline', attachments)
        self.assertIn('aws_organizations_policy_attachment.agent_cannot_erase_evidence_production', attachments)


if __name__ == "__main__":
    unittest.main()
