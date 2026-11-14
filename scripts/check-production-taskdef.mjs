#!/usr/bin/env node
/**
 * Reads a production ECS task definition and fails when it is not a release configuration
 * (release security gate #637, "no debug flags, no environment or server overrides, no test endpoints").
 *
 * The API decides a great deal from its environment: whether a missing e-mail provider echoes a reset token,
 * whether any browser origin is accepted, whether the demo family is seeded, whether a legacy signature is
 * still honoured. Each of those is right somewhere (a developer's machine, staging, CI) and wrong for real
 * families' data. Terraform's production guard checks what Terraform was told; this checks what AWS was
 * actually given, so a hand-edited task definition or a variable added in the console is caught too.
 *
 * Input is what `aws ecs describe-task-definition --task-definition <family>` prints, saved to a file:
 *
 *   node scripts/check-production-taskdef.mjs --file taskdef.json            # launch configuration
 *   node scripts/check-production-taskdef.mjs --file taskdef.json --pre-launch
 *   node scripts/check-production-taskdef.mjs --source                       # every variable the API reads is classified
 *   node scripts/check-production-taskdef.mjs --selftest                     # one fixture per rule
 *
 * `--pre-launch` reports the LAUNCH group (iPhone push, Play billing) as PENDING instead of failing, for the
 * days when the stack exists and the store credentials do not. Nothing in the SECURITY group can be waived.
 *
 * The output names variables and never prints a value: an `environment` entry can hold something that should
 * have been a secret, which is one of the things this looks for.
 *
 * Exits 0 clean · 1 a finding · 2 the input could not be read or an argument is not one of the above.
 */
import fs from 'node:fs';
import pathMod from 'node:path';

// ── What the API reads (services/api/src), and where each may appear in production ────────────────────────

/** Must be present, and must be a `secrets` entry (Secrets Manager), never a plain `environment` value. */
const REQUIRED_SECRETS = ['DATABASE_URL', 'JWT_SECRET', 'VAULT_KEY', 'INTERNAL_HMAC_SECRET'];

/** May be absent; when present, only as a `secrets` entry. */
const SECRET_ONLY = ['FCM_SERVICE_ACCOUNT_JSON', 'APNS_KEY_P8', 'RESEND_API_KEY'];

/** Must be present with a value that passes its rule. A rule returns a reason, or null. */
const REQUIRED_SECURITY = {
  NODE_ENV: (v) => (v === 'production' ? null : 'must be "production"'),
  TRUST_PROXY: (v) => (/^[1-9]\d*$/.test(v) ? null : 'must be a hop count (1 behind the load balancer), never "true" or 0'),
  CORS_ORIGIN: (v) => {
    const origins = v.split(',').map((o) => o.trim()).filter(Boolean);
    if (origins.length === 0) return 'must name at least one origin';
    const bad = origins.filter((o) => !/^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(o));
    return bad.length ? `${bad.length} origin(s) are not plain https:// origins` : null;
  },
  DATABASE_TLS_VERIFY: (v) => (v === 'required' ? null : 'must be "required" (services/api/src/lib/databaseTls.ts)'),
  EMAIL_PROVIDER: (v) => (v === 'ses' ? null : 'must be "ses": without a provider no reset, invite or deletion mail is sent'),
  EMAIL_FROM: (v) => (/@/.test(v) ? null : 'must be a sender address'),
  APP_PUBLIC_URL: (v) => (/^https:\/\/[a-z0-9.-]+(\/.*)?$/i.test(v) && !/localhost|127\.0\.0\.1/.test(v) ? null : 'must be the public https:// address that mailed links open'),
};

/** REDIS_URL may be plain (no credential) or a secret (it carries the AUTH token). Checked on its own below. */

