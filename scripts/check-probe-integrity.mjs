#!/usr/bin/env node
/**
 * Checks that the adversarial gate (`services/api/scripts/qa-probe.mjs`) was only *extended* between
 * two revisions — never silently narrowed.
 *
 * Why this exists. `AGENTS.md` §4 forbids weakening a check to make a gate green, and the gate is the
 * one mechanism that keeps the other agents honest. But the rule was only enforceable by a tester
 * reading a diff, and these diffs are large: PR #65 rewrote the signing helper and moved two targets
 * to gates in a **225-added / 43-deleted** change to that file. Reading 43 deletions by eye once is
 * possible; doing it on every PR, forever, is how a weakened check eventually gets through. A deleted
 * or renamed assertion is exactly the change that looks innocuous in a stat line.
 *
 * What it compares: the *sets of assertion names* per severity (`check` = gating, `target` = tracked
 * design decision, `note` = observation). It reports:
 *   - REMOVED   a name that existed in the base and not in the head  -> exits 1 unless acknowledged
 *   - DEMOTED   check -> target/note, or target -> note             -> exits 1 unless acknowledged
 *   - promoted  target -> check (a strengthening, informational)
 *   - added     genuinely new assertions (informational)
 *
 * A legitimate rename is allowed, but it must be *written down*: add an entry to
 * `scripts/probe-gate-acks.json` with the old name and a reason. That is deliberate friction — the
 * point is that no assertion disappears without a sentence saying why.
 *
 * Names built by interpolation (the probe generates some suites in loops) cannot be compared
 * statically; they are counted and reported so a reviewer knows the coverage of this check itself.
 * The same limitation applies to loops that share one literal name: nine iterations of
 * `check(`I category "${c}" ...`)` collapse into a single comparable entry, so this tool detects
 * "an assertion family disappeared", not "one iteration of it disappeared". A reviewer still has to
 * look at a loop that lost an iteration — this check narrows the search, it does not replace the eye.
 *
 * Usage:
 *   node scripts/check-probe-integrity.mjs                            # origin/main -> working tree
 *   node scripts/check-probe-integrity.mjs --base origin/main --head HEAD
 *   node scripts/check-probe-integrity.mjs --base <sha> --head <sha> --quiet
 *
 * Exits 1 on an unacknowledged removal or demotion.
 */
import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const PROBE = "services/api/scripts/qa-probe.mjs";
const ACKS = "scripts/probe-gate-acks.json";
const KINDS = ["check", "target", "note"];

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf(name);
  return i === -1 ? fallback : argv[i + 1];
};
const quiet = argv.includes("--quiet");
const base = flag("--base", "origin/main");
const head = flag("--head", null); // null = working tree

/** Read the probe from a git ref, or from disk when ref is null. */
function readProbe(ref) {
  if (ref === null) {
    if (!existsSync(PROBE)) throw new Error(`${PROBE} not found in the working tree`);
    return readFileSync(PROBE, "utf8");
  }
  try {
    return execFileSync("git", ["show", `${ref}:${PROBE}`], { encoding: "utf8" });
  } catch {
    throw new Error(`cannot read ${PROBE} at ${ref} — is the ref fetched? (git fetch origin)`);
  }
}

/**
 * Collect assertion names. Handles the two literal forms the probe uses:
 *   check("literal name", ...)      and      check(`literal ${interpolated} name`, ...)
 * Interpolations are normalised to `<*>`, so a loop that renames one placeholder still matches.
 */
function assertions(src) {
  const found = { check: new Map(), target: new Map(), note: new Map() };
  const dynamic = { check: 0, target: 0, note: 0 };
  const lines = src.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    for (const kind of KINDS) {
      // The call may be indented, and the first argument may open on the same line (the probe's
      // style) — anything else is treated as dynamic rather than guessed at.
      const re = new RegExp(`(^|[^\\w.])${kind}\\(\\s*(.)`);
      const m = line.match(re);
      if (!m) continue;
      const opener = m[2];
      const at = line.indexOf(m[0]) + m[0].length - 1;
      if (opener !== '"' && opener !== "`") {
        dynamic[kind] += 1;
        continue;
      }
      const closer = opener;
      // Names never contain a closing quote of the same kind before the end of the argument; if one
      // appears on this line, take it; otherwise join following lines until it closes.
      let text = line.slice(at + 1);
      let guard = 0;
      while (!text.includes(closer) && i + 1 < lines.length && guard < 5) {
        i += 1;
        guard += 1;
        text += "\n" + lines[i];
      }
      const end = text.indexOf(closer);
      if (end === -1) {
        dynamic[kind] += 1;
        continue;
      }
      const name = text
        .slice(0, end)
        .replace(/\$\{[^}]*\}/g, "<*>")
        .replace(/\s+/g, " ")
        .trim();
      if (name.length === 0) {
        dynamic[kind] += 1;
        continue;
      }
      found[kind].set(name, (found[kind].get(name) ?? 0) + 1);
    }
  }
  return { found, dynamic };
}

