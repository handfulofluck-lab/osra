"""All boundaries are in-memory fakes: no AWS, Keychain, credential files or network."""
import base64
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("agent_credential_mac", Path(__file__).resolve().parents[3] / "scripts/agent_credential_mac.py")
helper = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = helper
spec.loader.exec_module(helper)

OLD = helper.Credential("fixture-id-old", "fixture-value-old")
NEW = helper.Credential("fixture-id-new", "fixture-value-new")


class MemoryStore:
    def __init__(self, events, fail_write=False, fail_restore=False, ignore_write=False):
        self.value = OLD
        self.events = events
        self.fail_write = fail_write
        self.fail_restore = fail_restore
        self.ignore_write = ignore_write

    def read(self):
        self.events.append("read-old" if self.value == OLD else "read-new")
        return self.value

    def write(self, credential):
        self.events.append("restore-old" if credential == OLD else "save-new")
        if credential == OLD and self.fail_restore:
            raise helper.CredentialError("fixture failure")
        if not self.ignore_write:
            self.value = credential
        if credential == NEW and self.fail_write:
            raise helper.CredentialError("fixture failure")


class MemoryCloud:
    def __init__(self, events, fail_proof=False, fail_delete=False, fail_cleanup=False, wrong_identity=False):
        self.events = events
        self.fail_proof = fail_proof
        self.fail_delete = fail_delete
        self.fail_cleanup = fail_cleanup
        self.wrong_identity = wrong_identity

    def client(self, credential):
        cloud = self
        class Client:
            def identity(self):
                cloud.events.append("verify-new" if credential == NEW else "identify-old")
                if credential == NEW and cloud.fail_proof:
                    raise helper.CredentialError("fixture failure")
                return "another-fixture-principal" if credential == NEW and cloud.wrong_identity else "fixture-principal"

            def existing_key(self):
                cloud.events.append("check-single-old")

            def create(self):
                cloud.events.append("create-new")
                return {"AccessKeyId": NEW.key_id, "SecretAccessKey": NEW.secret}

            def delete(self, key_id):
                cloud.events.append("delete-old" if key_id == OLD.key_id else "delete-new")
                if key_id == OLD.key_id and cloud.fail_delete or key_id == NEW.key_id and cloud.fail_cleanup:
                    raise helper.CredentialError("fixture failure")
        return Client()


class RotationTests(unittest.TestCase):
    def test_save_readback_and_exact_identity_proof_precede_old_deletion(self):
        # Mutant: moving delete-old before verify-new makes this order assertion fail.
        events = []
        store = MemoryStore(events)
        helper.rotate(store, MemoryCloud(events).client, sleep=lambda _: None)
        self.assertEqual(events, ["read-old", "identify-old", "check-single-old", "create-new", "save-new", "read-new", "verify-new", "delete-old"])
        self.assertEqual(store.value, NEW)

    def test_failed_write_restores_old_before_revoking_replacement(self):
        events = []
        store = MemoryStore(events, fail_write=True)
        with self.assertRaises(helper.CredentialError):
            helper.rotate(store, MemoryCloud(events).client, sleep=lambda _: None)
        self.assertEqual(events[-2:], ["restore-old", "delete-new"])
        self.assertNotIn("delete-old", events)
        self.assertEqual(store.value, OLD)

    def test_silent_store_failure_cannot_prove_old_and_delete_it(self):
        # Mutant: proving the configured profile without checking new read-back survives only if broken.
        events = []
        store = MemoryStore(events, ignore_write=True)
        with self.assertRaises(helper.CredentialError):
            helper.rotate(store, MemoryCloud(events).client, sleep=lambda _: None)
        self.assertNotIn("verify-new", events)
        self.assertNotIn("delete-old", events)

    def test_failed_or_wrong_identity_proof_never_deletes_old(self):
        for kwargs in [{"fail_proof": True}, {"wrong_identity": True}]:
            with self.subTest(kwargs=kwargs):
                events = []
                store = MemoryStore(events)
                with self.assertRaises(helper.CredentialError):
                    helper.rotate(store, MemoryCloud(events, **kwargs).client, sleep=lambda _: None)
                self.assertEqual(events.count("verify-new"), 6)
                self.assertEqual(events[-2:], ["restore-old", "delete-new"])
                self.assertNotIn("delete-old", events)

    def test_failed_restore_keeps_both_keys_for_recovery(self):
        events = []
        with self.assertRaisesRegex(helper.CredentialError, "both keys are retained"):
            helper.rotate(MemoryStore(events, fail_restore=True), MemoryCloud(events, fail_proof=True).client, sleep=lambda _: None)
        self.assertNotIn("delete-old", events)
        self.assertNotIn("delete-new", events)

    def test_post_proof_delete_failure_keeps_verified_new_store(self):
        events = []
        store = MemoryStore(events)
        with self.assertRaisesRegex(helper.CredentialError, "old-key deletion needs review"):
            helper.rotate(store, MemoryCloud(events, fail_delete=True).client, sleep=lambda _: None)
        self.assertEqual(store.value, NEW)
        self.assertNotIn("restore-old", events)
        self.assertNotIn("delete-new", events)

    def test_failed_replacement_cleanup_reports_restored_old_without_key_values(self):
        events = []
        store = MemoryStore(events)
        with self.assertRaisesRegex(helper.CredentialError, "cleanup needs review") as caught:
            helper.rotate(store, MemoryCloud(events, fail_proof=True, fail_cleanup=True).client, sleep=lambda _: None)
        self.assertEqual(store.value, OLD)
        self.assertNotIn(NEW.key_id, str(caught.exception))
        self.assertNotIn(NEW.secret, str(caught.exception))


