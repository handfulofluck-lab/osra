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
import fs from "node:fs";
import os from "node:os";
import pathMod from "node:path";

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf(name);
  return i === -1 ? fallback : argv[i + 1];
};
const title = flag("--title", "");
const base = flag("--base", "origin/main");
const head = flag("--head", "HEAD");
const quiet = argv.includes("--quiet");
const repo = flag("--repo", null); // run git in another checkout (used by the synthetic self-test)

const DOC_PREFIXES = ["docs/", "CHANGELOG.md", "README.md", "AGENTS.md", "LICENSE"];
const CI_PREFIXES = [".github/", "scripts/"];

function changedFiles() {
  let out;
  try {
    out = execFileSync("git", ["diff", "--name-status", `${base}...${head}`], { encoding: "utf8", cwd: repo ?? undefined });
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
  // A durable fixture: the earlier version of this self-test pointed at two commits on a
  // force-pushed branch, which CI's fetch never sees (exit 2 "cannot compute the diff"). This repo
  // is built in a temp dir, so the case exists wherever the check runs.
  const FIXTURE = (() => {
    const dir = fs.mkdtempSync(pathMod.join(os.tmpdir(), "scope-fixture-"));
    const g = (...args) => execFileSync("git", args, { cwd: dir, stdio: "pipe" });
    g("init", "-q", "-b", "main");
    g("config", "user.email", "fixture@local");
    g("config", "user.name", "fixture");
    fs.writeFileSync(pathMod.join(dir, "a.txt"), "v1");
    g("add", "."); g("commit", "-qm", "A");
    fs.writeFileSync(pathMod.join(dir, "a.txt"), "v2");
    g("add", "."); g("commit", "-qm", "B");
    g("checkout", "-qb", "feat");
    fs.writeFileSync(pathMod.join(dir, "a.txt"), "v3");   // the merge itself changes a.txt
    fs.writeFileSync(pathMod.join(dir, "b.txt"), "x");
    g("add", "."); g("commit", "-qm", "C");
    g("checkout", "-q", "main");
    g("merge", "-q", "--no-ff", "feat", "-m", "merge feature");
    g("checkout", "-qb", "pr");
    fs.writeFileSync(pathMod.join(dir, "a.txt"), "v2"); // restores the PRE-merge value of a.txt
    g("add", "."); g("commit", "-qm", "R");
    return { dir };
  })();

  const cases = [
    { name: "docs PR with a docs diff passes", args: ["--title", "docs(x): fixture", "--base", "dd84bc0^", "--head", "dd84bc0", "--quiet"], want: 0 },
    { name: "docs title over a code diff fails", args: ["--title", "docs(x): fixture", "--base", "0530fdf^", "--head", "0530fdf", "--quiet"], want: 1 },
    { name: "a revert-by-value PR fails under a fix(…) title", args: ["--title", "fix(x): fixture", "--base", "main", "--head", "pr", "--repo", FIXTURE.dir, "--quiet"], want: 1 },
    { name: "the same PR passes under a revert(…) title", args: ["--title", "revert(x): fixture", "--base", "main", "--head", "pr", "--repo", FIXTURE.dir, "--quiet"], want: 0 },
    { name: "an unconventional title is refused", args: ["--title", "tidy up things", "--base", "origin/main", "--head", "HEAD", "--quiet"], want: 1 },
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

if (declared === null && !/^revert/i.test(title.trim())) {
  problems.push(`title "${title}" does not declare a kind — use docs(…), ci(…), feat(…), fix(…), test(…), refactor(…), perf(…) or revert(…)`);
}

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

// A code-titled PR can still be a stale-base revert: the dead giveaway is that its blob for a path
// equals the *pre-merge* blob of a recent merge on main, i.e. it puts back what that merge changed.
// Claude asked for this after the #220 near-miss; it is the half the title check cannot see.
const REVERSE_WINDOW = 30;
const isRevertTitle = /^revert/i.test(title.trim());
const blobAt = (rev, path) => {
  try {
    return execFileSync("git", ["rev-parse", `${rev}:${path}`], { encoding: "utf8", cwd: repo ?? undefined, stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null; // missing path counts as a blob
  }
};
if (!isRevertTitle) {
  let merges = [];
  try {
    merges = execFileSync("git", ["log", "--first-parent", "-n", String(REVERSE_WINDOW), "--format=%H", base], { encoding: "utf8", cwd: repo ?? undefined })
      .split(String.fromCharCode(10))
      .filter(Boolean);
  } catch {
    merges = [];
  }
  for (const m of merges) {
    let changed = [];
    try {
      changed = execFileSync("git", ["diff", "--name-only", `${m}^1`, m], { encoding: "utf8", cwd: repo ?? undefined }).split(String.fromCharCode(10)).filter(Boolean);
    } catch {
      continue;
    }
    for (const path of changed) {
      const preMerge = blobAt(`${m}^1`, path);   // null = absent before the merge
      const mergedIn = blobAt(m, path);          // null = absent after it
      const baseBlob = blobAt(base, path);
      const headBlob = blobAt(head, path);
      // The PR puts the path back exactly as it was before the merge, while main still carries the
      // merged version. Works for additions (preMerge null, head null) and deletions/renames alike.
      const undoes = headBlob === preMerge && baseBlob === mergedIn && preMerge !== mergedIn;
      if (undoes) {
        problems.push(`${path}: this PR restores the pre-merge state of ${m.slice(0, 7)} (title declares "${title}") — a revert needs a revert(…) title`);
        break;
      }
    }
  }
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
