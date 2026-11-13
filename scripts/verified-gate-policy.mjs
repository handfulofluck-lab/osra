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
 *   - Signatures (parseSignatures; the workflow runs --parse): a `Verified-sha:` / `UIUX-Bureau: reviewed` /
 *     `Arabic-Bureau: reviewed` line counts only at the START of a line, outside fenced code blocks and blockquotes.
 *     The signer is the LAST line that starts with "— <Name>". A Bureau line also needs the Bureau in that signer line
 *     ("— Claude (UI/UX Bureau)", "— Claude (Arabic Language Bureau)"). So a request that quotes a line inline, in a
 *     code block or as a quote is never read as a signature.
 *   - An empty changed-files list fails closed.
 *
 * Input: a JSON object on stdin, { headRef, kimiCommits, labels[], files[], signatures: [{kind, name}] }, where
 * kind is "verify" (name = signer), "uiux" or "arabic". Prints the decision; exits 0 when it passes, 1 when not.
 *
 * Usage:
 *   node scripts/verified-gate-policy.mjs < input.json
 *   node scripts/verified-gate-policy.mjs --parse < bodies.jsonl
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
  const r = String(ref).toLowerCase();
  for (const [re, name] of PREFIXES) if (re.test(r)) return name;
  return 'Kimi Code';
}

