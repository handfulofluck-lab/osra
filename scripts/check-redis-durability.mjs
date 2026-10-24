#!/usr/bin/env node
/**
 * Fails when the staging ElastiCache configuration can lose revocation state (ADR-0032).
 *
 * The API stores every revocation in Postgres and treats Redis as a cache: the per-parent sessions
 * version (`auth:session-version:<parentId>`), single logout (`revoked:token:<jti>`) and an unpaired
 * device (`revoked:device:<deviceId>`). A miss on any of those keys sends the API to the database, so
 * the cache is worth having only if it is not silently emptied. Two settings decide that:
 *
 *  - `maxmemory-policy`. The Redis default `allkeys-lru` evicts *any* key under memory pressure —
 *    including the three above — and an evicted version key reads as "nothing was revoked". The
 *    parameter group must pin `noeviction`, so a full node refuses writes and the API fails closed
 *    instead of losing a revocation.
 *  - `snapshot_retention_limit`. `0` disables snapshots. A restarted node then comes back empty and
 *    every revocation lives only in Postgres; a snapshot bounds that window. At least one daily
 *    snapshot is the floor this check enforces.
 *
 * Both are read from `infra/terraform/env/elasticache.tf` as text, comment-stripped so a sentence
 * about the policy cannot satisfy the check.
 *
 * Usage:
 *   node scripts/check-redis-durability.mjs                    # the repository's file
 *   node scripts/check-redis-durability.mjs --file <path>      # another file (fixtures)
 *   node scripts/check-redis-durability.mjs --selftest         # prove it fires, and that the fixed file passes
 *
 * Exits 1 on a violation, 2 on an environment problem (missing file, no parameter group).
 */
import fs from 'node:fs';
import os from 'node:os';
import pathMod from 'node:path';

const DEFAULT_FILE = 'infra/terraform/env/elasticache.tf';

const argv = process.argv.slice(2);
const flagValue = (name) => {
  const i = argv.indexOf(name);
  return i === -1 ? null : argv[i + 1] ?? null;
};

/**
 * Blank out `#` and `//` comments while keeping every newline, so line-anchored parsing still works
 * and prose that mentions `maxmemory-policy = noeviction` cannot stand in for the setting.
 */
function stripComments(text) {
  return text
    .split('\n')
    .map((line) => {
      let out = '';
      let inString = false;
      for (let i = 0; i < line.length; i += 1) {
        const ch = line[i];
        if (ch === '"' && line[i - 1] !== '\\') inString = !inString;
        if (!inString && (ch === '#' || (ch === '/' && line[i + 1] === '/'))) break;
        out += ch;
      }
      return out;
    })
    .join('\n');
}

/** The brace-balanced body of the first `resource "<type>" "<name>" {` block, or null. */
function resourceBody(text, type, name) {
  const re = new RegExp(`resource\\s+"${type}"\\s+"${name}"\\s*\\{`);
  const start = text.search(re);
  if (start === -1) return null;
  let depth = 0;
  for (let i = text.indexOf('{', start); i < text.length; i += 1) {
    if (text[i] === '{') depth += 1;
    if (text[i] === '}') {
      depth -= 1;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return null;
}

export function checkDurability(text) {
  const code = stripComments(text);
  const problems = [];

  const group = resourceBody(code, 'aws_elasticache_parameter_group', 'cache');
  if (!group) {
    problems.push('infra/terraform/env/elasticache.tf: no `aws_elasticache_parameter_group "cache"` resource — the parameter group this check reads is gone or renamed');
  } else {
    const values = [...group.matchAll(/name\s*=\s*"maxmemory-policy"\s*\n?\s*value\s*=\s*"([^"]*)"/g)].map((m) => m[1]);
    if (values.length === 0) {
      problems.push('the `cache` parameter group sets no `maxmemory-policy` — Redis defaults to `allkeys-lru`, which evicts the revocation keys under memory pressure and reads as "nothing was revoked"');
    } else if (values.some((v) => v !== 'noeviction')) {
      problems.push(`the \`cache\` parameter group sets \`maxmemory-policy = ${values.join(', ')}\` — it must be \`noeviction\`, or the revocation keys can be evicted`);
    }
  }

  const replication = resourceBody(code, 'aws_elasticache_replication_group', 'main');
  if (!replication) {
    problems.push('infra/terraform/env/elasticache.tf: no `aws_elasticache_replication_group "main"` resource — the snapshot setting this check reads is gone or renamed');
  } else {
    const limit = replication.match(/snapshot_retention_limit\s*=\s*(\d+)/);
    if (!limit) {
      // The provider's default is 0 (snapshots off), so an absent setting is the failure, not a pass.
      problems.push('the replication group does not set `snapshot_retention_limit`; the provider default is 0 (no snapshots), so a restart returns an empty cache');
    } else if (Number(limit[1]) < 1) {
      problems.push(`the replication group sets \`snapshot_retention_limit = ${limit[1]}\` — at least 1 daily snapshot is required (ADR-0032)`);
    }
  }

  return problems;
}

function run(file = DEFAULT_FILE) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    console.error(`cannot read ${file}: ${e.message}`);
    process.exit(2);
  }
  const problems = checkDurability(text);
  if (problems.length) {
    for (const p of problems) console.error(`FAIL  ${p}`);
    console.error('');
    console.error('Revocation state is not reconstructible by Redis behaviour: Postgres holds the record');
    console.error('(ADR-0032), and these two settings are what stop the cache from silently disagreeing.');
    process.exit(1);
  }
  console.log(`redis durability: ${file} sets maxmemory-policy=noeviction and snapshot_retention_limit>=1`);
}

