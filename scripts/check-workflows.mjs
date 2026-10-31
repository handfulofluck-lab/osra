#!/usr/bin/env node
/**
 * Validates .github/workflows/*.yml against the GitHub Actions schema traps that YAML parsers
 * accept but GitHub rejects, plus gates that cannot fail.
 *
 * Why this exists: on 2026-10-13 `ci.yml` was pushed with a step containing BOTH `uses:` and
 * `run:`. PyYAML parsed it happily; GitHub rejected the whole file, so **every job was skipped**
 * and `main` had no CI signal at all for a day (issue #37). This script is the cheap local check
 * that catches that class before it reaches the remote.
 *
 * Errors (exit 1):
 *   - a step with both `uses:` and `run:`   (GitHub: "Unexpected value 'run'")
 *   - a step with `with:` but no `uses:`    (GitHub: "Unexpected value 'with'")
 *   - a job without `runs-on:`
 *   - a tab character in the file (YAML forbids tabs for indentation)
 * Warnings (exit 0 unless --strict): a gate that cannot fail
 *   - `|| echo …`, `|| true` inside a run body, or `continue-on-error: true` on a step
 *   - `check && echo …` on any line of a run body but the last: bash exempts every command of an
 *     `&&` list but the final one from `-e`, so a failing check there never fails the step (#361)
 *   - `secrets.` inside an `if:` expression — the secrets context is not available there and
 *     GitHub rejects the whole file ("Unrecognized named-value: 'secrets'") → zero jobs run (PR #49)
 *
 * Usage: node scripts/check-workflows.mjs [--strict] [dir]
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const strict = args.includes("--strict");
const dir = args.find((a) => !a.startsWith("--")) ?? ".github/workflows";

const errors = [];
const warnings = [];

/** Collect the key lines of the step starting at `start` (whose dash is at `dashIndent`). */
function readStep(lines, start, dashIndent) {
  const stepIndent = dashIndent + 2; // step keys align after "- "
  const keys = [];
  let runBody = null;

  // The first line of a step carries a key too: "- uses: actions/checkout@v4" / "- run: …"
  const firstKey = (lines[start].match(/^\s*-\s*([A-Za-z0-9_-]+):/) || [])[1];
  if (firstKey) {
    keys.push(firstKey);
    if (firstKey === "run") runBody = [];
  }

  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === "") {
      if (runBody) runBody.push("");
      continue;
    }
    if (/^\s*#/.test(line)) {
      continue; // comments inside a run body are documentation, not executable code
    }
    const indent = line.match(/^ */)[0].length;
    if (indent < dashIndent) break; // dedented out of the step
    if (indent === dashIndent && /^\s*- /.test(line)) break; // next step
    if (indent === stepIndent) {
      const m = line.match(/^ *([A-Za-z0-9_-]+):(.*)$/);
      if (m) {
        keys.push(m[1]);
        runBody = m[1] === "run" ? [] : null;
        continue;
      }
    }
    if (runBody) runBody.push(line.trim());
  }
  return { keys, runBody };
}

