#!/usr/bin/env python3
"""Fail loudly if the built iOS app is missing an extension or an entitlement (roadmap 5.5, #372).

An Xcode build can succeed while producing an app that cannot work: an extension left out of
PlugIns/, an Info.plist with the wrong extension point, or an entitlements file without the Family
Controls key. None of those fail the build, so this script checks them after it (the lesson of #361).

    python3 scripts/check-app-bundle.py <path/to/OSRAAgent.app> [<path/to/OSRAAgent.app> ...]

It checks, for each .app given:
  1. PlugIns/ holds exactly the three expected .appex bundles, and nothing else;
  2. each .appex Info.plist has the expected NSExtensionPointIdentifier and NSExtensionPrincipalClass;
  3. on macOS (where `nm` reads Mach-O), each .appex binary defines its principal class.
And once, from the source tree (an unsigned build embeds no entitlements):
  4. every target's .entitlements file carries com.apple.developer.family-controls = true and the
     app group group.dev.familyshield.agent.

It prints what it found, so the CI log shows the bundle list, and exits 1 on any mismatch.
"""
import os
import plistlib
import shutil
import subprocess
import sys

APP_GROUP = "group.dev.familyshield.agent"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# .appex name -> (extension point, principal class)
EXTENSIONS = {
    "OSRAAgentMonitor.appex": ("com.apple.deviceactivity.monitor-extension", "FamilyShieldDeviceActivityMonitor"),
    "OSRAAgentShieldConfiguration.appex": (
        "com.apple.ManagedSettingsUI.shield-configuration-service",
        "FamilyShieldConfigurationDataSource",
    ),
    "OSRAAgentShieldAction.appex": ("com.apple.ManagedSettings.shield-action-service", "FamilyShieldShieldActionDelegate"),
}

ENTITLEMENTS = [
    "App/OSRAAgent.entitlements",
    "Extensions/Monitor/Monitor.entitlements",
    "Extensions/ShieldConfiguration/ShieldConfiguration.entitlements",
    "Extensions/ShieldAction/ShieldAction.entitlements",
]

failures = []


def fail(message):
    failures.append(message)
    print(f"FAIL  {message}")


def ok(message):
    print(f"ok    {message}")


def read_plist(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def check_app(app):
    print(f"\n{app}")
    if not os.path.isdir(app):
        fail(f"{app}: not a directory")
        return
    plugins = os.path.join(app, "PlugIns")
    found = sorted(os.listdir(plugins)) if os.path.isdir(plugins) else []
    print(f"      PlugIns/: {', '.join(found) if found else '(missing or empty)'}")
    if found == sorted(EXTENSIONS):
        ok(f"PlugIns/ holds exactly the {len(EXTENSIONS)} expected extensions")
    else:
        missing = sorted(set(EXTENSIONS) - set(found))
        extra = sorted(set(found) - set(EXTENSIONS))
        fail(f"PlugIns/ mismatch: missing {missing or 'none'}, unexpected {extra or 'none'}")

    for name, (point, principal) in EXTENSIONS.items():
        appex = os.path.join(plugins, name)
        info_path = os.path.join(appex, "Info.plist")
        if not os.path.isfile(info_path):
            fail(f"{name}: no Info.plist")
            continue
        ext = read_plist(info_path).get("NSExtension", {})
        got_point = ext.get("NSExtensionPointIdentifier")
        got_principal = ext.get("NSExtensionPrincipalClass")
        if got_point == point:
            ok(f"{name}: NSExtensionPointIdentifier = {got_point}")
        else:
            fail(f"{name}: NSExtensionPointIdentifier = {got_point!r}, expected {point!r}")
        if got_principal == principal:
            ok(f"{name}: NSExtensionPrincipalClass = {got_principal}")
        else:
            fail(f"{name}: NSExtensionPrincipalClass = {got_principal!r}, expected {principal!r}")
        check_principal_linked(appex, name, principal)


def check_principal_linked(appex, name, principal):
    """The class the plist names must be in the extension binary, or the extension starts with nothing."""
    if sys.platform != "darwin" or not shutil.which("nm"):
        print(f"skip  {name}: principal class not looked up in the binary (needs macOS nm)")
        return
    binary = os.path.join(appex, os.path.splitext(name)[0])
    if not os.path.isfile(binary):
        fail(f"{name}: no executable at {binary}")
        return
    symbols = subprocess.run(["nm", binary], capture_output=True, text=True).stdout
    if f"_OBJC_CLASS_$_{principal}" in symbols:
        ok(f"{name}: binary defines {principal}")
    else:
        fail(f"{name}: binary does not define _OBJC_CLASS_$_{principal}")


def check_entitlements():
    print("\nentitlements (source files: an unsigned build embeds none)")
    for rel in ENTITLEMENTS:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            fail(f"{rel}: missing")
            continue
        ent = read_plist(path)
        family = ent.get("com.apple.developer.family-controls")
        groups = ent.get("com.apple.security.application-groups", [])
        if family is True and APP_GROUP in groups:
            ok(f"{rel}: family-controls and {APP_GROUP}")
        else:
            fail(f"{rel}: family-controls={family!r}, application-groups={groups!r}")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    for app in argv[1:]:
        check_app(app)
    check_entitlements()
    print(f"\n{len(failures)} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
