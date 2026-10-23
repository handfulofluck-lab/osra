#!/usr/bin/env node
/**
 * Fails when `verified-gate.yml` could read a verification from an account other than the team's agent account.
 *
 * Why (2026-10-23): the repository is public, so any GitHub account can comment on a PR, and a second member with
 * write access (Ahmed, `ahmedyusseff`) joined that day working with his own Claude Code agent. Until then the gate
 * read every comment, so a comment from ANY account whose last signature was "— Claude" and which named the head
 * sha verified the PR. The gate now keeps only comments written by `SIGNER_LOGIN`; this script fails if that
 * filter is lost, inverted or pointed at another account.
 *
 * Two layers:
 *   1. Structural: `SIGNER_LOGIN` is set once, to the agent account, and every line that reads comment or review
 *      bodies selects `.user.login == env.SIGNER_LOGIN` before `.body`.
 *   2. Behavioural: each such jq filter, exactly as written in the workflow, runs under `jq` over fixture comments
 *      from three accounts; only the agent account's body may come out. Without `jq` this layer is skipped
 *      locally, and in CI (`CI=true`) a missing `jq` is an environment error (exit 2), so the layer cannot
 *      quietly disappear there. `gh --jq` and `jq -r` print strings the same way.
 *
 * Usage:
 *   node scripts/check-verified-gate-signers.mjs            # check the workflow
 *   node scripts/check-verified-gate-signers.mjs --selftest # prove both layers fail on the pre-fix gate
 *
 * Exits 1 on a violation, 2 on an environment problem.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const WORKFLOW = '.github/workflows/verified-gate.yml';
const AGENT_LOGIN = 'handfulofluck-lab';
const FILTER = '.[] | select(.user.login == env.SIGNER_LOGIN) | .body';

// One verification-shaped comment per account; only the first may survive the gate's filter.
const FIXTURE = [
  { user: { login: AGENT_LOGIN }, body: 'Verified-sha: aaaaaaa\n\n— Claude (architecture + testing)' },
  { user: { login: 'ahmedyusseff' }, body: 'Verified-sha: bbbbbbb\n\n— Claude' },
  { user: { login: 'drive-by-account' }, body: 'Verified-sha: ccccccc\n— Antigravity' },
];
const WANT = ['Verified-sha: aaaaaaa  — Claude (architecture + testing)'];

function structural(text) {
  const problems = [];
  const logins = [...text.matchAll(/^\s*SIGNER_LOGIN:\s*(\S+)\s*$/gm)].map((m) => m[1]);
  if (logins.length !== 1 || logins[0] !== AGENT_LOGIN) {
    problems.push(`SIGNER_LOGIN must be set once, to ${AGENT_LOGIN}; found ${logins.length ? logins.join(', ') : 'none'}`);
  }
  const reads = text
    .split('\n')
    .filter((l) => !l.trim().startsWith('#'))
    .filter((l) => /\/(comments|reviews)\b/.test(l) && /\.body\b/.test(l));
  if (!reads.length) problems.push(`no line in ${WORKFLOW} reads comment bodies; the check no longer matches the gate`);
  for (const l of reads) {
    if (!l.includes(`--jq '${FILTER}`)) problems.push(`comment bodies are read without the author filter: ${l.trim()}`);
  }
  const filters = reads.map((l) => /--jq '([^']*)'/.exec(l)?.[1]).filter(Boolean);
  return { problems, filters };
}

function hasJq() {
  try {
    execFileSync('jq', ['--version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function behavioural(filters) {
  const problems = [];
  for (const f of filters) {
    let out;
    try {
      out = execFileSync('jq', ['-r', f], {
        input: JSON.stringify(FIXTURE),
        encoding: 'utf8',
        env: { ...process.env, SIGNER_LOGIN: AGENT_LOGIN },
      })
        .split('\n')
        .filter(Boolean);
    } catch (e) {
      problems.push(`jq rejected the filter ${f}: ${String(e.stderr ?? e.message).trim()}`);
      continue;
    }
    if (JSON.stringify(out) !== JSON.stringify(WANT)) {
      problems.push(`filter ${f} yields ${JSON.stringify(out)}; want only the ${AGENT_LOGIN} comment ${JSON.stringify(WANT)}`);
    }
  }
  return problems;
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
  const { problems, filters } = structural(text);
  return withJq ? [...problems, ...behavioural(filters)] : problems;
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
  const preFix = `.[].body | gsub(`;
  const cases = [
    { name: 'the committed workflow passes', text: source, want: 0 },
    { name: 'the pre-fix filter (every comment) fails', text: swap(`${FILTER} | gsub(`, preFix), want: 1 },
    { name: 'an inverted filter fails', text: swap(`${FILTER} | gsub(`, `${FILTER.replace('==', '!=')} | gsub(`), want: 1 },
    { name: 'SIGNER_LOGIN set to another account fails', text: swap(`SIGNER_LOGIN: ${AGENT_LOGIN}`, 'SIGNER_LOGIN: ahmedyusseff'), want: 1 },
    { name: 'SIGNER_LOGIN removed fails', text: swap(`SIGNER_LOGIN: ${AGENT_LOGIN}`, ''), want: 1 },
  ];
  if (withJq) {
    // Each layer must catch the pre-fix gate on its own, not only through the other one.
    cases.push(
      { name: 'behavioural: the committed filter yields only the agent comment', run: () => behavioural([`${FILTER} | gsub("[[:cntrl:]]"; " ")`]), want: 0 },
      { name: 'behavioural: the pre-fix filter leaks the other accounts', run: () => behavioural(['.[].body | gsub("[[:cntrl:]]"; " ")']), want: 1 },
      { name: 'behavioural: an inverted filter leaks the other accounts', run: () => behavioural([`${FILTER.replace('==', '!=')} | gsub("[[:cntrl:]]"; " ")`]), want: 1 },
    );
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
  console.error('\nThe repository is public: a comment from any account other than the agent account must never verify a PR');
  console.error('(AGENTS.md §6.4). Restore the author filter rather than relaxing this check.');
  process.exit(1);
}
console.log(`${WORKFLOW}: verifications are read only from ${AGENT_LOGIN}${withJq ? ' (structural + behavioural)' : ' (structural)'}`);
