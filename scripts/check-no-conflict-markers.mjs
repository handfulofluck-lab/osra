#!/usr/bin/env node
/**
 * Fails when a tracked file contains Git conflict markers.
 *
 * Why a gate and not care: on 2026-10-23 I chained `git merge`, `git add -A` and `git commit` in one shell
 * command. The merge conflicted, `add -A` staged the markers, and the commit went through — so a pushed
 * commit carried `<<<<<<<` in two documentation files and every test stayed green, because no test reads
 * docs. The reviewer's own check (`git grep '<<<<<<<'`) found it; a gate would have found it first.
 *
 * A line of seven `=` characters alone is a legitimate Markdown setext heading underline, and `<<<<<<<`
 * appears in prose about merges (this file, the discussion log). So the rule is deliberately narrow: a
 * file is a conflict when it contains BOTH an opening marker line (`<<<<<<< `) and a closing one
 * (`>>>>>>> `). One marker alone is not enough to fail, because the pair is what Git writes.
 *
 * Usage:
 *   node scripts/check-no-conflict-markers.mjs              # scan tracked files
 *   node scripts/check-no-conflict-markers.mjs --staged     # scan the index instead of the tree
 *   node scripts/check-no-conflict-markers.mjs --selftest   # prove the rule fires and does not false-positive
 *
 * Exits 1 on a marker pair, 2 on an environment problem.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import pathMod from 'node:path';

const argv = process.argv.slice(2);

const OPEN = /^<{7}(\s|$)/;
const CLOSE = /^>{7}(\s|$)/;

/** Files git tracks (or has staged), skipping anything binary by git's own judgement. */
function trackedFiles({ staged }) {
  const args = staged
    ? ['diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z']
    : ['ls-files', '-z'];
  let out;
  try {
    out = execFileSync('git', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    console.error(`cannot list files: ${String(e.stderr ?? e.message).trim()}`);
    process.exit(2);
  }
  return out.split('\0').filter(Boolean);
}

function scan(paths, cwd = process.cwd()) {
  const hits = [];
  for (const p of paths) {
    const abs = pathMod.join(cwd, p);
    let text;
    try {
      text = fs.readFileSync(abs, 'utf8');
    } catch {
      continue; // deleted since listing, or unreadable: not this check's business
    }
    if (text.includes('\u0000')) continue; // binary
    const lines = text.split(/\r?\n/);
    const open = [];
    const close = [];
    lines.forEach((line, i) => {
      if (OPEN.test(line)) open.push(i + 1);
      else if (CLOSE.test(line)) close.push(i + 1);
    });
    if (open.length && close.length) hits.push({ path: p, open, close });
  }
  return hits;
}

function report(hits) {
  if (!hits.length) {
    console.log('no conflict markers in any tracked file');
    return 0;
  }
  for (const h of hits) {
    console.error(`ERROR ${h.path} — conflict markers at line(s) ${h.open.join(', ')} (open) and ${h.close.join(', ')} (close)`);
  }
  console.error('\nA file with both marker lines is what Git leaves behind a conflicted merge. If the merge was');
  console.error('intentional, resolve it and commit the resolution; do not commit the markers.');
  return 1;
}

if (argv.includes('--selftest')) {
  const dir = fs.mkdtempSync(pathMod.join(os.tmpdir(), 'markers-fixture-'));
  const write = (name, body) => fs.writeFileSync(pathMod.join(dir, name), body, 'utf8');
  // A real conflict: both marker lines.
  write('conflicted.md', 'a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> origin/main\n');
  // A setext heading and a prose mention: must NOT fail.
  write('heading.md', 'Title\n=======\n\ntext\n');
  write('prose.md', 'Git writes <<<<<<< HEAD and >>>>>>> branch when a merge conflicts.\n');
  // Only one marker line: not a conflict pair.
  write('half.md', '<<<<<<< HEAD\nours\n');
  const cases = [
    { name: 'a real conflict pair fails', files: ['conflicted.md'], want: 1 },
    { name: 'a setext heading does not fail', files: ['heading.md'], want: 0 },
    { name: 'prose naming the markers does not fail', files: ['prose.md'], want: 0 },
    { name: 'one marker line alone does not fail', files: ['half.md'], want: 0 },
  ];
  let bad = 0;
  for (const c of cases) {
    const got = scan(c.files, dir).length ? 1 : 0;
    if (got !== c.want) {
      bad += 1;
      console.error(`FAIL ${c.name}: want ${c.want}, got ${got}`);
    }
  }
  fs.rmSync(dir, { recursive: true, force: true });
  console.log(`conflict-marker self-test: ${cases.length - bad}/${cases.length} cases`);
  process.exit(bad ? 1 : 0);
}

// This file and the discussion log talk about the markers; the pair rule keeps them out of the failure set
// on their own, but say it here so a reader is not surprised when they appear in a grep.
process.exit(report(scan(trackedFiles({ staged: argv.includes('--staged') }))));
