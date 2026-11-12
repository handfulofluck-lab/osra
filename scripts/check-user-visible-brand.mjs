#!/usr/bin/env node
/**
 * Issue #608: fails when a repo file still carries old user-visible branding that must become OSRA.
 *
 * The rename touches four user-visible surfaces and leaves the internal identifiers alone:
 *
 *   1. the export filename becomes `osra-export-<familyId>.json`;
 *   2. the support domain/email becomes `demo@osratech.com`;
 *   3. the desktop user-visible data folder becomes `OSRA` (Windows `%LOCALAPPDATA%` and macOS
 *      `~/Library/Application Support`), with a one-time pairing-preserving migration from the old
 *      folder;
 *   4. the Windows test-certificate subject becomes `OSRA Test Root`.
 *
 * The old desktop folder name is matched as a *path segment* — double- or single-quoted, any
 * casing, followed by a comma-and-quoted-next-segment, a closing `)`, or a `+`-concatenation into a
 * path — and as a *path string* when it is a data-folder path. A bare `"FamilyShield";` constant or
 * a prose mention (the one-time migration's legacy-folder reference) is NOT a finding, and neither
 * are the internal identifiers: `FamilyShield.Agent.*`, the `FamilyShieldAgent` source folder,
 * `com.familyshield.agent` (and its `com/familyshield/agent/…` path form), `@familyshield/…` npm
 * scopes, `familyshield-tests`, and the root package name `familyshield`.
 *
 * Files scanned: everything `git ls-files` reports (tracked) plus `git ls-files --others
 * --exclude-standard` (untracked but not ignored), so a local pre-commit run cannot be false-green
 * while a new offender sits unstaged. The script itself is skipped (it names the patterns).
 *
 * Usage:
 *   node scripts/check-user-visible-brand.mjs              # tracked + untracked-not-ignored files
 *   node scripts/check-user-visible-brand.mjs --selftest   # prove each rule fires, and the CLI wires it
 *
 * Exits 1 on any finding, 0 when clean, 2 on an environment problem.
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import pathMod from "node:path";
import { fileURLToPath } from "node:url";

const SELF = "scripts/check-user-visible-brand.mjs";

// These dated QA records must retain the names as tested at the time (Claude's #608 ruling).
const ALLOWED_PATHS = [
  "docs/QA/KCL-2026-10-16/AUDIT-IOS-WINDOWS-MACOS.md",
  "docs/QA/audits/AUDIT-IOS-MACOS-2026-10-11.md",
  "docs/QA/audits/AUDIT-WINDOWS-2026-10-11.md",
];

/**
 * Ordered rules; a line is reported against the first rule it matches. The folder rules are
 * deliberately narrow so the migration's legacy-folder reference (`"FamilyShield";`) and the
 * internal package/namespace/path identifiers pass, while a path segment or a data-folder path
 * fails in any casing and with single or double quotes.
 */
