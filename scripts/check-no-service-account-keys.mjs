#!/usr/bin/env node
/**
 * Fails when a tracked file contains a Google service-account key or a PEM private key.
 *
 * Why a content check when `.gitignore` already names the files (roadmap 1.5): name rules miss a renamed
 * file. `firebase.json`, `keys.json`, `backup/service.json` and `google-services (2).json.bak` are all names
 * no glob covers, and a credential is only dangerous once it is committed — a public repository keeps it
 * forever, in every clone and in every fork.
 *
 * The two patterns below match the parts of a Google service account and a PEM private key that cannot be
 * avoided. The PEM one is built from a repeated dash so a plain grep for the header does not show this
 * repository as a hit; the service-account pattern is written plainly, which is harmless because `SELF` is
 * skipped. The docs describe both instead of printing them.
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

/**
 * Regexes, not literals: minified JSON has no spaces, a service account can be escaped inside a `.env`
 * string, and the PEM header has five spellings (PKCS#8, RSA, EC, OPENSSH, ENCRYPTED). The first version of
 * this check matched one spelling and the spaced JSON, and its comment claimed otherwise (#318 review).
 */
const MARKERS = [
  [/\\?"type\\?"\s*:\s*\\?"service_account\\?"/, 'a Google service-account JSON'],
  [new RegExp(`${'-'.repeat(5)}BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY${'-'.repeat(5)}`), 'a PEM private key'],
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
    if (p === SELF) continue; // this file has to name the patterns to look for them
    let text;
    try {
      text = fs.readFileSync(pathMod.join(cwd, p), 'utf8');
    } catch {
      continue; // unreadable or deleted since listing
    }
    if (text.includes('\u0000')) continue; // binary
    for (const [re, what] of MARKERS) {
      const m = re.exec(text);
      if (!m) continue;
      const line = text.slice(0, m.index).split('\n').length;
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
  const dashes = '-'.repeat(5);
  write('service-account.json', `{ "type": "service_account", "project_id": "x" }\n`);
  write('minified.json', '{"type":"service_account","project_id":"x"}\n');
  write('escaped.env', 'FCM_SERVICE_ACCOUNT_JSON={\\"type\\": \\"service_account\\"}\n');
  write('key.pem', `${dashes}BEGIN PRIVATE KEY${dashes}\nMIIE...\n`);
  write('legacy-rsa.pem', `${dashes}BEGIN RSA PRIVATE KEY${dashes}\nMIIE...\n`);
  write('openssh.key', `${dashes}BEGIN OPENSSH PRIVATE KEY${dashes}\nb3Bl...\n`);
  write('ordinary.json', '{ "type": "module", "name": "osra" }\n');
  write('prose.md', 'A service account JSON is issued by Google; this file does not contain one.\n');
  const cases = [
    { name: 'a service-account JSON fails', files: ['service-account.json'], want: 1 },
    { name: 'minified service-account JSON fails', files: ['minified.json'], want: 1 },
    { name: 'an escaped service account in a .env string fails', files: ['escaped.env'], want: 1 },
    { name: 'a PEM private key fails', files: ['key.pem'], want: 1 },
    { name: 'a legacy RSA private key fails', files: ['legacy-rsa.pem'], want: 1 },
    { name: 'an OpenSSH private key fails', files: ['openssh.key'], want: 1 },
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