for (const file of readdirSync(dir).filter((f) => /\.ya?ml$/.test(f)).sort()) {
  const path = join(dir, file);
  const text = readFileSync(path, "utf8");
  const lines = text.split(/\r?\n/);

  lines.forEach((line, idx) => {
    if (/^\s*\t/.test(line) || / \t/.test(line))
      errors.push(`${path}:${idx + 1} tab character in YAML (use spaces)`);
  });

  // ── jobs: every job needs runs-on (unless it only calls a reusable workflow) ──
  let inJobs = false;
  for (let i = 0; i < lines.length; i++) {
    if (/^jobs:\s*$/.test(lines[i])) { inJobs = true; continue; }
    if (inJobs && /^[A-Za-z]/.test(lines[i])) { inJobs = false; }
    if (!inJobs) continue;
    const job = lines[i].match(/^ {2}([A-Za-z0-9_-]+):\s*$/);
    if (!job) continue;
    let hasRunsOn = false, callsReusable = false;
    for (let j = i + 1; j < lines.length; j++) {
      if (/^ {2}[A-Za-z0-9_-]+:\s*$/.test(lines[j])) break;
      if (/^ {4}runs-on:/.test(lines[j])) hasRunsOn = true;
      if (/^ {4}uses:/.test(lines[j])) callsReusable = true;
    }
    if (!hasRunsOn && !callsReusable)
      errors.push(`${path}:${i + 1} job "${job[1]}" has no runs-on:`);
  }

  // ── `if:` expressions: the secrets context is not allowed there (file rejected, zero jobs) ──
  for (let i = 0; i < lines.length; i++) {
    const cond = lines[i].match(/^\s*(?:- )?if:\s*(.+)$/);
    if (cond && /\bsecrets\./.test(cond[1]))
      errors.push(`${path}:${i + 1} 'if:' references the secrets context — GitHub rejects the whole file ("Unrecognized named-value: 'secrets'"); copy the secret into env: and test that, or branch inside the run body`);
  }

  // ── verified-gate's trigger list: nothing may drop an event that can wake the gate ──
  // A gate that never STARTS is the same class as a gate that cannot fail (2026-10-31, #501/#503): a
  // stacked PR is retargeted to main by GitHub when its base branch is deleted, and that arrives as
  // `edited`; without it the required check is never created and the PR is unmergeable with every
  // visible check green.
  if (file === "verified-gate.yml") {
    const typesLine = lines.find((l) => /^\s+types:\s*\[/.test(l));
    const listed = typesLine
      ? typesLine.match(/\[([^\]]*)\]/)[1].split(",").map((s) => s.trim()).filter(Boolean)
      : [];
    const required = [
      ["opened", "a normal PR never runs the gate"],
      ["reopened", "a reopened PR keeps a stale result"],
      ["synchronize", "a new commit keeps a signature for the old head"],
      ["labeled", "the label this gate reads never triggers it"],
      ["unlabeled", "removing state:verified keeps a passing result"],
      ["ready_for_review", "a draft opened straight into review is never judged"],
      ["edited", "a PR retargeted to main (stacked base deleted) never runs the gate at all"],
    ];
    for (const [event, why] of required)
      if (!listed.includes(event))
        errors.push(`${path} pull_request types: is missing "${event}" — ${why}`);
  }

  // ── steps: the uses+run / with-without-uses traps ──
  for (let i = 0; i < lines.length; i++) {
    const stepStart = lines[i].match(/^(\s*)- /);
    if (!stepStart) continue;
    const dashIndent = stepStart[1].length;
    const { keys, runBody } = readStep(lines, i, dashIndent);
    if (keys.includes("uses") && keys.includes("run"))
      errors.push(`${path}:${i + 1} step has BOTH 'uses:' and 'run:' — GitHub rejects the whole file ("Unexpected value 'run'")`);
    if (keys.includes("with") && !keys.includes("uses"))
      errors.push(`${path}:${i + 1} step has 'with:' but no 'uses:' — GitHub rejects the file ("Unexpected value 'with'")`);
    if (keys.includes("continue-on-error"))
      warnings.push(`${path}:${i + 1} step sets continue-on-error — the gate cannot fail`);
    if (runBody) {
      const body = runBody.join("\n");
      const swallow = body.match(/\|\|\s*(echo|true|exit\s+0)\b/);
      if (swallow)
        warnings.push(`${path}:${i + 1} run body swallows failures via "|| ${swallow[1]}" — the step exits 0 even when the command fails`);
      const commands = runBody.filter((l) => l !== "");
      commands.slice(0, -1).forEach((l) => {
        if (/&&\s*(echo|printf)\b/.test(l))
          warnings.push(`${path}:${i + 1} run body line "${l.length > 60 ? `${l.slice(0, 57)}...` : l}" is an "&& ${l.match(/&&\s*(echo|printf)\b/)[1]}" guard before the last line — bash -e ignores a failure there, so the step passes; end the guard in "|| { echo …; exit 1; }"`);
      });
    }
  }
}

for (const w of warnings) console.log(`WARN  ${w}`);
for (const e of errors) console.log(`ERROR ${e}`);
console.log(`\n${errors.length} error(s), ${warnings.length} warning(s) across ${readdirSync(dir).filter((f) => /\.ya?ml$/.test(f)).length} workflow file(s)`);
process.exit(errors.length > 0 || (strict && warnings.length > 0) ? 1 : 0);
