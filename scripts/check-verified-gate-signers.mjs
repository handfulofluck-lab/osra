#!/usr/bin/env node
/**
 * Fails when `verified-gate.yml` could read a verification from the wrong account, or a signature under the
 * wrong name.
 *
 * Why (2026-10-23): the repository is public, so any GitHub account can comment on a PR, and a second member with
 * write access (Ahmed, `ahmedyusseff`) joined that day working with his own Claude Code agent. Until then the gate
 * read every comment, so a comment from ANY account whose last signature was "— Claude" and which named the head
 * sha verified the PR. The gate now keeps only comments written by `SIGNER_LOGIN`.
 *
 * 2026-11-13 21:15Z (maintainer, #617): Ahmed's agent may sign as the R3 security key from his own account. The
 * gate reads that account (`SECURITY_KEY_LOGIN`) for ONE thing: a `Verified-sha:` line signed "— Ahmed". And since
 * every agent posts from `SIGNER_LOGIN`, a "— Ahmed" signature from `SIGNER_LOGIN` is dropped: only Ahmed's own
 * account signs as Ahmed.
 *
 * Two layers:
 *   1. Structural: `SIGNER_LOGIN`, `SECURITY_KEY_LOGIN` and `SECURITY_KEY_NAME` are each set once, to the values
 *      below; the gate reads comment bodies on exactly two lines, each with its author filter; and each parse
 *      line carries its awk filter exactly as below.
 *   2. Behavioural: those lines, exactly as written in the workflow, run under bash + jq + awk + the policy's
 *      --parse over fixture comments from three accounts (forgeries included); only the two genuine signatures
 *      may come out. Without `jq` this layer is skipped locally, and in CI (`CI=true`) a missing `jq` is an
 *      environment error (exit 2), so the layer cannot quietly disappear there.
 *
 * Usage:
 *   node scripts/check-verified-gate-signers.mjs            # check the workflow
 *   node scripts/check-verified-gate-signers.mjs --selftest # prove both layers fail on broken gates
 *
 * Exits 1 on a violation, 2 on an environment problem.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const WORKFLOW = '.github/workflows/verified-gate.yml';
const POLICY = path.resolve('scripts/verified-gate-policy.mjs');
const AGENT_LOGIN = 'handfulofluck-lab';
const KEY_LOGIN = 'ahmedyusseff';
const KEY_NAME = 'Ahmed';
const FILTER = '.[] | select(.user.login == env.SIGNER_LOGIN) | .body';
const KEY_FILTER = '.[] | select(.user.login == env.SECURITY_KEY_LOGIN) | .body';
// The awk filter on each parse line (kind<TAB>name<TAB>sha rows).
const DROP_KEY = `awk -F'\\t' -v key="$SECURITY_KEY_NAME" '$2 != key'`;
const KEEP_KEY = `awk -F'\\t' -v key="$SECURITY_KEY_NAME" '$1 == "verify" && $2 == key'`;
const PARSE_AGENT = `node "$policy" --parse < "$RUNNER_TEMP/bodies.jsonl" | ${DROP_KEY} > "$sigs"`;
const PARSE_KEY = `node "$policy" --parse < "$RUNNER_TEMP/key-bodies.jsonl" | ${KEEP_KEY} >> "$sigs"`;

// Verification-shaped comments; only the agent's "— Claude" and Ahmed's own "— Ahmed" may survive.
const FIXTURE = [
  { user: { login: AGENT_LOGIN }, body: 'Verified-sha: aaaaaaa\n\n— Claude (architecture + testing)' },
  { user: { login: AGENT_LOGIN }, body: 'Verified-sha: eeeeeee\n\n— Ahmed' }, // forged from the shared account
  { user: { login: KEY_LOGIN }, body: 'Verified-sha: bbbbbbb\n\n— Claude' }, // Ahmed's agent is also "Claude"
  { user: { login: KEY_LOGIN }, body: 'Arabic-Bureau: reviewed fffffff\n\n— Claude (Arabic Language Bureau)' },
  { user: { login: KEY_LOGIN }, body: 'Verified-sha: ddddddd\n\n— Ahmed (security + iOS)' },
  { user: { login: 'drive-by-account' }, body: 'Verified-sha: ccccccc\n— Ahmed' },
  { user: { login: 'drive-by-account' }, body: 'Verified-sha: 1111111\n— Antigravity' },
];
const WANT = ['verify\tClaude\taaaaaaa', 'verify\tAhmed\tddddddd'];

const envValues = (text, key) => [...text.matchAll(new RegExp(`^\\s*${key}:\\s*(\\S+)\\s*$`, 'gm'))].map((m) => m[1]);
const codeLines = (text) => text.split('\n').filter((l) => !l.trim().startsWith('#'));
const bodyReads = (text) => codeLines(text).filter((l) => /\/(comments|reviews)\b/.test(l) && /\.body\b/.test(l));
const parseLines = (text) => codeLines(text).filter((l) => /--parse\s*</.test(l));

function structural(text) {
  const problems = [];
  for (const [key, want] of [['SIGNER_LOGIN', AGENT_LOGIN], ['SECURITY_KEY_LOGIN', KEY_LOGIN], ['SECURITY_KEY_NAME', KEY_NAME]]) {
    const got = envValues(text, key);
    if (got.length !== 1 || got[0] !== want) problems.push(`${key} must be set once, to ${want}; found ${got.length ? got.join(', ') : 'none'}`);
  }
  const reads = bodyReads(text);
  if (!reads.length) problems.push(`no line in ${WORKFLOW} reads comment bodies; the check no longer matches the gate`);
  for (const l of reads) {
    if (!l.includes(`--jq '${FILTER}`) && !l.includes(`--jq '${KEY_FILTER}`)) {
      problems.push(`comment bodies are read without an author filter: ${l.trim()}`);
    }
  }
  if (reads.filter((l) => l.includes(`--jq '${FILTER} | @json' > "$RUNNER_TEMP/bodies.jsonl"`)).length !== 1) {
    problems.push('the agent account must be read once, into bodies.jsonl');
  }
  if (reads.filter((l) => l.includes(`--jq '${KEY_FILTER} | @json' > "$RUNNER_TEMP/key-bodies.jsonl"`)).length !== 1) {
    problems.push(`the security-key account must be read once, into key-bodies.jsonl`);
  }
  if (reads.length !== 2) problems.push(`the gate must read comment bodies on exactly two lines; found ${reads.length}`);
  const parses = parseLines(text).map((l) => l.trim());
  for (const [want, what] of [[PARSE_AGENT, 'agent bodies, minus any "— Ahmed"'], [PARSE_KEY, 'key bodies, only verify by "— Ahmed"']]) {
    if (parses.filter((l) => l === want).length !== 1) problems.push(`missing the parse line for ${what}: ${want}`);
  }
  if (parses.length !== 2) problems.push(`the gate must parse signatures on exactly two lines; found ${parses.length}`);
  return problems;
}

function hasJq() {
  try {
    execFileSync('jq', ['--version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

/**
 * Runs the workflow's own read and parse lines over FIXTURE: `gh api … --jq 'F'` becomes `jq -r 'F' < fixture`,
 * `$policy` is this checkout's policy, and the three env values are the workflow's own.
 */