// R3: security, money, children's data and location, infrastructure, signing, and the merge gate itself.
const R3_PATHS = [
  /^infra\//,
  /(^|\/)migrations?\//,
  /(^|\/)schema\.prisma$/,
  /^services\/api\/src\/middleware\//,
  // Workflows that build, publish, deploy or guard, including the gate and the lint that runs this self-test.
  /^\.github\/workflows\/(verified-gate|workflow-lint|main-guard|ci|api-image|api-publish|play-upload|terraform|deploy[^/]*|release[^/]*)\.ya?ml$/,
  /^scripts\/(verified-gate|check-verified-gate|check-workflows|check-no-pins|check-no-service-account-keys|check-pr-diff-scope|play-upload)/,
  /^AGENTS\.md$/,
  // Keywords anywhere in the path (also in docs: a doc named for one of these is usually policy, not prose).
  // (".entitlements" files are covered by "entitlement".)
  /(auth|pair|mfa|totp|session|token|revocation|deletion|invite|billing|refund|payment|purchase|subscription|entitlement|consent|location|geo|keystore|signing|secret|vault|redact|ratelimit|crypto)/i,
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
// Test files, which never need the UI/UX line on their own (this does not change their risk tier).
const TEST_PATHS = [
  /(^|\/)(test|tests|Tests|__tests__|androidTest|testFixtures)\//,
  /\.(test|spec)\.[cm]?[jt]sx?$/,
  /_test\.(dart|go|py)$/,
  /Tests?\.(kt|swift|cs)$/,
];
// Anything a family sees: UI/UX Bureau. Maintainer 2026-11-13 18:44Z: "any screen should have the UI/UX Bureau OK
// before it goes" (AGENTS.md §6.6). Path list agreed with the Bureau; it errs toward asking.
const UIUX_PATHS = [
  /^apps\/parent-app\/lib\//, // the whole Flutter parent app
  /^apps\/[^/]+\/lib\/(features|theme|l10n)\//,
  // Every Android resource and manifest in every source set (main, full, play, debug): strings, layouts, drawables,
  // icons, colours, themes, app label.
  /\/src\/(?!test\/|androidTest\/)[^/]+\/res\//,
  /\/src\/(?!test\/|androidTest\/)[^/]+\/AndroidManifest\.xml$/,
  // Kotlin that draws a screen or holds its words (block screen copy, quick-settings tile).
  /^apps\/.*\/src\/(?!test\/|androidTest\/)[^/]+\/(java|kotlin)\/.*(Activity|Screen|Screens|Overlay|Dialog|View|Theme|Compose|Composable|Copy|Tile)[^/]*\.kt$/,
  // Android UI package (Compose screens land under ui/, #728).
  /^apps\/.*\/src\/(?!test\/|androidTest\/)[^/]+\/(java|kotlin)\/.*\/ui\//,
  // Parent app iOS shell: launch screen, icons, display name (Info.plist).
  /^apps\/parent-app\/ios\/Runner\//,
  // Android code that builds a notification or a cover in code (UI/UX Bureau, #730 comment 6862247266).
  /^apps\/child-android\/app\/src\/main\/java\/.*\/(CommandDispatcher|CommandPollWorker|UnlinkedNotice|CallEnforcer|LocationService|FilterVpnService)\.kt$/,
  // Server words a family reads: email templates, and which push alert (loc keys) a parent sees.
  /^services\/api\/src\/lib\/email\//,
  /^services\/api\/src\/lib\/push\/notify\.ts$/,
  /^apps\/child-ios\/(App|Extensions)\//, // app shell, icons, shield screens, extension strings
  /^apps\/child-ios\/Sources\/[^/]+\/(Resources\/|L10n\.swift$|Shield[^/]*\.swift$)/,
  /Views?\.swift$/,
  // Desktop agents: the lock overlay, dialogs, the SOS prompt and the web block page the proxy serves.
  /^apps\/agent-(desktop|macos)\/(?!tests\/).*(Overlay|Dialog|Alert|Window|Form|View|Tray|Notification|Sos|WebFilterProxy)[^/]*\.cs$/,
  /^apps\/agent-(desktop|macos)\/(?!tests\/)(.*\/)?Resources\//, // strings, icons
  /\.xaml$/,
  /(^|\/)Assets\.xcassets\//,
  /\.lproj\//,
  /\.(storyboard|xib)$/,
  /\.arb$/,
  /\.strings(dict)?$/,
  /\.xcstrings$/,
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
  if (!files.length) {
    // The files call returned nothing: never fall through to a lower tier (fail closed).
    return { ok: false, author: authorFromRef(headRef), tier: 'R?', signers: [], counted: [], needUiux: false, needArabic: false,
      reasons: ['no changed files were read for this PR: failing closed'] };
  }
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

  const uiuxLabel = labels.includes('needs:uiux');
  // A test of a screen is not the screen: test files never trigger the UI/UX line on their own.
  const notTests = files.filter((f) => !TEST_PATHS.some((re) => re.test(f)));
  const needUiux = uiuxLabel || any(notTests, UIUX_PATHS);
  const needArabic = labels.includes('needs:arabic') || any(files, ARABIC_PATHS);
  // The Bureau's waiver (`UIUX-Bureau: not user-visible <sha>`) answers a path match only: when someone asked for a
  // review with the needs:uiux label, only a review answers it.
  const uiuxOk = signatures.some((s) => s.kind === 'uiux' || (!uiuxLabel && s.kind === 'uiux-waiver'));
  if (needUiux && !uiuxOk) {
    ok = false;
    reasons.push(
      uiuxLabel
        ? 'labelled needs:uiux: needs `UIUX-Bureau: reviewed <head sha>`'
        : "user-visible path: needs `UIUX-Bureau: reviewed <head sha>` (or the Bureau's `UIUX-Bureau: not user-visible <head sha>`)"
    );
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

// The signer is the LAST line that starts with "— <Name>" (a footer such as "_Generated by …_" may follow it).
const SIGNER_RE = /^\s*— (Antigravity|Claude|Fable|Kimi Code|K31-Mac|K31|Ahmed)(?![\w-])/;
const KEYWORD = {
  verify: /^\s*[*_]*Verified-sha:[*_]*\s*`?([0-9a-fA-F]{7,40})(?![0-9a-fA-F])/,
  uiux: /^\s*[*_]*UIUX-Bureau:[*_]*\s*reviewed\s*`?([0-9a-fA-F]{7,40})(?![0-9a-fA-F])/,
  uiuxWaiver: /^\s*[*_]*UIUX-Bureau:[*_]*\s*not user-visible\s*`?([0-9a-fA-F]{7,40})(?![0-9a-fA-F])/,
  arabic: /^\s*[*_]*Arabic-Bureau:[*_]*\s*reviewed\s*`?([0-9a-fA-F]{7,40})(?![0-9a-fA-F])/,
};

/**
 * Signatures in one comment body: [{kind, name, sha}]. A keyword or signer line counts only at the start of a line
 * (so never inline and never in a "> " quote) and never inside a fenced code block: a request that quotes a line is
 * not a signature. A Bureau line also needs its Bureau named in the signer line.
 */
export function parseSignatures(body) {
  const lines = [];
  let fenced = false;
  for (const raw of String(body).split(/\r?\n/)) {
    if (/^\s*(```|~~~)/.test(raw)) {
      fenced = !fenced;
      continue;
    }
    if (!fenced) lines.push(raw);
  }
  const signerLine = lines.filter((l) => /^\s*— /.test(l)).at(-1) ?? '';
  const name = SIGNER_RE.exec(signerLine)?.[1] ?? '';
  const shas = (re) => lines.map((l) => re.exec(l)?.[1]).filter(Boolean).map((s) => s.toLowerCase());
  const out = [];
  if (name) for (const sha of shas(KEYWORD.verify)) out.push({ kind: 'verify', name, sha });
  if (/UI\/UX Bureau/.test(signerLine)) {
    for (const sha of shas(KEYWORD.uiux)) out.push({ kind: 'uiux', name: '-', sha });
    for (const sha of shas(KEYWORD.uiuxWaiver)) out.push({ kind: 'uiux-waiver', name: '-', sha });
  }
  if (/Arabic (Language )?Bureau/.test(signerLine)) for (const sha of shas(KEYWORD.arabic)) out.push({ kind: 'arabic', name: '-', sha });
  return out;
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
    // Added for Fable's review of #721 (B2): each case pins one rule that a planted fault could otherwise remove.
    ['Kimi R3 signed by Ahmed alone (key is not also cross-family partner)', { headRef: 'kimi/x', files: ['services/api/src/auth/jwt.ts'], signatures: v('Ahmed') }, false],
    ['Kimi R3 signed by Fable alone', { headRef: 'kimi/x', files: ['services/api/src/auth/jwt.ts'], signatures: v('Fable') }, false],
    ['Kimi R3 signed by Claude + K31 (no security key)', { headRef: 'kimi/x', files: ['services/api/src/auth/jwt.ts'], signatures: v('Claude', 'K31') }, false],
    ['Kimi R3 signed by Fable + K31', { headRef: 'kimi/x', files: ['services/api/src/auth/jwt.ts'], signatures: v('Fable', 'K31') }, true],
    ['code + doc is not R1', { headRef: 'claude/x', files: ['a/b.ts', 'docs/x.md'], signatures: v('Fable') }, false],
    ['empty file list fails closed', { headRef: 'claude/x', files: [], signatures: v('Fable', 'K31', 'Kimi Code') }, false],
    ['needs:uiux label forces the UI/UX line', { headRef: 'kimi/x', labels: ['needs:uiux'], files: ['a/b.ts'], signatures: v('Claude') }, false],
    ['fable/ R2 signed by Claude (same family)', { headRef: 'fable/x', files: ['a/b.ts'], signatures: v('Claude') }, false],
    ['fable/ R2 signed by K31', { headRef: 'fable/x', files: ['a/b.ts'], signatures: v('K31') }, true],
    ['k31/ R2 signed by K31-Mac (same family)', { headRef: 'k31/x', files: ['a/b.ts'], signatures: v('K31-Mac') }, false],
    ['k31/ R2 signed by Claude', { headRef: 'k31/x', files: ['a/b.ts'], signatures: v('Claude') }, true],
    ['prefix is case-insensitive: K31/ signed by K31', { headRef: 'K31/x', files: ['a/b.ts'], signatures: v('K31') }, false],
    ['UI .arb outside l10n needs the UI/UX line', { headRef: 'kimi/x', files: ['apps/child-android/lib/x.arb'], signatures: v('Claude') }, false],
    ['values-ar strings need the Arabic line', { headRef: 'kimi/x', files: ['apps/child-android/app/src/main/res/values-ar/strings.xml'], signatures: [...v('Claude'), { kind: 'uiux' }] }, false],
    ['email templates need the Arabic line', { headRef: 'kimi/x', files: ['services/api/src/lib/email/templates.ts'], signatures: v('Claude') }, false],
    // UI/UX Bureau waiver (maintainer 2026-11-13 18:44Z rule; the Bureau's only waiver).
    ['UI path with the Bureau waiver', { headRef: 'kimi/x', files: ['apps/parent-app/lib/providers/x.dart'], signatures: [...v('Claude'), { kind: 'uiux-waiver' }] }, true],
    ['needs:uiux label is not answered by a waiver', { headRef: 'kimi/x', labels: ['needs:uiux'], files: ['a/b.ts'], signatures: [...v('Claude'), { kind: 'uiux-waiver' }] }, false],
    ['needs:uiux label with a review', { headRef: 'kimi/x', labels: ['needs:uiux'], files: ['a/b.ts'], signatures: [...v('Claude'), { kind: 'uiux' }] }, true],
    ['non-UI Kotlin service needs no UI/UX line', { headRef: 'kimi/x', files: ['apps/child-android/app/src/main/java/com/osra/child/sync/SyncWorker.kt'], signatures: v('Claude') }, true],
    ['push transport (fcm.ts) needs no UI/UX line', { headRef: 'kimi/x', files: ['services/api/src/lib/push/fcm.ts'], signatures: v('Claude') }, true],
    ['CommandDispatcher test only needs no UI/UX line', { headRef: 'kimi/x', files: ['apps/child-android/app/src/test/java/com/familyshield/agent/CommandDispatcherAckTest.kt'], signatures: v('Claude') }, true],
    ['non-UI Swift needs no UI/UX line', { headRef: 'kimi/x', files: ['apps/child-ios/Sources/OSRAKidsCore/Heartbeat.swift'], signatures: v('Claude') }, true],
    ['a test of a screen needs no UI/UX line', { headRef: 'kimi/x', files: ['apps/child-android/app/src/test/java/com/familyshield/agent/enforcement/LockScreenPolicyTest.kt'], signatures: v('Claude') }, true],
    ['an iOS shield-text test needs no UI/UX line', { headRef: 'kimi/x', files: ['apps/child-ios/Tests/FamilyShieldAgentTests/ShieldTextTests.swift'], signatures: v('Claude') }, true],
    ['a desktop test needs no UI/UX line', { headRef: 'kimi/x', files: ['apps/agent-desktop/tests/FamilyShield.Agent.Tests/SosHotkeyTests.cs'], signatures: v('Claude') }, true],
    ['a screen plus its test still needs the line', { headRef: 'kimi/x', files: ['apps/agent-desktop/Services/LockOverlay.cs', 'apps/agent-desktop/tests/FamilyShield.Agent.Tests/LockOverlayTests.cs'], signatures: v('Claude') }, false],
    ['server code needs no UI/UX line', { headRef: 'kimi/x', files: ['services/api/src/routes/foo.ts'], signatures: v('Claude') }, true],
    ['email templates with the Arabic line', { headRef: 'kimi/x', files: ['services/api/src/lib/email/templates.ts'], signatures: [...v('Claude'), { kind: 'arabic' }, { kind: 'uiux' }] }, true],
  ];
  // R3 by path: one cross-family signer alone must NOT pass (it would at R2). One case per R3 entry Fable listed.
  const r3Paths = [
    'services/api/prisma/migrations/20261113_x/migration.sql',
    'scripts/verified-gate-carry.mjs',
    'apps/child-ios/OSRAKids/OSRAKids.entitlements',
    'services/api/src/lib/totp.ts',
    'services/api/src/lib/sessions.ts',
    'services/api/src/middleware/sessionGuard.ts',
    'services/api/src/middleware/requireFamily.ts',
    'services/api/src/lib/pairApproval.ts',
    'services/api/src/lib/entitlement.ts',
    'services/api/src/lib/deviceToken.ts',
    'services/api/src/lib/deviceRevocation.ts',
    'services/api/src/lib/accountDeletionLink.ts',
    'services/api/src/lib/geo.ts',
    'services/api/src/routes/invites.ts',
    'services/api/prisma/schema.prisma',
    '.github/workflows/terraform.yml',
    '.github/workflows/play-upload.yml',
    '.github/workflows/api-publish.yml',
    '.github/workflows/main-guard.yml',
    '.github/workflows/workflow-lint.yml',
    '.github/workflows/ci.yml',
    'scripts/play-upload.mjs',
    'scripts/check-workflows.mjs',
    'scripts/check-no-pins.mjs',
    'scripts/check-verified-gate-signers.mjs',
    'AGENTS.md',
  ];
  // Every screen needs the UI/UX Bureau (maintainer 2026-11-13 18:44Z). One case per path family the Bureau listed.
  const uiPaths = [
    'apps/parent-app/lib/providers/x.dart',
    'apps/parent-app/lib/api/client.dart',
    'apps/child-android/app/src/main/res/values/colors.xml',
    'apps/child-android/app/src/main/res/drawable/ic_shield.xml',
    'apps/child-android/app/src/main/AndroidManifest.xml',
    'apps/child-android/app/src/main/java/com/osra/child/lock/LockActivity.kt',
    'apps/child-android/app/src/main/java/com/osra/child/pip/PipCoverOverlay.kt',
    'apps/child-android/app/src/main/java/com/osra/child/ui/VisibleScreens.kt',
    'apps/child-ios/Sources/OSRAKids/ParentPinViews.swift',
    'apps/child-ios/Sources/OSRAKids/PairingView.swift',
    'apps/child-ios/Sources/OSRAKidsCore/L10n.swift',
    'apps/child-ios/Sources/OSRAKids/Resources/en.lproj/Localizable.strings',
    'apps/child-ios/Sources/OSRAKids/Resources/ar.lproj/Localizable.stringsdict',
    'apps/child-ios/App/Assets.xcassets/AppIcon.appiconset/Contents.json',
    'apps/child-ios/Extensions/ShieldConfiguration/ShieldConfiguration.swift',
    'apps/child-ios/Extensions/ShieldAction/en.lproj/InfoPlist.strings',
    'apps/parent-app/ios/Runner/Base.lproj/LaunchScreen.storyboard',
    'apps/agent-desktop/Services/LockOverlay.cs',
    'apps/agent-desktop/Services/PairingDialog.cs',
    'apps/agent-desktop/Services/ProxyStartupAlert.cs',
    'apps/agent-desktop/Services/SosHotkey.cs',
    'apps/agent-desktop/Services/WebFilterProxy.cs',
    'apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/BlockWindowCopy.kt',
    'apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosTileService.kt',
    'apps/child-android/app/src/full/res/values/ic_app_colors.xml',
    'apps/child-android/app/src/full/AndroidManifest.xml',
    'apps/child-ios/Sources/FamilyShieldAgent/ShieldText.swift',
    'apps/parent-app/android/app/src/main/kotlin/dev/familyshield/familyshield_parent/MainActivity.kt',
    'apps/child-android/app/src/main/java/com/familyshield/agent/ui/pairing/PairingContent.kt',
    'apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingComposables.kt',
    'apps/parent-app/ios/Runner/Info.plist',
    'apps/parent-app/android/app/src/main/res/mipmap-hdpi/ic_launcher.png',
    'apps/agent-desktop/Resources/Strings.resx',
    'apps/agent-desktop/Views/MainWindow.xaml',
    'apps/agent-macos/Sources/StatusView.swift',
    'apps/agent-macos/Assets.xcassets/AppIcon.appiconset/Contents.json',
    'apps/agent-macos/Resources/Localizable.xcstrings',
    'docs/design/tokens.json',
    'apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt',
    'apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandPollWorker.kt',
    'apps/child-android/app/src/main/java/com/familyshield/agent/network/UnlinkedNotice.kt',
    'apps/child-android/app/src/main/java/com/familyshield/agent/services/CallEnforcer.kt',
    'apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt',
    'apps/child-android/app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt',
    'services/api/src/lib/email/templates.ts',
    'services/api/src/lib/email/index.ts',
    'services/api/src/lib/push/notify.ts',
    'site/index.html',
    'scripts/site/build.mjs',
    'docs/design/brand/export/logo.svg',
    'docs/store/play/listing-en.md',
  ];
  for (const f of uiPaths) {
    cases.push([`UI path ${f}: no UI/UX line`, { headRef: 'kimi/x', files: [f], signatures: v('Claude', 'Fable') }, false]);
  }

  for (const f of r3Paths) {
    cases.push([`R3 path ${f}: K31 alone on a Claude PR`, { headRef: 'claude/x', files: [f], signatures: v('K31') }, false]);
  }
  cases.push(['R3 migrations path passes with K31 + Fable on a Claude PR', { headRef: 'claude/x', files: [r3Paths[0]], signatures: v('K31', 'Fable') }, true]);

  let failed = 0;
  for (const [name, input, want] of cases) {
    const got = decide(input);
    if (got.ok !== want) {
      failed++;
      console.error(`FAIL ${name}: want ${want}, got ${got.ok} (${got.tier}; ${got.reasons.join('; ')})`);
    }
  }

  // Signature parsing: [description, body, expected "kind:name:sha" list].
  const H = '0123456789abcdef0123456789abcdef01234567';
  const FOOT = '\n\n---\n_Generated by [Claude Code](https://claude.ai/code)_';
  const parseCases = [
    ['a real signature with the footer', `Checked.\n\nVerified-sha: ${H}\n— Claude (architecture + testing), team coordinator${FOOT}`, [`verify:Claude:${H}`]],
    ['Kimi signature', `Verified-sha: ${H.slice(0, 8)}\n— Kimi Code (development lead)`, [`verify:Kimi Code:${H.slice(0, 8)}`]],
    ['K31-Mac is not read as K31', `Verified-sha: ${H}\n— K31-Mac`, [`verify:K31-Mac:${H}`]],
    ['inline request quoting a line is not a signature', `Fable, please post \`Verified-sha: ${H}\` — Fable`, []],
    ['inline request signed by the coordinator is not a signature', `Please verify and post \`Verified-sha: ${H}\`.\n— Claude (architecture + testing), team coordinator`, []],
    ['a line in a code block is not a signature', `Please post:\n\`\`\`\nVerified-sha: ${H}\n— Fable\n\`\`\`\n— Claude (architecture + testing), team coordinator`, []],
    ['a blockquoted line is not a signature', `> Verified-sha: ${H}\n> — Fable\n\nNoted.\n— Claude (architecture + testing), team coordinator`, []],
    ['a body with no signer line yields nothing', `Verified-sha: ${H}`, []],
    ['the LAST signer line wins', `— Fable said this was fine.\nVerified-sha: ${H}\n— K31`, [`verify:K31:${H}`]],
    ['UI/UX line signed by the Bureau', `UIUX-Bureau: reviewed ${H}\n— Claude (UI/UX Bureau)${FOOT}`, [`uiux:-:${H}`]],
    ['waiver signed by the Bureau', `UIUX-Bureau: not user-visible ${H}\n— Claude (UI/UX Bureau)${FOOT}`, [`uiux-waiver:-:${H}`]],
    ['waiver signed by the coordinator is not the Bureau', `UIUX-Bureau: not user-visible ${H}\n— Claude (architecture + testing), team coordinator`, []],
    ['waiver inline in a request is not a waiver', `Bureau, please post \`UIUX-Bureau: not user-visible ${H}\`.\n— Claude (UI/UX Bureau)`, []],
    ['waiver in a code block is not a waiver', `Post:\n\`\`\`\nUIUX-Bureau: not user-visible ${H}\n\`\`\`\n— Claude (UI/UX Bureau)`, []],
    ['a review and a waiver in one Bureau comment', `UIUX-Bureau: reviewed ${H}\nUIUX-Bureau: not user-visible ${H}\n— Claude (UI/UX Bureau)`, [`uiux:-:${H}`, `uiux-waiver:-:${H}`]],
    ['UI/UX line signed by the coordinator is not the Bureau', `UIUX-Bureau: reviewed ${H}\n— Claude (architecture + testing), team coordinator`, []],
    ['Arabic line signed by the Bureau', `Arabic-Bureau: reviewed ${H}\n— Claude (Arabic Language Bureau)`, [`arabic:-:${H}`]],
    ['Arabic line signed by the coordinator is not the Bureau', `Arabic-Bureau: reviewed ${H}\n— Claude (architecture + testing), team coordinator`, []],
    ['a longer name is not a member (Claudette is not Claude)', `Verified-sha: ${H}\n— Claudette`, []],
    ['Arabic line inline in a request is not a review', `Bureau, please post \`Arabic-Bureau: reviewed ${H}\`.\n— Claude (Arabic Language Bureau)`, []],
    ['a longer hex run is not a sha', `Verified-sha: ${H}ff\n— K31`, []],
  ];
  for (const [name, body, want] of parseCases) {
    const got = parseSignatures(body).map((s) => `${s.kind}:${s.name}:${s.sha}`);
    if (JSON.stringify(got) !== JSON.stringify(want)) {
      failed++;
      console.error(`FAIL parse: ${name}: want ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
    }
  }

  const total = cases.length + parseCases.length;
  if (failed) {
    console.error(`verified-gate policy self-test: ${failed} of ${total} cases fail`);
    process.exit(1);
  }
  console.log(`verified-gate policy self-test: ${total} cases pass`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.includes('--selftest')) {
    selftest();
  } else if (process.argv.includes('--parse')) {
    // One JSON-encoded comment body per line (jq @json) -> kind<TAB>name<TAB>sha per signature.
    for (const line of fs.readFileSync(0, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      for (const s of parseSignatures(JSON.parse(line))) console.log(`${s.kind}\t${s.name}\t${s.sha}`);
    }
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
