/**
 * Issue #221 (D1): the location grant an Android agent reports in its telemetry upload, and the
 * reason a `locate_now` cannot work because of it.
 *
 * Without "allow all the time" background location the agent's `LocationService` never starts
 * (#155), so the only poll is WorkManager's 15-minute floor: a Locate issued just before a tick used
 * to expire unseen. The agent now sends what its own `LocationStartPolicy` decided (fine/coarse
 * while-in-use, background, or nothing), the server stores the latest report on the Device row, and
 * `POST /v1/devices/:id/command {"command":"locate_now"}` can answer at once.
 *
 * The two refusal reasons are the strings `LocationStartPolicy.Decision` already acks a refused
 * `locate_now` with (#132); the server and the agent must not grow two vocabularies for one
 * condition.
 */
export const LOCATION_GRANT_STATES = ["background", "while_in_use", "none"] as const;
export type LocationGrantState = (typeof LOCATION_GRANT_STATES)[number];

export type LocateNowRefusalReason = "background_location_missing" | "location_permission_missing";

/**
 * How old a grant report may be and still be trusted to refuse a command.
 *
 * The grant is normally uploaded with the 15-minute telemetry tick. Refusing on an older report
 * tells a parent to fix something the child may already have fixed: Claude measured a Flip4 episode
 * where "Allow all the time" was granted and a Locate four seconds later was still failed. One
 * telemetry period plus its flex is the longest the report can be while the agent is faithfully
 * uploading; anything older is treated as unknown and the command is queued, so the phone itself
 * answers with its own reason.
 */
export const LOCATION_GRANT_MAX_AGE_MS = 20 * 60 * 1000;

function reportedAtMs(reportedAt: Date | string | null | undefined): number | null {
  if (reportedAt == null) return null;
  const ms = reportedAt instanceof Date ? reportedAt.getTime() : Date.parse(reportedAt);
  return Number.isFinite(ms) ? ms : null;
}

/**
 * Why a `locate_now` cannot work for a device whose last report is `grant`; null means "queue it".
 *
 * `null`/`undefined` (never reported) is deliberately not a refusal: failing a command on a guess is
 * worse than queueing one, and an agent that predates this contract never sends the field.
 *
 * [reportedAt] is the freshness guard (issue #221 D1 follow-up): a grant we cannot date, or one
 * older than [LOCATION_GRANT_MAX_AGE_MS], is not evidence about the phone *now*, so the command is
 * queued and the agent answers it. A `background` report is never a refusal whatever its age.
 */
export function locateNowRefusal(
  grant: string | null | undefined,
  reportedAt?: Date | string | null,
  nowMs: number = Date.now(),
): LocateNowRefusalReason | null {
  if (grant !== "while_in_use" && grant !== "none") return null;
  const at = reportedAtMs(reportedAt);
  if (at == null) return null;
  if (nowMs - at > LOCATION_GRANT_MAX_AGE_MS) return null;
  return grant === "while_in_use" ? "background_location_missing" : "location_permission_missing";
}
