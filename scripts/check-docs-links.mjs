#!/usr/bin/env node
/**
 * Checks that relative links in the repository's Markdown resolve to files that exist, and that
 * relative and intra-file anchors point at a heading that exists.
 *
 * Why: a documentation set is only world-class if it can be *navigated*. Broken links rot silently —
 * a rename or a moved guide turns the index into a maze, and nobody notices because the file still
 * exists. Cheap to check, so it is checked in CI and can be run locally.
 *
 * Issue #324: three shapes used to pass silently — an anchor into a **heading-less** file (the old
 * `headings.size > 0` guard), **reference-style** links (`[label][ref]` + `[ref]: path`), and
 * **intra-file** anchors (`[x](#section)`), which the old comment claimed were "handled below" when
 * nothing handled them. Each is now a rule with a self-test.
 *
 * Usage: node scripts/check-docs-links.mjs [--quiet] [--selftest]
 * Exits 1 when a link is broken.
 */
import { readFileSync, existsSync, statSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";
import { execFileSync } from "node:child_process";

const quiet = process.argv.includes("--quiet");

/** Every Markdown file: tracked *and* untracked-but-not-ignored, so a new doc is checked before its
 *  first commit (git ls-files alone silently skips untracked files — the checker would report a
 *  clean run while scanning none of the new documents). */
function markdownFiles() {
  try {
    const out = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "*.md"], {
      encoding: "utf8",
    });
    return out.split(/\r?\n/).filter(Boolean);
  } catch {
    return ["README.md", "CHANGELOG.md", "AGENTS.md"];
  }
}

