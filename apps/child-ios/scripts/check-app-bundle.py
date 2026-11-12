#!/usr/bin/env python3
"""Fail loudly if the built iOS app is missing an extension or an entitlement (roadmap 5.5, #372).

An Xcode build can succeed while producing an app that cannot work: an extension left out of
PlugIns/, an Info.plist with the wrong extension point, or an entitlements file without the Family
Controls key. None of those fail the build, so this script checks them after it (the lesson of #361).

    python3 scripts/check-app-bundle.py <path/to/OSRAAgent.app> [<path/to/OSRAAgent.app> ...]

It checks, for each .app given:
  1. PlugIns/ holds exactly the three expected .appex bundles, and nothing else;
  2. each .appex Info.plist has the expected NSExtensionPointIdentifier and NSExtensionPrincipalClass;
  3. on macOS (where `nm` reads Mach-O), each .appex binary defines its principal class (a Swift class of the
     extension's own module, #561);
  4. the app's display name is "OSRA Kids" in Info.plist and in en.lproj (Karim, 11 Nov), and ar.lproj
     carries a display name too; the app's Info.plist asks for location with both usage strings, has them in English and Arabic
     (en.lproj, ar.lproj), and has no `location` background mode (significant-change monitoring needs
     none, and the entry draws App Review questions, 5.5 PR E).
And once, from the source tree (an unsigned build embeds no entitlements):
  5. every target's .entitlements file carries com.apple.developer.family-controls = true and the
     app group group.com.osratech.child.
  6. each extension's Info.plist names "$(PRODUCT_MODULE_NAME).<Class>" and declares <Class> in its own sources (#561).
And for the app and each .appex, built and in the source tree:
  7. Info.plist lists en and ar in CFBundleLocalizations, and the bundle carries en.lproj and ar.lproj (#654: an
     extension that declares only English gets English from iOS, so the block screen stayed English on an
     Arabic phone).

It prints what it found, so the CI log shows the bundle list, and exits 1 on any mismatch.
"""
import os
import plistlib
import re
import shutil
import subprocess
import sys

APP_GROUP = "group.com.osratech.child"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# .appex name -> (extension point, module, principal class). #561: the principal class is declared in the extension's
# own module and named "$(PRODUCT_MODULE_NAME).<Class>" in Info.plist, as Apple's template does; a class that lived
# only in the statically linked package could not be loaded on the iPhone (SpringBoard: "ExtensionError Code=0").
EXTENSIONS = {
    "OSRAAgentMonitor.appex": (
        "com.apple.deviceactivity.monitor-extension", "OSRAAgentMonitor", "DeviceActivityMonitorExtension"),
    "OSRAAgentShieldConfiguration.appex": (
        "com.apple.ManagedSettingsUI.shield-configuration-service", "OSRAAgentShieldConfiguration",
        "ShieldConfigurationExtension"),
    "OSRAAgentShieldAction.appex": (
        "com.apple.ManagedSettings.shield-action-service", "OSRAAgentShieldAction", "ShieldActionExtension"),
}

# Extension folder in the source tree -> the .appex it builds.
EXTENSION_SOURCES = {
    "Extensions/Monitor": "OSRAAgentMonitor.appex",
    "Extensions/ShieldConfiguration": "OSRAAgentShieldConfiguration.appex",
    "Extensions/ShieldAction": "OSRAAgentShieldAction.appex",
}

DISPLAY_NAME = "OSRA Kids"

LOCATION_KEYS = ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"]

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

    check_display_name(app)
    check_location(app)

    for name, (point, module, cls) in EXTENSIONS.items():
        principal = f"{module}.{cls}"
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
        check_principal_linked(appex, name, module, cls)
        check_localizations(appex, name)
    check_localizations(app, "app")


def check_display_name(app):
    info_path = os.path.join(app, "Info.plist")
    if not os.path.isfile(info_path):
        fail("app: no Info.plist")
        return
    name = read_plist(info_path).get("CFBundleDisplayName")
    if name == DISPLAY_NAME:
        ok(f"app: CFBundleDisplayName = {name}")
    else:
        fail(f"app: CFBundleDisplayName = {name!r}, expected {DISPLAY_NAME!r}")
    for lang in ("en", "ar"):
        strings = os.path.join(app, f"{lang}.lproj", "InfoPlist.strings")
        if not os.path.isfile(strings):
            fail(f"app: no {lang}.lproj/InfoPlist.strings")
            continue
        value = read_strings_value(strings, "CFBundleDisplayName")
        if lang == "en" and value != DISPLAY_NAME:
            fail(f"app: en.lproj CFBundleDisplayName = {value!r}, expected {DISPLAY_NAME!r}")
        elif not value:
            fail(f"app: {lang}.lproj/InfoPlist.strings has no CFBundleDisplayName")
        else:
            ok(f"app: {lang}.lproj CFBundleDisplayName present")


def read_strings_value(path, key):
    """The value of one key in a built .strings file (binary plist, or text in UTF-8/UTF-16)."""
    with open(path, "rb") as f:
        data = f.read()
    try:
        return plistlib.loads(data).get(key)
    except Exception:
        pass
    for encoding in ("utf-8", "utf-16"):
        try:
            text = data.decode(encoding)
        except UnicodeDecodeError:
            continue
        for line in text.splitlines():
            line = line.strip()
            prefix = f'"{key}" = "'
            if line.startswith(prefix) and line.endswith('";'):
                return line[len(prefix):-2]
    return None