class BoundaryTests(unittest.TestCase):
    def test_phase1_rotation_fails_before_keychain_or_aws_construction(self):
        # Mutant: construct either boundary before rejecting the superseded mode.
        with patch.object(helper, "LoginKeychain") as store, patch.object(helper, "AwsClient") as client, patch("sys.stderr", new_callable=io.StringIO) as output:
            self.assertEqual(helper.main(["rotate"]), 1)
            store.assert_not_called()
            client.assert_not_called()
            self.assertIn("disabled", output.getvalue())

    def test_shell_mac_mode_cannot_invoke_any_subprocess(self):
        # Mutant: the previous Python rotation invocation would match this source guard.
        script = (Path(__file__).resolve().parents[1].parent / "rotate-agent-key.sh").read_text()
        mode = script[script.index('if [ "${1:-}" = "--mac" ]; then'):script.index("fi\n")]
        self.assertIn("exit 1", mode)
        self.assertNotIn("python", mode)
        self.assertNotIn("aws ", mode)
        result = subprocess.run(["bash", "-c", mode + "fi\n", "fixture", "--mac"], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("disabled", result.stderr)

    def test_credential_process_returns_only_required_json(self):
        with patch.object(helper, "LoginKeychain") as store, patch("sys.stdout", new_callable=io.StringIO) as output:
            store.return_value.read.return_value = OLD
            self.assertEqual(helper.main(["credential-process"]), 0)
            self.assertEqual(json.loads(output.getvalue()), OLD.document())
            store.return_value.write.assert_not_called()

    def test_keychain_payload_only_uses_private_pipe_and_readback(self):
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs))
            encoded = base64.b64encode(json.dumps(NEW.document()).encode()).decode()
            return subprocess.CompletedProcess(args, 0, encoded if "find-generic-password" in args else "", "")
        helper.LoginKeychain(run=run, path="/fixture/login.keychain-db").write(NEW)
        self.assertEqual(calls[0][0], ["/usr/bin/security", "-q", "-i"])
        self.assertNotIn(NEW.secret, repr(calls[0][0]))
        self.assertNotIn(NEW.key_id, repr(calls[0][0]))
        self.assertNotIn(" -A ", calls[0][1]["input"])
        self.assertIn("-T /usr/bin/security", calls[0][1]["input"])
        self.assertEqual(len(calls), 2)

    def test_security_interactive_success_cannot_hide_failed_write(self):
        def run(args, **kwargs):
            encoded = base64.b64encode(json.dumps(OLD.document()).encode()).decode()
            return subprocess.CompletedProcess(args, 0, encoded if "find-generic-password" in args else "", NEW.secret)
        with self.assertRaises(helper.CredentialError) as caught:
            helper.LoginKeychain(run=run, path="/fixture/login.keychain-db").write(NEW)
        self.assertNotIn(NEW.secret, str(caught.exception))

    def test_aws_uses_exact_pair_without_other_credential_sources_or_argv_values(self):
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs))
            return subprocess.CompletedProcess(args, 0, "{}", "")
        with patch.dict(helper.os.environ, {"AWS_PROFILE": "fixture-profile", "AWS_SESSION_TOKEN": "fixture-session", "AWS_WEB_IDENTITY_TOKEN_FILE": "fixture-path"}, clear=True):
            helper.AwsClient(NEW, "eu-central-1", run=run).delete(OLD.key_id)
        args, kwargs = calls[0]
        self.assertNotIn(NEW.secret, repr(args))
        self.assertNotIn(OLD.key_id, repr(args))
        self.assertEqual(kwargs["env"]["AWS_ACCESS_KEY_ID"], NEW.key_id)
        self.assertEqual(kwargs["env"]["AWS_SECRET_ACCESS_KEY"], NEW.secret)
        self.assertNotIn("AWS_PROFILE", kwargs["env"])
        self.assertNotIn("AWS_SESSION_TOKEN", kwargs["env"])
        self.assertNotIn("AWS_WEB_IDENTITY_TOKEN_FILE", kwargs["env"])
        self.assertEqual(kwargs["env"]["AWS_CONFIG_FILE"], helper.os.devnull)
        self.assertEqual(kwargs["env"]["AWS_SHARED_CREDENTIALS_FILE"], helper.os.devnull)
        self.assertEqual(json.loads(kwargs["input"])["AccessKeyId"], OLD.key_id)

    def test_unexpected_credential_identity_fails_closed(self):
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, '{"Arn":"fixture-other-principal"}', "")
        with self.assertRaises(helper.CredentialError):
            helper.AwsClient(OLD, "eu-central-1", run=run).identity()

    def test_zero_multiple_inactive_or_mismatched_keys_are_refused(self):
        # Mutant: removing the exact-one-active-current-key guard opens every rejected case here.
        for entries in [[], [{}, {}], [{"AccessKeyId": OLD.key_id, "Status": "Inactive"}], [{"AccessKeyId": NEW.key_id, "Status": "Active"}]]:
            with self.subTest(entries=entries):
                def run(args, **kwargs):
                    return subprocess.CompletedProcess(args, 0, json.dumps({"AccessKeyMetadata": entries}), "")
                with self.assertRaises(helper.CredentialError):
                    helper.AwsClient(OLD, "eu-central-1", run=run).existing_key()

    def test_valid_matching_current_key_is_accepted(self):
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, json.dumps({"AccessKeyMetadata": [{"AccessKeyId": OLD.key_id, "Status": "Active"}]}), "")
        helper.AwsClient(OLD, "eu-central-1", run=run).existing_key()

    def test_invalid_store_or_line_injection_is_refused_without_echo(self):
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, "not-valid-base64", NEW.secret)
        with self.assertRaises(helper.CredentialError) as caught:
            helper.LoginKeychain(run=run, path="/fixture/login.keychain-db").read()
        self.assertNotIn(NEW.secret, str(caught.exception))
        with self.assertRaises(helper.CredentialError):
            helper.LoginKeychain(run=run, path="/fixture/\ninvalid")

    def test_subprocess_errors_never_echo_captured_output(self):
        def run(args, **kwargs):
            raise subprocess.TimeoutExpired(args, 30, output=NEW.secret)
        with self.assertRaises(helper.CredentialError) as caught:
            helper.LoginKeychain(run=run, path="/fixture/login.keychain-db").read()
        self.assertNotIn(NEW.secret, str(caught.exception))
        self.assertNotIn(NEW.key_id, repr(NEW))
        self.assertNotIn(NEW.secret, repr(NEW))


if __name__ == "__main__":
    unittest.main()
