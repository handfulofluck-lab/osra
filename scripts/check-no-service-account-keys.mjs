#!/usr/bin/env node
/**
 * Fails when a tracked file contains a Google service-account key or a PEM private key.
 *
 * Why a content check when `.gitignore` already names the files (roadmap 1.5): name rules miss a renamed
 * file. `firebase.json`, `keys.json`, `backup/service.json` and `google-services (2).json.bak` are all names
 * no glob covers, and a credential is only dangerous once it is committed — a public repository keeps it
 * forever, in every clone and in every fork.
 *
 * The two literals below are the parts of a Google service account and a PEM private key that cannot be
 * avoided: `"type": "service_account"` appears in every service-account JSON Google issues, and the PEM
 * header opens every RSA/EC private key. Quoting either in documentation would trip this check, so the docs
 * describe them instead of printing them — that is deliberate, not an oversight.
 *
 * Usage:
 *   node scripts/check-no-service-account-keys.mjs            # tracked files
 *   node scripts/check-no-service-account-keys.mjs --selftest # prove it fires, and that ordinary files pass
 *
 * Exits 1 on a hit, 2 on an environment problem.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import pathMod from 'node:path';

const SELF = 'scripts/check-no-service-account-keys.mjs';

/** Built here rather than inline so a grep for the literal does not show this file as a hit. */
const MARKERS = [
  ['"type": "service_account"', 'a Google service-account JSON'],
  [`${'-'.repeat(5)}BEGIN ${'PRIVATE'} KEY${'-'.repeat(5)}`, 'a PEM private key'],
];

function trackedFiles() {
  try {
    return execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
      .split('\0')
      .filter(Boolean);
  } catch (e) {
    console.error(`cannot list tracked files: ${String(e.stderr ?? e.message).trim()}`);
    process.exit(2);
  }
}

function scan(paths, cwd = process.cwd()) {
  const hits = [];
  for (const p of paths) {
    if (p === SELF) continue; // this file has to name the markers to look for them
    let text;
    try {
      text = fs.readFileSync(pathMod.join(cwd, p), 'utf8');
    } catch {
      continue; // unreadable or deleted since listing
    }
    if (text.includes('\u0000')) continue; // binary
    for (const [marker, what] of MARKERS) {
      const at = text.indexOf(marker);
      if (at === -1) continue;
      const line = text.slice(0, at).split('\n').length;
      hits.push({ path: p, line, what });
    }
  }
  return hits;
}

function report(hits) {
  if (!hits.length) {
    console.log('no service-account or private-key material in any tracked file');
    return 0;
  }
  for (const h of hits) {
    console.error(`ERROR ${h.path}:${h.line} — looks like ${h.what}`);
  }
  console.error('\nA committed credential stays in the history of every clone. Remove the file, rotate the key, and');
  console.error('if it was ever pushed, tell the maintainer: deleting it in a new commit is not enough.');
  return 1;
}

if (process.argv.includes('--selftest')) {
  const dir = fs.mkdtempSync(pathMod.join(os.tmpdir(), 'keys-fixture-'));
  const write = (name, body) => fs.writeFileSync(pathMod.join(dir, name), body, 'utf8');
  write('service-account.json', `{ "type": "service_account", "project_id": "x" }\n`);
  write('key.pem', `${'-'.repeat(5)}BEGIN ${'PRIVATE'} KEY${'-'.repeat(5)}\nMIIE...\n`);
  write('ordinary.json', '{ "type": "module", "name": "osra" }\n');
  write('prose.md', 'A service account JSON is issued by Google; this file does not contain one.\n');
  const cases = [
    { name: 'a service-account JSON fails', files: ['service-account.json'], want: 1 },
    { name: 'a PEM private key fails', files: ['key.pem'], want: 1 },
    { name: 'an ordinary package file passes', files: ['ordinary.json'], want: 0 },
    { name: 'prose about service accounts passes', files: ['prose.md'], want: 0 },
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
  console.log(`service-account self-test: ${cases.length - bad}/${cases.length} cases`);
  process.exit(bad ? 1 : 0);
}

process.exit(report(scan(trackedFiles())));