if (argv.includes('--selftest')) {
  const dir = fs.mkdtempSync(pathMod.join(os.tmpdir(), 'redis-durability-'));
  const fixture = (name, body) => {
    const p = pathMod.join(dir, name);
    fs.writeFileSync(p, body);
    return p;
  };

  // The pre-fix file, in the shape this repository actually had: an empty parameter group and
  // `snapshot_retention_limit = 0`, with the sentence that justified it.
  const BEFORE = `resource "aws_elasticache_parameter_group" "cache" {
  name   = "x-redis7"
  family = "redis7"
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "x-redis"
  # No snapshots: cache contents are reconstructible and staging does not pay for backups.
  snapshot_retention_limit = 0
}
`;

  const cases = [
    {
      name: 'the pre-fix file fails, naming both settings',
      file: fixture('before.tf', BEFORE),
      want: 1,
      expect: ['maxmemory-policy', 'snapshot_retention_limit = 0'],
    },
    {
      name: 'a comment claiming noeviction does not satisfy the check',
      file: fixture('comment-only.tf', BEFORE.replace('family = "redis7"', 'family = "redis7"\n  # maxmemory-policy = noeviction')),
      want: 1,
      expect: ['maxmemory-policy'],
    },
    {
      name: 'allkeys-lru fails even with snapshots on',
      file: fixture('lru.tf', BEFORE
        .replace('family = "redis7"', 'family = "redis7"\n  parameter {\n    name  = "maxmemory-policy"\n    value = "allkeys-lru"\n  }')
        .replace('snapshot_retention_limit = 0', 'snapshot_retention_limit = 1')),
      want: 1,
      expect: ['allkeys-lru'],
    },
    {
      name: 'noeviction with no snapshot setting fails (provider default is 0)',
      file: fixture('no-snapshot.tf', BEFORE
        .replace('family = "redis7"', 'family = "redis7"\n  parameter {\n    name  = "maxmemory-policy"\n    value = "noeviction"\n  }')
        .replace(/snapshot_retention_limit = 0/, '')),
      want: 1,
      expect: ['snapshot_retention_limit'],
    },
    {
      name: 'noeviction plus one day of snapshots passes',
      file: fixture('after.tf', BEFORE
        .replace('family = "redis7"', 'family = "redis7"\n  parameter {\n    name  = "maxmemory-policy"\n    value = "noeviction"\n  }')
        .replace('snapshot_retention_limit = 0', 'snapshot_retention_limit = 1')),
      want: 0,
      expect: [],
    },
    {
      name: 'a missing file is an environment error, not a pass',
      file: pathMod.join(dir, 'absent.tf'),
      want: 2,
      expect: ['cannot read'],
    },
  ];

  let bad = 0;
  for (const c of cases) {
    let out = '';
    let code = 0;
    const realExit = process.exit;
    const realError = console.error;
    const realLog = console.log;
    // Run the check in-process: --selftest must not fork, because a fork's stderr is invisible to CI's
    // step summary and swallows the reason a case failed.
    process.exit = (n) => { throw new Error(`__exit__${n}`); };
    console.error = (line) => { out += `${line}\n`; };
    console.log = () => {};
    try {
      run(c.file);
      code = 0;
    } catch (e) {
      const m = /^__exit__(\d+)$/.exec(e.message);
      code = m ? Number(m[1]) : 1;
      if (!m) out += `${e.message}\n`;
    } finally {
      process.exit = realExit;
      console.error = realError;
      console.log = realLog;
    }
    const missing = c.expect.filter((needle) => !out.includes(needle));
    const ok = code === c.want && missing.length === 0;
    if (!ok) bad += 1;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${c.name} — exit ${code}, want ${c.want}${missing.length ? `; not said: ${missing.join(', ')}` : ''}`);
  }
  console.log(`redis-durability self-test: ${cases.length - bad}/${cases.length} cases`);
  fs.rmSync(dir, { recursive: true, force: true });
  process.exit(bad ? 1 : 0);
}

if (process.argv[1] && pathMod.resolve(process.argv[1]) === pathMod.resolve(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'))) {
  run(flagValue('--file') ?? DEFAULT_FILE);
  process.exit(0);
}
