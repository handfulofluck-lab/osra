#!/usr/bin/env node
/**
 * osra-security#27: `infra/terraform/up.sh` must never reach production with the staging credential.
 *
 * Why this exists. `up.sh` defaults `AWS_PROFILE` to the staging profile, and a production run passes
 * `-var-file=production.tfvars` through `"$@"` like any other argument. So the natural way to run
 * production was with whatever key the shared Windows PC holds — a long-lived staging access key — and
 * the production deploy role it assumes reaches the database password, the JWT signing secret and the
 * vault key, all three of which sit in Terraform state (Fable's review of the production Terraform).
 *
 * A written rule was already in place and had nothing under it. This is the thing under it: the script
 * refuses, before it reads anything, when the run names production and the profile is unset or staging.
 *
 * The checks run the real script with a controlled environment; the guard sits first on purpose, so it
 * fires without terraform or the AWS CLI installed and no cloud account is touched. The self-test removes
 * the guard from a copy and shows the first check stop failing — what a check that cannot fail looks like
 * is the exact shape this repository keeps finding.
 *
 * Usage:
 *   node scripts/check-up-production-guard.mjs
 *   node scripts/check-up-production-guard.mjs --selftest
 *
 * Exit: 0 the guard is in place and behaves · 1 it does not · 2 refused to run (usage, missing file).
 */
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SCRIPT = join(ROOT, 'infra', 'terraform', 'up.sh');

const UNSET_MSG = 'refusing: this run names production and AWS_PROFILE is unset';
const STAGING_MSG = 'refusing: this run names production while AWS_PROFILE is osra-staging';
const GUARD_MARKER = '# osra-security#27: this script defaults the credential to the staging profile';

/** Run up.sh with a controlled environment. Returns {status, stderr}. */
function run(scriptPath, { args = [], profile }) {
  const env = { ...process.env, PATH: process.env.PATH };
  delete env.AWS_PROFILE;
  if (profile !== undefined) env.AWS_PROFILE = profile;
  const out = spawnSync('sh', [scriptPath, ...args], { env, encoding: 'utf8' });
  return { status: out.status, stderr: out.stderr ?? '' };
}

function check(name, condition, detail) {
  if (!condition) {
    console.error(`FAIL ${name}${detail ? ` — ${detail}` : ''}`);
    return false;
  }
  return true;
}

function suite(scriptPath) {
  let ok = true;

  // 1. Production named, no profile: refuse, and say which of the two things is wrong.
  const unset = run(scriptPath, { args: ['-var-file=production.tfvars'] });
  ok = check('production with AWS_PROFILE unset is refused', unset.status === 1 && unset.stderr.includes(UNSET_MSG), `status ${unset.status}`) && ok;

  // 2. Production named, staging profile: refuse. This is the case that would have run.
  const staging = run(scriptPath, { args: ['-var-file=production.tfvars'], profile: 'osra-staging' });
  ok = check('production with the staging profile is refused', staging.status === 1 && staging.stderr.includes(STAGING_MSG), `status ${staging.status}`) && ok;

  // 3. Production named, some other profile: the guard must let it past. It will fail later on the
  //    missing terraform or tfvars, which is a different failure and must not be mistaken for a refusal.
  const other = run(scriptPath, { args: ['-var-file=production.tfvars'], profile: 'osra-production' });
  ok = check('another profile is not refused by the guard', !other.stderr.includes(UNSET_MSG) && !other.stderr.includes(STAGING_MSG), `status ${other.status}`) && ok;

  // 4. A run that does not name production is untouched, whatever the profile.
  const staging2 = run(scriptPath, { profile: 'osra-staging' });
  ok = check('a staging run is not refused by the guard', !staging2.stderr.includes(UNSET_MSG) && !staging2.stderr.includes(STAGING_MSG), `status ${staging2.status}`) && ok;

  return ok;
}

function selftest() {
  const source = readFileSync(SCRIPT, 'utf8');
  if (!source.includes(GUARD_MARKER)) {
    console.error(`FAIL selftest: the guard marker is gone from up.sh, so the self-test cannot remove it`);
    return false;
  }
  // Cut the guard: from the marker to the `esac` that closes it, keeping the rest of the script intact.
  const start = source.indexOf(GUARD_MARKER);
  const esacAt = source.indexOf('esac', start);
  const end = source.indexOf('\n', esacAt) + 1;
  const withoutGuard = source.slice(0, start) + source.slice(end);

  const dir = mkdtempSync(join(tmpdir(), 'up-guard-'));
  const mutated = join(dir, 'up.sh');
  writeFileSync(mutated, withoutGuard);
  try {
    const unset = run(mutated, { args: ['-var-file=production.tfvars'] });
    const caught = !(unset.status === 1 && unset.stderr.includes(UNSET_MSG));
    if (!caught) {
      console.error('FAIL selftest: with the guard removed, a production run with no profile was still refused — the check cannot fail');
      return false;
    }
    console.log('up-production-guard self-test: removing the guard makes check 1 stop passing');
    return true;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

if (process.argv.includes('--selftest')) {
  process.exit(selftest() ? 0 : 1);
}

if (!readFileSync(SCRIPT, 'utf8')) {
  console.error('up.sh is empty or unreadable');
  process.exit(2);
}

const ok = suite(SCRIPT);
if (ok) console.log('up-production-guard: the script refuses production without a production credential (4 checks)');
process.exit(ok ? 0 : 1);
