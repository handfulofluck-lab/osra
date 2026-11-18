#!/usr/bin/env python3
"""Phase1 login-Keychain credential_process; the rotation CLI is disabled.

The superseded rotation implementation is retained for fake-only regression coverage,
not exposed by this phase1 command. The IAM ceiling independently denies Mac IAM actions.
"""

import argparse
import base64
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import subprocess
import sys
import time


USER = "osra-codex-mac"
SERVICE = "osra-agent-credential"


class CredentialError(Exception):
    """Only fixed, nonsensitive diagnostic messages may leave this module."""


@dataclass(frozen=True)
class Credential:
    key_id: str = field(repr=False)
    secret: str = field(repr=False)

    def document(self):
        return {"Version": 1, "AccessKeyId": self.key_id, "SecretAccessKey": self.secret}

    @classmethod
    def parse(cls, document):
        if not isinstance(document, dict) or document.get("Version") != 1:
            raise CredentialError("The credential store has an unsupported format.")
        values = [document.get("AccessKeyId"), document.get("SecretAccessKey")]
        if not all(isinstance(value, str) and value and not any(c.isspace() for c in value) for value in values):
            raise CredentialError("The credential store is incomplete.")
        return cls(*values)


def invoke(run, args, **kwargs):
    try:
        return run(args, capture_output=True, text=True, check=False, timeout=30, **kwargs)
    except (OSError, subprocess.SubprocessError):
        # Subprocess exceptions can contain arguments or captured output; never include them.
        raise CredentialError("The credential operation could not complete.") from None


class LoginKeychain:
    def __init__(self, run=subprocess.run, path=None):
        self.run = run
        self.path = str(path or Path.home() / "Library/Keychains/login.keychain-db")
        if any(c in self.path for c in "\r\n\x00"):
            raise CredentialError("The login Keychain path is invalid.")

    def read(self):
        result = invoke(self.run, ["/usr/bin/security", "find-generic-password", "-a", USER, "-s", SERVICE, "-w", self.path])
        if result.returncode:
            raise CredentialError("The login Keychain credential is unavailable.")
        try:
            return Credential.parse(json.loads(base64.b64decode(result.stdout.strip(), validate=True)))
        except (ValueError, TypeError, UnicodeError):
            raise CredentialError("The login Keychain credential is unreadable.") from None

    def write(self, credential):
        # security's interactive mode takes commands over stdin. Base64 keeps the payload a single
        # argument in that command without shell quoting, and never puts it in the process arguments.
        payload = base64.b64encode(json.dumps(credential.document()).encode()).decode()
        quoted_path = '"' + self.path.replace("\\", "\\\\").replace('"', '\\"') + '"'
        command = f'add-generic-password -U -a {USER} -s {SERVICE} -T /usr/bin/security -w {payload} {quoted_path}\n'
        result = invoke(self.run, ["/usr/bin/security", "-q", "-i"], input=command)
        if result.returncode:
            raise CredentialError("The login Keychain credential could not be updated.")
        # Interactive security may finish successfully after a failed command; read-back is required.
        if self.read() != credential:
            raise CredentialError("The login Keychain credential did not match after writing.")


