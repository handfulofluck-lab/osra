"""Evaluate the expiry draft's real HCL locals without providers or cloud access."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AccessExpiryPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        terraform = shutil.which("terraform")
        if not terraform:
            raise RuntimeError("Terraform is required for provider-free policy checks")
        cls.source = (ROOT / "mac_access_expiry.tf").read_text()
        locals_block = cls.source[cls.source.index("locals {"):cls.source.index("# Dedicated narrow boundary")]
        fixture = '''variable "region" { default = "eu-central-1" }
locals {
 account_id = "fixture-account"
 agent_user_arns = { osra-codex-mac = "arn:aws:iam::fixture-account:user/osra-codex-mac" }
}
'''
        with tempfile.TemporaryDirectory(prefix=".osra-expiry-test-", dir=ROOT) as directory:
            Path(directory, "main.tf").write_text(fixture + locals_block)
            result = subprocess.run(
                [terraform, "-chdir=" + directory, "console", "-no-color"],
                input='jsonencode({execution=local.mac_expiry_execution_statements,protected=local.mac_expiry_resource_arns,function=local.mac_expiry_function_arn})\n',
                env={"PATH": os.environ.get("PATH", os.defpath), "AWS_CONFIG_FILE": os.devnull,
                     "AWS_SHARED_CREDENTIALS_FILE": os.devnull, "AWS_EC2_METADATA_DISABLED": "true"},
                capture_output=True, text=True, check=False, timeout=20,
            )
        if result.returncode:
            raise AssertionError("Provider-free expiry HCL evaluation failed")
        values = []
        for line in result.stdout.splitlines():
            try:
                value = json.loads(line)
                value = json.loads(value) if isinstance(value, str) else value
                if isinstance(value, dict) and {"execution", "protected", "function"} <= value.keys():
                    values.append(value)
            except ValueError:
                pass
        if len(values) != 1:
            raise AssertionError("Expected one expiry HCL value")
        cls.document = values[0]

    def test_execution_and_boundary_allow_only_mac_metadata_status_and_own_logs(self):
        # Mutant: adding TagUser, an AssumeRole/secret/delete action, or widening the target fails.
        statements = self.document["execution"]
        self.assertEqual(len(statements), 2)
        key_policy = next(s for s in statements if s["Sid"] == "OnlyMacKeyStatusAndMetadata")
        self.assertEqual(key_policy["Effect"], "Allow")
        self.assertEqual(set(key_policy["Action"]), {"iam:ListUserTags", "iam:ListAccessKeys", "iam:UpdateAccessKey"})
        self.assertEqual(key_policy["Resource"], "arn:aws:iam::fixture-account:user/osra-codex-mac")
        logs = next(s for s in statements if s["Sid"] == "OnlyItsStatusLog")
        self.assertEqual(set(logs["Action"]), {"logs:CreateLogStream", "logs:PutLogEvents"})
        self.assertEqual(logs["Resource"], "arn:aws:logs:eu-central-1:fixture-account:log-group:/aws/lambda/osra-mac-expiry:*")
        self.assertEqual(self.source.count("Statement = local.mac_expiry_execution_statements"), 2)
        self.assertRegex(self.source, r"permissions_boundary\s*= aws_iam_policy.mac_expiry_boundary.arn")

    def test_control_arns_are_account_bound_and_cover_every_job_surface(self):
        self.assertEqual(self.document["function"], "arn:aws:lambda:eu-central-1:fixture-account:function:osra-mac-expiry")
        self.assertEqual(set(self.document["protected"]), {
            "arn:aws:lambda:eu-central-1:fixture-account:function:osra-mac-expiry*",
            "arn:aws:iam::fixture-account:role/osra-mac-expiry",
            "arn:aws:iam::fixture-account:policy/osra-mac-expiry",
            "arn:aws:logs:eu-central-1:fixture-account:log-group:/aws/lambda/osra-mac-expiry*",
            "arn:aws:events:eu-central-1:fixture-account:rule/osra-mac-expiry",
        })
        for filename in ["access.tf", "role_boundary.tf"]:
            source = (ROOT / filename).read_text()
            self.assertRegex(source, r'Sid\s*= "ExpiryStays"\s+Effect\s*= "Deny"\s+Action\s*= "\*"\s+Resource\s*= local.mac_expiry_resource_arns')

    def test_invocation_is_only_named_rule_same_account_and_schedule_remains_enabled(self):
        permission = re.search(r'resource "aws_lambda_permission" "mac_expiry" \{(.*?)\n\}', self.source, re.S).group(1)
        self.assertRegex(permission, r'principal\s*= "events.amazonaws.com"')
        self.assertRegex(permission, r'source_arn\s*= aws_cloudwatch_event_rule.mac_expiry.arn')
        self.assertRegex(permission, r'source_account\s*= local.account_id')
        self.assertIn('schedule_expression = "rate(1 minute)"', self.source)
        self.assertRegex(self.source, r'state\s*= "ENABLED"')
        self.assertIn('maximum_event_age_in_seconds = 60', self.source)
        self.assertIn('treat_missing_data  = each.key == "missing" ? "breaching" : "notBreaching"', self.source)
        access = (ROOT / "access.tf").read_text()
        self.assertIn("[aws_cloudwatch_metric_alarm.mac_expiry_failure.arn]", access)
        self.assertIn("[for alarm in aws_cloudwatch_metric_alarm.mac_expiry_health : alarm.arn]", access)


if __name__ == "__main__":
    unittest.main()
