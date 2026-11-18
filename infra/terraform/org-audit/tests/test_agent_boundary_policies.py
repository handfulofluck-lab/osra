"""Source-derived HCL policy checks; Terraform evaluates locals only, with no provider or AWS session.

The small evaluator below covers only the explicit key guards under test. It is not an IAM simulator;
the private deployment gate still requires AWS simulator and live-session evidence.
"""
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
USERS = ["osra-staging-deployer", "osra-codex-mac"]


def policy_expression(filename, name):
    text = (ROOT / filename).read_text()
    found = re.search(r'resource "aws_iam_policy" "' + name + r'" \{.*?\n  policy = (jsonencode\(\{.*?\n  \}\))\n\}', text, re.S)
    if not found:
        raise AssertionError("Expected policy expression was not found")
    return re.sub(r'aws_\w+\.\w+\.arn', lambda match: json.dumps("arn:aws:fixture::fixture-account:" + match.group()), found.group(1))


def key_denied(document, action, resource, username, principal_type):
    context = {"aws:username": username, "aws:PrincipalType": principal_type}
    for statement in document["Statement"]:
        if statement["Effect"] != "Deny":
            continue
        actions = statement["Action"] if isinstance(statement["Action"], list) else [statement["Action"]]
        if not any(fnmatch.fnmatchcase(action.lower(), item.lower()) for item in actions):
            continue
        if "NotResource" in statement:
            # The separate Null and non-User denies must carry absent username context explicitly.
            if username is None:
                continue
            exempt = statement["NotResource"].replace("${aws:username}", username)
            if fnmatch.fnmatchcase(resource, exempt):
                continue
        else:
            resources = statement["Resource"] if isinstance(statement["Resource"], list) else [statement["Resource"]]
            if not any(fnmatch.fnmatchcase(resource, item) for item in resources):
                continue
        matches = True
        for operator, conditions in statement.get("Condition", {}).items():
            for key, value in conditions.items():
                if operator == "StringNotEquals":
                    matches = matches and context.get(key) != value
                elif operator == "Null":
                    matches = matches and (context.get(key) is None) == (value == "true")
                else:
                    raise AssertionError("Unexpected condition on a tested key deny")
        if matches:
            return True
    return False


class BoundaryPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        terraform = shutil.which("terraform")
        if not terraform:
            raise RuntimeError("Terraform is required for the source-derived local policy tests")
        arns = {user: "arn:aws:iam::fixture-account:user/" + user for user in USERS}
        fixture = {
            "account_id": "fixture-account",
            "agent_user_arns": arns,
            "agent_own_key_arn": "arn:aws:iam::fixture-account:user/$${aws:username}",
            "management_roles": "arn:aws:iam::fixture-account:role/*",
            "boundary_arn": "arn:aws:iam::fixture-account:policy/osra-management-role-boundary",
            "agent_deny_policy_arns": ["arn:aws:iam::fixture-account:policy/fixture"],
            "mac_expiry_resource_arns": [
                "arn:aws:lambda:eu-central-1:fixture-account:function:osra-mac-expiry*",
                "arn:aws:iam::fixture-account:role/osra-mac-expiry",
                "arn:aws:iam::fixture-account:policy/osra-mac-expiry",
                "arn:aws:logs:eu-central-1:fixture-account:log-group:/aws/lambda/osra-mac-expiry*",
                "arn:aws:events:eu-central-1:fixture-account:rule/osra-mac-expiry",
            ],
        }
        declarations = "\n".join(key + " = " + json.dumps(value) for key, value in fixture.items())
        mac = (ROOT / "mac_agent.tf").read_text()
        trust = re.search(r'production_entry_agent_trust_statements = (\[.*?\n  \])\n\}', mac, re.S).group(1)
        text = "locals {\n" + declarations + "\nboundary = " + policy_expression("role_boundary.tf", "role_boundary")
        text += "\ndirect = " + policy_expression("access.tf", "agent_no_escalation") + "\ntrust = " + trust + "\n}\n"
        access = (ROOT / "access.tf").read_text()
        clauses = re.search(r'agent_principal_clauses = (\{.*?\n  \})', access, re.S).group(1)
        principals = re.search(r'agent_new_principals = (\{.*?\n  \})', access, re.S).group(1)
        text += "locals {\nagent_principal_clauses = " + clauses + "\nagent_new_principals = " + principals + "\n}\n"
        with tempfile.TemporaryDirectory(prefix=".osra-policy-test-", dir=ROOT) as directory:
            Path(directory, "main.tf").write_text(text)
            result = subprocess.run(
                [terraform, "-chdir=" + directory, "console", "-no-color"],
                input='jsonencode({boundary=jsondecode(local.boundary),direct=jsondecode(local.direct),trust=local.trust,principal_patterns=local.agent_new_principals})\n',
                env={"PATH": os.environ.get("PATH", os.defpath), "AWS_CONFIG_FILE": os.devnull, "AWS_SHARED_CREDENTIALS_FILE": os.devnull, "AWS_EC2_METADATA_DISABLED": "true"},
                capture_output=True, text=True, check=False, timeout=20,
            )
        if result.returncode:
            raise AssertionError("Local Terraform policy evaluation failed: " + result.stderr)
        # setup-terraform's CI wrapper can append output annotations. Only the console's single
        # JSON-string value is data; annotations are not treated as additional policy output.
        values = []
        for line in result.stdout.splitlines():
            try:
                value = json.loads(line)
                if isinstance(value, str):
                    value = json.loads(value)
                if isinstance(value, dict) and {"boundary", "direct", "trust", "principal_patterns"} <= value.keys():
                    values.append(value)
            except ValueError:
                pass
        if len(values) != 1:
            raise AssertionError("Expected one local Terraform policy value")
        cls.documents = values[0]
        cls.arns = arns

    def test_baseline_creation_deny_and_stricter_key_guards(self):
        # Mutant: exempting the two-user list, or using an account wildcard, fails this cross-user matrix.
        for user in USERS:
            for target in [*USERS, "fixture-other-user"]:
                for action in ["iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:UpdateAccessKey", "iam:ListAccessKeys"]:
                    for policy in ["boundary", "direct"]:
                        with self.subTest(user=user, target=target, action=action, policy=policy):
                            resource = "arn:aws:iam::fixture-account:user/" + target
                            self.assertEqual(key_denied(self.documents[policy], action, resource, user, "User"), target != user or (policy == "boundary" and (user == "osra-codex-mac" or action == "iam:CreateAccessKey")))
                    self.assertTrue(key_denied(self.documents["boundary"], action, "arn:aws:iam::another-fixture-account:user/" + user, user, "User"))

    def test_roles_and_absent_username_never_get_the_self_exception(self):
        for principal_type, username in [("Role", None), ("AssumedRole", None), ("FederatedUser", None), (None, None), ("User", None), ("Role", USERS[0])]:
            for action in ["iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:UpdateAccessKey", "iam:ListAccessKeys"]:
                with self.subTest(principal_type=principal_type, action=action):
                    self.assertTrue(key_denied(self.documents["boundary"], action, self.arns[USERS[0]], username, principal_type))

    def test_either_agent_cannot_change_either_users_policy_or_boundary(self):
        # Mutant: retaining only the old PC user ARN as Resource leaves the Mac surface unprotected.
        for caller in USERS:
            for target in USERS:
                for action in ["iam:PutUserPolicy", "iam:DeleteUserPolicy", "iam:AttachUserPolicy", "iam:DetachUserPolicy", "iam:PutUserPermissionsBoundary", "iam:DeleteUserPermissionsBoundary"]:
                    with self.subTest(caller=caller, target=target, action=action):
                        self.assertTrue(key_denied(self.documents["direct"], action, self.arns[target], caller, "User"))
        deadline = next(item for item in self.documents["direct"]["Statement"] if item["Sid"] == "AccessDeadlineStays")
        self.assertEqual(deadline["Effect"], "Deny")
        self.assertEqual(set(deadline["Resource"]), set(self.arns.values()))
        self.assertEqual(set(deadline["Action"]), {"iam:TagUser", "iam:UntagUser"})
        self.assertEqual(deadline["Condition"], {"ForAnyValue:StringEqualsIgnoreCase": {"aws:TagKeys": ["osra:access-expires-at"]}})

    def test_deadline_tag_protection_matches_iam_user_key_case_semantics(self):
        deadline = next(item for item in self.documents["direct"]["Statement"] if item["Sid"] == "AccessDeadlineStays")
        operator, terms = next(iter(deadline["Condition"].items()))
        wanted = terms["aws:TagKeys"]
        for keys in [["osra:access-expires-at"], ["OSRA:ACCESS-EXPIRES-AT"], ["other", "Osra:Access-Expires-At"]]:
            with self.subTest(keys=keys):
                if operator == "ForAnyValue:StringEquals":
                    matched = any(key in wanted for key in keys)
                elif operator == "ForAnyValue:StringEqualsIgnoreCase":
                    matched = any(key.casefold() in {value.casefold() for value in wanted} for key in keys)
                else:
                    self.fail("Unexpected deadline tag condition")
                self.assertTrue(matched)

    def test_entire_original_watcher_deny_statement_is_unchanged(self):
        after = next(item["Action"] for item in self.documents["boundary"]["Statement"] if item["Sid"] == "NotTheWatchers")
        # Pin the complete baseline list, including the unconditional CreateAccessKey deny.
        digest = hashlib.sha256(json.dumps(after, separators=(",", ":")).encode()).hexdigest()
        self.assertEqual(digest, "57377cf73ce8fb817c725f3cd58a4a5b6d9a3f84b301d65dfcc0f43a8582db31")

    def test_expected_missing_and_cross_user_source_identity_cases(self):
        deny, allow = self.documents["trust"]
        self.assertEqual(deny["Effect"], "Deny")
        self.assertEqual(allow["Effect"], "Allow")
        for user in USERS:
            for source in [None, user, next(item for item in USERS if item != user)]:
                with self.subTest(user=user, source=source):
                    expected = deny["Condition"]["StringNotEquals"]["sts:SourceIdentity"].replace("${aws:username}", user)
                    self.assertEqual(source != expected, source != user)
                    expected = allow["Condition"]["StringEquals"]["sts:SourceIdentity"].replace("${aws:username}", user)
                    self.assertEqual(source == expected, source == user)
        self.assertEqual(set(deny["Principal"]["AWS"]), {self.arns["osra-codex-mac"]})
        self.assertEqual(allow["Principal"], deny["Principal"])
        self.assertNotIn(self.arns["osra-staging-deployer"], deny["Principal"]["AWS"])
        self.assertEqual(set(allow["Action"]), {"sts:AssumeRole", "sts:SetSourceIdentity"})

    def test_principal_patterns_and_policies_stay_under_service_limits(self):
        for pattern in self.documents["principal_patterns"].values():
            self.assertLessEqual(len("{ " + pattern + " }"), 1024)
        for name in ["boundary", "direct"]:
            self.assertLess(len(json.dumps(self.documents[name], separators=(",", ":"))), 4500)


if __name__ == "__main__":
    unittest.main()