class AwsClient:
    def __init__(self, credential, region, run=subprocess.run):
        self.credential = credential
        self.region = region
        self.run = run

    def call(self, service, operation, parameters=None):
        # The proof and cleanup use the exact in-memory pair, never a profile, session, container,
        # web-identity provider or metadata fallback that could silently prove a different credential.
        env = {key: value for key, value in os.environ.items() if not key.startswith("AWS_")}
        env.update(AWS_ACCESS_KEY_ID=self.credential.key_id, AWS_SECRET_ACCESS_KEY=self.credential.secret,
                   AWS_CONFIG_FILE=os.devnull, AWS_SHARED_CREDENTIALS_FILE=os.devnull,
                   AWS_EC2_METADATA_DISABLED="true", AWS_PAGER="")
        args = ["aws", service, operation, "--region", self.region, "--output", "json", "--no-cli-pager"]
        kwargs = {"env": env}
        if parameters is not None:
            args += ["--cli-input-json", "file:///dev/stdin"]
            kwargs["input"] = json.dumps(parameters)
        result = invoke(self.run, args, **kwargs)
        if result.returncode:
            raise CredentialError("The AWS credential operation was refused.")
        try:
            document = json.loads(result.stdout) if result.stdout.strip() else {}
            if not isinstance(document, dict):
                raise ValueError("invalid response type")
            return document
        except (ValueError, TypeError):
            raise CredentialError("The AWS credential operation returned an unreadable result.") from None

    def identity(self):
        result = self.call("sts", "get-caller-identity")
        arn = result.get("Arn", "")
        if not isinstance(arn, str) or not arn.endswith(":user/" + USER):
            raise CredentialError("The credential is not the expected Mac IAM user.")
        return arn

    def existing_key(self):
        entries = self.call("iam", "list-access-keys", {"UserName": USER}).get("AccessKeyMetadata", [])
        if not isinstance(entries, list) or len(entries) != 1 or not isinstance(entries[0], dict) or entries[0].get("Status") != "Active" or entries[0].get("AccessKeyId") != self.credential.key_id:
            raise CredentialError("Rotation requires exactly one active key matching the login Keychain.")

    def create(self):
        result = self.call("iam", "create-access-key", {"UserName": USER}).get("AccessKey", {})
        if not isinstance(result, dict):
            raise CredentialError("The replacement credential response was incomplete.")
        return result

    def delete(self, key_id):
        self.call("iam", "delete-access-key", {"UserName": USER, "AccessKeyId": key_id})


def rotate(store, client_factory, sleep=time.sleep):
    original = store.read()
    old = client_factory(original)
    identity = old.identity()
    old.existing_key()
    new_id = None
    proven = False
    try:
        created = old.create()
        new_id = created.get("AccessKeyId")
        replacement = Credential.parse({"Version": 1, "AccessKeyId": new_id, "SecretAccessKey": created.get("SecretAccessKey")})
        if replacement.key_id == original.key_id:
            raise CredentialError("The replacement key must differ from the current key.")
        store.write(replacement)
        # Prove the credential_process source after read-back, not just the create-access-key answer.
        saved = store.read()
        if saved != replacement:
            raise CredentialError("The replacement credential was not saved correctly.")
        for attempt in range(6):
            try:
                if client_factory(saved).identity() == identity:
                    proven = True
                    break
            except CredentialError:
                pass
            if attempt < 5:
                sleep((attempt + 1) * 5)
        if not proven:
            raise CredentialError("The replacement credential could not prove the expected identity.")
    except BaseException:
        if new_id and new_id != original.key_id:
            # Restore first. If that fails, retain both keys for recovery instead of deleting the
            # potentially sole credential currently available through credential_process.
            try:
                store.write(original)
            except BaseException:
                raise CredentialError("Rotation stopped; both keys are retained because Keychain restoration needs review.") from None
            try:
                old.delete(new_id)
            except BaseException:
                raise CredentialError("The previous credential was restored; replacement-key cleanup needs review.") from None
        raise CredentialError("Rotation stopped before verification; the previous credential is retained.") from None
    # A deletion failure after proof must keep the new working credential, not roll it back.
    try:
        client_factory(saved).delete(original.key_id)
    except CredentialError:
        raise CredentialError("The replacement credential is verified and saved; old-key deletion needs review.") from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["credential-process", "rotate"])
    parser.add_argument("--region", default="eu-central-1")
    args = parser.parse_args(argv)
    if args.mode == "rotate":
        print("Mac rotation is disabled in phase 1; renewal requires the owner's approved MFA key-creation step.", file=sys.stderr)
        return 1
    try:
        store = LoginKeychain()
        print(json.dumps(store.read().document()))
        return 0
    except CredentialError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
