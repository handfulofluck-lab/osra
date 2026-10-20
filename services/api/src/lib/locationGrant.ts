/**
 * Issue #221 (D1): the location grant an Android agent reports in its 15-minute telemetry upload,
 * and the reason a `locate_now` cannot work because of it.
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
 * Why a `locate_now` cannot work for a device whose last report is `grant`; null means "queue it".
 *
 * `null`/`undefined` (never reported) is deliberately not a refusal: failing a command on a guess is
 * worse than queueing one, and an agent that predates this contract never sends the field.
 */
export function locateNowRefusal(grant: string | null | undefined): LocateNowRefusalReason | null {
  if (grant === "while_in_use") return "background_location_missing";
  if (grant === "none") return "location_permission_missing";
  return null;
}
