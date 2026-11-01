/**
 * ADR-0034 decision 4 + 5, with amendment A3: every client names its build in a header, and the server
 * can tell it to update.
 *
 * **The header is a hint, not a control.** Any client can send any value, so a forged header can get an old
 * parent app past the 426 gate. That is acceptable only because the gate is an upgrade prompt: a forged
 * header gets a client nothing its token did not already allow. For the same reason `min` must never be
 * used to retire an insecure request shape or route — that is done by removing the shape on the server.
 *
 * Pure on purpose: the parser, the policy and the verdict are the three things a row can pin, and the
 * Fastify hook that uses them is a thin adapter.
 */

/** A3's hard cap, before any parsing. */
export const CLIENT_HEADER_MAX_LENGTH = 64;

/** A3's pattern, verbatim. `build` is the integer that orders releases. */
const CLIENT_HEADER_PATTERN =
  /^(parent-app|child-android|child-ios|agent-desktop|agent-macos)\/\d{1,4}\.\d{1,4}\.\d{1,4}\+\d{1,9} \([a-z0-9-]{1,16}\)$/;

export interface ClientIdentity {
  app: string;
  version: string;
  build: number;
  flavour: string;
}

/**
 * Parse `X-OSRA-Client`, or return null for **legacy**.
 *
 * Everything that is not exactly the pattern is legacy — too long, malformed, absent, or an app the server
 * does not know. Legacy requests are served exactly as today, which is what keeps every client released
 * before this change working (decision 4, claim 7).
 */
export function parseClientHeader(raw: string | string[] | undefined | null): ClientIdentity | null {
  // A repeated header arrives as an array; a client that sends two is not naming one build.
  if (typeof raw !== "string") return null;
  if (raw.length === 0 || raw.length > CLIENT_HEADER_MAX_LENGTH) return null;
  if (!CLIENT_HEADER_PATTERN.test(raw)) return null;
  const match = /^([a-z-]+)\/(\d{1,4}\.\d{1,4}\.\d{1,4})\+(\d{1,9}) \(([a-z0-9-]{1,16})\)$/.exec(raw);
  if (!match) return null;
  return { app: match[1], version: match[2], build: Number(match[3]), flavour: match[4] };
}

/**
 * The update verdict for one request: `none`, `recommended` or `required`.
 *
 * `CLIENT_POLICY` is one JSON value per environment, and it **ships empty** — an empty or absent policy
 * means no gate, which is how this change goes out. The first `min` is a later, separate change.
 */
export type UpdateVerdict = "none" | "recommended" | "required";

export interface ClientPolicyEntry {
  min?: number;
  recommended?: number;
}
export type ClientPolicy = Partial<Record<string, ClientPolicyEntry>>;

/** Parse `CLIENT_POLICY`. Anything unreadable is "no policy": a broken env var must not lock parents out. */
export function parseClientPolicy(raw: string | undefined | null): ClientPolicy {
  if (!raw || raw.trim() === "") return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (parsed == null || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    const out: ClientPolicy = {};
    for (const [app, entry] of Object.entries(parsed as Record<string, unknown>)) {
      if (entry == null || typeof entry !== "object") continue;
      const { min, recommended } = entry as { min?: unknown; recommended?: unknown };
      const clean: ClientPolicyEntry = {};
      if (typeof min === "number" && Number.isFinite(min)) clean.min = min;
      if (typeof recommended === "number" && Number.isFinite(recommended)) clean.recommended = recommended;
      out[app] = clean;
    }
    return out;
  } catch {
    return {};
  }
}

/** The verdict for one parsed client, given the policy. Legacy (null client) is always `none`. */
export function updateVerdict(client: ClientIdentity | null, policy: ClientPolicy): UpdateVerdict {
  if (!client) return "none";
  const entry = policy[client.app];
  if (!entry) return "none";
  if (entry.min != null && client.build < entry.min) return "required";
  if (entry.recommended != null && client.build < entry.recommended) return "recommended";
  return "none";
}

/**
 * A5: the gate never blocks a data right.
 *
 * A parent on an old app must always be able to withdraw consent and delete a child's data — withdrawal has
 * to stay as easy as consent was (ADR-0008), so a gate that blocked it until an app update would be a
 * compliance failure rather than a UX choice.
 */
const ALWAYS_ALLOWED: Array<{ method: string; pattern: RegExp }> = [
  { method: "GET", pattern: /^\/health$/ },
  { method: "POST", pattern: /^\/v1\/auth\/logout$/ },
  { method: "POST", pattern: /^\/v1\/auth\/logout-all$/ },
  { method: "POST", pattern: /^\/v1\/family\/children\/[^/]+\/consent\/revoke$/ },
  { method: "DELETE", pattern: /^\/v1\/family\/children\/[^/]+$/ },
  // A5 as amended on #528: sign-out starts by removing this phone's push token (#356), and a parent who
  // cannot update (an app that no longer supports their phone) must still be able to take the family's
  // data out and delete their account or the whole family. A prefixed `/` route also answers with a
  // trailing slash, so those two allow one.
  { method: "DELETE", pattern: /^\/v1\/me\/push-token$/ },
  { method: "GET", pattern: /^\/v1\/family\/export$/ },
  { method: "DELETE", pattern: /^\/v1\/me\/?$/ },
  { method: "DELETE", pattern: /^\/v1\/family\/?$/ },
];

/** True when [method] [url] is outside the 426 gate. The query string is not part of the decision. */
export function isGateExempt(method: string, url: string): boolean {
  const path = url.split("?")[0] ?? url;
  return ALWAYS_ALLOWED.some((entry) => entry.method === method.toUpperCase() && entry.pattern.test(path));
}

/**
 * The 426 decision.
 *
 * **Only the parent app is ever refused.** A refused child agent is an unmonitored phone, and refusing an
 * out-of-date agent would trade a mismatch that can be seen for a phone nobody monitors — so the agent's
 * pressure to update goes to the parent, who can act on it (decision 5, claim 6).
 */
export function shouldRefuseWith426(client: ClientIdentity | null, verdict: UpdateVerdict): boolean {
  return client?.app === "parent-app" && verdict === "required";
}
