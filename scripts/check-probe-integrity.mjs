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
 *   node scripts/check-probe-integrity.mjs --base <sha> --head <sha> --stats   # call-site counts
 *   node scripts/check-probe-integrity.mjs --selftest                 # the gate's own test
 *
 * Exits 1 on an unacknowledged removal or demotion.
 */
import { readFileSync, existsSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

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
 *
 * The scan is over the whole file, not line by line (issue #310): the title may open on a later
 * line — `check(` and then `  "A4 …"` — which a per-line `\s*` can never cross. Nine calls in
 * `qa-probe.mjs` were invisible to the old matcher, so renaming or deleting one of them passed the
 * gate, and adding one printed "0 added".
 */
function assertions(src) {
  const found = { check: new Map(), target: new Map(), note: new Map() };
  const dynamic = { check: 0, target: 0, note: 0 };
  const calls = { check: 0, target: 0, note: 0 };
  for (const kind of KINDS) {
    // The lookbehind is the boundary the per-line matcher used to express as `(^|[^\w.])`:
    // `foo.check(` and `mycheck(` are not calls. Global, because a line may hold more than one.
    const re = new RegExp(`(?<![\\w.])${kind}\\(`, "g");
    let m;
    while ((m = re.exec(src)) !== null) {
      calls[kind] += 1;
      // Skip whitespace before the first argument — including newlines, which is the fix.
      let at = m.index + m[0].length;
      while (at < src.length && /\s/.test(src[at])) at += 1;
      const opener = src[at];
      if (opener !== '"' && opener !== "`") {
        // A name built in a variable cannot be compared statically; count it and say so.
        dynamic[kind] += 1;
        continue;
      }
      const closer = opener;
      // Names never contain a closing quote of the same kind before the end of the argument.
      const end = src.indexOf(closer, at + 1);
      if (end === -1) {
        dynamic[kind] += 1;
        continue;
      }
      const name = src
        .slice(at + 1, end)
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
  return { found, dynamic, calls };
}

/**
 * Compare two assertion sets and say what disappeared, was demoted, or was added.
 * Kept as a function (rather than inline at the bottom) so `--selftest` exercises the same path
 * the CLI uses; a test of a copy is not a test.
 */
function compare(a, b, acks) {
  const acked = (kind, name) =>
    acks.some((a) => a.kind === kind && a.name === name && typeof a.reason === "string" && a.reason.length > 10);
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
      // An UNCHANGED if/else fallback is not a demotion. A probe may write
      //     if (precondition) check("Q6 …"); else target("Q6 …");
      // which puts one title in both kinds by design; the pass used to read its own fallback line as a
      // demotion of its own check line and reported "DEMOTED check -> target" with base and head
      // identical — `main` failed against itself on 2026-10-23.
      //
      // The condition is "the fallback was already there", NOT "a check still exists". Skipping on the
      // latter (my first attempt) would let a check GAIN a same-name advisory fallback with no
      // acknowledgement, which is a narrowing of the gate: before it, that needed an entry in
      // scripts/probe-gate-acks.json, and AGENTS.md §4 says a gate may be extended, not narrowed.
      if (b.found.check.has(name) && a.found[weaker].has(name)) continue;
      if (b.found[weaker].has(name)) {
        if (acked("check", name)) infos.push(`acked-demoted check -> ${weaker}: ${name}`);
        else problems.push(`DEMOTED check -> ${weaker}: ${name}`);
      }
    }
  }
  for (const name of a.found.target.keys()) {
    if (b.found.target.has(name) && a.found.note.has(name)) continue; // unchanged target->note fallback
    if (b.found.note.has(name)) {
      if (acked("target", name)) infos.push(`acked-demoted target -> note: ${name}`);
      else problems.push(`DEMOTED target -> note: ${name}`);
    }
  }
  for (const name of a.found.target.keys()) if (b.found.check.has(name) && !a.found.check.has(name)) infos.push(`promoted target -> check: ${name}`);
  for (const name of a.found.note.keys()) if (b.found.check.has(name)) infos.push(`promoted note -> check: ${name}`);

  return { problems, infos };
}

/**
 * Mutant for the cases below (AGENTS.md §3): restore the per-line matcher
 * `new RegExp(`(^|[^\\w.])${kind}\\(\\s*(.)`)` over `src.split(/\r?\n/)`. A call whose title opens on
 * the next line is then never seen, so the wrapped fixtures lose their names, the call-site count
 * drops, and a deleted wrapped call is reported as nothing (the CLI exits 0). Every one of those
 * expectations fails — that is what makes this a test rather than a printout.
 */
if (argv.includes("--selftest")) {
  let total = 0;
  let bad = 0;
  const expect = (name, ok, detail = "") => {
    total += 1;
    if (ok) console.log(`PASS  ${name}`);
    else {
      bad += 1;
      console.error(`FAIL  ${name}${detail ? `: ${detail}` : ""}`);
    }
  };

  const inline = assertions("check(\"A1 inline\", ok);");
  expect('inline check("…") is read', inline.found.check.has("A1 inline"));

  const wrapped = assertions("check(\n  \"A2 wrapped\",\n  ok,\n);");
  expect(
    'multi-line check(\\n  "…") is read',
    wrapped.found.check.has("A2 wrapped"),
    `names=${[...wrapped.found.check.keys()].join(",")} dynamic=${wrapped.dynamic.check}`,
  );

  const wrappedTarget = assertions("target(\n  \"T1 tracked\",\n  ok,\n);");
  expect(
    "multi-line target( is read",
    wrappedTarget.found.target.has("T1 tracked"),
    `names=${[...wrappedTarget.found.target.keys()].join(",")} dynamic=${wrappedTarget.dynamic.target}`,
  );

  const interpolated = assertions("check(\`I category ${c} is gated\`, ok);");
  expect(
    "an interpolated title is normalised to <*>",
    interpolated.found.check.has("I category <*> is gated"),
    `names=${[...interpolated.found.check.keys()].join(",")}`,
  );

  const dynamic = assertions("const name = title; check(name, ok);");
  expect("a title built in a variable is counted as dynamic", dynamic.dynamic.check === 1);

  const baseSrc = "check(\"A1 inline\", ok);\ncheck(\n  \"D1 deleted wrapped\",\n  ok,\n);\ntarget(\n  \"T1 tracked\",\n  ok,\n);\n";
  const headSrc = "check(\"A1 inline\", ok);\ntarget(\n  \"T1 tracked\",\n  ok,\n);\ncheck(\"N1 added\", ok);\n";
  const baseSet = assertions(baseSrc);
  expect(
    "wrapped calls are counted as call sites",
    baseSet.calls.check === 2 && baseSet.calls.target === 1,
    `check=${baseSet.calls.check} target=${baseSet.calls.target}`,
  );

  const { problems, infos } = compare(baseSet, assertions(headSrc), []);
  expect(
    "a deleted multi-line call is REMOVED",
    problems.includes("REMOVED check: D1 deleted wrapped"),
    `problems=${JSON.stringify(problems)} infos=${JSON.stringify(infos)}`,
  );
  expect(
    "a surviving multi-line target is not reported",
    !problems.some((p) => p.includes("T1 tracked")),
    `problems=${JSON.stringify(problems)}`,
  );
  expect("an added inline call is reported as added", infos.includes("added check: N1 added"));

  const demoted = compare(assertions("check(\"Z1 demoted\", ok);"), assertions("target(\n  \"Z1 demoted\",\n  ok,\n);"), []);
  expect(
    "check -> target is still a DEMOTED",
    demoted.problems.includes("DEMOTED check -> target: Z1 demoted"),
    `problems=${JSON.stringify(demoted.problems)}`,
  );

  // The if/else degradation pattern: ONE title written as both a check and a target, which is what a
  // probe does when a precondition can be unavailable. Base and head identical => no finding. The pass
  // used to read the target line as a demotion of the check line and made every such branch red,
  // including `main` against itself (issue: found on 2026-10-23 while #339 sat red for a change that
  // touched only infra).
  const bothKinds = [
    "if (ok) {",
    '  check("Q6 same title", ok);',
    "} else {",
    '  target("Q6 same title", "unavailable");',
    "}",
  ].join("\n");
  const ifElse = compare(assertions(bothKinds), assertions(bothKinds), []);
  expect(
    "a title that is both a check and a target is not a DEMOTED when the check survives",
    ifElse.problems.length === 0,
    `problems=${JSON.stringify(ifElse.problems)}`,
  );

  // A check that GAINS a same-name fallback is a narrowing of the gate and must be acknowledged: it was
  // a gating assertion in base and can be advisory in head. Claude's #340 review measured exactly this
  // against the first version of the fix, which skipped any name that still had a check.
  const checkOnly = 'check("G3 gated", ok);';
  const gained = compare(assertions(checkOnly), assertions(bothKinds.replaceAll("Q6 same title", "G3 gated")), []);
  expect(
    "a check that gains a same-name fallback is a DEMOTED until acknowledged",
    gained.problems.some((p) => p.startsWith("DEMOTED check -> target: G3 gated")),
    `problems=${JSON.stringify(gained.problems)}`,
  );

  const gainedAcked = compare(assertions(checkOnly), assertions(bothKinds.replaceAll("Q6 same title", "G3 gated")), [
    { kind: "check", name: "G3 gated", reason: "a precondition can now be unavailable, fallback added" },
  ]);
  expect(
    "the same gained fallback with an acknowledgement is informational, not an error",
    gainedAcked.problems.length === 0 && gainedAcked.infos.some((i) => i.startsWith("acked-demoted check -> target: G3 gated")),
    `problems=${JSON.stringify(gainedAcked.problems)} infos=${JSON.stringify(gainedAcked.infos)}`,
  );

  const acked = compare(assertions("check(\"R1 renamed\", ok);"), assertions(""), [
    { kind: "check", name: "R1 renamed", reason: "renamed to R2 in the same PR" },
  ]);
  expect(
    "an acknowledged removal is not an error",
    acked.problems.length === 0 && acked.infos.includes("acked-removed check: R1 renamed"),
    `problems=${JSON.stringify(acked.problems)}`,
  );

  // The scanner cases above would still pass if the CLI never called the scanner. Run the real
  // command the way CI does — git refs, the real PROBE path — in a throwaway repository.
  const dir = mkdtempSync(join(tmpdir(), "probe-integrity-fixture-"));
  const git = (...args) => execFileSync("git", args, { cwd: dir, stdio: "pipe" });
  git("init", "-q");
  git("config", "user.email", "fixture@local");
  git("config", "user.name", "fixture");
  mkdirSync(join(dir, "services", "api", "scripts"), { recursive: true });
  writeFileSync(join(dir, PROBE), baseSrc);
  git("add", "-A");
  git("commit", "-qm", "base");
  writeFileSync(join(dir, PROBE), headSrc);
  git("add", "-A");
  git("commit", "-qm", "head");
  const cli = (...args) =>
    spawnSync(process.execPath, [fileURLToPath(import.meta.url), ...args], { cwd: dir, encoding: "utf8" });
  const removed = cli("--base", "HEAD~1", "--head", "HEAD", "--quiet");
  expect(
    "the CLI exits 1 on a deleted multi-line call",
    removed.status === 1,
    `exit=${removed.status} stdout=${removed.stdout.trim()} stderr=${removed.stderr.trim()}`,
  );
  expect(
    "the CLI names the deleted multi-line call as REMOVED",
    /REMOVED check: D1 deleted wrapped/.test(removed.stdout),
    `stdout=${removed.stdout.trim()}`,
  );
  const unchanged = cli("--base", "HEAD", "--head", "HEAD");
  expect("the CLI exits 0 when the call survives", unchanged.status === 0, `exit=${unchanged.status}`);
  rmSync(dir, { recursive: true, force: true });

  console.log(`probe-integrity self-test: ${total - bad}/${total} cases`);
  process.exit(bad ? 1 : 0);
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

const stats = argv.includes("--stats");
const a = assertions(readProbe(base));
const b = assertions(readProbe(head));
const { problems, infos } = compare(a, b, acks);

if (stats) {
  for (const [label, x] of [
    [base, a],
    [head ?? "working tree", b],
  ]) {
    const gate = x.calls.check + x.calls.target;
    console.log(
      `call sites ${label}: check=${x.calls.check} target=${x.calls.target} note=${x.calls.note}` +
        ` (check+target=${gate}; named check=${x.found.check.size} target=${x.found.target.size};` +
        ` dynamic check=${x.dynamic.check} target=${x.dynamic.target})`,
    );
  }
}

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
