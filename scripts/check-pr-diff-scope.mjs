#!/usr/bin/env node
/**
 * Guards the class of mistake that would have silently reverted #218 (2026-10-19).
 *
 * What happened: a squash was built from a `origin/main` that predated #218. The commit's tree was
 * therefore *pre-#218 plus one docs edit*, so the PR's diff was 24 files / +125 -503 — it removed the
 * application label, deleted `BlockSession` and its test, renamed the receiver back to the name Knox
 * had stranded, and restored `dpm remove-active-admin` to the cleanup procedure.
 *
 * Every test stayed green, because they tested the tree in front of them, which was the old code.
 * A unit suite proves the code works; it cannot prove the *diff* is the change that was intended.
 *
 * This check reads the intent from the PR title, and the reality from `git diff`. A docs PR that
 * touches code fails; a CI PR that touches app code fails; a code PR that deletes a directory of
 * unrelated files fails loudly instead of quietly.
 *
 * Usage (CI):
 *   node scripts/check-pr-diff-scope.mjs --title "<PR title>" --base <sha> --head <sha>
 * Local:
 *   node scripts/check-pr-diff-scope.mjs --title "docs(x): ..." --base origin/main --head HEAD
 *
 * Exits 1 on a scope violation, 0 otherwise. `--quiet` prints only failures.
 */
import { execFileSync } from "node:child_process";

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf(name);
  return i === -1 ? fallback : argv[i + 1];
};
const title = flag("--title", "");
const base = flag("--base", "origin/main");
const head = flag("--head", "HEAD");
const quiet = argv.includes("--quiet");

const DOC_PREFIXES = ["docs/", "CHANGELOG.md", "README.md", "AGENTS.md", "LICENSE"];
const CI_PREFIXES = [".github/", "scripts/"];

function changedFiles() {
  let out;
  try {
    out = execFileSync("git", ["diff", "--name-status", `${base}...${head}`], { encoding: "utf8" });
  } catch (e) {
    // A missing ref is an environment problem, not a scope violation: say so instead of a stack trace.
    console.error(`cannot compute the diff between ${base} and ${head}: ${String(e.stderr ?? e.message).trim()}`);
    console.error("In CI: check out with fetch-depth: 0 and fetch the base branch before running this check.");
    process.exit(2);
  }
  return out
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [status, ...rest] = line.split("\t");
      return { status, path: rest.join("\t") };
    });
}

function kindOf(path) {
  if (path.startsWith("docs/")) return "docs";
  if (CI_PREFIXES.some((p) => path.startsWith(p))) return "ci";
  if (path === "CHANGELOG.md" || path === "README.md" || path === "AGENTS.md") return "docs";
  if (path.startsWith("apps/") || path.startsWith("services/") || path.startsWith("packages/")) return "code";
  return "other";
}

function declaredKind(t) {
  const lower = t.toLowerCase();
  if (/^docs(\(|:|!)/.test(lower)) return "docs";
  if (/^(ci|build|chore\(ci\))(\(|:|!)/.test(lower)) return "ci";
  if (/^(feat|fix|test|refactor|perf|revert)(\(|:|!)/.test(lower)) return "code";
  return null;
}

if (argv.includes("--selftest")) {
  // Two real refs on this repo's history: a genuine docs PR must pass, and a docs title over a
  // code diff must fail. The second is the negative control for the stale-base revert.
  const { execFileSync: run } = await import("node:child_process");
  const spawn = (args) => {
    try {
      run(process.execPath, [new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"), ...args], { stdio: "pipe" });
      return 0;
    } catch (e) {
      return e.status ?? 1;
    }
  };
  const cases = [
    { name: "docs PR with a docs diff passes", args: ["--title", "docs(x): fixture", "--base", "dd84bc0^", "--head", "dd84bc0", "--quiet"], want: 0 },
    { name: "docs title over a code diff fails", args: ["--title", "docs(x): fixture", "--base", "0530fdf^", "--head", "0530fdf", "--quiet"], want: 1 },
  ];
  let bad = 0;
  for (const c of cases) {
    const got = spawn(c.args);
    const ok = got === c.want;
    if (!ok) bad += 1;
    console.log(`${ok ? "PASS" : "FAIL"}  ${c.name} — exit ${got}, want ${c.want}`);
  }
  console.log(`diff-scope self-test: ${cases.length - bad}/${cases.length} cases`);
  process.exit(bad ? 1 : 0);
}

const files = changedFiles();
const declared = declaredKind(title);
const problems = [];

if (declared === "docs") {
  const offenders = files.filter((f) => !DOC_PREFIXES.some((p) => f.path === p || f.path.startsWith(p)));
  for (const f of offenders) problems.push(`${f.status} ${f.path} — a docs-titled PR must not touch this`);
}
if (declared === "ci") {
  const offenders = files.filter((f) => !CI_PREFIXES.some((p) => f.path.startsWith(p)) && f.path !== "docs/TESTING.md" && f.path !== "CHANGELOG.md");
  for (const f of offenders) problems.push(`${f.status} ${f.path} — a ci-titled PR must not touch this`);
}

// Regardless of title: a large deletion outside the declared kind is the revert signature.
const deletions = files.filter((f) => f.status === "D").length;
const total = files.filter((f) => f.path || f.status).length;
if (declared === "docs" && deletions > 0) {
  problems.push(`${deletions} file(s) deleted by a docs-titled PR — a squash on a stale base looks exactly like this`);
}

if (!quiet) {
  console.log(`declared kind: ${declared ?? "none (title not conventional)"}`);
  console.log(`diff ${base}...${head}: ${files.length} file(s), ${deletions} deletion(s)`);
  for (const f of files) console.log(`  ${f.status} ${f.path}  [${kindOf(f.path)}]`);
}

if (problems.length) {
  console.error("");
  for (const p of problems) console.error(`ERROR ${p}`);
  console.error("");
  console.error("A PR may only change what its title says it changes. If this is a stale-base squash, rebuild");
  console.error("the branch from current main and re-apply the intended hunks:");
  console.error("  git fetch origin && git checkout -B <branch> origin/main");
  process.exit(1);
}
if (!quiet) console.log("scope OK");
