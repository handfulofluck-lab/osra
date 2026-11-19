#!/usr/bin/env node
// #558: the parent iPhone app only receives push when ALL of these hold. Each one has been missing before
// (the 16 Nov 2026 device check found build 8 with no aps-environment at all), so CI checks them statically.
//   1. apps/parent-app/ios/Runner/Runner.entitlements declares aps-environment (development|production).
//   2. Every Runner build configuration (Debug, Release, Profile) points CODE_SIGN_ENTITLEMENTS at that file.
//      Without it Xcode signs the app with no push entitlement and iOS never issues an APNs token.
//   3. The Runner target runs the "Copy Firebase config (optional)" phase, which puts GoogleService-Info.plist
//      into the app when the build machine supplies it (firebase_messaging needs it for an FCM token).
//   4. GoogleService-Info.plist itself is never committed (#317) and stays gitignored.
// Usage: node scripts/check-parent-ios-push.mjs [repoRoot]   (exit 1 with one line per failure)
import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";

const root = process.argv[2] ?? process.cwd();
const ios = join(root, "apps/parent-app/ios");
const failures = [];

const entPath = join(ios, "Runner/Runner.entitlements");
if (!existsSync(entPath)) {
  failures.push("apps/parent-app/ios/Runner/Runner.entitlements is missing");
} else {
  const ent = readFileSync(entPath, "utf8");
  const m = ent.match(/<key>aps-environment<\/key>\s*<string>([^<]*)<\/string>/);
  if (!m) failures.push("Runner.entitlements has no aps-environment key");
  else if (!["development", "production"].includes(m[1])) failures.push(`Runner.entitlements aps-environment is "${m[1]}"`);
}

const pbx = readFileSync(join(ios, "Runner.xcodeproj/project.pbxproj"), "utf8");
const configs = [...pbx.matchAll(/\/\* (Debug|Release|Profile) \*\/ = \{\s*isa = XCBuildConfiguration;([\s\S]*?)name = \1;/g)]
  .filter((c) => c[2].includes("PRODUCT_BUNDLE_IDENTIFIER = com.osratech.parent;"));
if (configs.length !== 3) failures.push(`expected 3 Runner build configurations, found ${configs.length}`);
for (const c of configs) {
  if (!c[2].includes("CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;")) {
    failures.push(`Runner ${c[1]} configuration does not set CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements`);
  }
}

const target = pbx.match(/\/\* Runner \*\/ = \{\s*isa = PBXNativeTarget;[\s\S]*?buildPhases = \(([\s\S]*?)\);/);
if (!target || !target[1].includes("/* Copy Firebase config (optional) */")) {
  failures.push('the Runner target does not run the "Copy Firebase config (optional)" build phase');
}

const tracked = execFileSync("git", ["-C", root, "ls-files", "apps/parent-app/ios/Runner/GoogleService-Info.plist"], { encoding: "utf8" });
if (tracked.trim()) failures.push("GoogleService-Info.plist is committed; it must stay out of git (#317)");
const ignored = (() => {
  try {
    execFileSync("git", ["-C", root, "check-ignore", "-q", "--no-index", "apps/parent-app/ios/Runner/GoogleService-Info.plist"]);
    return true;
  } catch { return false; }
})();
if (!ignored) failures.push("apps/parent-app/ios/Runner/GoogleService-Info.plist is not gitignored");

if (failures.length) {
  for (const f of failures) console.error(`::error::#558 parent iOS push: ${f}`);
  process.exit(1);
}
console.log(`parent iOS push wiring OK: aps-environment set, CODE_SIGN_ENTITLEMENTS on ${configs.length} Runner configs, Firebase config copy phase present, plist gitignored`);
