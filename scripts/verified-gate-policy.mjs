#!/usr/bin/env node
/**
 * The mesh merge policy (maintainer decision 2026-11-13 15:42Z, decision row on #617, rules on #719, AGENTS.md §6.6).
 *
 * verified-gate.yml collects, from comments written by the agent account, every signature that is valid for the
 * PR's current head (a sha prefix of the head, or carried forward by scripts/verified-gate-carry.mjs). This script
 * then decides whether those signatures are ENOUGH for this PR:
 *
 *   - Author: read from the head branch prefix (kimi/ claude/ qa/ verify/ fable/ ahmed/ k31/ k31mac/). A branch with
 *     no known prefix is Kimi's (the convention before 13 Nov). Kimi-authored non-merge commits (commit email) add
 *     Kimi as a co-author whatever the prefix.
 *   - Model families: anthropic = Claude, Fable, Ahmed (his tool is Claude Code); deepseek = Kimi Code;
 *     moonshot = K31, K31-Mac; google = Antigravity.
 *   - Risk tier: the higher of the `risk:R1/R2/R3` label and the tier computed from the changed paths. A label can
 *     raise the tier, never lower it.
 *       R1: one signer who is not an author.
 *       R2: one signer from a family that is not an author's family.
 *       R3: two different signers, neither an author; at least one from a non-author family; and one of the two is
 *           the security key, Ahmed or Fable.
 *   - Bureaus: a diff touching user-visible paths (or labelled `needs:uiux`) also needs `UIUX-Bureau: reviewed <sha>`
 *     valid at the head; a diff touching Arabic text (or labelled `needs:arabic`) needs `Arabic-Bureau: reviewed <sha>`.
 *
 * Input: a JSON object on stdin, { headRef, kimiCommits, labels[], files[], signatures: [{kind, name}] }, where
 * kind is "verify" (name = signer), "uiux" or "arabic". Prints the decision; exits 0 when it passes, 1 when not.
 *
 * Usage:
 *   node scripts/verified-gate-policy.mjs < input.json
 *   node scripts/verified-gate-policy.mjs --selftest
 */
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

export const FAMILY = {
  Claude: 'anthropic',
  Fable: 'anthropic',
  Ahmed: 'anthropic',
  'Kimi Code': 'deepseek',
  K31: 'moonshot',
  'K31-Mac': 'moonshot',
  Antigravity: 'google',
};
export const SECURITY_KEYS = ['Ahmed', 'Fable'];