/** Needed before families can use the product, not for the stack to be safe. `--pre-launch` reports, launch fails. */
const REQUIRED_LAUNCH = {
  APNS_KEY_ID: null,
  APNS_TEAM_ID: null,
  APNS_BUNDLE_ID: null,
  PLAY_PACKAGE_NAME: null,
  PLAY_SERVICE_ACCOUNT_SECRET_NAME: null,
  PLAY_RTDN_AUDIENCE: null,
  PLAY_RTDN_SERVICE_ACCOUNT_EMAIL: null,
};
const LAUNCH_SECRETS = ['APNS_KEY_P8', 'FCM_SERVICE_ACCOUNT_JSON'];

/** Development, staging and test switches. Present at all = a finding, whatever the value. */
const FORBIDDEN = {
  CORS_ALLOW_ANY_ORIGIN: 'accepts every browser origin with credentials (staging and the CI image check only)',
  SEED_DEMO_PASSWORD: 'the demo family is never seeded in production',
  SKIP_PRISMA_SYNC_CHECK: 'skips the schema-drift check at boot',
  IDLE_BUDGET_COUNTING: 'staging instrument; it fills the cache that holds revocations (#346)',
  IDLE_BUDGET_M10: 'staging instrument (#346)',
  INTERNAL_SIGNING_ALLOW_V1: 'honours the legacy internal signature',
  FCM_SERVICE_ACCOUNT_FILE: 'a credential read from a file in the image; production uses the secret entry',
  CLIENT_POLICY: 'set only by a reviewed change; a stray policy locks clients out or lets old ones in',
};

/** Allowed, optional, plain. A value rule where a wrong value matters. */
const OPTIONAL = {
  PORT: null,
  LOG_LEVEL: (v) => (['info', 'warn', 'error', 'fatal'].includes(v) ? null : 'must be info, warn, error or fatal (debug and trace log request detail)'),
  AWS_REGION: (v) => (v === 'eu-central-1' ? null : 'production is Frankfurt, eu-central-1 (ADR-0030)'),
  APNS_ENV: (v) => (v === 'production' ? null : 'must be "production" when set: sandbox pushes reach no released app'),
  APNS_DEVICE_BUNDLE_ID: null,
  // ADR-0033: the scorer is a private service in the same VPC. A public address would send a child's text out.
  AI_ENGINE_URL: (v) => (/^http:\/\/[a-z0-9.-]+\.(internal|local)(:\d+)?(\/.*)?$/i.test(v) ? null : 'must be the private service address inside the VPC (ADR-0033), not a public host'),
  INTERNAL_SERVICE_CALLERS: null,
  JOBS_ENABLED: null,
  DIGEST_HOUR: null,
  DIGEST_HOUR_UTC: null,
  ROLLUP_HOUR_UTC: null,
  PUSH_MIN_SEVERITY: null,
  DEVICE_SILENT_MINUTES: null,
  // Retention is a promise in the privacy policy. Longer than the promise is a finding; shorter is a choice.
  LOCATION_RETENTION_DAYS: (v) => (Number(v) >= 1 && Number(v) <= 30 ? null : 'location history is kept 30 days at most (ADR-0028 decision 5)'),
  RETENTION_DAYS: (v) => (Number(v) >= 1 && Number(v) <= 90 ? null : 'activity is kept 90 days at most (privacy policy)'),
  ALERT_RETENTION_DAYS: null,
  ROLLUP_RETENTION_DAYS: null,
};

const KNOWN = new Set([
  ...REQUIRED_SECRETS, ...SECRET_ONLY, 'REDIS_URL',
  ...Object.keys(REQUIRED_SECURITY), ...Object.keys(REQUIRED_LAUNCH), ...Object.keys(FORBIDDEN), ...Object.keys(OPTIONAL),
]);
const MUST_BE_SECRET = new Set([...REQUIRED_SECRETS, ...SECRET_ONLY]);

// ── The check ────────────────────────────────────────────────────────────────────────────────────────────

