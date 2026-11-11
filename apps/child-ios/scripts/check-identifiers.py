#!/usr/bin/env python3
"""Fail if any iOS identifier is not the final one (decision 2B, #372).

The store ids were fixed by the maintainer on 29 Oct: the child agent is com.osratech.child (its
extensions hang under it) with app group group.com.osratech.child, and the parent app is
com.osratech.parent, the same ids Android ships (#452). Nothing can be registered in the Apple
account until every file agrees, and one stray id is enough to break it: an extension whose
entitlements keep another group cannot read the Keychain items or the rules the app writes.

    python3 apps/child-ios/scripts/check-identifiers.py

Stdlib only, reads the source tree, runs on Linux. It checks:
  1. each target in project.yml has exactly its expected PRODUCT_BUNDLE_IDENTIFIER;
  2. each .entitlements file lists exactly the one app group, and no other Keychain access group;
  3. every "group.…" string literal in the Swift sources is the app group, and the Swift constants
     that name it (the identity suite; the old picker `SelectionStore` is gone, ADR-0036) are that literal;
  4. the parent app's Runner.xcodeproj uses only com.osratech.parent and its test bundle;
  5. no old reverse-DNS id (dev.familyshield.…) is left in the iOS trees or the iOS workflows.
It prints what it found and exits 1 on any mismatch.
"""
import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
CHILD = os.path.join(ROOT, "apps", "child-ios")

APP_ID = "com.osratech.child"
APP_GROUP = "group.com.osratech.child"
PARENT_ID = "com.osratech.parent"

BUNDLE_IDS = {
    "OSRAAgent": APP_ID,
    "OSRAAgentMonitor": f"{APP_ID}.Monitor",
    "OSRAAgentShieldConfiguration": f"{APP_ID}.ShieldConfiguration",
    "OSRAAgentShieldAction": f"{APP_ID}.ShieldAction",
    "OSRAAgentHostedTests": f"{APP_ID}.HostedTests",
    "FamilyShieldAgentIntegrationTests": f"{APP_ID}.IntegrationTests",
}

ENTITLEMENTS = [
    "App/OSRAAgent.entitlements",
    "Extensions/Monitor/Monitor.entitlements",
    "Extensions/ShieldConfiguration/ShieldConfiguration.entitlements",
    "Extensions/ShieldAction/ShieldAction.entitlements",
]

SWIFT_DIRS = ["Sources", "App", "Extensions", "HostedTests", "IntegrationTests", "Tests"]

# Swift constants that must spell the app group, as (file, declaration prefix).
GROUP_CONSTANTS = [
    ("Sources/FamilyShieldAgent/AgentIdentityStore.swift", "public static let suiteName = "),
]

OLD_ID = re.compile(r"\bdev\.familyshield\.(agent|familyshieldParent)\b")
OLD_ID_TREES = ["apps/child-ios", "apps/parent-app/ios"]
OLD_ID_FILES = [".github/workflows/ios-ci.yml", ".github/workflows/parent-app.yml"]

failures = []


def fail(message):
    failures.append(message)
    print(f"FAIL  {message}")


def ok(message):
    print(f"ok    {message}")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def project_bundle_ids(text):
    """target name -> PRODUCT_BUNDLE_IDENTIFIER values under it, from XcodeGen's project.yml."""
    found = {}
    in_targets = False
    target = None
    for line in text.splitlines():
        if re.match(r"^\S", line):
            in_targets = line.startswith("targets:")
            target = None
            continue
        if not in_targets:
            continue
        m = re.match(r"^  (\w+):\s*$", line)
        if m:
            target = m.group(1)
            found.setdefault(target, [])
            continue
        m = re.match(r"^\s+PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)\s*$", line)
        if m and target:
            found[target].append(m.group(1).strip("\"'"))
    return found


