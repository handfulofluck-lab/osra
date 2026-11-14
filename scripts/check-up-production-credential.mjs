#!/usr/bin/env node
/**
 * osra#768: a production run of `infra/terraform/up.sh` must name its own credential.
 *
 * #765 already refuses a production run with **no** `AWS_PROFILE`. What it still allowed is
 * `OSRA_ENV=production AWS_PROFILE=osra-staging` — explicitly naming the profile that belongs to the
 * other environment. That is the case this check pins: a profile that was given, and is the wrong one.
 *
 * The checks run the real script with a controlled environment. Two details matter:
 *  - **bash, not sh.** `up.sh` is `#!/bin/sh` but uses `set -o pipefail`, so it cannot run where `/bin/sh`
 *    is dash. Spawning `sh` here would test the shell rather than the guard, and on Windows it silently
 *    passed because Git Bash's `sh` is bash.
 *  - **stub `terraform` and `aws` on PATH.** The script checks for both before it reaches the production
 *    block, so a machine without them would fail earlier and every row would be measuring the wrong thing.
 *
 * Usage:
 *   node scripts/check-up-production-credential.mjs
 *   node scripts/check-up-production-credential.mjs --selftest
 *
 * Exit: 0 the guard is in place and behaves · 1 it does not · 2 refused to run.
 */
import { readFileSync, mkdtempSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SCRIPT = join(ROOT, 'infra', 'terraform', 'up.sh');

const UNSET_MSG = 'production: set AWS_PROFILE explicitly';
const STAGING_MSG = 'production: AWS_PROFILE is the staging profile';
const GUARD_MARKER = 'osra#768: the profile must not only be given';

/** A scratch directory holding no-op `terraform` and `aws`, so the script reaches its production block. */
function stubBin() {
  const dir = mkdtempSync(join(tmpdir(), 'up-cred-bin-'));
  for (const name of ['terraform', 'aws']) {
    const file = join(dir, name);
    writeFileSync(file, '#!/bin/sh\nexit 0\n');
    chmodSync(file, 0o755);
  }
  return dir;
}

function run(scriptPath, bin, { env = {} } = {}) {
  const childEnv = { ...process.env, PATH: `${bin}${process.platform === 'win32' ? ';' : ':'}${process.env.PATH}` };
  delete childEnv.AWS_PROFILE;
  delete childEnv.OSRA_ENV;
  Object.assign(childEnv, env);
  const out = spawnSync('bash', [scriptPath], { env: childEnv, encoding: 'utf8' });
  return { status: out.status, stderr: `${out.stdout ?? ''}${out.stderr ?? ''}` };
}

function check(name, condition, detail) {
  if (!condition) {
    console.error(`FAIL ${name}${detail ? ` — ${detail}` : ''}`);
    return false;
  }
  return true;
}

function suite(scriptPath) {
  const bin = stubBin();
  let ok = true;
  try {
    // 1. #765's own rule still holds: production with no profile is refused, and by its message.
    const unset = run(scriptPath, bin, { env: { OSRA_ENV: 'production' } });
    ok = check('production with AWS_PROFILE unset is refused', unset.status === 1 && unset.stderr.includes(UNSET_MSG), `status ${unset.status}`) && ok;

    // 2. The case this PR adds: a profile that was given, and is the staging one.
    const staging = run(scriptPath, bin, { env: { OSRA_ENV: 'production', AWS_PROFILE: 'osra-staging' } });
    ok = check('production naming the staging profile is refused', staging.status === 1 && staging.stderr.includes(STAGING_MSG), `status ${staging.status}`) && ok;

    // 3. A named production profile is not refused by either guard; it fails later on the missing tfvars,
    //    which is a different failure and must not be mistaken for a refusal.
    const named = run(scriptPath, bin, { env: { OSRA_ENV: 'production', AWS_PROFILE: 'osra-production' } });
    ok = check('another profile is not refused by the guard', !named.stderr.includes(UNSET_MSG) && !named.stderr.includes(STAGING_MSG), `status ${named.status}`) && ok;

    // 4. Staging is untouched, even with the staging profile — that is the profile it is supposed to use.
    const onStaging = run(scriptPath, bin, { env: { AWS_PROFILE: 'osra-staging' } });
    ok = check('a staging run is not refused by the guard', !onStaging.stderr.includes(UNSET_MSG) && !onStaging.stderr.includes(STAGING_MSG), `status ${onStaging.status}`) && ok;
  } finally {
    rmSync(bin, { recursive: true, force: true });
  }
  return ok;
}

function selftest() {
  const source = readFileSync(SCRIPT, 'utf8');
  if (!source.includes(GUARD_MARKER)) {
    console.error('FAIL selftest: the guard marker is gone from up.sh, so the self-test cannot remove it');
    return false;
  }
  const start = source.indexOf(GUARD_MARKER);
  const fiAt = source.indexOf('\n  fi\n', start);
  const end = fiAt + '\n  fi\n'.length;
  const withoutGuard = source.slice(0, start) + source.slice(end);

  const dir = mkdtempSync(join(tmpdir(), 'up-cred-selftest-'));
  const mutated = join(dir, 'up.sh');
  writeFileSync(mutated, withoutGuard);
  const bin = stubBin();
  try {
    const staging = run(mutated, bin, { env: { OSRA_ENV: 'production', AWS_PROFILE: 'osra-staging' } });
    const caught = !(staging.status === 1 && staging.stderr.includes(STAGING_MSG));
    if (!caught) {
      console.error('FAIL selftest: with the guard removed, naming the staging profile was still refused — the check cannot fail');
      return false;
    }
    console.log('up-production-credential self-test: removing the guard makes check 2 stop passing');
    return true;
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(bin, { recursive: true, force: true });
  }
}

if (process.argv.includes('--selftest')) process.exit(selftest() ? 0 : 1);

if (!readFileSync(SCRIPT, 'utf8')) {
  console.error('up.sh is empty or unreadable');
  process.exit(2);
}

const ok = suite(SCRIPT);
if (ok) console.log('up-production-credential: production never runs on the staging profile by name (4 checks)');
process.exit(ok ? 0 : 1);
