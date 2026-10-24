#!/usr/bin/env node
/**
 * Decides whether a `Verified-sha:` signature still covers a PR head after main was folded in.
 *
 * This is the decision `verified-gate.yml` makes when the head is no longer the signed sha. It lives here,
 * not inline in the workflow, so the rule can be tested with real git fixtures — the same split as
 * `check-verified-gate-signers.mjs` for the signer rule.
 *
 * A signature at sha S covers head H when ALL of these hold:
 *   1. S is an ancestor of H.
 *   2. Every commit in `S..H` that is not on main is a merge commit.
 *   3. Every such merge is a clean merge of its parents: `git merge-tree --write-tree <p1> <p2>` must
 *      produce exactly the merge commit's own tree. A conflict, a hand resolution, an evil merge that
 *      adds something in neither parent, or a merge with other than two parents refuses.
 *   4. The PR's own change is identical:
 *        patch-id( diff(-U0, merge-base(main,S), S) )  ==  patch-id( diff(-U0, merge-base(main,H), H) )
 *
 * Why -U0 (2026-10-24, issue #357): `git patch-id` hashes hunks WITH their context lines. Folding main in
 * moves the merge base, so the same change is extracted against a new base; when main touched a line inside
 * the PR hunk's context window, the context differs while the change does not, and the gate refused a
 * correctly folded merge. On #349 the default-context ids differed while the -U0 ids were equal and both
 * `git diff --stat` outputs were identical. -U0 on BOTH sides: a stored signature has no stored patch-id to
 * stay compatible with, and comparing one side with context would make every comparison say "differs".
 *
 * Why rule 3 exists (#358 review): `patch-id` also drops the `@@` header, including the function name git
 * writes there, so with -U0 nothing records WHERE a hunk sits. A hand-edited fold could move the PR's line
 * into another function and the patch would still hash the same. Rule 3 closes that: only a merge git
 * produced itself may follow the signature, so a line that moved, moved because git moved it. Rule 4 still
 * asks whether the change itself moved; rule 3 is what makes the answer safe. The remaining limit is a line
 * moved by a clean merge — and that is git's own merge result, not a person's edit.
 *
 * Usage:
 *   node scripts/verified-gate-carry.mjs <signed-sha> <head-sha>
 *   SIGNED_SHA=<sha> HEAD_SHA=<sha> node scripts/verified-gate-carry.mjs
 *   node scripts/verified-gate-carry.mjs --selftest
 *
 * The main ref is `origin/main`; set MAIN_REF to override (the self-test uses a local `main`).
 *
 * stdout: `carried`, `differs`, or `cannot-decide`.
 * stderr: one line naming the rule that decided.
 * Exit: 0 carried · 1 differs (the patch moved, or a merge after the signature was not a clean merge of
 *       its parents) · 2 cannot decide (missing or unknown sha, S not an ancestor of H, a non-merge commit
 *       after the signature, git older than 2.38 so a merge cannot be re-run, or git could not answer).
 *       Any nonzero means "do not carry".
 *
 * The `cannot-decide` choice for a non-merge commit is deliberate: the signature did cover a different
 * thing than the head now contains, so the gate refuses exactly as the inline bash did (it printed
 * "non-merge commits since, not carried forward" and the job failed). It is reported as exit 2 rather than
 * 1 because the patch comparison never ran — "differs" would claim a comparison this rule never made.
 *
 * Security reasoning (what a signature can and cannot prove) is in the `verified-gate.yml` header; this
 * script only implements the carry-forward half of it.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SCRIPT = fileURLToPath(import.meta.url);
const DEFAULT_MAIN_REF = 'origin/main';
const MAX_BUFFER = 64 * 1024 * 1024;
const HEX_SHA = /^[0-9a-f]{4,40}$/i;

function git(cwd, args, { input } = {}) {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    input,
    maxBuffer: MAX_BUFFER,
    stdio: input === undefined ? ['ignore', 'pipe', 'pipe'] : ['pipe', 'pipe', 'pipe'],
  });
}

function resolveCommit(cwd, rev) {
  try {
    return git(cwd, ['rev-parse', '--verify', '--quiet', `${rev}^{commit}`]).trim() || null;
  } catch {
    return null;
  }
}

function isAncestor(cwd, ancestor, descendant) {
  const result = spawnSync('git', ['merge-base', '--is-ancestor', ancestor, descendant], {
    cwd,
    encoding: 'utf8',
  });
  if (result.status === 0) return true;
  if (result.status === 1) return false;
  throw new Error(`git merge-base --is-ancestor failed (${result.status ?? result.error?.message ?? 'unknown'})`);
}

function mergeBase(cwd, mainRef, rev) {
  const base = git(cwd, ['merge-base', mainRef, rev]).trim();
  if (!base) throw new Error(`no merge base between ${mainRef} and ${rev}`);
  return base;
}

/**
 * `git patch-id --stable` of the diff from `base` to `rev`, with `context` lines of context.
 * `context: null` leaves git's default (3) in place; the self-test needs it to reproduce the pre-#357
 * comparison, while the gate always passes 0.
 */