def check_location(app):
    info_path = os.path.join(app, "Info.plist")
    if not os.path.isfile(info_path):
        fail("app: no Info.plist")
        return
    info = read_plist(info_path)
    missing = [k for k in LOCATION_KEYS if not info.get(k)]
    if missing:
        fail(f"app: Info.plist lacks {missing}")
    else:
        ok("app: both location usage strings")
    modes = info.get("UIBackgroundModes", [])
    if "location" in modes:
        fail(f"app: UIBackgroundModes has 'location' ({modes}); significant-change monitoring needs none")
    else:
        ok(f"app: UIBackgroundModes = {modes}, no 'location'")
    for lang in ("en", "ar"):
        strings = os.path.join(app, f"{lang}.lproj", "InfoPlist.strings")
        if not os.path.isfile(strings):
            fail(f"app: no {lang}.lproj/InfoPlist.strings")
            continue
        text = read_strings(strings)
        absent = [k for k in LOCATION_KEYS if k not in text]
        if absent:
            fail(f"app: {lang}.lproj/InfoPlist.strings lacks {absent}")
        else:
            ok(f"app: {lang}.lproj/InfoPlist.strings has both location strings")


def read_strings(path):
    """A built .strings file may be binary plist or text, in UTF-8 or UTF-16."""
    with open(path, "rb") as f:
        data = f.read()
    try:
        return " ".join(plistlib.loads(data).keys())
    except Exception:
        pass
    for encoding in ("utf-8", "utf-16"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return ""


def swift_class_symbol(module, cls):
    """The Objective-C class symbol Swift emits for `module.cls` (its mangled runtime name)."""
    return f"_OBJC_CLASS_$__TtC{len(module)}{module}{len(cls)}{cls}"


def check_principal_linked(appex, name, module, cls):
    """The class the plist names must be in the extension binary, or the extension starts with nothing."""
    if sys.platform != "darwin" or not shutil.which("nm"):
        print(f"skip  {name}: principal class not looked up in the binary (needs macOS nm)")
        return
    binary = os.path.join(appex, os.path.splitext(name)[0])
    if not os.path.isfile(binary):
        fail(f"{name}: no executable at {binary}")
        return
    symbols = subprocess.run(["nm", binary], capture_output=True, text=True).stdout
    symbol = swift_class_symbol(module, cls)
    if symbol in symbols:
        ok(f"{name}: binary defines {module}.{cls}")
    else:
        fail(f"{name}: binary does not define {symbol}")


def check_principal_sources():
    """#561, from the source tree: each Info.plist names "$(PRODUCT_MODULE_NAME).<Class>", and <Class> is declared in
    that extension's own Swift files, not only in the package."""
    print("\nprincipal classes (source files)")
    for folder, appex in EXTENSION_SOURCES.items():
        _, _, cls = EXTENSIONS[appex]
        info = read_plist(os.path.join(ROOT, folder, "Info.plist"))
        named = info.get("NSExtension", {}).get("NSExtensionPrincipalClass")
        expected = f"$(PRODUCT_MODULE_NAME).{cls}"
        if named == expected:
            ok(f"{folder}/Info.plist: NSExtensionPrincipalClass = {named}")
        else:
            fail(f"{folder}/Info.plist: NSExtensionPrincipalClass = {named!r}, expected {expected!r}")
        sources = ""
        for entry in sorted(os.listdir(os.path.join(ROOT, folder))):
            if entry.endswith(".swift"):
                with open(os.path.join(ROOT, folder, entry), encoding="utf-8") as f:
                    sources += f.read()
        if re.search(rf"\bclass\s+{cls}\s*:", sources):
            ok(f"{folder}: declares class {cls}")
        else:
            fail(f"{folder}: no `class {cls}:` in its own Swift files")


LANGUAGES = ["en", "ar"]

# Source folder -> the bundle it builds, for the localization check (#654).
LOCALIZED_SOURCES = {"App": "app", **EXTENSION_SOURCES}


def check_localizations(bundle, name):
    """#654: the bundle tells iOS it speaks English and Arabic, so iOS hands it the phone's language."""
    info_path = os.path.join(bundle, "Info.plist")
    if not os.path.isfile(info_path):
        fail(f"{name}: no Info.plist")
        return
    declared = read_plist(info_path).get("CFBundleLocalizations") or []
    missing = [lang for lang in LANGUAGES if lang not in declared]
    if missing:
        fail(f"{name}: CFBundleLocalizations = {declared!r}, missing {missing}")
    else:
        ok(f"{name}: CFBundleLocalizations has {', '.join(LANGUAGES)}")
    for lang in LANGUAGES:
        if not os.path.isdir(os.path.join(bundle, f"{lang}.lproj")):
            fail(f"{name}: no {lang}.lproj")


def check_localization_sources():
    print("\nlocalizations (source files)")
    for folder in LOCALIZED_SOURCES:
        check_localizations(os.path.join(ROOT, folder), folder)


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
        if family is True and groups == [APP_GROUP]:
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
    check_principal_sources()
    check_localization_sources()
    print(f"\n{len(failures)} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