export const slugify = (heading) =>
  heading
    .trim()
    .toLowerCase()
    .replace(/[`*_[\]()]/g, "")
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .replace(/\s+/g, "-");

/** Headings of a file, slugged the way GitHub does it (plus a `-N` suffix for duplicates). */
export const headingsOfText = (text) => {
  const seen = new Map();
  const headings = new Set();
  for (const line of text.split(/\r?\n/)) {
    if (!/^#{1,6}\s/.test(line)) continue;
    const base = slugify(line.replace(/^#{1,6}\s+/, ""));
    const n = seen.get(base) ?? 0;
    seen.set(base, n + 1);
    headings.add(n === 0 ? base : `${base}-${n}`);
  }
  return headings;
};

const headingsOf = (file) => {
  try {
    return headingsOfText(readFileSync(file, "utf8"));
  } catch {
    return new Set();
  }
};

/** An anchor that legitimately has no heading: `#` and `#top` scroll to the top of any page. */
const TOP_ANCHORS = new Set(["", "top"]);

/** Normalise a raw anchor the way GitHub does: percent-decoding, then a leading `user-content-` strip. */
const normaliseAnchor = (raw) => {
  let a = raw;
  try {
    a = decodeURIComponent(raw);
  } catch {
    /* a malformed escape stays literal and simply will not match a heading */
  }
  return a.replace(/^user-content-/, "");
};

/**
 * Remove fenced code blocks and inline code spans before scanning.
 *
 * Markdown renders `[x](y)` inside backticks or a fence as **literal text**, not a link, so a
 * documentation PR that quotes a broken link (exactly what #324's own changelog does while describing
 * the three shapes) must not fail the gate. Found the hard way: with the three new rules in place, four
 * "broken links" appeared in this repository and all four were examples inside code.
 *
 * Mutant: return the text unmodified and the self-test's "a link inside a code span is not a link"
 * case fails with four problems reported against prose.
 */
export function stripCode(text) {
  return (
    text
      // Fenced blocks: opening and closing fence with the same character, then to the next fence.
      .replace(/^[ \t]*(```|~~~)[\s\S]*?^[ \t]*\1[^\n]*$/gm, "")
      // Inline code spans, single line.
      .replace(/`[^`\n]*`/g, "")
  );
}

/**
 * Every link target in one Markdown file, in the three shapes that exist in practice:
 *  - inline          [label](target)  and  [label](<target with spaces>)
 *  - reference       [label][ref], [label][], [label]  ->  the `[ref]: target` definitions
 *  - intra-file      [label](#anchor)
 * Returns `{ target, kind }` so a caller can report the shape it came from.
 */
export function linksOf(rawText) {
  const found = [];
  const text = stripCode(rawText);

  // Reference definitions first: [ref]: target "optional title"
  const defs = new Map();
  for (const m of text.matchAll(/^\s{0,3}\[([^\]]+)\]:\s*(\S+)(?:\s+["'(].*)?$/gm)) {
    defs.set(m[1].trim().toLowerCase(), m[2]);
  }

  // Inline links and images. <...> allows spaces in the target.
  for (const m of text.matchAll(/\[[^\]]*\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+["'][^"']*["'])?\s*\)/g)) {
    found.push({ target: m[1].replace(/^<|>$/g, ""), kind: "inline" });
  }

  // Reference links: [label][ref] and the collapsed [label][] form.
  for (const m of text.matchAll(/\[([^\]]*)\]\[([^\]]*)\]/g)) {
    const key = (m[2] || m[1]).trim().toLowerCase();
    const target = defs.get(key);
    if (target !== undefined) found.push({ target, kind: "reference" });
  }

  // Intra-file anchors: [label](#anchor). Not a path, but it is still a link.
  for (const m of text.matchAll(/\[[^\]]*\]\(\s*(#[^)\s]*)\s*\)/g)) {
    found.push({ target: m[1], kind: "intra-file" });
  }

  // In-repo absolute links written from the repo root, e.g. (/docs/TESTING.md)
  for (const m of text.matchAll(/\]\((\/[^)\s]+)\)/g)) {
    found.push({ target: m[1], kind: "root-absolute" });
  }

  // De-duplicate: the inline pass also catches `[x](#anchor)`; the intra-file pass reports it once.
  const seen = new Set();
  return found.filter((l) => {
    const key = `${l.kind}|${l.target}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/**
 * Check one file's links. Pure over (text, resolver) so the self-test needs no filesystem.
 *
 * `resolveTarget(file, pathPart)` returns an absolute path or null; `headingsFor(abs)` returns the
 * heading set (or null when the file cannot be read).
 */
export function checkLinks(file, text, resolveTarget, headingsFor) {
  const problems = [];
  let checked = 0;

  for (const { target, kind } of linksOf(text)) {
    if (/^(https?:|mailto:|tel:|\/\/)/.test(target)) continue;

    // Intra-file anchor: the containing file is the target.
    if (kind === "intra-file") {
      const anchor = normaliseAnchor(target.slice(1));
      if (TOP_ANCHORS.has(anchor)) continue;
      checked++;
      const abs = resolveTarget(file, file);
      const headings = abs ? headingsFor(abs) : null;
      // Issue #324: a heading-less file cannot satisfy ANY anchor. The old `headings.size > 0`
      // guard made this the one case that passed while being certainly wrong.
      if (!abs || !headings || !headings.has(anchor)) {
        problems.push(`${file}: intra-file anchor not found -> ${target}`);
      }
      continue;
    }

    const hash = target.indexOf("#");
    const pathPart = hash === -1 ? target : target.slice(0, hash);
    const anchor = hash === -1 ? "" : normaliseAnchor(target.slice(hash + 1));

    if (kind === "root-absolute") {
      checked++;
      const abs = resolve(process.cwd(), "." + pathPart);
      if (!existsSync(abs)) problems.push(`${file}: missing target -> ${target}`);
      continue;
    }

    if (!pathPart) continue;
    checked++;
    const abs = resolveTarget(file, pathPart);
    if (!abs) {
      problems.push(`${file}: missing target -> ${target}`);
      continue;
    }
    if (anchor && TOP_ANCHORS.has(anchor)) continue;
    if (anchor && abs.endsWith(".md")) {
      const headings = headingsFor(abs);
      if (!headings.has(anchor)) problems.push(`${file}: anchor not found -> ${target}`);
    }
  }

  return { problems, checked };
}

/* ───────────────────────────── the CLI ───────────────────────────── */

function runCli() {
  const problems = [];
  let checked = 0;
  const files = markdownFiles();

  const resolveTarget = (file, pathPart) => {
    const abs = resolve(dirname(file), pathPart);
    return existsSync(abs) ? abs : null;
  };

  for (const file of files) {
    const text = readFileSync(file, "utf8");
    const result = checkLinks(
      file,
      text,
      resolveTarget,
      (abs) => (statSync(abs).isFile() && abs.endsWith(".md") ? headingsOf(abs) : new Set()),
    );
    for (const p of result.problems) problems.push(p);
    checked += result.checked;
  }

  if (problems.length) for (const p of problems) console.log(`ERROR ${p}`);
  if (!quiet) {
    console.log(
      `\n${problems.length} broken link(s) out of ${checked} checked in ${files.length} Markdown file(s)`,
    );
  }
  process.exit(problems.length ? 1 : 0);
}

/* ───────────────────────────── the self-test ─────────────────────────────
 * Issue #324. Each case names the shape it protects and the mutant that breaks it; the three
 * shapes below were all silently passing before this change.
 */
const CASES = [
  {
    name: "inline link to an existing file is clean",
    text: "see [guide](docs/guide.md)",
    files: { "docs/guide.md": "# Guide\n" },
    expect: [],
  },
  {
    name: "inline link to a missing file is reported",
    text: "see [guide](docs/nope.md)",
    files: { "docs/guide.md": "# Guide\n" },
    expect: ["missing target -> docs/nope.md"],
  },
  {
    name: "an anchor that exists in the target is clean",
    text: "[x](docs/guide.md#the-guide)",
    files: { "docs/guide.md": "# The guide\n" },
    expect: [],
  },
  {
    name: "an anchor that does not exist is reported",
    text: "[x](docs/guide.md#nope)",
    files: { "docs/guide.md": "# The guide\n" },
    expect: ["anchor not found -> docs/guide.md#nope"],
  },
  {
    // Mutant: restore the old `headings.size > 0` guard and this passes silently.
    name: "an anchor into a heading-less file is reported (#324)",
    text: "[x](docs/plain.md#anything)",
    files: { "docs/plain.md": "just a paragraph, no headings\n" },
    expect: ["anchor not found -> docs/plain.md#anything"],
  },
  {
    // Mutant: drop the reference-definition scan and this passes silently.
    name: "a reference-style link to a missing file is reported (#324)",
    text: "see [the guide][g]\n\n[g]: docs/nope.md\n",
    files: {},
    expect: ["missing target -> docs/nope.md"],
  },
  {
    // Mutant: drop the intra-file branch and this passes silently.
    name: "an intra-file anchor with no such heading is reported (#324)",
    text: "# Real\n\njump [there](#not-here)\n",
    files: {},
    expect: ["intra-file anchor not found -> #not-here"],
  },
  {
    name: "an intra-file anchor that exists is clean",
    text: "# Real heading\n\njump [there](#real-heading)\n",
    files: {},
    expect: [],
  },
  {
    name: "#top and a bare # are accepted anywhere",
    text: "# Real\n\n[top](#top) and [here](#)\n",
    files: {},
    expect: [],
  },
  {
    name: "duplicate headings get GitHub's -1 suffix",
    text: "# Dup\n\n## Dup\n\n[x](#dup-1)\n",
    files: {},
    expect: [],
  },
  {
    // Mutant: return `text` instead of `stripCode(text)` in linksOf and this reports four problems.
    name: "a link inside a code span is not a link (#324)",
    text: [
      "prose `[x](missing.md)` is literal.",
      "",
      "```",
      "[y](also-missing.md)",
      "```",
      "",
    ].join("\n"),
    files: {},
    expect: [],
  },
  {
    name: "the same missing link outside a code span is still reported",
    text: "`[x](missing.md)` then a real one [y](really-missing.md)",
    files: {},
    expect: ["missing target -> really-missing.md"],
  },
  {
    name: "absolute urls, mailto and tel are ignored",
    text: "[a](https://example.com) [b](mailto:x@y.z) [c](tel:123)",
    files: {},
    expect: [],
  },
];

function runSelfTest() {
  let failed = 0;
  for (const c of CASES) {
    // The case's own text is the containing file; `files` supplies the targets it links to.
    const fixture = { "probe.md": c.text, ...c.files };
    const rel = (abs) => relative(process.cwd(), abs).split("\\").join("/");
    const resolveTarget = (file, pathPart) => {
      const abs = resolve(dirname(file), pathPart);
      return fixture[rel(abs)] !== undefined ? abs : null;
    };
    const headingsFor = (abs) => {
      const text = fixture[rel(abs)];
      return text === undefined ? new Set() : headingsOfText(text);
    };
    const { problems } = checkLinks("probe.md", c.text, resolveTarget, headingsFor);
    const ok = c.expect.length === 0 ? problems.length === 0 : c.expect.every((e) => problems.some((p) => p.endsWith(e)));
    if (ok) {
      console.log(`PASS  ${c.name}`);
    } else {
      failed++;
      console.log(`FAIL  ${c.name}: ${problems.length ? problems.join(" | ") : "no problems reported"}`);
    }
  }
  console.log(`\ndocs-links self-test: ${CASES.length - failed}/${CASES.length} cases`);
  process.exit(failed ? 1 : 0);
}

if (process.argv.includes("--selftest")) runSelfTest();
else runCli();
