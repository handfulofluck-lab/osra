#!/usr/bin/env node
/**
 * CI gate: a PR that changes code must carry a changelog fragment.
 *
 * The rule this enforces is `AGENTS.md` §8 — every user-visible change is documented in the same PR — but
 * the *mechanism* changed on 2026-10-21: entries go in `CHANGELOG.d/<date>-<slug>.md` instead of the single
 * `[Unreleased]` block, because that block made every open PR conflict with every other one.
 *
 * What counts as needing a fragment: any change under `apps/`, `services/`, `scripts/`, `infra/` or
 * `.github/workflows/`. A PR that only touches Markdown (`docs/`, `*.md`) does not — a documentation sweep
 * is its own record, and demanding a changelog entry for a changelog fix is how a rule gets ignored.
 *
 *   node scripts/check-changelog-fragment.mjs --base origin/main
 *
 * Exits 1 with the exact remedy, because "add a fragment" is cheap and a red gate nobody understands is not.
 */

import { execFileSync } from "node:child_process";

const args = process.argv.slice(2);
const baseIndex = args.indexOf("--base");
const base = baseIndex >= 0 ? args[baseIndex + 1] : "origin/main";

function git(...gitArgs) {
  return execFileSync("git", gitArgs, { encoding: "utf8" }).trim();
}

let changed;
try {
  changed = git("diff", "--name-only", "--diff-filter=d", `${base}...HEAD`).split("\n").filter(Boolean);
} catch (error) {
  console.error(`could not diff against ${base}: ${error.message}`);
  process.exit(1);
}

if (changed.length === 0) {
  console.log(`no files changed against ${base}`);
  process.exit(0);
}

const codePath = /^(apps|services|scripts|infra)\/|^\.github\/workflows\//;
const needsFragment = changed.some((path) => codePath.test(path));
const fragment = changed.find((path) => path.startsWith("CHANGELOG.d/") && path.endsWith(".md") && !path.endsWith("README.md"));
// A revert carries nothing else, and a release commit assembles the fragments — both are named in
// AGENTS.md rather than inferred, so they may skip.
const title = process.env.PR_TITLE || "";
const exempt = /^revert[(:]/i.test(title) || /\bassemble\b/i.test(title);

if (!needsFragment || fragment || exempt) {
  if (fragment) console.log(`changelog fragment: ${fragment}`);
  else if (exempt) console.log("exempt: revert or changelog assembly");
  else console.log("no code paths changed; no fragment required");
  process.exit(0);
}

console.error("This PR changes code but adds no changelog fragment.");
console.error("");
console.error("Create CHANGELOG.d/<YYYY-MM-DD>-<slug>.md containing the entry verbatim — heading, bullets");
console.error("and all — for example:");
console.error("");
console.error("  ### Parent app — the digest preferences screen speaks Arabic (#277)");
console.error("  - 27 ARB keys cover every string on the screen …");
console.error("");
console.error("Why a file and not the [Unreleased] block: every PR used to edit that block, so merges conflicted");
console.error("with every open PR and cost re-signatures. `node scripts/assemble-changelog.mjs` folds fragments");
console.error("into CHANGELOG.md. See CHANGELOG.d/README.md.");
process.exit(1);