/** @returns {{findings: string[], pending: string[]}} */
export function checkTaskDefinition(doc, { preLaunch = false } = {}) {
  const findings = [];
  const pending = [];
  const task = doc?.taskDefinition ?? doc;
  const containers = task?.containerDefinitions;
  if (!Array.isArray(containers) || containers.length === 0) {
    return { findings: ['no containerDefinitions: this is not a task definition'], pending };
  }
  const api = containers.find((c) => c.name === 'api');
  if (!api) return { findings: ['no container named "api"'], pending };
  if (containers.length > 1) findings.push(`${containers.length} containers; production's task has one, "api"`);

  // Image: an immutable reference in the production repository, so what runs is what was reviewed.
  const image = String(api.image ?? '');
  const ref = image.includes('@') ? image.split('@')[1] : image.split(':').pop();
  if (!/^\d{12}\.dkr\.ecr\.eu-central-1\.amazonaws\.com\/osra-production\/api[:@]/.test(image)) {
    findings.push('image: not from the osra-production/api repository in eu-central-1');
  }
  // api-publish.yml tags with the 12-character commit sha (`git rev-parse --short=12`); the repository's tags are
  // immutable, so that names one image for good. A digest or the full sha is accepted too; a word is not.
  if (!/^sha256:[0-9a-f]{64}$/.test(ref) && !/^([0-9a-f]{12}|[0-9a-f]{40})$/.test(ref)) {
    findings.push('image: not pinned to a digest or a commit sha of 12 or 40 characters (a moving tag such as "latest" can change under the service)');
  }

  if (api.privileged === true) findings.push('container: privileged');
  if (api.user !== undefined && /^(0|root)(:|$)/.test(String(api.user))) findings.push('container: runs as root');
  if (api.logConfiguration?.logDriver !== 'awslogs') findings.push('logConfiguration: not awslogs, so the API log is not kept');
  if (api.command || api.entryPoint) findings.push('container: command or entryPoint overrides the image (the service runs the image as built)');

  const env = new Map();
  for (const e of api.environment ?? []) {
    if (env.has(e.name)) findings.push(`${e.name}: given twice in environment`);
    env.set(e.name, String(e.value ?? ''));
  }
  const secrets = new Set();
  for (const s of api.secrets ?? []) {
    if (secrets.has(s.name)) findings.push(`${s.name}: given twice in secrets`);
    secrets.add(s.name);
    if (!/^arn:aws:(secretsmanager|ssm):eu-central-1:\d{12}:/.test(String(s.valueFrom ?? ''))) {
      findings.push(`${s.name}: its secret is not a Secrets Manager or Parameter Store ARN in eu-central-1`);
    }
  }
  for (const name of env.keys()) if (secrets.has(name)) findings.push(`${name}: in both environment and secrets`);

  for (const name of [...env.keys(), ...secrets]) {
    if (FORBIDDEN[name]) findings.push(`${name}: not allowed in production: ${FORBIDDEN[name]}`);
    else if (!KNOWN.has(name)) findings.push(`${name}: unknown variable. Classify it in scripts/check-production-taskdef.mjs or remove it`);
  }
  for (const name of MUST_BE_SECRET) {
    if (env.has(name)) findings.push(`${name}: is a plain environment value; it must be a secrets entry`);
  }
  for (const name of REQUIRED_SECRETS) if (!secrets.has(name) && !env.has(name)) findings.push(`${name}: missing`);

  for (const [name, rule] of Object.entries(REQUIRED_SECURITY)) {
    if (secrets.has(name)) continue; // a value held in Secrets Manager cannot be read here
    if (!env.has(name)) findings.push(`${name}: missing`);
    else {
      const reason = rule(env.get(name));
      if (reason) findings.push(`${name}: ${reason}`);
    }
  }
  for (const [name, rule] of Object.entries(OPTIONAL)) {
    if (!env.has(name) || !rule) continue;
    const reason = rule(env.get(name));
    if (reason) findings.push(`${name}: ${reason}`);
  }

  // The cache holds sessions and revocations. Plain: TLS and no credential in the value. Secret: cannot be read.
  if (env.has('REDIS_URL')) {
    const v = env.get('REDIS_URL');
    if (!v.startsWith('rediss://')) findings.push('REDIS_URL: must be rediss:// (TLS to the cache)');
    if (/^rediss?:\/\/[^/]*@/.test(v)) findings.push('REDIS_URL: carries a credential in a plain environment value; make it a secrets entry');
  } else if (!secrets.has('REDIS_URL')) {
    findings.push('REDIS_URL: missing');
  }

  for (const name of [...Object.keys(REQUIRED_LAUNCH), ...LAUNCH_SECRETS]) {
    if (env.has(name) || secrets.has(name)) continue;
    (preLaunch ? pending : findings).push(`${name}: missing${preLaunch ? '' : ' (needed at launch; --pre-launch reports it as pending)'}`);
  }
  return { findings, pending };
}

