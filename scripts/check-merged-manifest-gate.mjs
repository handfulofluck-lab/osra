#!/usr/bin/env node
/**
 * Fails unless ADR-0021's merged-manifest gate actually ran — every test, in both flavours and both
 * build types, none skipped.
 *
 * Why this exists. The gate (`PlayMergedManifestTest`, `FullMergedManifestTest` in
 * `apps/child-android/app/src/test/java/com/familyshield/agent/manifest/`) reads the manifest AGP
 * produced after merging, because that is where a dependency's `READ_SMS` or notification listener
 * appears. If the artefact is absent it skips with a loud message rather than failing — the right call
 * for an IDE run, and exactly the shape of a silent hole in CI. So CI runs this script as its own step:
 *
 *   - a missing results directory means the unit-test task did not run → fail;
 *   - a skipped or failed gate test → fail;
 *   - a gate test that is gone from the report → fail. Deleting an assertion is how a gate is weakened
 *     without a diff that says so (AGENTS.md §4), and the expected names are listed below for that
 *     reason. Adding a test is free; removing or renaming one means editing this list in the same PR,
 *     which is the sentence of justification the rule asks for.
 *
 * Issue #170 added the second artefact and the second half of this gate: the debug merged manifest must
 * declare `android:testOnly="true"` (so `dpm remove-active-admin` works for a runner without the app
 * PIN) and the **release** merged manifest must not declare it at all (`testOnly` makes an APK
 * replaceable). `build.gradle.kts` makes the unit-test tasks depend on
 * `process<Flavor>{Debug,Release}Manifest`, so the release artefact exists on a Gradle run; if it is
 * nonetheless missing, the test skips and this script fails on that skip rather than passing silently.
 *
 * The class and method names are exact: JUnit reports the backticked Kotlin names verbatim.
 *
 * Usage (from anywhere; paths resolve from the repository root):
 *   node scripts/check-merged-manifest-gate.mjs
 *   node scripts/check-merged-manifest-gate.mjs --results apps/child-android/app/build/test-results/testPlayDebugUnitTest
 *
 * Exits 1 on any missing, skipped, failed or renamed gate test.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CHILD = "apps/child-android/app/build/test-results";

const EXPECTED = {
  "com.familyshield.agent.manifest.PlayMergedManifestTest": [
    "play merged manifest declares exactly the reviewed permission allow-list",
    "play merged manifest declares none of the Play-forbidden permissions",
    "play merged manifest registers no notification, call-log or SMS component",
    "play merged manifest keeps isMonitoringTool and the required queries",
    "play merged manifest declares the renamed device-admin receiver",
    "play debug merged manifest is testOnly so the test admin is removable",
    "play release merged manifest is not testOnly",
  ],
  "com.familyshield.agent.manifest.FullMergedManifestTest": [
    "full merged manifest keeps the capture permissions and the listener service",
    "full merged manifest keeps isMonitoringTool and the required queries",
    "full merged manifest declares the renamed device-admin receiver",
    "full debug merged manifest is testOnly so the test admin is removable",
    "full release merged manifest is not testOnly",
  ],
};

function parseArgs(argv) {
  const results = [];
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--results") {
      const value = argv[i + 1];
      if (!value) throw new Error("--results needs a directory");
      results.push(resolve(ROOT, value));
      i += 1;
    } else if (argv[i] === "--help" || argv[i] === "-h") {
      console.log("usage: node scripts/check-merged-manifest-gate.mjs [--results <dir>]...");
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${argv[i]}`);
    }
  }
  return results.length > 0 ? results : [join(CHILD, "testPlayDebugUnitTest"), join(CHILD, "testFullDebugUnitTest")];
}

function suiteAttributes(tag) {
  const attributes = {};
  for (const match of tag.matchAll(/([A-Za-z_][\w.-]*)="([^"]*)"/g)) attributes[match[1]] = match[2];
  return attributes;
}

function parseCases(xml) {
  return xml
    .split("<testcase")
    .slice(1)
    .map((chunk) => {
      const head = chunk.slice(0, chunk.indexOf(">") + 1);
      const body = head.endsWith("/>") ? "" : chunk.slice(head.length);
      const end = body.indexOf("</testcase>");
      const content = end >= 0 ? body.slice(0, end) : body;
      return {
        name: /name="([^"]*)"/.exec(head)?.[1] ?? "<unnamed>",
        skipped: /<skipped\b/.test(content),
        failed: /<(failure|error)\b/.test(content),
      };
    });
}

function checkResultsDir(dir, problems) {
  const relative = dir.startsWith(ROOT) ? dir.slice(ROOT.length + 1) : dir;
  if (!existsSync(dir)) {
    problems.push(`${relative}: no test results — did the unit-test task run?`);
    return [];
  }

  const notes = [];
  for (const [className, expectedNames] of Object.entries(EXPECTED)) {
    const file = join(dir, `TEST-${className}.xml`);
    if (!existsSync(file)) {
      problems.push(`${relative}: ${className} did not run (no TEST-${className}.xml)`);
      continue;
    }
    const xml = readFileSync(file, "utf8");
    const suiteTag = /<testsuite\b[^>]*>/.exec(xml)?.[0] ?? "";
    const suite = suiteAttributes(suiteTag);
    const cases = parseCases(xml);

    for (const attribute of ["tests", "skipped", "failures", "errors"]) {
      if (suite[attribute] === undefined) problems.push(`${className}: report has no "${attribute}" attribute`);
    }
    if (Number(suite.tests ?? 0) < expectedNames.length) {
      problems.push(`${className}: report lists ${suite.tests ?? 0} tests, expected at least ${expectedNames.length}`);
    }
    if (Number(suite.skipped ?? 0) !== 0) {
      const names = cases.filter((c) => c.skipped).map((c) => c.name);
      problems.push(`${className}: ${suite.skipped} skipped — the gate reads a build artefact it could not find: ${names.join(", ")}`);
    }
    if (Number(suite.failures ?? 0) !== 0 || Number(suite.errors ?? 0) !== 0) {
      problems.push(`${className}: ${suite.failures ?? 0} failures, ${suite.errors ?? 0} errors`);
    }

    for (const name of expectedNames) {
      const matches = cases.filter((c) => c.name === name);
      if (matches.length === 0) {
        problems.push(`${className}: assertion "${name}" is missing from the report (deleted or renamed?)`);
      } else if (matches.some((c) => c.skipped)) {
        problems.push(`${className}: assertion "${name}" was skipped`);
      } else if (matches.some((c) => c.failed)) {
        problems.push(`${className}: assertion "${name}" failed`);
      }
    }
    notes.push(`${className}: ${suite.tests ?? "?"} tests, ${suite.skipped ?? "?"} skipped, ${suite.failures ?? "?"} failed`);
  }
  return notes.map((note) => `${relative}: ${note}`);
}

let results;
try {
  results = parseArgs(process.argv.slice(2));
} catch (error) {
  console.error(`check-merged-manifest-gate: ${error.message}`);
  process.exit(1);
}

const problems = [];
const notes = [];
for (const dir of results) notes.push(...checkResultsDir(dir, problems));

for (const note of notes) console.log(`  ${note}`);
if (problems.length > 0) {
  console.error(`\nMERGED-MANIFEST GATE FAILED (${problems.length}):`);
  for (const problem of problems) console.error(`  - ${problem}`);
  console.error(
    "\nThe gate must run and pass: `cd apps/child-android && ./gradlew testPlayDebugUnitTest testFullDebugUnitTest` " +
      "(it also merges the Play/Full release manifests for the testOnly-absence assertions).",
  );
  process.exit(1);
}

console.log(`merged-manifest gate: ${results.length} result set(s) checked, all assertions ran and passed`);