export function patchIdAgainst(cwd, base, rev, { context = 0 } = {}) {
  const contextFlag = context === null ? [] : [`-U${context}`];
  const diff = git(cwd, ['diff', '--no-color', '--no-ext-diff', ...contextFlag, base, rev]);
  const ids = git(cwd, ['patch-id', '--stable'], { input: diff });
  return ids.trim().split(/\s+/)[0] ?? '';
}

/** The PR's own patch at `rev`: the diff from merge-base(main, rev) with context stripped. */
export function patchId(cwd, rev, { mainRef = DEFAULT_MAIN_REF, context = 0 } = {}) {
  return patchIdAgainst(cwd, mergeBase(cwd, mainRef, rev), rev, { context });
}

const short = (sha) => sha.slice(0, 12);
const show = (id) => (id ? `patch-id ${id.slice(0, 12)}` : 'an empty diff');

/** Is the local git at least `major.minor`? Returns null when the version cannot be read. */
export function gitVersionAtLeast(cwd, major, minor) {
  let out;
  try {
    out = git(cwd, ['version']).trim();
  } catch {
    return null;
  }
  const match = out.match(/^git version (\d+)\.(\d+)/);
  if (!match) return null;
  const [foundMajor, foundMinor] = [Number(match[1]), Number(match[2])];
  return foundMajor > major || (foundMajor === major && foundMinor >= minor);
}

/**
 * Why `merge` is not a clean merge of its parents, or null when it is one.
 * `git merge-tree --write-tree` (git >= 2.38) re-runs the merge; a clean result must reproduce the
 * merge commit's own tree exactly. Status 1 means the merge conflicted, so a person resolved it.
 */
export function mergeIsClean(cwd, merge) {
  const parents = git(cwd, ['rev-list', '--parents', '-n', '1', merge]).trim().split(' ').slice(1);
  if (parents.length !== 2) {
    return `${short(merge)} has ${parents.length} parents, so it is not a two-parent fold that this rule can judge`;
  }
  const result = spawnSync('git', ['merge-tree', '--write-tree', parents[0], parents[1]], {
    cwd,
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
  });
  if (result.status === 1) {
    return `${short(merge)} had conflicts, so its resolution needs a verification`;
  }
  if (result.status !== 0) {
    throw new Error(
      `git merge-tree --write-tree failed for ${short(merge)} (${result.status ?? result.error?.message ?? 'unknown'}): ${(result.stderr || '').trim()}`,
    );
  }
  const cleanTree = (result.stdout || '').split('\n')[0].trim();
  const mergeTree = git(cwd, ['rev-parse', `${merge}^{tree}`]).trim();
  if (cleanTree !== mergeTree) {
    return `${short(merge)} is not the clean merge of its parents: its tree differs from the merge git would produce, so a resolution or an evil merge changed it`;
  }
  return null;
}

/**
 * @returns {{code: 0|1|2, verdict: 'carried'|'differs'|'cannot-decide', reason: string}}
 */
