#!/usr/bin/env node
/**
 * The build-and-test workflows run only when their `paths:` change (2026-10-24, docs/TESTING.md §4). A path
 * list that misses one of a suite's inputs is a suite that silently stops running on exactly the PRs that can
 * break it, so this checks, for every suite workflow:
 *
 *   1. its `push` and `pull_request` path lists are the same list (a fix to one that misses the other is the
 *      usual way they drift);
 *   2. the list names the workflow file itself (a PR that edits the suite must run the suite);
 *   3. every repository file the workflow names outside its `on:` block (a `node scripts/…` step, a
 *      Dockerfile, a script it runs) is covered by the list;
 *   4. every file outside a suite's own folder that one of its tests reads through a `../` string literal is
 *      covered: the API tests (relative to the test file; device-silence.test.ts reads two agent files), the
 *      parent app's (relative to apps/parent-app, where `flutter test` runs; #344's alert-category parity test
 *      reads services/api/src/routes/alerts.ts) and the Android unit tests (relative to the Gradle module).
 *      The desktop agent's and the AI engine's tests read nothing outside their folders today;
 *   5. for `api-image.yml`: every source the API Dockerfile COPYs from the build context is covered.
 *
 * Usage: node scripts/check-ci-paths.mjs [--selftest]
 * Exit 0: every rule holds. Exit 1: a rule failed (each failure is printed). Exit 2: a suite file is missing.
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SUITES = ["api.yml", "parent-app.yml", "child-android.yml", "agent-desktop.yml", "ai-engine.yml", "api-image.yml"];
const REPO_TOKEN = /(?:^|[\s"'=(])((?:\.github|apps|packages|scripts|services)\/[A-Za-z0-9_.\/-]*[A-Za-z0-9_])/g;

/** `paths:` lists under each event of the `on:` block, by event name. Only the shape these files use. */
export function parsePaths(text) {
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

const globToRegex = (glob) =>
  new RegExp("^" + glob.split("**").map((part) => part.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*")).join(".*") + "$");

/** Is a repository path (file or directory) covered by any of the globs? A directory is covered by `dir/**`. */
export function covered(path, globs) {
  return globs.some((g) => globToRegex(g).test(path) || globToRegex(g).test(`${path}/x`));
}

/** Repository paths the workflow names outside its `on:` block (comments excluded), that exist. */
export function namedPaths(text, exists) {
  const found = new Set();
  let inOn = false;
  for (const line of text.split(/\r?\n/)) {
    if (/^on:\s*$/.test(line)) { inOn = true; continue; }
    if (inOn && /^\S/.test(line)) inOn = false;
    if (inOn || /^\s*#/.test(line)) continue;
    const code = line.replace(/\s#\s.*$/, "");
    for (const m of code.matchAll(REPO_TOKEN)) if (exists(m[1])) found.add(m[1]);
  }
  return [...found];
}

/** Where each suite's tests live, what a relative path in them is relative to, and the suite's own folder. */
const TEST_READS = {
  "api.yml": { dir: "services/api/test", ext: /\.(ts|mts|js|mjs)$/, base: null, home: "services/api/" },
  "parent-app.yml": { dir: "apps/parent-app/test", ext: /\.dart$/, base: "apps/parent-app", home: "apps/parent-app/" },
  "child-android.yml": { dir: "apps/child-android/app/src/test", ext: /\.(kt|java)$/, base: "apps/child-android/app", home: "apps/child-android/" },
};

/**
 * Files outside `home` that a suite's tests name with a relative string literal (`"../../../apps/…"`).
 * `base` is the directory the path is resolved against; null means the test file's own directory
 * (`new URL(…, import.meta.url)`). Every literal that starts with `../` counts, not only one written at the
 * call that opens it: device-silence.test.ts passes its paths through a `read(relative)` helper, and a
 * call-site-only match saw none of them. Dart `import`/`export`/`part` lines are resolved by the compiler, not
 * the test, so they are skipped.
 */
export function testReads(files, { base = null, home }) {
  const out = new Set();
  for (const [file, text] of files) {
    for (const line of text.split(/\r?\n/)) {
      if (/^\s*(?:import|export|part)\s/.test(line)) continue;
      for (const m of line.matchAll(/["'`]((?:\.\.\/)+[^"'`\s$]+)["'`]/g)) {
        const target = join(base ?? dirname(file), m[1]).replace(/\\/g, "/");
        if (!target.startsWith(home)) out.add(target);
      }
    }
  }
  return [...out];
}

/** Build-context sources the Dockerfile COPYs (not `--from=` stages). */
export function dockerCopySources(text) {
  const out = [];
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*(?:COPY|ADD)\s+(.*)$/i);
    if (!m || /--from=/.test(m[1])) continue;
    const parts = m[1].replace(/--[a-z]+=\S+/g, "").trim().split(/\s+/);
    for (const src of parts.slice(0, -1)) out.push(src.replace(/^\.\//, "").replace(/\/$/, ""));
  }
  return out;
}

/** Every rule for one suite; returns the list of failures. */
export function checkSuite(name, text, { exists, testReads: reads = [], copySources = [] }) {
  const problems = [];
  const lists = parsePaths(text);
  const events = Object.keys(lists);
  if (!lists.pull_request) problems.push(`${name}: no pull_request paths list (a suite here runs on its paths, or belongs in ci.yml)`);
  if (lists.push && lists.pull_request) {
    const a = [...lists.push].sort().join("\n"), b = [...lists.pull_request].sort().join("\n");
    if (a !== b) problems.push(`${name}: push and pull_request path lists differ`);
  }
  const globs = [...new Set(events.flatMap((e) => lists[e]))];
  if (!globs.includes(`.github/workflows/${name}`)) problems.push(`${name}: its paths do not include .github/workflows/${name}`);
  for (const p of namedPaths(text, exists)) if (!covered(p, globs)) problems.push(`${name}: names ${p} but its paths do not cover it`);
  for (const p of reads) if (!covered(p, globs)) problems.push(`${name}: a test reads ${p} but its paths do not cover it`);
  for (const p of copySources) if (p !== "." && !covered(p, globs)) problems.push(`${name}: the Dockerfile copies ${p} but its paths do not cover it`);
  return problems;
}

function walk(dir, ext) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...walk(full, ext));
    else if (ext.test(entry)) out.push(full);
  }
  return out;
}

function runRepo() {
  const exists = (p) => existsSync(join(ROOT, p));
  const reads = {};
  for (const [name, scan] of Object.entries(TEST_READS)) {
    const files = walk(join(ROOT, scan.dir), scan.ext).map((f) => [relative(ROOT, f).replace(/\\/g, "/"), readFileSync(f, "utf8")]);
    reads[name] = testReads(files, scan);
  }
  const copySources = dockerCopySources(readFileSync(join(ROOT, "services/api/Dockerfile"), "utf8"));
  const problems = [];
  for (const name of SUITES) {
    const path = join(ROOT, ".github/workflows", name);
    if (!existsSync(path)) { console.log(`ERROR ${name}: missing`); process.exit(2); }
    problems.push(...checkSuite(name, readFileSync(path, "utf8"), {
      exists,
      testReads: reads[name] ?? [],
      copySources: name === "api-image.yml" ? copySources : [],
    }));
  }
  for (const p of problems) console.log(`ERROR ${p}`);
  const readCount = Object.values(reads).reduce((n, r) => n + r.length, 0);
  console.log(`ci-paths: ${SUITES.length} suite workflow(s), ${readCount} test read(s) outside a suite's folder, ${copySources.length} Dockerfile source(s); ${problems.length} problem(s)`);
  process.exit(problems.length ? 1 : 0);
}

function selftest() {
  const files = new Set(["scripts/gate.mjs", "services/api/Dockerfile", "apps/agent/Pin.kt"]);
  const exists = (p) => files.has(p) || [...files].some((f) => f.startsWith(`${p}/`));
  const wf = (pushList, prList, body = "") => [
    "name: X", "on:", "  push:", "    branches: [main]", "    paths:", ...pushList.map((p) => `      - "${p}"`),
    "  pull_request:", "    paths:", ...prList.map((p) => `      - "${p}"`), "jobs:", "  x:", "    runs-on: ubuntu-latest", "    steps:", body,
  ].join("\n");
  const good = ["services/api/**", "scripts/gate.mjs", "apps/agent/Pin.kt", ".github/workflows/x.yml"];
  const cases = [
    { name: "a consistent suite passes", text: wf(good, good, "      - run: node scripts/gate.mjs"), opts: { testReads: ["apps/agent/Pin.kt"], copySources: ["services/api"] }, want: 0 },
    { name: "push and pull_request lists that differ fail", text: wf(good, good.slice(1)), opts: {}, want: 1 },
    { name: "a list without its own workflow file fails", text: wf(good.slice(0, 3), good.slice(0, 3)), opts: {}, want: 1 },
    { name: "a `node scripts/…` step outside the list fails", text: wf(good.slice(0, 1).concat(good[3]), good.slice(0, 1).concat(good[3]), "      - run: node scripts/gate.mjs"), opts: {}, want: 1 },
    { name: "a test read outside the list fails", text: wf(good.filter((g) => g !== "apps/agent/Pin.kt"), good.filter((g) => g !== "apps/agent/Pin.kt")), opts: { testReads: ["apps/agent/Pin.kt"] }, want: 1 },
    { name: "a Dockerfile source outside the list fails", text: wf(good, good), opts: { copySources: ["packages"] }, want: 1 },
    { name: "a comment naming a path is not a use of it", text: wf(good.slice(0, 1).concat(good[3]), good.slice(0, 1).concat(good[3]), "      # node scripts/gate.mjs"), opts: {}, want: 0 },
  ];
  const reads = testReads([
    ["services/api/test/a.test.ts", 'readFileSync(new URL("../../../apps/agent/Pin.kt", import.meta.url)); read("../src/inside.ts")'],
    ["services/api/test/b.test.ts", 'const read = (r) => readFileSync(new URL(r, import.meta.url)); read("../../../apps/agent/Other.kt")'],
  ], { home: "services/api/" });
  const dartReads = testReads([
    ["apps/parent-app/test/deep/x_test.dart", "import '../fake_api_client.dart';\nfinal s = File('../../services/api/src/routes/alerts.ts').readAsStringSync();"],
  ], { base: "apps/parent-app", home: "apps/parent-app/" });
  const copies = dockerCopySources("COPY package.json pnpm-lock.yaml ./\nCOPY packages/ ./packages/\nCOPY --from=build /app/x ./x");
  let bad = 0;
  for (const c of cases) {
    const got = checkSuite("x.yml", c.text, { exists, ...c.opts }).length ? 1 : 0;
    if (got !== c.want) bad += 1;
    console.log(`${got === c.want ? "PASS" : "FAIL"}  ${c.name}`);
  }
  const parsed = [
    ["an API test's \"../../../…\" literal resolves to the repository path, through a helper too, and an inside path is ignored", reads.sort().join() === "apps/agent/Other.kt,apps/agent/Pin.kt"],
    ["a Dart test's path resolves from the package root, not the file, and a relative import is not a read", dartReads.join() === "services/api/src/routes/alerts.ts"],
    ["COPY sources come from the build context, never from a --from stage", copies.join() === "package.json,pnpm-lock.yaml,packages"],
  ];
  for (const [name, ok] of parsed) { if (!ok) bad += 1; console.log(`${ok ? "PASS" : "FAIL"}  ${name}`); }
  console.log(`ci-paths self-test: ${cases.length + parsed.length - bad}/${cases.length + parsed.length} cases`);
  process.exit(bad ? 1 : 0);
}

if (process.argv.includes("--selftest")) selftest();
else runRepo();
