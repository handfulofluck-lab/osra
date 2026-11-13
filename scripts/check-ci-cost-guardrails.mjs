#!/usr/bin/env node
/**
 * Issue #613 guardrails: the CI-cost changes are structural contracts in the workflow files. This
 * dependency-free gate (node:fs only) pins them so a "cheaper CI" edit that quietly drops a guard —
 * the exact class of failure the workflow-lint file exists to catch — turns red instead of saving money
 * at the cost of coverage.
 *
 * Real checks (repository):
 *   1. `ios-ci.yml` push carries `branches: [main]`.
 *   2. `ios-ci.yml` push and pull_request path lists are exactly the six required patterns (child-ios,
 *      parent-app iOS, this workflow file, and the three API contract files).
 *   3. seven schedules are weekly — exactly one cron per file, so a re-added daily next to the weekly
 *      fails: `ios-ci.yml` Monday 01:23, and the six build suites Monday 02:11.
 *   4. all eight PR-suite workflows keep a real `concurrency.cancel-in-progress: true` key; a
 *      commented-out line does not count.
 *   5. `child-android.yml` pins `gradle/actions/setup-gradle` to a full commit SHA with a version comment after `actions/setup-java@v4`.
 *
 * Usage: node scripts/check-ci-cost-guardrails.mjs [--selftest]
 * Exit 0 green, 1 a rule failed, 2 a required workflow file is missing.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const IOS = ".github/workflows/ios-ci.yml";

const IOS_REQUIRED_PATHS = [
  "apps/child-ios/**",
  "apps/parent-app/ios/**",
  ".github/workflows/ios-ci.yml",
  "services/api/src/routes/devices.ts",
  "services/api/src/routes/alerts.ts",
  "services/api/src/lib/internalAuth.ts",
];

const WEEKLY_0211 = ["api.yml", "parent-app.yml", "child-android.yml", "agent-desktop.yml", "ai-engine.yml", "api-image.yml"];
const CANCEL_TRUE = ["api.yml", "parent-app.yml", "child-android.yml", "agent-desktop.yml", "ai-engine.yml", "api-image.yml", "ci.yml", "ios-ci.yml"];

const globToRegex = (glob) =>
  new RegExp("^" + glob.split("**").map((part) => part.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*")).join(".*") + "$");

function covered(path, globs) {
  return globs.some((g) => globToRegex(g).test(path) || globToRegex(g).test(`${path}/x`));
}

/** `paths:` lists per event (only the shape these files use). */
function parsePaths(text) {
  const lines = text.split(/\r?\n/);
  const out = {};
  let inOn = false, event = null, inPaths = false;
  for (const line of lines) {
    if (/^\s*#/.test(line) || line.trim() === "") continue;
    if (/^on:\s*$/.test(line)) { inOn = true; continue; }
    if (inOn && /^\S/.test(line)) { inOn = false; event = null; inPaths = false; continue; }
    if (!inOn) continue;
    const ev = line.match(/^ {2}([a-z_]+):\s*$/);
    if (ev) { event = ev[1]; inPaths = false; continue; }
    if (/^ {2}[a-z_]+:/.test(line)) { event = null; inPaths = false; continue; }
    if (event && /^ {4}paths:\s*$/.test(line)) { inPaths = true; out[event] = []; continue; }
    if (event && /^ {4}\S/.test(line)) { inPaths = false; continue; }
    const item = line.match(/^ {6}- ["']?([^"'#]+?)["']?\s*$/);
    if (inPaths && item) out[event].push(item[1]);
  }
  return out;
}

function hasPushBranchMain(text) {
  const lines = text.split(/\r?\n/);
  const on = lines.findIndex((l) => /^on:\s*$/.test(l));
  if (on === -1) return false;
  let i = on + 1;
  // find the push: event (a 2-space key) inside the on block
  while (i < lines.length && /^\S/.test(lines[i]) === false) {
    if (/^  push:\s*$/.test(lines[i])) {
      // scan its 4-space keys for branches: [main]
      for (let j = i + 1; j < lines.length; j++) {
        const l = lines[j];
        if (/^\S/.test(l) || /^  [a-z_]+:/.test(l)) break; // left push or the on block
        if (/^    branches:\s*\[\s*main\s*\]/.test(l)) return true;
      }
      return false;
    }
    if (/^  [a-z_]+:/.test(lines[i])) i += 1;
    else i += 1;
  }
  return false;
}

function scheduleCrons(text) {
  return [...text.matchAll(/^\s*-\s*cron:\s*["']([^"']+)["']/gm)].map((m) => m[1]);
}

function hasCancelInProgress(text) {
  // Comment lines are not keys: `# cancel-in-progress: true` must not stand in for the setting.
  return text.split(/\r?\n/).some((line) => !/^\s*#/.test(line) && /^\s*cancel-in-progress:\s*true\s*(#.*)?$/.test(line));
}

const GRADLE_PIN = /gradle\/actions\/setup-gradle@[0-9a-f]{40}\s+#\s*v4(?:\.\d+){0,2}\s*$/m;

function setupGradleAfterSetupJava(text) {
  const java = text.indexOf("actions/setup-java@v4");
  const gradle = GRADLE_PIN.exec(text);
  return gradle !== null && java !== -1 && gradle.index > java;
}

function check(read) {
  const problems = [];

  const ios = read(IOS);
  if (!hasPushBranchMain(ios)) problems.push(`${IOS}: push trigger has no branches: [main]`);

  const paths = parsePaths(ios);
  const want = [...IOS_REQUIRED_PATHS].sort().join("\n");
  if (!paths.push) problems.push(`${IOS}: no push paths list`);
  else if ([...paths.push].sort().join("\n") !== want) problems.push(`${IOS}: push paths are not the exact required set (got ${paths.push.join(", ")})`);
  if (!paths.pull_request) problems.push(`${IOS}: no pull_request paths list`);
  else if ([...paths.pull_request].sort().join("\n") !== want) problems.push(`${IOS}: pull_request paths are not the exact required set (got ${paths.pull_request.join(", ")})`);

  for (const f of WEEKLY_0211) {
    const crons = scheduleCrons(read(`.github/workflows/${f}`));
    if (crons.length !== 1 || crons[0] !== "11 2 * * 1") {
      problems.push(`${f}: schedule is not exactly one weekly Monday 02:11 cron (got ${crons.length ? crons.join(", ") : "none"})`);
    }
  }
  const iosCrons = scheduleCrons(ios);
  if (iosCrons.length !== 1 || iosCrons[0] !== "23 1 * * 1") {
    problems.push(`${IOS}: schedule is not exactly one weekly Monday 01:23 cron (got ${iosCrons.length ? iosCrons.join(", ") : "none"})`);
  }

  for (const f of CANCEL_TRUE) {
    if (!hasCancelInProgress(read(`.github/workflows/${f}`))) problems.push(`${f}: concurrency.cancel-in-progress is not true`);
  }

  const ca = read(".github/workflows/child-android.yml");
  if (!/gradle\/actions\/setup-gradle@/.test(ca)) problems.push("child-android.yml: gradle/actions/setup-gradle is missing");
  else if (!GRADLE_PIN.test(ca)) problems.push("child-android.yml: setup-gradle must use a full 40-character commit SHA with a version comment");
  else if (!setupGradleAfterSetupJava(ca)) problems.push("child-android.yml: setup-gradle must come after setup-java");

  return problems;
}

function runRepo() {
  const read = (p) => {
    const full = join(ROOT, p);
    if (!existsSync(full)) { console.log(`ERROR ${p}: missing`); process.exit(2); }
    return readFileSync(full, "utf8");
  };
  const problems = check(read);
  for (const p of problems) console.log(`ERROR ${p}`);
  console.log(`ci-cost-guardrails: ${problems.length} problem(s)`);
  process.exit(problems.length ? 1 : 0);
}

function selftest() {
  let total = 0, bad = 0;
  const expect = (name, ok, detail = "") => {
    total += 1;
    if (ok) console.log(`PASS  ${name}`);
    else { bad += 1; console.error(`FAIL  ${name}${detail ? `: ${detail}` : ""}`); }
  };

  // Static path semantics — the point of the iOS path list: a non-contract API file must NOT trigger
  // iOS CI, while the child-ios tree, the parent iOS tree and the three contract files must.
  const iosGlobs = IOS_REQUIRED_PATHS;
  expect("a non-contract API file matches no iOS path", !covered("services/api/src/routes/family.ts", iosGlobs));
  expect("the child-ios tree matches an iOS path", covered("apps/child-ios/scripts/live-api.mjs", iosGlobs));
  expect("the parent iOS tree matches an iOS path", covered("apps/parent-app/ios/Runner.xcodeproj/project.pbxproj", iosGlobs));
  expect("the devices contract file matches", covered("services/api/src/routes/devices.ts", iosGlobs));
  expect("the alerts contract file matches", covered("services/api/src/routes/alerts.ts", iosGlobs));
  expect("the internalAuth contract file matches", covered("services/api/src/lib/internalAuth.ts", iosGlobs));
  expect("** spans directories but * does not", covered("services/api/src/lib/internalAuth.ts", ["services/api/**"]) && !covered("services/api/src/lib/internalAuth.ts", ["services/api/*"]));

  // Each real rule must fire on a fixture that breaks it.
  const ios = (pushBranch = true, pushPaths = IOS_REQUIRED_PATHS, prPaths = IOS_REQUIRED_PATHS, cron = "23 1 * * 1") =>
    "on:\n  push:" +
    (pushBranch ? "\n    branches: [main]" : "") +
    "\n    paths:\n" + pushPaths.map((p) => `      - '${p}'`).join("\n") +
    "\n  pull_request:\n    paths:\n" + prPaths.map((p) => `      - '${p}'`).join("\n") +
    "\n  schedule:\n    - cron: '" + cron + "'\n  workflow_dispatch:\n";
  const suite = (cron = "11 2 * * 1") => "on:\n  schedule:\n    - cron: \"" + cron + "\"\n  workflow_dispatch:\n";
  const suiteMulti = (crons) => "on:\n  schedule:\n" + crons.map((c) => `    - cron: "${c}"`).join("\n") + "\n  workflow_dispatch:\n";
  const concurrencyTrue = "concurrency:\n  group: x\n  cancel-in-progress: true\n";
  const concurrencyFalse = "concurrency:\n  group: x\n  cancel-in-progress: false\n";
  const concurrencyCommented = "concurrency:\n  group: x\n  # cancel-in-progress: true\n";
  const ca = (setupGradle = true) =>
    "jobs:\n  x:\n    steps:\n      - uses: actions/setup-java@v4\n        with:\n          distribution: temurin\n          java-version: \"17\"" +
    (setupGradle ? "\n      - uses: gradle/actions/setup-gradle@ed408507eac070d1f99cc633dbcf757c94c7933a # v4.4.3" : "") + "\n";

  const withCancel = (s) => s + "\n" + concurrencyTrue;
  const good = () => {
    const m = new Map();
    m.set(IOS, withCancel(ios()));
    for (const f of WEEKLY_0211) {
      if (f === "child-android.yml") continue;
      m.set(`.github/workflows/${f}`, withCancel(suite()));
    }
    m.set(".github/workflows/ci.yml", concurrencyTrue);
    m.set(".github/workflows/child-android.yml", withCancel(suite()) + "\n" + ca());
    return m;
  };
  const read = (m) => (p) => m.get(p) ?? "";

  expect("a compliant fixture passes", check(read(good())).length === 0);

  const noBranch = good(); noBranch.set(IOS, withCancel(ios(false)));
  expect("a missing push branches: [main] fails", check(read(noBranch)).some((p) => p.includes("branches: [main]")));

  const wrongPaths = good(); wrongPaths.set(IOS, withCancel(ios(true, IOS_REQUIRED_PATHS.slice(0, 5))));
  expect("a missing iOS path fails", check(read(wrongPaths)).some((p) => p.includes("exact required set")));

  const wrongCron = good(); wrongCron.set(".github/workflows/api.yml", withCancel(suite("11 2 * * *")));
  expect("a daily schedule fails", check(read(wrongCron)).some((p) => p.includes("weekly Monday 02:11")));

  const weeklyPlusDaily = good(); weeklyPlusDaily.set(".github/workflows/api.yml", withCancel(suiteMulti(["11 2 * * 1", "11 2 * * *"])));
  expect("a weekly schedule with a re-added daily cron fails", check(read(weeklyPlusDaily)).some((p) => p.includes("exactly one weekly Monday 02:11")));

  const wrongIosCron = good(); wrongIosCron.set(IOS, withCancel(ios(true, IOS_REQUIRED_PATHS, IOS_REQUIRED_PATHS, "23 1 * * *")));
  expect("a daily iOS schedule fails", check(read(wrongIosCron)).some((p) => p.includes("weekly Monday 01:23")));

  const iosWeeklyPlusDaily = good();
  iosWeeklyPlusDaily.set(IOS, withCancel(ios().replace("  workflow_dispatch:", "    - cron: '23 1 * * *'\n  workflow_dispatch:")));
  expect("an iOS weekly schedule with a re-added daily cron fails", check(read(iosWeeklyPlusDaily)).some((p) => p.includes("exactly one weekly Monday 01:23")));

  const noCancel = good(); noCancel.set(".github/workflows/ci.yml", concurrencyFalse);
  expect("a suite without cancel-in-progress fails", check(read(noCancel)).some((p) => p.includes("cancel-in-progress is not true")));

  const commentedCancel = good(); commentedCancel.set(".github/workflows/ci.yml", concurrencyCommented);
  expect("a commented-out cancel-in-progress: true fails", check(read(commentedCancel)).some((p) => p.includes("cancel-in-progress is not true")));

  const noGradle = good(); noGradle.set(".github/workflows/child-android.yml", withCancel(suite()) + "\n" + ca(false));
  expect("a missing setup-gradle fails", check(read(noGradle)).some((p) => p.includes("setup-gradle is missing")));

  const unpinnedGradle = good(); unpinnedGradle.set(".github/workflows/child-android.yml", withCancel(suite()) + "\n" + ca().replace("ed408507eac070d1f99cc633dbcf757c94c7933a # v4.4.3", "v4"));
  expect("an unpinned setup-gradle tag fails", check(read(unpinnedGradle)).some((p) => p.includes("40-character commit SHA")));

  console.log(`ci-cost-guardrails self-test: ${total - bad}/${total} cases`);
  process.exit(bad ? 1 : 0);
}

if (process.argv.includes("--selftest")) selftest();
else runRepo();
