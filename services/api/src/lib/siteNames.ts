/**
 * #830 gating for site names (Fable B1, Claude's conditions): the server flag, the host exclusions and
 * the shorter retention window live here so one file answers "may a name reach a family".
 */

/**
 * Off unless `SITE_NAMES_ENABLED=true`. Karim's condition (16 Nov): the privacy notice (#649) names the
 * collection and Play's Data safety form declares web browsing history before any family sees a name.
 * While it is off the API stores no visit for a name that was not blocked, whatever a phone sends; the
 * agent also learns this flag and sends nothing (see `RuleSetDto.siteNames`).
 */
export function siteNamesEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return String(env.SITE_NAMES_ENABLED ?? "").trim().toLowerCase() === "true";
}

/**
 * One list, because three different owners would drift: our own API, the search-enforcement hosts the
 * DNS filter forces (they are the filter talking to itself), and the names Android and the OS resolve
 * to decide whether the phone is online. A report that showed these would say "sites your child
 * visited" about lookups the child never made.
 */
export const EXCLUDED_SITE_HOSTS: readonly string[] = [
  "osratech.com",
  "api.osratech.com",
  "staging.osratech.com",
  "forcesafesearch.google.com",
  "strict.bing.com",
  "safe.duckduckgo.com",
  "restrict.youtube.com",
  "restrictmoderate.youtube.com",
  "connectivitycheck.gstatic.com",
  "connectivitycheck.android.com",
  "clients3.google.com",
  "time.android.com",
  "time.google.com",
  "android.clients.google.com",
];

/** Exact match for every listed host, plus any subdomain of our own domain. */
export function isExcludedSiteHost(host: string): boolean {
  const h = host.trim().toLowerCase().replace(/^\*?\./, "");
  if (!h) return true;
  if (EXCLUDED_SITE_HOSTS.includes(h)) return true;
  return h === "osratech.com" || h.endsWith(".osratech.com");
}

/** The host name of a URL or bare host; empty when the value has none. */
export function hostOf(value: string): string {
  const trimmed = value.trim().replace(/^\*?\./, "");
  if (!trimmed) return "";
  try {
    const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
    return new URL(withScheme).hostname.toLowerCase();
  } catch {
    return "";
  }
}

/**
 * Site names are kept for 90 days, and never longer than the other raw rows. The privacy notice and the
 * store form name that period, so the cleanup job must not inherit a raised `RETENTION_DAYS` silently.
 */
export const SITE_VISIT_RETENTION_DAYS = 90;

export function siteVisitRetentionDays(rawRetentionDays: number): number {
  return Math.min(SITE_VISIT_RETENTION_DAYS, Math.max(1, Math.trunc(rawRetentionDays)));
}