// ── --source: every variable the API reads is classified above ──────────────────────────────────────────

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = pathMod.join(dir, e.name);
    return e.isDirectory() ? walk(p) : p.endsWith('.ts') ? [p] : [];
  });
}

/** Names read as `env.X`, `process.env.X`, `envVars.X` or destructured from one of those. */
export function variablesReadBy(sourceText) {
  const names = new Set();
  for (const m of sourceText.matchAll(/\b(?:process\.env|env|envVars)\.([A-Z][A-Z0-9_]+)\b/g)) names.add(m[1]);
  for (const m of sourceText.matchAll(/\{([^{}]+)\}\s*=\s*(?:process\.env|env|envVars)\b/g)) {
    for (const part of m[1].split(',')) {
      const name = part.split(':')[0].trim();
      if (/^[A-Z][A-Z0-9_]+$/.test(name)) names.add(name);
    }
  }
  return names;
}

function checkSource(root = 'services/api/src') {
  const read = new Set();
  for (const file of walk(root)) for (const n of variablesReadBy(fs.readFileSync(file, 'utf8'))) read.add(n);
  const unclassified = [...read].filter((n) => !KNOWN.has(n)).sort();
  return { read, unclassified };
}

// ── --selftest ───────────────────────────────────────────────────────────────────────────────────────────

const ARN = 'arn:aws:secretsmanager:eu-central-1:000000000000:secret:osra-production/';
function goodTask() {
  return {
    taskDefinition: {
      family: 'osra-production-api',
      containerDefinitions: [{
        name: 'api',
        image: `000000000000.dkr.ecr.eu-central-1.amazonaws.com/osra-production/api:${'a'.repeat(40)}`,
        environment: [
          { name: 'NODE_ENV', value: 'production' },
          { name: 'PORT', value: '3000' },
          { name: 'LOG_LEVEL', value: 'info' },
          { name: 'TRUST_PROXY', value: '1' },
          { name: 'REDIS_URL', value: 'rediss://cache.example.internal:6379' },
          { name: 'CORS_ORIGIN', value: 'https://app.osratech.com' },
          { name: 'DATABASE_TLS_VERIFY', value: 'required' },
          { name: 'EMAIL_PROVIDER', value: 'ses' },
          { name: 'EMAIL_FROM', value: 'no-reply@osratech.com' },
          { name: 'APP_PUBLIC_URL', value: 'https://app.osratech.com' },
          { name: 'APNS_KEY_ID', value: 'x' }, { name: 'APNS_TEAM_ID', value: 'x' }, { name: 'APNS_BUNDLE_ID', value: 'x' },
          { name: 'PLAY_PACKAGE_NAME', value: 'x' }, { name: 'PLAY_SERVICE_ACCOUNT_SECRET_NAME', value: 'x' },
          { name: 'PLAY_RTDN_AUDIENCE', value: 'x' }, { name: 'PLAY_RTDN_SERVICE_ACCOUNT_EMAIL', value: 'x' },
        ],
        secrets: ['DATABASE_URL', 'JWT_SECRET', 'VAULT_KEY', 'INTERNAL_HMAC_SECRET', 'APNS_KEY_P8', 'FCM_SERVICE_ACCOUNT_JSON']
          .map((name) => ({ name, valueFrom: `${ARN}${name.toLowerCase()}` })),
        logConfiguration: { logDriver: 'awslogs' },
      }],
    },
  };
}

