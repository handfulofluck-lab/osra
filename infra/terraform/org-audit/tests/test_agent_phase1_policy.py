"""Provider-free checks of the actual phase1 HCL; fictional requests, not AWS proof.

Mutants: restore administrator attachment, add a content action, omit a ceiling,
use an account-wildcard role target, or allow a missing/wrong SourceIdentity.
"""
import fnmatch
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MAC = "osra-codex-mac"
REGION = "eu-central-1"
ENTRY = "arn:aws:iam::fixture-production-account:role/fixture-reader"


def evaluate():
    terraform = shutil.which("terraform")
    if not terraform:
        raise RuntimeError("Terraform is required for provider-free phase1 tests")
    source = (ROOT / "mac_phase1_readonly.tf").read_text()
    local_block = source[source.index("locals {"):source.index('resource "aws_iam_policy"')]
    fixture = '''variable "mac_phase1_regions" { default = ["eu-central-1"] }
variable "mac_phase1_entry_role_names" { default = { entry = "fixture-reader" } }
variable "production_account_id" { default = "fixture-production-account" }
locals { account_id = "fixture-management-account" }
'''
    with tempfile.TemporaryDirectory(prefix=".osra-phase1-test-", dir=ROOT) as directory:
        Path(directory, "main.tf").write_text(fixture + local_block)
        result = subprocess.run(
            [terraform, "-chdir=" + directory, "console", "-no-color"],
            input='jsonencode({allow=jsondecode(local.mac_phase1_allow_document),ceiling=jsondecode(local.mac_phase1_ceiling_document),scp=jsondecode(local.mac_phase1_role_ceiling_document),actions=local.mac_phase1_metadata_actions})\n',
            env={"PATH": os.environ.get("PATH", os.defpath), "AWS_CONFIG_FILE": os.devnull,
                 "AWS_SHARED_CREDENTIALS_FILE": os.devnull, "AWS_EC2_METADATA_DISABLED": "true"},
            capture_output=True, text=True, check=False, timeout=20,
        )
    if result.returncode:
        raise AssertionError("Provider-free phase1 policy evaluation failed")
    for line in result.stdout.splitlines():
        try:
            value = json.loads(line)
            value = json.loads(value) if isinstance(value, str) else value
            if isinstance(value, dict) and {"allow", "ceiling", "scp", "actions"} <= value.keys():
                return value
        except ValueError:
            continue
    raise AssertionError("Expected phase1 policy value")


def values(value):
    return value if isinstance(value, list) else [value]


def matches(statement, action, resource, context):
    if "Action" in statement and not any(fnmatch.fnmatchcase(action.lower(), value.lower()) for value in values(statement["Action"])):
        return False
    if "NotAction" in statement and any(fnmatch.fnmatchcase(action.lower(), value.lower()) for value in values(statement["NotAction"])):
        return False
    if "Resource" in statement and not any(fnmatch.fnmatchcase(resource, value) for value in values(statement["Resource"])):
        return False
    if "NotResource" in statement and any(fnmatch.fnmatchcase(resource, value) for value in values(statement["NotResource"])):
        return False
    for operator, terms in statement.get("Condition", {}).items():
        for key, expected in terms.items():
            if operator == "StringEquals" and context.get(key) not in values(expected):
                return False
            if operator == "StringNotEquals" and context.get(key) in values(expected):
                return False
            if operator not in {"StringEquals", "StringNotEquals"}:
                raise AssertionError("Unexpected condition in bounded phase1 evaluator")
    return True


def effect(document, wanted, action, resource="*", **context):
    return any(statement["Effect"] == wanted and matches(statement, action, resource, context)
               for statement in document["Statement"])


