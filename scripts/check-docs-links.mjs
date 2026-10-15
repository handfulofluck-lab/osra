#!/usr/bin/env node
/**
 * Checks that relative links in the repository's Markdown resolve to files that exist, and that
 * relative anchors point at a heading that exists in the target file.
 *
 * Why: a documentation set is only world-class if it can be *navigated*. Broken links rot silently —
 * a rename or a moved guide turns the index into a maze, and nobody notices because the file still
 * exists. Cheap to check, so it is checked in CI and can be run locally.
 *
 * Usage: node scripts/check-docs-links.mjs [--quiet]
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

const slugify = (heading) =>
  heading
    .trim()
    .toLowerCase()
    .replace(/[`*_[\]()]/g, "")
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .replace(/\s+/g, "-");

const headingsOf = (file) => {
  try {
    return new Set(
      readFileSync(file, "utf8")
        .split(/\r?\n/)
        .filter((l) => /^#{1,6}\s/.test(l))
        .map((l) => slugify(l.replace(/^#{1,6}\s+/, ""))),
    );
  } catch {
    return new Set();
  }
};

const problems = [];
let checked = 0;

for (const file of markdownFiles()) {
  const text = readFileSync(file, "utf8");
  // [label](target) — ignore absolute URLs, mailto, and bare anchors handled below.
  const links = [...text.matchAll(/\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)].map((m) => m[1]);
  for (const target of links) {
    if (/^(https?:|mailto:|tel:|#)/.test(target)) continue;
    const [pathPart, anchor] = target.split("#");
    if (!pathPart) continue;
    checked++;
    const abs = resolve(dirname(file), decodeURI(pathPart));
    if (!existsSync(abs)) {
      problems.push(`${file}: missing target -> ${target}`);
      continue;
    }
    if (anchor && statSync(abs).isFile() && abs.endsWith(".md")) {
      const headings = headingsOf(abs);
      if (!headings.has(anchor) && headings.size > 0) {
        problems.push(`${file}: anchor not found -> ${target}`);
      }
    }
  }
  // Also check in-repo absolute links written from the repo root, e.g. (/docs/TESTING.md)
  for (const m of text.matchAll(/\]\((\/[^)\s]+)\)/g)) {
    const abs = resolve(process.cwd(), "." + m[1]);
    checked++;
    if (!existsSync(abs)) problems.push(`${file}: missing target -> ${m[1]}`);
  }
}

if (problems.length) {
  for (const p of problems) console.log(`ERROR ${p}`);
}
if (!quiet) console.log(`\n${problems.length} broken link(s) out of ${checked} checked in ${markdownFiles().length} Markdown file(s)`);
process.exit(problems.length ? 1 : 0);