def check_project():
    print("\nproject.yml bundle ids")
    found = project_bundle_ids(read(os.path.join(CHILD, "project.yml")))
    for target, expected in BUNDLE_IDS.items():
        got = found.get(target)
        if got == [expected]:
            ok(f"{target}: {expected}")
        else:
            fail(f"{target}: PRODUCT_BUNDLE_IDENTIFIER {got!r}, expected [{expected!r}]")
    extra = sorted(set(found) - set(BUNDLE_IDS))
    if extra:
        fail(f"targets with no expected bundle id here: {extra}")


def check_entitlements():
    print("\nentitlements")
    for rel in ENTITLEMENTS:
        path = os.path.join(CHILD, rel)
        if not os.path.isfile(path):
            fail(f"{rel}: missing")
            continue
        with open(path, "rb") as f:
            ent = plistlib.load(f)
        groups = ent.get("com.apple.security.application-groups")
        keychain = ent.get("keychain-access-groups")
        if groups == [APP_GROUP]:
            ok(f"{rel}: application-groups = [{APP_GROUP}]")
        else:
            fail(f"{rel}: application-groups = {groups!r}, expected [{APP_GROUP!r}]")
        if keychain not in (None, [APP_GROUP]):
            fail(f"{rel}: keychain-access-groups = {keychain!r}, expected none or [{APP_GROUP!r}]")


def swift_files():
    for d in SWIFT_DIRS:
        for dirpath, _, names in os.walk(os.path.join(CHILD, d)):
            for name in names:
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


def check_swift():
    print("\nSwift sources")
    literals = 0
    for path in swift_files():
        rel = os.path.relpath(path, CHILD)
        for n, line in enumerate(read(path).splitlines(), 1):
            for lit in re.findall(r'"(group\.[^"\\]*)"', line):
                literals += 1
                if lit != APP_GROUP:
                    fail(f"{rel}:{n}: app group literal {lit!r}, expected {APP_GROUP!r}")
    ok(f"{literals} \"group.…\" literal(s) read")
    for rel, prefix in GROUP_CONSTANTS:
        text = read(os.path.join(CHILD, rel))
        decl = [l.strip() for l in text.splitlines() if l.strip().startswith(prefix)]
        if decl == [f'{prefix}"{APP_GROUP}"']:
            ok(f"{rel}: suiteName = {APP_GROUP}")
        else:
            fail(f"{rel}: expected one `{prefix}\"{APP_GROUP}\"`, found {decl!r}")


def check_parent():
    print("\nparent Runner.xcodeproj")
    rel = "apps/parent-app/ios/Runner.xcodeproj/project.pbxproj"
    ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", read(os.path.join(ROOT, rel)))
    allowed = {PARENT_ID, f"{PARENT_ID}.RunnerTests"}
    bad = sorted(set(ids) - allowed)
    app = ids.count(PARENT_ID)
    if bad:
        fail(f"{rel}: unexpected bundle ids {bad}")
    if app != 3:
        fail(f"{rel}: {app} build configurations use {PARENT_ID}, expected 3 (Debug, Release, Profile)")
    if not bad and app == 3:
        ok(f"{rel}: {len(ids)} ids, all {PARENT_ID} or its RunnerTests")


def check_no_old_ids():
    print("\nold ids")
    paths = [os.path.join(ROOT, f) for f in OLD_ID_FILES]
    for tree in OLD_ID_TREES:
        for dirpath, dirs, names in os.walk(os.path.join(ROOT, tree)):
            dirs[:] = [d for d in dirs if d not in (".build", "Pods", "build", ".git")]
            paths += [os.path.join(dirpath, n) for n in names]
    hits = 0
    for path in paths:
        try:
            text = read(path)
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if OLD_ID.search(line):
                hits += 1
                fail(f"{os.path.relpath(path, ROOT)}:{n}: old id left: {line.strip()[:120]}")
    if not hits:
        ok(f"no dev.familyshield.* id in {len(paths)} file(s)")


def main():
    check_project()
    check_entitlements()
    check_swift()
    check_parent()
    check_no_old_ids()
    print(f"\n{len(failures)} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