const RULES = [
  { re: /familyshield-export/i, what: "the old export filename (use osra-export-<familyId>.json)" },
  { re: /familyshield\.dev/i, what: "the old support domain (use demo@osratech.com)" },
  { re: /["']FamilyShield["']\s*(?:,\s*["']|\)|\+\s*["']?[\\/.])/i, what: 'the old desktop data folder as a path segment (use "OSRA")' },
  { re: /FamilyShield[\\/]/, what: "the old desktop data folder in a path (use OSRA)" },
  { re: /(?:%LOCALAPPDATA%|%APPDATA%|Application Support|Application\\ Support)[\\/]familyshield[\\/]/i, what: "the old desktop data folder in a data path (use OSRA)" },
  { re: /FamilyShield Test Root/i, what: 'the old Windows test-certificate subject (use "OSRA Test Root")' },
];

/** Every file the repo knows: tracked, plus untracked-but-not-ignored, de-duplicated and sorted. */
function repoFiles() {
  const out = [];
  for (const extra of [[], ["--others", "--exclude-standard"]]) {
    try {
      out.push(
        ...execFileSync("git", ["ls-files", ...extra, "-z"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
          .split("\0")
          .filter(Boolean),
      );
    } catch (e) {
      console.error(`cannot list files: ${String(e.stderr ?? e.message).trim()}`);
      process.exit(2);
    }
  }
  return [...new Set(out)].sort();
}

/** One finding per line that matches a rule, in rule order. */
function scan(paths, cwd = process.cwd()) {
  const hits = [];
  for (const p of paths) {
    if (p === SELF || ALLOWED_PATHS.includes(p)) continue;
    let text;
    try {
      text = fs.readFileSync(pathMod.join(cwd, p), "utf8");
    } catch {
      continue; // deleted since listing, or unreadable
    }
    if (text.includes("\u0000")) continue; // binary
    text.split(/\r?\n/).forEach((line, index) => {
      for (const rule of RULES) {
        if (rule.re.test(line)) {
          hits.push({ path: p, line: index + 1, what: rule.what });
          break;
        }
      }
    });
  }
  return hits;
}

function report(hits) {
  if (!hits.length) {
    console.log("no old user-visible branding in any tracked or untracked repo file");
    return 0;
  }
  for (const h of hits) {
    console.error(`ERROR ${h.path}:${h.line} — ${h.what}`);
  }
  console.error("\nIssue #608 renames the user-visible surfaces to OSRA. Update the file to the new");
  console.error("form; internal identifiers and the one-time migration's legacy-folder reference stay.");
  return 1;
}

function runSelfTest() {
  const dir = fs.mkdtempSync(pathMod.join(os.tmpdir(), "brand-fixture-"));
  const write = (name, body) => fs.writeFileSync(pathMod.join(dir, name), body, "utf8");
  const cases = [
    // ── positive: each must be a finding ──
    ["the old export filename", 'Content-Disposition: attachment; filename="familyshield-export-123.json"', 1],
    ["the old support domain in an email", "seed the demo family demo@familyshield.dev", 1],
    ["the old support domain as a URL", 'apiBase = "https://api.familyshield.dev/v1"', 1],
    ["the old support domain bare", "the support address is familyshield.dev", 1],
    ["the old Windows data folder as a double-quoted segment", 'Path.Combine(GetFolderPath(LocalApplicationData), "FamilyShield", "status.json");', 1],
    ["the old macOS data folder as a double-quoted segment", 'Path.Combine(home, "Library", "Application Support", "FamilyShield", "status.json");', 1],
    ["the old data folder as the last path segment", 'Path.Combine(GetFolderPath(LocalApplicationData), "FamilyShield");', 1],
    ["the old data folder as a single-quoted segment", "Path.Combine(home, 'Library', 'Application Support', 'FamilyShield', 'status.json');", 1],
    ["the old data folder as a lowercase double-quoted segment", 'Path.Combine(GetFolderPath(LocalApplicationData), "familyshield", "agent.db");', 1],
    ["the old data folder as a lowercase single-quoted segment", "Path.Combine(home, 'Library', 'Application Support', 'familyshield', 'status.json');", 1],
    ["the old data folder built by double-quoted concatenation", 'const dir = "familyshield" + "/status.json";', 1],
    ["the old data folder built by single-quoted concatenation", "const dir = 'FamilyShield' + '/status.json';", 1],
    ["the old Windows data folder in a path string", "%LOCALAPPDATA%\\FamilyShield\\rootCert.pfx", 1],
    ["the old macOS data folder in a path string", "~/Library/Application Support/FamilyShield/status.json", 1],
    ["the old Windows data folder lowercase in a path string", "%LOCALAPPDATA%\\familyshield\\rootCert.pfx", 1],
    ["the old macOS data folder lowercase in a path string", "~/Library/Application Support/familyshield/status.json", 1],
    ["the old macOS data folder lowercase in an escaped path string", "~/Library/Application\\ Support/familyshield/status.json", 1],
    ["the old Windows test-certificate subject in code", 'RootCertSubject = "FamilyShield Test Root";', 1],
    ["the old Windows test-certificate subject in prose", 'self-signed "FamilyShield Test Root" into the user store', 1],
    // ── negative: the new forms and internal identifiers must pass ──
    ["the new export filename", 'Content-Disposition: attachment; filename="osra-export-123.json"', 0],
    ["the new support email", "seed the demo family demo@osratech.com", 0],
    ["the new Windows test-certificate subject", 'RootCertSubject = "OSRA Test Root";', 0],
    ["the new data folder", 'Path.Combine(GetFolderPath(LocalApplicationData), "OSRA", "status.json");', 0],
    ["an internal namespace", "namespace FamilyShield.Agent.Services;", 0],
    ["an internal using directive", "using FamilyShield.Agent.MacOS.Services;", 0],
    ["internal assembly and root-namespace names", "<AssemblyName>FamilyShield.Agent.MacOS</AssemblyName>\n<RootNamespace>FamilyShield.Agent.MacOS</RootNamespace>", 0],
    ["an internal project reference", '<ProjectReference Include="..\\..\\FamilyShield.Agent.csproj" />', 0],
    ["internal window and mutex names", 'Name = "FamilyShieldPairing";\nName = "FamilyShieldOverlay";\nName = "FamilyShieldSosHotkey";', 0],
    ["an internal Android package name", "com.familyshield.agent/.security.GuardianAdminReceiver", 0],
    ["an internal signature header", 'SignatureHeader = "X-FamilyShield-Signature";', 0],
    ["a test-only temp directory", 'Path.Combine(Path.GetTempPath(), "familyshield-tests", Guid.NewGuid().ToString("N"))', 0],
    ["the one-time migration's legacy folder constant (double quote)", 'LegacyFolderName = "FamilyShield";', 0],
    ["the one-time migration's legacy folder constant (single quote)", "LegacyFolderName = 'FamilyShield';", 0],
    ["the migration doc naming the legacy folder", 'the legacy "FamilyShield" Application Support folder moves to the "OSRA" folder', 0],
    ["the migration doc naming the legacy path", "<c>~/Library/Application Support/FamilyShield</c>", 0],
    ["an internal source folder name", "Sources/FamilyShieldAgent/DeviceActivityMonitor.swift", 0],
    ["an internal test project path", "dotnet test tests/FamilyShield.Agent.Tests", 0],
    ["the internal root package name in JSON", '"name": "familyshield",', 0],
    ["an internal identifier built with the name on the right of +", 'header = "X-" + "FamilyShield" + "-Signature";', 0],
    ["an internal identifier built with the name on the left of +", 'Name = "FamilyShield" + "Pairing";', 0],
    ["an internal Android package path", "app/src/main/java/com/familyshield/agent/App.kt", 0],
    ["an internal npm scope", "pnpm --filter @familyshield/api", 0],
    ["a regex literal, not a path", "expect(registerBody.email).not.toMatch(/familyshield/i);", 0],
    ["a repository layout tree entry, not a data folder", "familyshield/", 0],
    ["a developer checkout path, not a data folder", "C:\\KARIM\\familyshield\\dist\\App.apk", 0],
  ];
  let bad = 0;
  cases.forEach(([name, body, want], i) => {
    const file = `case-${String(i).padStart(2, "0")}.txt`;
    write(file, `${body}\n`);
    const got = scan([file], dir).length ? 1 : 0;
    if (got !== want) {
      bad += 1;
      console.error(`FAIL  ${name}: want ${want}, got ${got}`);
    }
  });
  fs.rmSync(dir, { recursive: true, force: true });

  // Dated-QA allowlist (Claude's #608 ruling): the three records below are exempt because they
  // must retain the names as tested at the time; a dated-looking sibling is still a finding.
  const datedDir = fs.mkdtempSync(pathMod.join(os.tmpdir(), "brand-dated-"));
  const dated = [
    ["docs/QA/KCL-2026-10-16/AUDIT-IOS-WINDOWS-MACOS.md", 0],
    ["docs/QA/audits/AUDIT-IOS-MACOS-2026-10-11.md", 0],
    ["docs/QA/audits/AUDIT-WINDOWS-2026-10-11.md", 0],
    ["docs/QA/audits/AUDIT-WINDOWS-2026-10-12.md", 1],
    ["docs/QA/KCL-2026-10-16/AUDIT-IOS-WINDOWS-MACOS-2.md", 1],
    ["docs/QA/audits/AUDIT-ANDROID-2026-10-11.md", 1],
  ];
  for (const [p, want] of dated) {
    const full = pathMod.join(datedDir, p);
    fs.mkdirSync(pathMod.dirname(full), { recursive: true });
    fs.writeFileSync(full, "%LOCALAPPDATA%\\FamilyShield\\agent.db\n");
    const got = scan([p], datedDir).length ? 1 : 0;
    if (got !== want) {
      bad += 1;
      console.error(`FAIL  dated-QA allowlist ${p}: want ${want}, got ${got}`);
    }
  }
  fs.rmSync(datedDir, { recursive: true, force: true });

  // Allowlist integrity: exactly these three dated records and nothing else. An extra user-facing
  // path added to the allowlist would let an offender through, so the self-test asserts the set.
  const expectedAllowed = [
    "docs/QA/KCL-2026-10-16/AUDIT-IOS-WINDOWS-MACOS.md",
    "docs/QA/audits/AUDIT-IOS-MACOS-2026-10-11.md",
    "docs/QA/audits/AUDIT-WINDOWS-2026-10-11.md",
  ];
  const allowlistOk =
    ALLOWED_PATHS.length === expectedAllowed.length &&
    expectedAllowed.every((p) => ALLOWED_PATHS.includes(p)) &&
    ALLOWED_PATHS.every((p) => expectedAllowed.includes(p));
  if (!allowlistOk) {
    bad += 1;
    console.error("FAIL  the dated-QA allowlist is not exactly the three dated records");
  }

  // The cases above test the scanner; they would still pass if the CLI never called it, or if
  // `report()` always returned 0. So run the real command the way CI does, in a throwaway repository.
  // `git ls-files` reads the index, so `git add` is enough: no commit and no git identity are needed.
  // The last case writes an offender WITHOUT staging it, proving the untracked-not-ignored scan works.
  const repo = fs.mkdtempSync(pathMod.join(os.tmpdir(), "brand-repo-"));
  const git = (...a) => execFileSync("git", a, { cwd: repo, stdio: "ignore" });
  const cli = () => {
    try {
      execFileSync(process.execPath, [fileURLToPath(import.meta.url)], { cwd: repo, stdio: "ignore" });
      return 0;
    } catch (e) {
      return e.status;
    }
  };
  git("init", "-q");
  fs.writeFileSync(pathMod.join(repo, "clean.txt"), "namespace FamilyShield.Agent.Services;\n");
  git("add", "-A");
  if (cli() !== 0) {
    bad += 1;
    console.error("FAIL  the CLI passes a clean index");
  }
  fs.writeFileSync(pathMod.join(repo, "tracked.txt"), "contact demo@familyshield.dev\n");
  git("add", "-A");
  if (cli() !== 1) {
    bad += 1;
    console.error("FAIL  the CLI exits 1 on a staged offender");
  }
  fs.unlinkSync(pathMod.join(repo, "tracked.txt"));
  git("add", "-A"); // stage the removal so the index is clean before the untracked check
  fs.writeFileSync(pathMod.join(repo, "unstaged.txt"), "%LOCALAPPDATA%\\familyshield\\rootCert.pfx\n");
  if (cli() !== 1) {
    bad += 1;
    console.error("FAIL  the CLI exits 1 on an unstaged (untracked) offender");
  }
  fs.rmSync(repo, { recursive: true, force: true });

  const total = cases.length + dated.length + 4;
  console.log(`user-visible-brand self-test: ${total - bad}/${total} cases`);
  process.exit(bad ? 1 : 0);
}

if (process.argv.includes("--selftest")) runSelfTest();
else process.exit(report(scan(repoFiles())));
