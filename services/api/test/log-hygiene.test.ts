import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

/**
 * Release security gate #637, "no logging of ids or content".
 *
 * The API log is kept for months and is read by people and tools that never see the database, so it may hold
 * what an operator needs (a route, a status, an opaque row id, an error) and nothing a family typed or owns:
 * no address, no message or search text, no page title, no link or token, no place, no name.
 *
 * This reads every log call in `src/` and fails when one mentions a field of that kind. It looks at the code
 * of the call, with fixed strings removed, so a sentence such as "password reset email failed" is not a hit
 * and `{ email: parent.email }` is.
 *
 * What it cannot see: the contents of an `err` object, and a value renamed before it is logged. Those stay a
 * reviewer's job; this catches the direct case, which is the one that has happened (`lib/email/index.ts`
 * wrote the recipient's address in production until this test was written).
 */
const SRC = fileURLToPath(new URL("../src", import.meta.url));

const LOG_CALL = /\b(?:(?:req|request|app|fastify)\.log|console)\.(?:trace|debug|info|log|warn|error|fatal)\(/g;
const PERSONAL =
  /\b(email|to|subject|text|body|query|snippet|title|link|cancelLink|token|ticket|password|secret|code|lat|lng|latitude|longitude|displayName|childName|phone|url|message\.\w+)\b/;

/**
 * Calls that may name such a field because they cannot run in production. Each entry says which guard keeps
 * it out, and the test checks that guard is still within the lines just above the call.
 */
const DEVELOPMENT_ONLY: { file: string; call: string; guard: RegExp }[] = [
  // The developer's inbox: the whole mail on the console, when no provider is set and this is not production.
  { file: "lib/email/index.ts", call: "console.log(`[email:dev]", guard: /if \(this\.production\) \{[\s\S]*\} else \{\s*const to[^\n]*\s*$/ },
  // ADR-0031's e-mail hook while its templates are deferred: links on the log, outside production only.
  { file: "routes/auth.ts", call: 'req.log.info({ email: parent.email', guard: /if \(process\.env\.NODE_ENV !== "production"\) \{\s*$/ },
];

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? sourceFiles(path) : path.endsWith(".ts") ? [path] : [];
  });
}

/** The call's code with fixed text removed: plain strings emptied, template literals reduced to their `${…}` parts. */
function codeOf(call: string): string {
  return call
    .replace(/"(?:[^"\\]|\\.)*"/g, '""')
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/`(?:[^`\\$]|\\.|\$(?!\{)|\$\{[^}]*\})*`/g, (template) =>
      [...template.matchAll(/\$\{([^}]*)\}/g)].map((part) => part[1]).join(" , "),
    );
}

type LogCall = { file: string; line: number; call: string; before: string };

export function logCalls(text: string, file: string): LogCall[] {
  const found: LogCall[] = [];
  for (const match of text.matchAll(LOG_CALL)) {
    let end = match.index! + match[0].length;
    for (let depth = 1; end < text.length && depth > 0; end += 1) {
      if (text[end] === "(") depth += 1;
      else if (text[end] === ")") depth -= 1;
    }
    found.push({
      file,
      line: text.slice(0, match.index).split("\n").length,
      call: text.slice(match.index, end),
      before: text.slice(Math.max(0, match.index! - 900), match.index),
    });
  }
  return found;
}

const personalField = (call: string): string | null => codeOf(call).match(PERSONAL)?.[0] ?? null;

describe("no log call names a field a family typed or owns (gate #637)", () => {
  const all = sourceFiles(SRC).flatMap((path) => logCalls(readFileSync(path, "utf8"), relative(SRC, path).replace(/\\/g, "/")));

  it("finds the log calls at all (a scan that matches nothing would pass everything)", () => {
    expect(all.length).toBeGreaterThan(60);
    expect(all.some((c) => c.call.startsWith("req.log."))).toBe(true);
    expect(all.some((c) => c.call.startsWith("console."))).toBe(true);
  });

  it("every call is free of such a field, or is on the development-only list", () => {
    const offenders = all
      .map((c) => ({ ...c, field: personalField(c.call) }))
      .filter((c) => c.field !== null)
      .filter((c) => !DEVELOPMENT_ONLY.some((d) => d.file === c.file && c.call.startsWith(d.call)))
      .map((c) => `${c.file}:${c.line} logs "${c.field}"`);
    expect(offenders).toEqual([]);
  });

  it("each development-only call still exists, still names such a field, and still sits under its guard", () => {
    for (const entry of DEVELOPMENT_ONLY) {
      const matches = all.filter((c) => c.file === entry.file && c.call.startsWith(entry.call));
      // A stale entry is a hole: a later call with the same opening would inherit the exemption.
      expect(matches, `${entry.file}: ${entry.call}`).toHaveLength(1);
      expect(personalField(matches[0].call), entry.file).not.toBeNull();
      expect(matches[0].before, `${entry.file}:${matches[0].line} lost its production guard`).toMatch(entry.guard);
    }
  });
});

describe("the scan itself: what it must catch and what it must leave alone", () => {
  const field = (code: string) => {
    const calls = logCalls(code, "fixture.ts");
    expect(calls).toHaveLength(1);
    return personalField(calls[0].call);
  };

  // Mutants: delete a word from PERSONAL and its row stops failing.
  it.each([
    ['req.log.info({ email: parent.email }, "sent")', "email"],
    ["console.warn(`would send to ${to}`)", "to"],
    ['req.log.warn({ query }, "search flagged")', "query"],
    ['app.log.info({ deviceId, lat: ping.lat }, "ping")', "lat"],
    ['req.log.error({ link }, "mail failed")', "link"],
    ["console.log(`[x] ${message.text}`)", "message.text"],
    ['req.log.info({ childName: child.displayName }, "paired")', "childName"],
    ['request.log.debug({ token }, "ticket issued")', "token"],
    ['req.log.info(\n  { title: page.title },\n  "page",\n)', "title"],
  ])("catches %s", (code, expected) => {
    expect(field(code)).toBe(expected);
  });

  // Mutant: stop stripping fixed strings and every one of these becomes a false alarm.
  it.each([
    'req.log.error({ err }, "password reset email failed")',
    'req.log.warn({ deviceId: id }, "capabilities report refused; the rest of the telemetry was stored")',
    "console.warn(`[push] delivery failed platform=${t.platform} reason=${result.reason}`)",
    'console.error("[security] reset-token store unreachable", err)',
    'req.log.warn({ metric: "pair_claim_failed" }, "pairing claim with an unknown or expired code")',
    "console.log(`[digest] scheduler started (tick=${TICK_MS / 60000}m), sends email to parents`)",
  ])("leaves %s alone", (code) => {
    expect(field(code)).toBeNull();
  });
});