export function decide({ signed, head, cwd = process.cwd(), mainRef = DEFAULT_MAIN_REF } = {}) {
  const cannot = (reason) => ({ code: 2, verdict: 'cannot-decide', reason });

  if (!signed || !head) {
    return cannot('a sha is missing (pass <signed-sha> <head-sha>, or set SIGNED_SHA and HEAD_SHA)');
  }
  if (!HEX_SHA.test(signed) || !HEX_SHA.test(head)) {
    return cannot(`expected two hex shas, got signed="${signed}" head="${head}"`);
  }

  const s = resolveCommit(cwd, signed);
  if (!s) return cannot(`the signed sha ${signed} is not a commit in this clone`);
  const h = resolveCommit(cwd, head);
  if (!h) return cannot(`the head sha ${head} is not a commit in this clone`);

  let ancestor;
  try {
    ancestor = isAncestor(cwd, s, h);
  } catch (error) {
    return cannot(`git could not answer the ancestor question: ${error.message}`);
  }
  if (!ancestor) {
    return cannot(
      `${short(s)} is not an ancestor of ${short(h)} — the branch was rebased or rewound after the signature, so the signed sha is not in the head's history`,
    );
  }

  let stray;
  try {
    stray = git(cwd, ['rev-list', '--no-merges', `${s}..${h}`, `^${mainRef}`]).trim().split('\n').filter(Boolean);
  } catch (error) {
    return cannot(`git could not list the commits since the signature: ${error.message}`);
  }
  if (stray.length) {
    return cannot(
      `${stray.length} non-merge commit(s) arrived after the signature (${stray.map(short).join(', ')}) — only merges of ${mainRef} may follow a signed sha`,
    );
  }

  // Rule (c): every merge after the signature must be a clean merge of its parents. A hand resolution,
  // an evil merge, or a merge this rule cannot judge (not two parents) needs a fresh verification.
  let merges;
  try {
    merges = git(cwd, ['rev-list', '--merges', `${s}..${h}`, `^${mainRef}`]).trim().split('\n').filter(Boolean);
  } catch (error) {
    return cannot(`git could not list the merges since the signature: ${error.message}`);
  }
  if (merges.length) {
    const supported = gitVersionAtLeast(cwd, 2, 38);
    if (supported !== true) {
      return cannot(
        `${supported === null ? 'the local git version could not be read' : 'this git is older than 2.38'}, but re-running the ${merges.length} merge(s) after the signature needs \`git merge-tree --write-tree\` (git >= 2.38); upgrade git, or verify the head instead of carrying a signature`,
      );
    }
    for (const merge of merges) {
      let why;
      try {
        why = mergeIsClean(cwd, merge);
      } catch (error) {
        return cannot(error.message);
      }
      if (why) return { code: 1, verdict: 'differs', reason: why };
    }
  }

  let signedId, headId;
  try {
    signedId = patchId(cwd, s, { mainRef });
    headId = patchId(cwd, h, { mainRef });
  } catch (error) {
    return cannot(`git could not compare the two patches: ${error.message}`);
  }

  if (signedId !== headId) {
    return {
      code: 1,
      verdict: 'differs',
      reason: `the PR's own -U0 patch changed after the signature (signed ${show(signedId)}, head ${show(headId)})`,
    };
  }
  return {
    code: 0,
    verdict: 'carried',
    reason: `only merges of ${mainRef} followed ${short(s)} and the PR's own -U0 patch is unchanged (${show(headId)})`,
  };
}

function usage(message) {
  process.stderr.write(
    `verified-gate-carry: ${message}\n` +
      'usage: node scripts/verified-gate-carry.mjs <signed-sha> <head-sha> [--selftest]\n' +
      '       SIGNED_SHA=<sha> HEAD_SHA=<sha> node scripts/verified-gate-carry.mjs\n',
  );
  process.exit(2);
}

function cli(argv) {
  const flags = argv.filter((arg) => arg.startsWith('-'));
  const unknown = flags.filter((flag) => flag !== '--selftest');
  if (unknown.length) usage(`unrecognised argument ${unknown.join(' ')}`);
  if (flags.includes('--selftest')) process.exit(selftest());

  const positional = argv.filter((arg) => !arg.startsWith('-'));
  if (positional.length > 2) usage(`too many arguments: ${positional.join(' ')}`);

  const signed = positional[0] ?? process.env.SIGNED_SHA ?? '';
  const head = positional[1] ?? process.env.HEAD_SHA ?? '';
  const result = decide({
    signed,
    head,
    cwd: process.cwd(),
    mainRef: process.env.MAIN_REF || DEFAULT_MAIN_REF,
  });
  process.stdout.write(`${result.verdict}\n`);
  process.stderr.write(`verified-gate-carry: ${result.reason}\n`);
  process.exit(result.code);
}

const LINES = (n) => Array.from({ length: n }, (_, i) => `line ${i + 1}`).join('\n') + '\n';

