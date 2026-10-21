#!/usr/bin/env node
/**
 * Assemble `CHANGELOG.d/` fragments into `CHANGELOG.md`'s `[Unreleased]` block.
 *
 * **Why fragments.** Every PR used to add its entry to the same `[Unreleased]` block, which meant every
 * merge conflicted with every other open PR in that one file. Today alone that cost three re-signatures
 * (a resolution inside a file the PR itself edits changes its patch-id, so §6.5's carry-forward correctly
 * refuses) and one duplicated entry that only a reviewer caught. A fragment is a file nobody else touches,
 * so the conflict cannot happen.
 *
 * **Shape.** One file per change, `CHANGELOG.d/<YYYY-MM-DD>-<slug>.md`, whose contents are the changelog
 * entry verbatim — heading, bullets and all. No front matter, no parser: the assembler concatenates.
 *
 *   node scripts/assemble-changelog.mjs            # insert and delete the fragments
 *   node scripts/assemble-changelog.mjs --keep     # insert but leave the files (dry run for review)
 *   node scripts/assemble-changelog.mjs --check    # exit 1 if fragments are pending
 *
 * Fragments are ordered by filename descending, so a date prefix gives "newest first" for free. An entry
 * already present in `CHANGELOG.md` is skipped, so running this twice is safe.
 */

import { readdir, readFile, writeFile, unlink } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const FRAGMENT_DIR = join(ROOT, "CHANGELOG.d");
const CHANGELOG = join(ROOT, "CHANGELOG.md");
const UNRELEASED = "## [Unreleased]";

async function fragmentFiles() {
  try {
    const names = await readdir(FRAGMENT_DIR);
    return names.filter((name) => name.endsWith(".md") && name !== "README.md").sort().reverse();
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

async function main() {
  const args = new Set(process.argv.slice(2));
  const files = await fragmentFiles();

  if (args.has("--check")) {
    if (files.length === 0) {
      console.log("no changelog fragments pending");
      return 0;
    }
    console.log(`${files.length} changelog fragment(s) pending; run node scripts/assemble-changelog.mjs`);
    for (const name of files) console.log(`  CHANGELOG.d/${name}`);
    return 1;
  }

  if (files.length === 0) {
    console.log("no changelog fragments pending; nothing to assemble");
    return 0;
  }

  const changelog = await readFile(CHANGELOG, "utf8");
  const index = changelog.indexOf(UNRELEASED);
  if (index === -1) {
    console.error(`CHANGELOG.md has no "${UNRELEASED}" heading; refusing to guess where entries go`);
    return 1;
  }

  const insertion = index + UNRELEASED.length;
  const pending = [];
  for (const name of files) {
    const body = (await readFile(join(FRAGMENT_DIR, name), "utf8")).trim();
    if (!body) continue;
    // Idempotence: a fragment whose text is already in the file is an assembled one, not a new entry.
    if (changelog.includes(body)) continue;
    pending.push({ name, body });
  }

  if (pending.length === 0) {
    console.log("every fragment is already assembled; nothing to insert");
    return 0;
  }

  const block = "\n\n" + pending.map((entry) => entry.body).join("\n\n");
  const next = changelog.slice(0, insertion) + block + changelog.slice(insertion);
  await writeFile(CHANGELOG, next, "utf8");

  if (!args.has("--keep")) {
    for (const entry of pending) await unlink(join(FRAGMENT_DIR, entry.name));
  }

  console.log(`inserted ${pending.length} entr${pending.length === 1 ? "y" : "ies"} under ${UNRELEASED}`);
  for (const entry of pending) console.log(`  CHANGELOG.d/${entry.name}${args.has("--keep") ? " (kept)" : ""}`);
  return 0;
}

main().then((code) => process.exit(code)).catch((error) => {
  console.error(error);
  process.exit(1);
});