function selftest() {
  const api = (t) => t.taskDefinition.containerDefinitions[0];
  const setEnv = (t, name, value) => {
    const e = api(t).environment.find((x) => x.name === name);
    if (e) e.value = value; else api(t).environment.push({ name, value });
  };
  const dropEnv = (t, name) => { api(t).environment = api(t).environment.filter((x) => x.name !== name); };
  const dropSecret = (t, name) => { api(t).secrets = api(t).secrets.filter((x) => x.name !== name); };

  /** [label, mutation, text the one finding must contain] — each fixture differs from the good one by one thing. */
  const cases = [
    ['NODE_ENV=development', (t) => setEnv(t, 'NODE_ENV', 'development'), 'NODE_ENV: must be "production"'],
    ['any-origin switch', (t) => setEnv(t, 'CORS_ALLOW_ANY_ORIGIN', '1'), 'CORS_ALLOW_ANY_ORIGIN: not allowed'],
    ['wildcard origin', (t) => setEnv(t, 'CORS_ORIGIN', '*'), 'CORS_ORIGIN: 1 origin(s)'],
    ['http origin', (t) => setEnv(t, 'CORS_ORIGIN', 'https://app.osratech.com,http://app.osratech.com'), 'CORS_ORIGIN: 1 origin(s)'],
    ['demo seed password', (t) => api(t).secrets.push({ name: 'SEED_DEMO_PASSWORD', valueFrom: `${ARN}demo` }), 'SEED_DEMO_PASSWORD: not allowed'],
    ['schema check skipped', (t) => setEnv(t, 'SKIP_PRISMA_SYNC_CHECK', '1'), 'SKIP_PRISMA_SYNC_CHECK: not allowed'],
    ['legacy signature', (t) => setEnv(t, 'INTERNAL_SIGNING_ALLOW_V1', '0'), 'INTERNAL_SIGNING_ALLOW_V1: not allowed'],
    ['idle counter', (t) => setEnv(t, 'IDLE_BUDGET_COUNTING', '1'), 'IDLE_BUDGET_COUNTING: not allowed'],
    ['debug logging', (t) => setEnv(t, 'LOG_LEVEL', 'debug'), 'LOG_LEVEL: must be info'],
    ['TRUST_PROXY=true', (t) => setEnv(t, 'TRUST_PROXY', 'true'), 'TRUST_PROXY: must be a hop count'],
    ['database TLS switch missing', (t) => dropEnv(t, 'DATABASE_TLS_VERIFY'), 'DATABASE_TLS_VERIFY: missing'],
    ['database TLS switch misspelt', (t) => setEnv(t, 'DATABASE_TLS_VERIFY', 'require'), 'DATABASE_TLS_VERIFY: must be "required"'],
    ['plaintext cache', (t) => setEnv(t, 'REDIS_URL', 'redis://cache.example.internal:6379'), 'REDIS_URL: must be rediss://'],
    ['cache credential in plain value', (t) => setEnv(t, 'REDIS_URL', 'rediss://:token@cache.example.internal:6379'), 'REDIS_URL: carries a credential'],
    ['cache address missing', (t) => dropEnv(t, 'REDIS_URL'), 'REDIS_URL: missing'],
    ['JWT secret as plain value', (t) => { dropSecret(t, 'JWT_SECRET'); setEnv(t, 'JWT_SECRET', 'x'); }, 'JWT_SECRET: is a plain environment value'],
    ['database URL as plain value', (t) => { dropSecret(t, 'DATABASE_URL'); setEnv(t, 'DATABASE_URL', 'x'); }, 'DATABASE_URL: is a plain environment value'],
    ['vault key missing', (t) => dropSecret(t, 'VAULT_KEY'), 'VAULT_KEY: missing'],
    ['service secret missing', (t) => dropSecret(t, 'INTERNAL_HMAC_SECRET'), 'INTERNAL_HMAC_SECRET: missing'],
    ['secret from another region', (t) => { api(t).secrets[0].valueFrom = api(t).secrets[0].valueFrom.replace('eu-central-1', 'eu-north-1'); }, 'DATABASE_URL: its secret is not'],
    ['no mail provider', (t) => dropEnv(t, 'EMAIL_PROVIDER'), 'EMAIL_PROVIDER: missing'],
    ['links to localhost', (t) => setEnv(t, 'APP_PUBLIC_URL', 'http://localhost:3000'), 'APP_PUBLIC_URL: must be the public'],
    ['sandbox push', (t) => setEnv(t, 'APNS_ENV', 'sandbox'), 'APNS_ENV: must be "production"'],
    ['public scorer address', (t) => setEnv(t, 'AI_ENGINE_URL', 'https://api.example.com'), 'AI_ENGINE_URL: must be the private'],
    ['location kept too long', (t) => setEnv(t, 'LOCATION_RETENTION_DAYS', '365'), 'LOCATION_RETENTION_DAYS: location history'],
    ['unknown variable', (t) => setEnv(t, 'DEBUG', '*'), 'DEBUG: unknown variable'],
    ['moving image tag', (t) => { api(t).image = api(t).image.replace(/:[0-9a-f]{40}$/, ':latest'); }, 'image: not pinned'],
    ['version-shaped tag', (t) => { api(t).image = api(t).image.replace(/:[0-9a-f]{40}$/, ':1.4.0'); }, 'image: not pinned'],
    ['a sha cut to 7 characters', (t) => { api(t).image = api(t).image.replace(/:[0-9a-f]{40}$/, ':abcdef0'); }, 'image: not pinned'],
    ['staging image', (t) => { api(t).image = api(t).image.replace('osra-production', 'osra-staging'); }, 'image: not from the osra-production/api'],
    ['command override', (t) => { api(t).command = ['sh', '-c', 'node dist/server.js']; }, 'command or entryPoint'],
    ['root user', (t) => { api(t).user = '0'; }, 'runs as root'],
    ['no log driver', (t) => { delete api(t).logConfiguration; }, 'logConfiguration: not awslogs'],
    ['a second container', (t) => { t.taskDefinition.containerDefinitions.push({ name: 'sidecar' }); }, '2 containers'],
    ['iPhone push key missing at launch', (t) => dropSecret(t, 'APNS_KEY_P8'), 'APNS_KEY_P8: missing (needed at launch'],
    ['Play package missing at launch', (t) => dropEnv(t, 'PLAY_PACKAGE_NAME'), 'PLAY_PACKAGE_NAME: missing (needed at launch'],
  ];

  let failed = 0;
  const say = (ok, text) => { if (!ok) failed += 1; console.log(`${ok ? 'ok  ' : 'FAIL'} ${text}`); };

  const clean = checkTaskDefinition(goodTask());
  say(clean.findings.length === 0 && clean.pending.length === 0, `the good fixture is clean${clean.findings.length ? `: ${clean.findings.join(' | ')}` : ''}`);
  for (const [label, ref] of [['a 12-character sha tag', `:${'b'.repeat(12)}`], ['a digest', `@sha256:${'c'.repeat(64)}`]]) {
    const t = goodTask();
    api(t).image = api(t).image.replace(/:[0-9a-f]{40}$/, ref);
    say(checkTaskDefinition(t).findings.length === 0, `${label} is accepted`);
  }

  for (const [label, mutate, expected] of cases) {
    const t = goodTask();
    mutate(t);
    const { findings } = checkTaskDefinition(t);
    const hit = findings.filter((f) => f.includes(expected));
    // Exactly one finding, and it is the expected one: a rule that also trips a neighbour hides which rule fired.
    say(hit.length === 1 && findings.length === 1, `${label} -> ${findings.length === 1 && hit.length === 1 ? expected : `expected one finding with "${expected}", got ${JSON.stringify(findings)}`}`);
  }

  // --pre-launch waives the LAUNCH group and nothing else.
  const pre = goodTask();
  dropSecret(pre, 'APNS_KEY_P8');
  dropEnv(pre, 'PLAY_PACKAGE_NAME');
  setEnv(pre, 'CORS_ALLOW_ANY_ORIGIN', '1');
  const waived = checkTaskDefinition(pre, { preLaunch: true });
  say(waived.pending.length === 2 && waived.findings.length === 1 && waived.findings[0].startsWith('CORS_ALLOW_ANY_ORIGIN'),
    '--pre-launch reports the two launch gaps as pending and still fails the security finding');

  // No value is ever printed.
  const leak = goodTask();
  dropSecret(leak, 'JWT_SECRET');
  setEnv(leak, 'JWT_SECRET', 'VALUE-THAT-MUST-NOT-APPEAR');
  setEnv(leak, 'REDIS_URL', 'rediss://:VALUE-THAT-MUST-NOT-APPEAR@cache.example.internal:6379');
  say(!checkTaskDefinition(leak).findings.join('\n').includes('VALUE-THAT-MUST-NOT-APPEAR'), 'a finding names the variable and never prints its value');

  // The source scan sees each way the API reads a variable.
  const seen = variablesReadBy('const a = process.env.ALPHA_ONE; f(env.BETA_TWO); const { GAMMA_3, DELTA: d } = env; g(envVars.EPSILON);');
  say(['ALPHA_ONE', 'BETA_TWO', 'GAMMA_3', 'DELTA', 'EPSILON'].every((n) => seen.has(n)) && seen.size === 5, 'the source scan finds dotted and destructured reads');

  console.log(failed === 0 ? `selftest: ${cases.length + 6} checks pass` : `selftest: ${failed} check(s) FAILED`);
  process.exit(failed === 0 ? 0 : 1);
}