/**
 * Fixtures are built with real git in a temporary directory — no faked diff, patch-id or merge-tree output.
 * Each case also asserts the facts that make its named rule the deciding one, so removing that rule changes
 * the outcome (or, for the ancestor case, changes which rule the human line names). Cases 1 and 5 are clean
 * folds that must carry; case 2 is a conflicted resolution; case 6 is a hand rewrite whose -U0 patch is
 * unchanged (the gap rule (c) closes); case 7 is a merge rule (c) cannot judge.
 */
function selftest() {
  const root = mkdtempSync(join(tmpdir(), 'verified-gate-carry-'));
  const gitEnv = {
    ...process.env,
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: join(root, 'gitconfig'),
  };
  writeFileSync(
    gitEnv.GIT_CONFIG_GLOBAL,
    '[user]\n\tname = fixture\n\temail = fixture@example.invalid\n' +
      '[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' +
      '[core]\n\tautocrlf = false\n\teol = lf\n[init]\n\tdefaultBranch = main\n',
  );

  const g = (cwd, args, opts = {}) =>
    execFileSync('git', args, {
      cwd,
      env: gitEnv,
      encoding: 'utf8',
      input: opts.input,
      maxBuffer: MAX_BUFFER,
      stdio: opts.input === undefined ? ['ignore', 'pipe', 'pipe'] : ['pipe', 'pipe', 'pipe'],
    });
  const rev = (cwd, ref) => g(cwd, ['rev-parse', ref]).trim();
  const setLine = (cwd, file, number, text) => {
    const path = join(cwd, file);
    const lines = readFileSync(path, 'utf8').split('\n');
    lines[number - 1] = text;
    writeFileSync(path, lines.join('\n'));
  };
  const commit = (cwd, message) => {
    g(cwd, ['add', '-A']);
    g(cwd, ['commit', '-qm', message]);
    return rev(cwd, 'HEAD');
  };
  let repos = 0;
  const newRepo = (file, content) => {
    const dir = join(root, `repo-${++repos}`);
    mkdirSync(dir);
    g(dir, ['init', '-q', '-b', 'main']);
    writeFileSync(join(dir, file), content);
    commit(dir, 'base');
    return dir;
  };
  const mergeMain = (cwd, message = 'merge main') => {
    g(cwd, ['merge', '-q', '--no-ff', 'main', '-m', message]);
    return rev(cwd, 'HEAD');
  };
  const patchIdAt = (cwd, ref, context) =>
    patchIdAgainst(cwd, g(cwd, ['merge-base', 'main', ref]).trim(), ref, { context });
  const cli = (cwd, signed, head) => {
    const result = spawnSync(process.execPath, [SCRIPT, signed, head], {
      cwd,
      env: { ...gitEnv, MAIN_REF: 'main' },
      encoding: 'utf8',
    });
    return { code: result.status, stdout: result.stdout.trim(), stderr: result.stderr.trim() };
  };

  const cases = [];

  // 1. A neighbour moved in main, and the PR's own change did not. Before #357 this case returned
  //    `differs`: the default-context patch-id was computed against a new merge base, and main's edit at
  //    line 8 sat inside the 3-line context of the PR's line-10 hunk. That is the regression this pins.
  //    (main also edits line 20, outside the context window, to show the case is not one narrowly built
  //    hunk: both sides describe the same file, the -U0 hashes are equal.)
  cases.push({
    name: 'neighbours moved: a folded merge carries the signature',
    run() {
      const bad = [];
      const dir = newRepo('f.txt', LINES(30));
      g(dir, ['checkout', '-q', '-b', 'pr']);
      setLine(dir, 'f.txt', 10, 'line 10 (PR)');
      const S = commit(dir, 'pr: change line 10');
      g(dir, ['checkout', '-q', 'main']);
      setLine(dir, 'f.txt', 8, 'line 8 (main)');
      setLine(dir, 'f.txt', 20, 'line 20 (main)');
      commit(dir, 'main: move a neighbour');
      g(dir, ['checkout', '-q', 'pr']);
      const H = mergeMain(dir);

      if (patchIdAt(dir, S, null) === patchIdAt(dir, H, null)) {
        bad.push('the fixture no longer reproduces #357: the default-context patch-id is equal on both sides');
      }
      if (patchIdAt(dir, S, 0) !== patchIdAt(dir, H, 0)) {
        bad.push('the -U0 patch-id differs; the fixture does not represent an unchanged PR change');
      }
      const result = cli(dir, S, H);
      if (result.code !== 0 || result.stdout !== 'carried') {
        bad.push(`want carried/0, got ${result.stdout || '(no stdout)'}/${result.code}: ${result.stderr}`);
      }
      return bad;
    },
  });

  // 2. The merge changes the PR's own hunk. A plain edit committed after signing would be refused by the
  //    merge-only rule before rule (c) ran, so this fixture is the realistic shape: main changed the same
  //    line, the merge resolved the conflict to main's value, and the PR's own change is gone. Rule (a)
  //    passes (only the merge commit follows S); rule (c) now decides it — the merge conflicted, so a
  //    person resolved it — and the patch comparison is the second layer behind that.
  cases.push({
    name: "the PR's own hunk changed: a folded merge still refuses",
    run() {
      const bad = [];
      const dir = newRepo('f.txt', LINES(20));
      g(dir, ['checkout', '-q', '-b', 'pr']);
      setLine(dir, 'f.txt', 10, 'line 10 (PR)');
      const S = commit(dir, 'pr: change line 10');
      g(dir, ['checkout', '-q', 'main']);
      setLine(dir, 'f.txt', 10, 'line 10 (main)');
      commit(dir, 'main: change the same line');
      g(dir, ['checkout', '-q', 'pr']);
      const merge = spawnSync('git', ['merge', 'main'], { cwd: dir, env: gitEnv, encoding: 'utf8' });
      if (merge.status === 0) bad.push('the fixture merge did not conflict, so it does not exercise a conflict resolution');
      writeFileSync(join(dir, 'f.txt'), LINES(20).replace('line 10\n', 'line 10 (main)\n'));
      g(dir, ['add', 'f.txt']);
      g(dir, ['commit', '-qm', 'merge main, resolved to main']);
      const H = rev(dir, 'HEAD');

      if (g(dir, ['rev-list', '--no-merges', `${S}..${H}`, '^main']).trim()) {
        bad.push('a non-merge commit follows the signature, so the merge-only rule would decide this case');
      }
      if (patchIdAt(dir, S, 0) === patchIdAt(dir, H, 0)) {
        bad.push('the -U0 patch-ids are equal: the rule this case exists for has been weakened');
      }
      const result = cli(dir, S, H);
      if (result.code !== 1 || result.stdout !== 'differs') {
        bad.push(`want differs/1, got ${result.stdout || '(no stdout)'}/${result.code}: ${result.stderr}`);
      }
      if (!/had conflicts/.test(result.stderr)) {
        bad.push(`rule (c) should be what refuses a conflicted merge, got: ${result.stderr}`);
      }
      if (!result.stderr.includes(short(H))) bad.push(`the reason does not name the merge: ${result.stderr}`);
      return bad;
    },
  });

  // 3. A non-merge commit arrived after signing. It is patch-neutral (empty commit), so the merge-only
  //    rule is the only thing that can refuse: with that rule removed the gate would carry it.
  cases.push({
    name: 'a non-merge commit after signing: not carried (exit 2)',
    run() {
      const bad = [];
      const dir = newRepo('f.txt', LINES(10));
      g(dir, ['checkout', '-q', '-b', 'pr']);
      setLine(dir, 'f.txt', 5, 'line 5 (PR)');
      const S = commit(dir, 'pr: change line 5');
      g(dir, ['commit', '-q', '--allow-empty', '-m', 'empty commit pushed after signing']);
      const H = rev(dir, 'HEAD');

      if (!g(dir, ['rev-list', '--no-merges', `${S}..${H}`, '^main']).trim()) {
        bad.push('the fixture has no non-merge commit after the signature');
      }
      if (patchIdAt(dir, S, 0) !== patchIdAt(dir, H, 0)) {
        bad.push('the empty commit changed the patch, so rule (b) would refuse this case too');
      }
      const result = cli(dir, S, H);
      if (result.code !== 2 || result.stdout !== 'cannot-decide') {
        bad.push(`want cannot-decide/2, got ${result.stdout || '(no stdout)'}/${result.code}: ${result.stderr}`);
      }
      if (!/non-merge/.test(result.stderr)) bad.push(`the human line does not name the non-merge rule: ${result.stderr}`);
      return bad;
    },
  });

  // 4. The signed sha is not an ancestor (rewound after signing). The head has the same patch and carries
  //    no non-merge commits, so only the ancestor rule refuses; without it, an older head would carry a
  //    signature made for a later one.
  cases.push({
    name: 'signed sha is not an ancestor: cannot decide (exit 2)',
    run() {
      const bad = [];
      const dir = newRepo('f.txt', LINES(10));
      g(dir, ['checkout', '-q', '-b', 'pr']);
      setLine(dir, 'f.txt', 5, 'line 5 (PR)');
      commit(dir, 'pr: change line 5');
      g(dir, ['commit', '-q', '--allow-empty', '-m', 'signed here']);
      const S = rev(dir, 'HEAD');
      g(dir, ['reset', '-q', '--hard', 'HEAD~1']);
      const H = rev(dir, 'HEAD');

      const ancestor = spawnSync('git', ['merge-base', '--is-ancestor', S, H], { cwd: dir, env: gitEnv });
      if (ancestor.status === 0) bad.push('the fixture still has the signed sha as an ancestor');
      if (g(dir, ['rev-list', '--no-merges', `${S}..${H}`, '^main']).trim()) {
        bad.push('a non-merge commit divides S and H, so the merge-only rule would decide this case too');
      }
      if (patchIdAt(dir, S, 0) !== patchIdAt(dir, H, 0)) {
        bad.push('the patches differ, so rule (b) would refuse this case too');
      }
      const result = cli(dir, S, H);
      if (result.code !== 2 || result.stdout !== 'cannot-decide') {
        bad.push(`want cannot-decide/2, got ${result.stdout || '(no stdout)'}/${result.code}: ${result.stderr}`);
      }
      if (!/not an ancestor/.test(result.stderr)) bad.push(`the human line does not name the ancestor rule: ${result.stderr}`);
      return bad;
    },
  });

  // 5. main brought in a file the PR never touched. main's own content must not count against the PR, so
  //    the signature carries. The last assertion pins the merge-base choice: against main's tip instead of
  //    the merge base, the signed patch would read as a deletion of main's file and differ.
  cases.push({
    name: "a merge of main's own file does not count against the PR",
    run() {
      const bad = [];
      const dir = newRepo('f.txt', LINES(15));
      g(dir, ['checkout', '-q', '-b', 'pr']);
      setLine(dir, 'f.txt', 5, 'line 5 (PR)');
      const S = commit(dir, 'pr: change line 5');
      g(dir, ['checkout', '-q', 'main']);
      writeFileSync(join(dir, 'g.txt'), 'main only\n');
      commit(dir, 'main: add g.txt');
      const mainTip = rev(dir, 'main');
      g(dir, ['checkout', '-q', 'pr']);
      const H = mergeMain(dir);

      const headBase = g(dir, ['merge-base', 'main', H]).trim();
      if (/g\.txt/.test(g(dir, ['diff', '-U0', headBase, H]))) {
        bad.push("the head's own patch includes main's file g.txt");
      }
      if (patchIdAt(dir, S, 0) !== patchIdAt(dir, H, 0)) {
        bad.push('the -U0 patch-ids differ although the PR change did not move');
      }
      if (patchIdAgainst(dir, mainTip, S, { context: 0 }) === patchIdAt(dir, S, 0)) {
        bad.push("using main's tip instead of the merge base does not change the signed patch; the merge-base rule is not pinned");
      }
      const result = cli(dir, S, H);
      if (result.code !== 0 || result.stdout !== 'carried') {
        bad.push(`want carried/0, got ${result.stdout || '(no stdout)'}/${result.code}: ${result.stderr}`);
      }
      return bad;
    },
  });

  // 6. The gap rule (c) closes (#358 review): the fold rewrites the file so the PR's `guard();` sits in a
  //    different function. Every hunk is still "add one line", so the -U0 patch-ids are EQUAL — asserted
  //    below, because that equality is the gap — and only rule (c) can refuse. With default context the
  //    old comparison refused this; -U0 alone would carry it.
  cases.push({
    name: "a merge that moves the PR's line into another function refuses",
    run() {
      const bad = [];
      const base = 'function a() {\n  one();\n}\n\nfunction b() {\n  two();\n}\n';
      const dir = newRepo('f.js', base);
      g(dir, ['checkout', '-q', '-b', 'pr']);
      writeFileSync(join(dir, 'f.js'), base.replace('  one();\n', '  one();\n  guard();\n'));
      const S = commit(dir, 'pr: guard under a()');
      g(dir, ['checkout', '-q', 'main']);
      writeFileSync(join(dir, 'f.js'), '// touched by main\n' + base);
      commit(dir, 'main: unrelated change');
      g(dir, ['checkout', '-q', 'pr']);
      const merge = spawnSync('git', ['merge', '--no-ff', '--no-commit', 'main'], {
        cwd: dir,
        env: gitEnv,
        encoding: 'utf8',
      });
      if (merge.status !== 0) {
        bad.push(`the fixture merge did not complete cleanly (${merge.status}); it should be a hand rewrite of a clean merge`);
      }
      writeFileSync(join(dir, 'f.js'), '// touched by main\n' + base.replace('  two();\n', '  two();\n  guard();\n'));
      g(dir, ['add', 'f.js']);
      g(dir, ['commit', '-qm', 'fold main, guard moved into b()']);
      const H = rev(dir, 'HEAD');

      const ancestor = spawnSync('git', ['merge-base', '--is-ancestor', S, H], { cwd: dir, env: gitEnv });
      if (ancestor.status !== 0) bad.push('rule (a) does not hold in the fixture');
      if (g(dir, ['rev-list', '--no-merges', `${S}..${H}`, '^main']).trim()) {
        bad.push('a non-merge commit follows the signature, so the merge-only rule would decide this case');
      }
      if (patchIdAt(dir, S, 0) !== patchIdAt(dir, H, 0)) {
        bad.push('the -U0 patch-ids differ, so the patch comparison would decide this case; the gap is not pinned');
      }
      const result = cli(dir, S, H);
      if (result.code !== 1 || result.stdout !== 'differs') {
        bad.push(`want differs/1, got ${result.stdout || '(no stdout)'}/${result.code}: ${result.stderr}`);
      }
      if (!result.stderr.includes(short(H))) bad.push(`the reason does not name the merge: ${result.stderr}`);
      if (!/not the clean merge/.test(result.stderr)) bad.push(`the reason does not name rule (c): ${result.stderr}`);
      return bad;
    },
  });

  // 7. A merge this rule cannot judge: an octopus merge (three parents) after the signature. The other
  //    parents are on main, so the merge-only rule passes and rule (c) is reached; it must say so rather
  //    than pick two parents and guess.
  cases.push({
    name: 'a merge with other than two parents refuses',
    run() {
      const bad = [];
      const dir = newRepo('f.txt', LINES(10));
      g(dir, ['checkout', '-q', '-b', 'pr']);
      setLine(dir, 'f.txt', 5, 'line 5 (PR)');
      const S = commit(dir, 'pr: change line 5');
      g(dir, ['checkout', '-q', 'main']);
      writeFileSync(join(dir, 'm1.txt'), 'm1\n');
      const m1 = commit(dir, 'main: m1');
      g(dir, ['checkout', '-q', '-b', 'side', 'HEAD~1']);
      writeFileSync(join(dir, 'side.txt'), 'side\n');
      const side = commit(dir, 'side: s1');
      g(dir, ['checkout', '-q', 'main']);
      g(dir, ['merge', '-q', '--no-ff', 'side', '-m', 'main: merge side']);
      const mainTip = rev(dir, 'main');
      const tree = rev(dir, `${mainTip}^{tree}`);
      const H = g(dir, ['commit-tree', tree, '-p', S, '-p', m1, '-p', side, '-m', 'three-parent fold']).trim();

      if (g(dir, ['rev-list', '--no-merges', `${S}..${H}`, '^main']).trim()) {
        bad.push('a non-merge commit divides S and H, so the merge-only rule would decide this case');
      }
      const result = cli(dir, S, H);
      if (result.code !== 1 || result.stdout !== 'differs') {
        bad.push(`want differs/1, got ${result.stdout || '(no stdout)'}/${result.code}: ${result.stderr}`);
      }
      if (!/has 3 parents/.test(result.stderr)) bad.push(`the reason does not report the parent count: ${result.stderr}`);
      if (!result.stderr.includes(short(H))) bad.push(`the reason does not name the merge: ${result.stderr}`);
      return bad;
    },
  });

  let failed = 0;
  for (const testCase of cases) {
    let problems;
    try {
      problems = testCase.run();
    } catch (error) {
      problems = [`threw: ${error.message}`];
    }
    if (problems.length) {
      failed += 1;
      for (const problem of problems) console.error(`FAIL ${testCase.name}: ${problem}`);
    }
  }
  try {
    rmSync(root, { recursive: true, force: true });
  } catch {
    // A leftover temp directory is not a test failure.
  }
  console.log(`verified-gate-carry self-test: ${cases.length - failed}/${cases.length} cases`);
  return failed ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  cli(process.argv.slice(2));
}