function behavioural(text) {
  const lines = codeLines(text).filter((l) => bodyReads(text).includes(l) || parseLines(text).includes(l));
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gate-signers-'));
  const fixture = path.join(tmp, 'comments.json');
  fs.writeFileSync(fixture, JSON.stringify(FIXTURE));
  const script = [
    'set -euo pipefail',
    'sigs="$RUNNER_TEMP/sigs.tsv"',
    ': > "$sigs"',
    ...lines.map((l) => l.trim().replace(/gh api --paginate "[^"]*" --jq ('[^']*')/, `jq -r $1 < "$FIXTURE"`)),
    'cat "$sigs"',
  ].join('\n');
  const env = {
    ...process.env,
    RUNNER_TEMP: tmp,
    FIXTURE: fixture,
    policy: POLICY,
    SIGNER_LOGIN: envValues(text, 'SIGNER_LOGIN')[0] ?? '',
    SECURITY_KEY_LOGIN: envValues(text, 'SECURITY_KEY_LOGIN')[0] ?? '',
    SECURITY_KEY_NAME: envValues(text, 'SECURITY_KEY_NAME')[0] ?? '',
  };
  try {
    const out = execFileSync('bash', ['-c', script], { encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe'] })
      .split('\n')
      .filter(Boolean)
      .sort();
    const want = [...WANT].sort();
    return JSON.stringify(out) === JSON.stringify(want)
      ? []
      : [`the gate's lines yield ${JSON.stringify(out)}; want only ${JSON.stringify(want)}`];
  } catch (e) {
    return [`the gate's read and parse lines fail to run: ${String(e.stderr ?? e.message).trim()}`];
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function jqOrExit() {
  if (hasJq()) return true;
  if (process.env.CI === 'true') {
    console.error('jq is not installed, so the behavioural layer cannot run; CI must have jq (ubuntu-latest does).');
    process.exit(2);
  }
  console.log('jq not found: behavioural layer skipped here (CI always runs it)');
  return false;
}

function check(text, withJq) {
  const problems = structural(text);
  return withJq ? [...problems, ...behavioural(text)] : problems;
}

let source;
try {
  source = fs.readFileSync(WORKFLOW, 'utf8');
} catch (e) {
  console.error(`cannot read ${WORKFLOW}: ${e.message} (run from the repository root)`);
  process.exit(2);
}
const withJq = jqOrExit();

if (process.argv.includes('--selftest')) {
  const swap = (from, to) => {
    if (source.split(from).length !== 2) {
      console.error(`self-test fixture is stale: "${from}" must occur exactly once in ${WORKFLOW}`);
      process.exit(2);
    }
    return source.replace(from, to);
  };
  const agentRead = `${FILTER} | @json`;
  const keyRead = `${KEY_FILTER} | @json`;
  const broken = [
    ['the pre-fix filter (every comment)', swap(agentRead, '.[].body | @json')],
    ['an inverted agent filter', swap(agentRead, `${FILTER.replace('==', '!=')} | @json`)],
    ['the key account read without its filter', swap(keyRead, '.[].body | @json')],
    ['an inverted key filter', swap(keyRead, `${KEY_FILTER.replace('==', '!=')} | @json`)],
    ['a key account signing under any name', swap(KEEP_KEY, `awk -F'\\t' '$1 == "verify"'`)],
    ['a key account posting Bureau lines', swap(KEEP_KEY, `awk -F'\\t' -v key="$SECURITY_KEY_NAME" '$2 == key || $2 == "-"'`)],
    ['"— Ahmed" accepted from the shared account', swap(DROP_KEY, 'cat')],
    ['SIGNER_LOGIN set to another account', swap(`SIGNER_LOGIN: ${AGENT_LOGIN}`, 'SIGNER_LOGIN: drive-by-account')],
    ['SECURITY_KEY_LOGIN set to another account', swap(`SECURITY_KEY_LOGIN: ${KEY_LOGIN}`, 'SECURITY_KEY_LOGIN: drive-by-account')],
    ['SECURITY_KEY_NAME set to Claude', swap(`SECURITY_KEY_NAME: ${KEY_NAME}`, 'SECURITY_KEY_NAME: Claude')],
    ['SIGNER_LOGIN removed', swap(`SIGNER_LOGIN: ${AGENT_LOGIN}`, '')],
  ];
  const cases = [
    { name: 'the committed workflow passes', text: source, want: 0 },
    ...broken.map(([name, text]) => ({ name: `structural: ${name} fails`, run: () => structural(text), want: 1 })),
  ];
  if (withJq) {
    // Each layer must catch every broken gate on its own, not only through the other one.
    cases.push({ name: 'behavioural: the committed workflow yields only the two genuine signatures', run: () => behavioural(source), want: 0 });
    for (const [name, text] of broken) cases.push({ name: `behavioural: ${name} fails`, run: () => behavioural(text), want: 1 });
  }
  let bad = 0;
  for (const c of cases) {
    const problems = c.run ? c.run() : check(c.text, withJq);
    const got = problems.length ? 1 : 0;
    if (got !== c.want) {
      bad += 1;
      console.error(`FAIL ${c.name}: want ${c.want ? 'a violation' : 'clean'}, got ${got ? problems.join('; ') : 'clean'}`);
    }
  }
  console.log(`verified-gate signer self-test: ${cases.length - bad}/${cases.length} cases${withJq ? '' : ' (structural only, no jq)'}`);
  process.exit(bad ? 1 : 0);
}

const problems = check(source, withJq);
if (problems.length) {
  for (const p of problems) console.error(`ERROR ${WORKFLOW}: ${p}`);
  console.error('\nThe repository is public: a comment from any account other than the agent account, or Ahmed\'s own');
  console.error('"— Ahmed" verification, must never verify a PR (AGENTS.md §6.4, §6.6). Restore the filters rather than');
  console.error('relaxing this check.');
  process.exit(1);
}
console.log(
  `${WORKFLOW}: verifications are read only from ${AGENT_LOGIN}, plus "— ${KEY_NAME}" verifications from ${KEY_LOGIN}` +
    `${withJq ? ' (structural + behavioural)' : ' (structural)'}`,
);