const PREFIXES = [
  [/^(claude|qa|verify)\//, 'Claude'],
  [/^fable\//, 'Fable'],
  [/^ahmed\//, 'Ahmed'],
  [/^k31-?mac\//, 'K31-Mac'],
  [/^k31\//, 'K31'],
  [/^kimi\//, 'Kimi Code'],
];

export function authorFromRef(ref) {
  for (const [re, name] of PREFIXES) if (re.test(ref)) return name;
  return 'Kimi Code';
}

// R3: security, money, children's data and location, infrastructure, signing, and the merge gate itself.
const R3_PATHS = [
  /^infra\//,
  /(^|\/)migrations?\//,
  /^\.github\/workflows\/(verified-gate|api-image|deploy[^/]*|release[^/]*)\.ya?ml$/,
  /^scripts\/(verified-gate|check-verified-gate)/,
  /(auth|pairing|mfa|billing|refund|payment|purchase|subscription|consent|location|geofence|keystore|signing|entitlements|secret|crypto)/i,
  /\.entitlements$/,
];
// R1: text, docs and tests only.
const R1_PATHS = [
  /\.(md|txt)$/i,
  /^docs\//,
  /^CHANGELOG/,
  /(^|\/)(test|tests|__tests__|androidTest|testFixtures)\//,
  /\.(test|spec)\.[cm]?[jt]sx?$/,
  /_test\.(dart|go|py)$/,
  /Tests?\.(kt|swift)$/,
];
// Anything a family sees: UI/UX Bureau.
const UIUX_PATHS = [
  /^apps\/[^/]+\/lib\/(features|theme|l10n)\//,
  /\.arb$/,
  /\.strings$/,
  /\.xcstrings$/,
  /\/res\/(values[^/]*\/strings\.xml|layout[^/]*\/|drawable[^/]*\/|mipmap[^/]*\/)/,
  /View\.swift$/,
  /^site\//,
  /^scripts\/site\//,
  /^docs\/(store|design)\//,
];
// Arabic text: Arabic Language Bureau.
const ARABIC_PATHS = [
  /_ar\.arb$/,
  /\/values-ar\//,
  /(^|\/)ar\.lproj\//,
  /^site\/ar\//,
  /\.ar\.[a-z]+$/,
  /^docs\/(store|customer)\//,
  /^services\/api\/src\/lib\/email\//,
];

const any = (files, res) => files.some((f) => res.some((re) => re.test(f)));

export function pathTier(files) {
  if (any(files, R3_PATHS)) return 3;
  if (files.length && files.every((f) => R1_PATHS.some((re) => re.test(f)))) return 1;
  return 2;
}

export function decide({ headRef = '', kimiCommits = 0, labels = [], files = [], signatures = [] }) {
  const reasons = [];
  const author = authorFromRef(headRef);
  const authors = new Set([author]);
  if (kimiCommits > 0) authors.add('Kimi Code');
  const authorFamilies = new Set([...authors].map((a) => FAMILY[a]));

  const labelTier = Math.max(0, ...labels.map((l) => /^risk:R([123])$/.exec(l)).filter(Boolean).map((m) => Number(m[1])));
  const tier = Math.max(labelTier, pathTier(files));

  const signers = [...new Set(signatures.filter((s) => s.kind === 'verify').map((s) => s.name))].filter((n) => FAMILY[n]);
  const notAuthor = signers.filter((n) => !authors.has(n));
  const crossFamily = notAuthor.filter((n) => !authorFamilies.has(FAMILY[n]));

  let ok;
  if (tier === 1) {
    ok = notAuthor.length >= 1;
    if (!ok) reasons.push('R1 needs one signature from a member who is not the author');
  } else if (tier === 2) {
    ok = crossFamily.length >= 1;
    if (!ok) reasons.push(`R2 needs one signature from a model family other than the author's (${[...authorFamilies].join(', ')})`);
  } else {
    const keys = notAuthor.filter((n) => SECURITY_KEYS.includes(n));
    ok = keys.some((k) => crossFamily.some((c) => c !== k));
    if (!ok) {
      reasons.push(
        'R3 needs two different signers who are not the author: one from a family other than the author\'s, and one security key (Ahmed or Fable)'
      );
    }
  }

  const needUiux = labels.includes('needs:uiux') || any(files, UIUX_PATHS);
  const needArabic = labels.includes('needs:arabic') || any(files, ARABIC_PATHS);
  if (needUiux && !signatures.some((s) => s.kind === 'uiux')) {
    ok = false;
    reasons.push('user-visible change: needs `UIUX-Bureau: reviewed <head sha>`');
  }
  if (needArabic && !signatures.some((s) => s.kind === 'arabic')) {
    ok = false;
    reasons.push('Arabic text change: needs `Arabic-Bureau: reviewed <head sha>`');
  }

  return {
    ok,
    author: [...authors].join(' + '),
    tier: `R${tier}`,
    signers,
    counted: tier === 1 ? notAuthor : crossFamily.concat(notAuthor.filter((n) => SECURITY_KEYS.includes(n))),
    needUiux,
    needArabic,
    reasons,
  };
}

function selftest() {
  const v = (...names) => names.map((name) => ({ kind: 'verify', name }));
  const cases = [
    // [description, input, expected ok]
    ['Kimi R2 signed by Claude', { headRef: 'fix/643-x', files: ['services/api/src/routes/foo.ts'], signatures: v('Claude') }, true],
    ['Kimi R2 signed only by Kimi', { headRef: 'kimi/x', files: ['services/api/src/routes/foo.ts'], signatures: v('Kimi Code') }, false],
    ['Claude R2 signed by Claude (self)', { headRef: 'claude/x', files: ['apps/child-android/app/src/main/java/A.kt'], signatures: v('Claude') }, false],
    ['Claude R2 signed by Fable (same family)', { headRef: 'claude/x', files: ['apps/child-android/app/src/main/java/A.kt'], signatures: v('Fable') }, false],
    ['Claude R2 signed by K31', { headRef: 'claude/x', files: ['apps/child-android/app/src/main/java/A.kt'], signatures: v('K31') }, true],
    ['K31-Mac R2 signed by K31 (same family)', { headRef: 'k31mac/x', files: ['apps/agent-macos/Sources/A.swift'], signatures: v('K31') }, false],
    ['K31-Mac R2 signed by Kimi', { headRef: 'k31mac/x', files: ['apps/agent-macos/Sources/A.swift'], signatures: v('Kimi Code') }, true],
    ['Ahmed R2 signed by Claude (same family)', { headRef: 'ahmed/x', files: ['apps/child-ios/Sources/A.swift'], signatures: v('Claude') }, false],
    ['Ahmed R2 signed by K31', { headRef: 'ahmed/x', files: ['apps/child-ios/Sources/A.swift'], signatures: v('K31') }, true],
    ['Claude branch with a Kimi commit, signed by Kimi', { headRef: 'claude/x', kimiCommits: 1, files: ['a/b.ts'], signatures: v('Kimi Code') }, false],
    ['docs-only R1 signed by same family', { headRef: 'claude/x', files: ['docs/QA/X.md'], signatures: v('Fable') }, true],
    ['docs-only R1 signed by author', { headRef: 'claude/x', files: ['docs/QA/X.md'], signatures: v('Claude') }, false],
    ['R1 label cannot lower code to R1', { headRef: 'claude/x', labels: ['risk:R1'], files: ['a/b.ts'], signatures: v('Fable') }, false],
    ['R3 label raises docs to R3', { headRef: 'kimi/x', labels: ['risk:R3'], files: ['docs/x.md'], signatures: v('Claude') }, false],
    ['R3 path, one signer', { headRef: 'kimi/x', files: ['services/api/src/auth/jwt.ts'], signatures: v('Claude') }, false],
    ['R3 path, Claude + Ahmed on Kimi PR', { headRef: 'kimi/x', files: ['services/api/src/auth/jwt.ts'], signatures: v('Claude', 'Ahmed') }, true],
    ['R3 path, K31 + Ahmed on Claude PR', { headRef: 'claude/x', files: ['infra/terraform/main.tf'], signatures: v('K31', 'Ahmed') }, true],
    ['R3 path, Fable + Ahmed on Claude PR (no cross-family)', { headRef: 'claude/x', files: ['infra/terraform/main.tf'], signatures: v('Fable', 'Ahmed') }, false],
    ['R3 path, Ahmed authored, Ahmed + K31', { headRef: 'ahmed/x', files: ['apps/child-ios/Sources/Pairing.swift'], signatures: v('Ahmed', 'K31') }, false],
    ['R3 path, Ahmed authored, Fable + K31', { headRef: 'ahmed/x', files: ['apps/child-ios/Sources/Pairing.swift'], signatures: v('Fable', 'K31') }, true],
    ['R3 path, K31 + Kimi (no security key)', { headRef: 'claude/x', files: ['infra/terraform/main.tf'], signatures: v('K31', 'Kimi Code') }, false],
    ['the gate itself is R3', { headRef: 'claude/x', files: ['.github/workflows/verified-gate.yml'], signatures: v('K31') }, false],
    ['UI change without UI/UX line', { headRef: 'kimi/x', files: ['apps/parent-app/lib/features/home/home.dart'], signatures: v('Claude') }, false],
    ['UI change with UI/UX line', { headRef: 'kimi/x', files: ['apps/parent-app/lib/features/home/home.dart'], signatures: [...v('Claude'), { kind: 'uiux' }] }, true],
    ['Arabic change with UI/UX line only', { headRef: 'kimi/x', files: ['apps/parent-app/lib/l10n/app_ar.arb'], signatures: [...v('Claude'), { kind: 'uiux' }] }, false],
    ['Arabic change with both lines', { headRef: 'kimi/x', files: ['apps/parent-app/lib/l10n/app_ar.arb'], signatures: [...v('Claude'), { kind: 'uiux' }, { kind: 'arabic' }] }, true],
    ['needs:arabic label forces the Arabic line', { headRef: 'kimi/x', labels: ['needs:arabic'], files: ['a/b.ts'], signatures: v('Claude') }, false],
    ['unknown signer name ignored', { headRef: 'kimi/x', files: ['a/b.ts'], signatures: v('Mallory') }, false],
  ];
  let failed = 0;
  for (const [name, input, want] of cases) {
    const got = decide(input);
    if (got.ok !== want) {
      failed++;
      console.error(`FAIL ${name}: want ${want}, got ${got.ok} (${got.tier}; ${got.reasons.join('; ')})`);
    }
  }
  if (failed) {
    console.error(`verified-gate policy self-test: ${failed} of ${cases.length} cases fail`);
    process.exit(1);
  }
  console.log(`verified-gate policy self-test: ${cases.length} cases pass`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.includes('--selftest')) {
    selftest();
  } else {
    const input = JSON.parse(fs.readFileSync(0, 'utf8'));
    const d = decide(input);
    console.log(`author: ${d.author}; tier: ${d.tier}; valid signers at head: ${d.signers.join(', ') || 'none'}`);
    console.log(`UI/UX Bureau line required: ${d.needUiux}; Arabic Bureau line required: ${d.needArabic}`);
    if (d.ok) {
      console.log(`OK: counted ${d.counted.join(', ')}`);
    } else {
      for (const r of d.reasons) console.log(`::error::${r}`);
      process.exit(1);
    }
  }
}
