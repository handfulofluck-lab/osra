#!/usr/bin/env node
/**
 * Issue #151: fails when a documentation or script file publishes something that looks like a PIN.
 *
 * **Why this exists.** The repository is public, and the test family's parent-app PIN was in five places
 * on `main` for days. That PIN opens *Remove protection* and *stop ring* on the paired phone, so the
 * exposure was real until it was rotated — and a rotation does not stop the next one being written down.
 * This is the check that makes the next one cost a red run instead of an incident.
 *
 * **What counts as a finding:** a run of 4–8 digits within 16 characters of any `PIN` on the line, in
 * either order, in a text file under `docs/`, `scripts/`, `.github/`, `infra/` or `CHANGELOG.d/`, or in
 * the root `README.md`, `CHANGELOG.md` or `AGENTS.md`.
 *
 * **What does not:**
 * - `<app-PIN>`, `<device-PIN>` and any `<…>` placeholder — no digits, nothing to leak.
 * - `0000`: the desktop agent's *old, refused* default, which the docs must name to explain why it was
 *   removed (#140). It is not a credential: since `fix/desktop-pin-and-tls` no install adopts it.
 * - A digit run that is not near the word `PIN` — order numbers, test counts, ports.
 *
 * **Why a plain scan and not a lint rule:** the exposure was in prose, in five different files, written
 * by agents over weeks. A check that reads the files the way a reader does is the only one that catches
 * it, and it has to run on every PR rather than on a path filter — a guard that is green by absence is
 * the failure mode this repository has paid for before.
 *
 * Usage: node scripts/check-no-pins.mjs [--quiet] [--selftest]
 * Exits 1 on any finding, 0 when clean, and the self-test exits 1 if a fixture does not behave.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const SCAN_DIRS = ["docs", "scripts", ".github", "infra", "CHANGELOG.d"];
const SCAN_FILES = ["README.md", "CHANGELOG.md", "AGENTS.md"];

/** `0000` is the refused desktop default the documentation has to name; it is not a credential. */
const ALLOWED = new Set(["0000"]);

const PROXIMITY = 16;

/**
 * The fixture value, composed rather than written: this file is scanned by the very rule it defines, and
 * a literal here would be a finding in the gate that exists to find it.
 */
const SAMPLE = ["48", "2613"].join("");
// A standalone token: not part of an identifier like `ADR-0010` or `TR-09`, which share the shape.
// A date or a time is not a PIN either: `2026-10-23`, `10:15`.
const DIGITS = /(?<![A-Za-z0-9_-]|\d[:./])\d{4,8}(?![A-Za-z0-9_]|[-:./]\d)/g;
const WORD_PIN = /\bPINs?\b/gi;

/** True when [line] publishes something that looks like a PIN. Pure, so the fixtures can call it. */
export function pinFinding(line) {
  // Every `PIN` on the line counts, not only the first: "the PIN gate … the parent PIN <value>".
  const words = [...line.matchAll(WORD_PIN)];
  if (words.length === 0) return null;
  for (const match of line.matchAll(DIGITS)) {
    const digits = match[0];
    if (ALLOWED.has(digits)) continue;
    const at = match.index ?? 0;
    // Character distance to the nearest edge of a word, so a value written before the word is caught
    // as well as one after it, while an unrelated number a clause away is not.
    for (const word of words) {
      const wordStart = word.index ?? 0;
      const wordEnd = wordStart + word[0].length;
      const distance = at >= wordEnd ? at - wordEnd : Math.max(0, wordStart - (at + digits.length));
      if (distance <= PROXIMITY) return digits;
    }
  }
  return null;
}

function* walk(dir) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else if (entry.isFile()) yield full;
  }
}

const isText = (path) => /\.(md|mjs|js|ts|json|ya?ml|html|txt|ps1|bat|sh|kt|dart|cs|swift|py)$/i.test(path);

function scan() {
  const findings = [];
  const files = [
    ...SCAN_DIRS.flatMap((d) => [...walk(join(ROOT, d))]),
    ...SCAN_FILES.map((f) => join(ROOT, f)),
  ].filter((f) => isText(f) && !f.includes("node_modules"));
  for (const file of files) {
    let text;
    try {
      text = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    text.split(/\r?\n/).forEach((line, index) => {
      const digits = pinFinding(line);
      if (digits) findings.push({ file: relative(ROOT, file), line: index + 1, digits });
    });
  }
  return findings;
}

function runCli() {
  const findings = scan();
  const quiet = process.argv.includes("--quiet");
  if (findings.length === 0) {
    if (!quiet) console.log(`0 PIN-shaped literals in ${SCAN_DIRS.join(", ")} (#151)`);
    return 0;
  }
  for (const f of findings) {
    console.error(`${f.file}:${f.line}: a ${f.digits.length}-digit number next to the word PIN (#151)`);
  }
  console.error(
    `\n${findings.length} finding(s). A PIN in a public repository is a credential: redact it as ` +
      `<app-PIN> or <device-PIN>, and keep the value outside the repo. If it was ever pushed, rotate it.`,
  );
  return 1;
}

/**
 * The fixtures, one per rule. Each asserts a *decision*, not a string: the first two would pass on a
 * check that always says "fine", and the last two on one that always says "finding".
 */
function runSelfTest() {
  const cases = [
    ["an actual PIN in prose", `the parent PIN ${SAMPLE} opens removal`, SAMPLE],
    ["a PIN on the other side of the word", `${SAMPLE} is the app PIN`, SAMPLE],
    ["a PIN after an earlier PIN on the same line", `the PIN gate covers removal; the parent PIN ${SAMPLE} opens it`, SAMPLE],
    ["the old desktop default, named on purpose", "the old desktop PIN 0000 is refused since #140", null],
    ["an identifier that shares the shape", "the PIN rule is ADR-0010, checked in TR-0909", null],
    ["a date or a time next to the word", "the PIN gate passed on 2026-10-23 at 10:15", null],
    ["a placeholder rather than a value", "enter your PIN <app-PIN> at pairing", null],
    ["digits far from the word", "the PIN gate held over the removal screens in test 2019", null],
    ["too short to be a PIN", "PIN 123 is not a PIN", null],
    ["too long to be a PIN", "PIN 123456789 is not a PIN", null],
    ["the word without digits", "the PIN gate is over the OS removal screens", null],
  ];
  let failures = 0;
  for (const [name, line, expected] of cases) {
    const actual = pinFinding(line);
    if (actual !== expected) {
      console.error(`selftest FAILED: ${name}\n  line:     ${line}\n  expected: ${expected}\n  actual:   ${actual}`);
      failures += 1;
    }
  }
  if (failures === 0) console.log(`check-no-pins selftest: ${cases.length} fixtures passed`);
  return failures === 0 ? 0 : 1;
}

const code = process.argv.includes("--selftest") ? runSelfTest() : runCli();
process.exit(code);