const acksPath = ACKS;
let acks = [];
if (existsSync(acksPath)) {
  try {
    acks = JSON.parse(readFileSync(acksPath, "utf8"));
  } catch (err) {
    console.log(`ERROR ${acksPath} is not valid JSON: ${err.message}`);
    process.exit(1);
  }
}
const acked = (kind, name) =>
  acks.some((a) => a.kind === kind && a.name === name && typeof a.reason === "string" && a.reason.length > 10);

const a = assertions(readProbe(base));
const b = assertions(readProbe(head));

const problems = [];
const infos = [];

for (const kind of KINDS) {
  const removed = [...a.found[kind].keys()].filter((n) => !b.found[kind].has(n));
  const added = [...b.found[kind].keys()].filter((n) => !a.found[kind].has(n));
  for (const name of removed) {
    // A gating check that survives only as a weaker severity is a *demotion*, and it is reported
    // once by the demotion pass below. Reporting it here as well would say "REMOVED" and "DEMOTED"
    // for the same line and count it twice, which overstates the finding — the tool must not
    // exaggerate, or nobody will trust its quiet runs either.
    const demotedTo =
      kind === "check"
        ? ["target", "note"].find((k) => b.found[k].has(name))
        : kind === "target" && b.found.note.has(name)
          ? "note"
          : null;
    if (demotedTo) continue;
    if (acked(kind, name)) infos.push(`acked-removed ${kind}: ${name}`);
    else problems.push(`REMOVED ${kind}: ${name}`);
  }
  for (const name of added) infos.push(`added ${kind}: ${name}`);
}

// Demotions: a gating check that survives only as an advisory severity is a weakening even though the
// name is still present — the exact change a rename would disguise.
for (const name of a.found.check.keys()) {
  for (const weaker of ["target", "note"]) {
    if (b.found[weaker].has(name)) {
      if (acked("check", name)) infos.push(`acked-demoted check -> ${weaker}: ${name}`);
      else problems.push(`DEMOTED check -> ${weaker}: ${name}`);
    }
  }
}
for (const name of a.found.target.keys()) {
  if (b.found.note.has(name)) {
    if (acked("target", name)) infos.push(`acked-demoted target -> note: ${name}`);
    else problems.push(`DEMOTED target -> note: ${name}`);
  }
}
for (const name of a.found.target.keys()) if (b.found.check.has(name)) infos.push(`promoted target -> check: ${name}`);
for (const name of a.found.note.keys()) if (b.found.check.has(name)) infos.push(`promoted note -> check: ${name}`);

const counts = (x) => KINDS.map((k) => `${k}=${x.found[k].size}`).join(" ");
if (!quiet) {
  console.log(`probe integrity: ${base} (${counts(a)}) -> ${head ?? "working tree"} (${counts(b)})`);
  for (const line of infos) console.log(`  ${line}`);
  for (const kind of KINDS) {
    if (b.dynamic[kind] > 0) {
      console.log(`  note: ${b.dynamic[kind]} ${kind}(...) call(s) use a dynamically built name and cannot be compared`);
    }
  }
}
if (problems.length) {
  for (const p of problems) console.log(`ERROR ${p}`);
  console.log(
    `\n${problems.length} assertion(s) disappeared or were demoted without an acknowledgement in ${acksPath}.` +
      `\nIf the change is legitimate, add { "kind": "<check|target|note>", "name": "<old name>", "reason": "<why>" },` +
      `\nand remember the rule in AGENTS.md §4: a gate may be extended, not narrowed.`,
  );
} else if (!quiet) {
  console.log(`\nno assertion removed or demoted (${infos.filter((i) => i.startsWith("added")).length} added, ${infos.filter((i) => i.startsWith("promoted")).length} promoted)`);
}
process.exit(problems.length ? 1 : 0);