class Phase1PolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.documents = evaluate()

    def test_literal_action_inventory_and_unchanged_policy_budgets(self):
        # A wildcard Get*/Describe* or an unnoticed newly added read must fail this inventory.
        expected = {
            "ecs": "ListClusters DescribeClusters ListServices DescribeServices",
            "ecr": "DescribeRepositories DescribeImages ListImages",
            "rds": "DescribeDBInstances DescribeDBSnapshots DescribeDBSnapshotAttributes",
            "elasticloadbalancing": "DescribeLoadBalancers DescribeTargetGroups DescribeTargetHealth DescribeListeners DescribeRules DescribeLoadBalancerAttributes",
            "ec2": "DescribeVpcs DescribeSubnets DescribeRouteTables DescribeSecurityGroups DescribeNetworkAcls DescribeNatGateways DescribeInternetGateways DescribeVpcEndpoints DescribeNetworkInterfaces",
            "cloudwatch": "ListMetrics GetMetricData GetMetricStatistics DescribeAlarms DescribeAlarmsForMetric DescribeAlarmHistory",
            "backup": "ListBackupJobs DescribeBackupJob ListRestoreJobs DescribeRestoreJob ListBackupVaults DescribeBackupVault ListRecoveryPointsByBackupVault DescribeRecoveryPoint",
            "config": "DescribeConfigRules DescribeComplianceByConfigRule DescribeComplianceByResource DescribeConfigurationRecorders DescribeConfigurationRecorderStatus DescribeDeliveryChannels DescribeDeliveryChannelStatus GetComplianceSummaryByConfigRule",
            "cloudtrail": "DescribeTrails GetTrailStatus",
        }
        self.assertEqual(set(self.documents["actions"]), {service + ":" + action for service, actions in expected.items() for action in actions.split()})
        self.assertFalse(any("*" in action for action in self.documents["actions"]))
        for document, limit in [("allow", 4500), ("ceiling", 4500), ("scp", 5120)]:
            self.assertLess(len(json.dumps(self.documents[document], separators=(",", ":"))), limit, document)
        for action in ["ecs:DescribeServices", "ecr:DescribeImages", "rds:DescribeDBInstances",
                       "cloudwatch:GetMetricData", "backup:ListBackupJobs", "config:DescribeConfigRules"]:
            self.assertIn(action, self.documents["actions"])

    def test_metadata_allowed_only_in_reviewed_regions_and_scoped_accounts(self):
        context = {"aws:RequestedRegion": REGION}
        for action, resource in [("ecs:DescribeServices", "arn:aws:ecs:" + REGION + ":fixture-production-account:service/fixture/service"),
                                 ("ecr:DescribeImages", "arn:aws:ecr:" + REGION + ":fixture-management-account:repository/fixture"),
                                 ("cloudwatch:GetMetricData", "*"), ("config:DescribeConfigRules", "*")]:
            with self.subTest(action=action):
                self.assertTrue(effect(self.documents["allow"], "Allow", action, resource, **context))
                self.assertFalse(effect(self.documents["ceiling"], "Deny", action, resource, **context))
                self.assertTrue(effect(self.documents["ceiling"], "Deny", action, resource, **{"aws:RequestedRegion": "fixture-other-region"}))
        other = "arn:aws:ecs:" + REGION + ":fixture-other-account:service/fixture/service"
        self.assertFalse(effect(self.documents["allow"], "Allow", "ecs:DescribeServices", other, **context))

    def test_content_and_writes_denied_even_if_another_policy_allows_them(self):
        cases = ["iam:CreateAccessKey", "iam:ListAccessKeys", "iam:UpdateAccessKey", "iam:DeleteAccessKey", "iam:PassRole",
                 "organizations:DetachPolicy", "secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue",
                 "ssm:GetParameter", "kms:Decrypt", "rds-data:ExecuteStatement", "rds-db:connect", "s3:GetObject",
                 "s3:GetObjectVersion", "logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults",
                 "logs:Unmask", "dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan",
                 "dynamodb:ExecuteStatement", "ecs:ExecuteCommand", "ecs:DescribeTasks", "ecs:DescribeTaskDefinition",
                 "ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "cloudtrail:LookupEvents",
                 "config:GetResourceConfigHistory", "config:SelectResourceConfig", "config:DeliverConfigSnapshot", "ec2:RunInstances"]
        for action in cases:
            for name, context in [("ceiling", {"aws:RequestedRegion": REGION}),
                                  ("scp", {"aws:RequestedRegion": REGION, "aws:SourceIdentity": MAC})]:
                with self.subTest(action=action, document=name):
                    self.assertTrue(effect(self.documents[name], "Deny", action, **context))
                    self.assertFalse(effect(self.documents["allow"], "Allow", action, **context))

    def test_entry_requires_exact_mapped_role_and_identity(self):
        for target in [ENTRY, "arn:aws:iam::fixture-production-account:role/another", "arn:aws:iam::another-account:role/fixture-reader"]:
            for identity in [MAC, "osra-staging-deployer", None]:
                context = {"sts:SourceIdentity": identity}
                for action in ["sts:AssumeRole", "sts:SetSourceIdentity"]:
                    with self.subTest(target=target, identity=identity, action=action):
                        accepted = target == ENTRY and identity == MAC
                        self.assertEqual(effect(self.documents["allow"], "Allow", action, target, **context), accepted)
                        self.assertEqual(effect(self.documents["ceiling"], "Deny", action, target, **context), not accepted)

    def test_new_role_ceiling_is_mac_attributed_only_not_claimed_for_missing_identity(self):
        for identity in [MAC, "osra-staging-deployer", "fixture-other", None]:
            context = {"aws:SourceIdentity": identity, "aws:RequestedRegion": REGION}
            self.assertEqual(effect(self.documents["scp"], "Deny", "s3:GetObject", **context), identity == MAC)
        self.assertEqual(len(self.documents["scp"]["Statement"]), 5)
        self.assertTrue(all(s["Condition"]["StringEquals"] == {"aws:SourceIdentity": MAC}
                            for s in self.documents["scp"]["Statement"]))

    def test_active_attachment_and_ceilings_protect_both_control_surfaces(self):
        source = (ROOT / "mac_phase1_readonly.tf").read_text()
        mac = (ROOT / "mac_agent.tf").read_text()
        self.assertNotIn("AdministratorAccess", source + mac)
        self.assertNotIn("ReadOnlyAccess", source + mac)
        self.assertIn("target_id = var.production_account_id", source)
        for prerequisite in ["agent_keep_watchers", "agent_keep_backups", "agent_no_escalation", "mac_phase1_ceiling",
                             "mac_authorization_deadline", "agent_cannot_erase_evidence_production", "mac_phase1_ceiling_production"]:
            self.assertIn(prerequisite, source[source.index('resource "aws_iam_user_policy_attachment" "mac_phase1_readonly"'):])
        protected = (ROOT / "access.tf").read_text()
        self.assertIn("policy/osra-mac-phase1-metadata", protected)
        self.assertIn("policy/osra-mac-phase1-ceiling", protected)
        self.assertIn("aws_organizations_policy.mac_phase1_ceiling.arn", protected)


if __name__ == "__main__":
    unittest.main()
