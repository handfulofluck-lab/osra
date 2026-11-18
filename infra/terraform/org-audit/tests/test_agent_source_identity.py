"""Construct the real Bash invocation with a fake shell AWS function; no CLI or cloud call."""
from pathlib import Path
import subprocess
import unittest

LIBRARY = Path(__file__).resolve().parents[2] / "lib/agent-source-identity.sh"


class SourceIdentityTests(unittest.TestCase):
    def invoke(self, source=None):
        env = {"PATH": "/usr/bin:/bin"}
        if source is not None:
            env["OSRA_AGENT_SOURCE_IDENTITY"] = source
        return subprocess.run(
            ["/bin/bash", "-c", 'source "$1"; aws() { printf "%s\\0" "$@"; }; agent_assume_production_role fixture-role fixture-session', "fixture", str(LIBRARY)],
            env=env, capture_output=True, check=False,
        )

    def test_mac_and_pc_values_reach_the_actual_assume_role_argument(self):
        # Mutant: omitting the source argument or silently defaulting all calls to one user fails here.
        for user in ["osra-codex-mac", "osra-staging-deployer"]:
            with self.subTest(user=user):
                result = self.invoke(user)
                self.assertEqual(result.returncode, 0)
                args = result.stdout.decode().rstrip("\0").split("\0")
                self.assertEqual(args[:2], ["sts", "assume-role"])
                self.assertEqual(args[args.index("--source-identity") + 1], user)
                self.assertEqual(args[args.index("--role-arn") + 1], "fixture-role")

    def test_missing_value_preserves_identity_center_path_without_fake_attribution(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(b"--source-identity", result.stdout)

    def test_invalid_input_fails_before_even_the_fake_cli_is_called(self):
        for source in ["aws:reserved", "bad value", "x", "line\nbreak"]:
            with self.subTest(source=source):
                result = self.invoke(source)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")

    def test_up_calls_this_tested_helper(self):
        source = (LIBRARY.parents[1] / "up.sh").read_text()
        self.assertIn('creds=$(agent_assume_production_role "$role" osra-production-migrate)', source)
        self.assertIn('. "$HERE/lib/agent-source-identity.sh"', source)


if __name__ == "__main__":
    unittest.main()