// ── main ─────────────────────────────────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const ALLOWED_FLAGS = new Set(['--file', '--pre-launch', '--source', '--selftest']);
const fileIndex = argv.indexOf('--file');
const unknown = argv.filter((a, i) => !ALLOWED_FLAGS.has(a) && !(fileIndex !== -1 && i === fileIndex + 1));
// A mistyped flag must not fall through to a run that checks nothing (docs/TESTING.md, `--self-test`).
if (unknown.length > 0) {
  console.error(`check-production-taskdef: unknown argument(s): ${unknown.join(' ')}`);
  process.exit(2);
}

if (argv.includes('--selftest')) {
  selftest();
} else if (argv.includes('--source')) {
  const { read, unclassified } = checkSource();
  if (read.size === 0) {
    console.error('check-production-taskdef: found no environment reads under services/api/src; run from the repository root');
    process.exit(2);
  }
  if (unclassified.length > 0) {
    console.error(`check-production-taskdef: the API reads ${unclassified.length} variable(s) this script does not classify: ${unclassified.join(', ')}`);
    console.error('Decide for each whether production requires it, allows it or forbids it, and add it to the matching list.');
    process.exit(1);
  }
  console.log(`check-production-taskdef: all ${read.size} variables the API reads are classified`);
} else {
  const file = fileIndex === -1 ? null : argv[fileIndex + 1];
  if (!file) {
    console.error('usage: node scripts/check-production-taskdef.mjs --file <describe-task-definition.json> [--pre-launch] | --source | --selftest');
    process.exit(2);
  }
  let doc;
  try {
    doc = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    console.error(`check-production-taskdef: cannot read ${file}: ${err.code ?? 'not JSON'}`);
    process.exit(2);
  }
  const preLaunch = argv.includes('--pre-launch');
  const { findings, pending } = checkTaskDefinition(doc, { preLaunch });
  const task = doc?.taskDefinition ?? doc;
  console.log(`task definition: ${task?.family ?? '?'}:${task?.revision ?? '?'}`);
  for (const p of pending) console.log(`PENDING  ${p}`);
  for (const f of findings) console.log(`FINDING  ${f}`);
  if (findings.length > 0) {
    console.log(`${findings.length} finding(s). This is not a release configuration.`);
    process.exit(1);
  }
  console.log(pending.length > 0
    ? `no findings; ${pending.length} launch item(s) pending. Safe to run, not yet complete for families.`
    : 'no findings. This is a release configuration.');
}
