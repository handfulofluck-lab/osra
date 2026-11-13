/**
 * Issue #672: where an SOS was sent from, and whether what arrived is a location at all.
 *
 * The child agent writes five flat metadata keys — `lat`, `lng`, `accuracyM`, `takenAt`, `ageSeconds`
 * (`SosLocationPolicy` in `apps/child-android`) — because alert metadata travels as flat strings. This
 * module is the one place that turns those into a canonical location for the parent app, and the one place
 * that refuses a location nobody should pin.
 *
 * Two rules, both load-bearing:
 *
 * 1. **A valid fix survives at any JSON type.** A producer that sends `"25.2769"` is not wrong, it is
 *    unhelpful: the app would need its own parser and its own idea of a decimal separator. What is stored
 *    is always a number (and an ISO-8601 time), so the parent app reads one shape.
 * 2. **A bad fix never blocks the alert.** Dropping the location is the only response, and it drops only
 *    the five location keys — the rest of the metadata is the producer's, untouched. An SOS a parent never
 *    receives because the phone could not say where it was would be worse than the bug #672 closes.
 *
 * Why not a column: the alert already carries structured extras in `metadata` (a tamper alert's
 * `type`/`layout`, an app block's `packageId`), the API schema accepts it as `record(unknown)`, and a
 * migration would restructure a contract the issue only asked to extend.
 */

/** The five keys, in the order the parent app reads them. `apps/child-android` pins the same names. */
export const ALERT_LOCATION_KEYS = ["lat", "lng", "accuracyM", "takenAt", "ageSeconds"] as const;

export interface AlertLocation {
  lat: number;
  lng: number;
  /** Horizontal accuracy in metres, when the producer had one. */
  accuracyM?: number;
  /** When the platform took the fix, when the producer dated it. */
  takenAt?: Date;
  /** Age of the fix when the alert was sent, whole seconds. */
  ageSeconds?: number;
}

/**
 * A numeric field from an unknown JSON value: a finite number, or a **strict decimal** string.
 *
 * `Number()` is deliberately not used for strings (Fable's #672 review, note 2): it accepts `"0x10"`,
 * `"1e1"`, `"Infinity"` and `" 5 "`, so a producer's typo would arrive as a coordinate. A coordinate is
 * written as an optional sign, digits and an optional fraction — nothing else is a number here.
 */
const DECIMAL = /^-?\d{1,15}(\.\d{1,15})?$/;

function numeric(value: unknown): number | undefined {
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  if (!DECIMAL.test(text)) return undefined;
  const parsed = Number(text);
  return Number.isFinite(parsed) ? parsed : undefined;
}

/** A `takenAt` in the past (or within a minute of now): an ISO string or epoch milliseconds. */
function takenAt(value: unknown, nowMs: number): Date | undefined {
  let date: Date | undefined;
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) date = new Date(parsed);
  } else {
    const ms = numeric(value);
    // Epoch milliseconds only: a producer sending seconds lands in 1970, which is a fix we cannot age
    // confidently, and a bare "176…" is far more likely a mistake than a date.
    if (ms !== undefined && ms > 1_000_000_000_000) date = new Date(ms);
  }
  if (!date || Number.isNaN(date.getTime())) return undefined;
  // A fix from the future cannot be aged. A minute of clock skew is allowed; a year is a broken clock.
  if (date.getTime() > nowMs + 60_000) return undefined;
  return date;
}

/**
 * The location in [metadata], or `null` when it does not describe one.
 *
 * A half fix is not a fix: both coordinates must be present and inside their ranges, or the answer is
 * `null`. The optional fields are per-key — a junk accuracy does not throw away a good pair of coordinates.
 */
export function readAlertLocation(metadata: unknown, nowMs: number = Date.now()): AlertLocation | null {
  if (typeof metadata !== "object" || metadata === null) return null;
  const values = metadata as Record<string, unknown>;
  const lat = numeric(values.lat);
  const lng = numeric(values.lng);
  if (lat === undefined || lng === undefined) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;

  const location: AlertLocation = { lat, lng };
  const accuracyM = numeric(values.accuracyM);
  if (accuracyM !== undefined && accuracyM >= 0) location.accuracyM = accuracyM;
  const at = takenAt(values.takenAt, nowMs);
  if (at) location.takenAt = at;
  const ageSeconds = numeric(values.ageSeconds);
  if (ageSeconds !== undefined && ageSeconds >= 0) location.ageSeconds = Math.round(ageSeconds);
  return location;
}

/**
 * [metadata] with its location in canonical form, or with the five location keys removed when what arrived
 * is not a location. Every other key is returned exactly as the producer sent it, and metadata that carries
 * no location key at all is returned untouched — the common case, and the one that must stay free.
 */
export function sanitizeAlertMetadata(
  metadata: Record<string, unknown> | undefined,
  nowMs: number = Date.now(),
): Record<string, unknown> | undefined {
  if (!metadata) return metadata;
  const carried = ALERT_LOCATION_KEYS.some((key) => key in metadata);
  if (!carried) return metadata;

  const rest: Record<string, unknown> = { ...metadata };
  for (const key of ALERT_LOCATION_KEYS) delete rest[key];

  const location = readAlertLocation(metadata, nowMs);
  if (!location) return rest;

  const canonical: Record<string, unknown> = { ...rest, lat: location.lat, lng: location.lng };
  if (location.accuracyM !== undefined) canonical.accuracyM = location.accuracyM;
  if (location.takenAt) canonical.takenAt = location.takenAt.toISOString();
  if (location.ageSeconds !== undefined) canonical.ageSeconds = location.ageSeconds;
  return canonical;
}

/**
 * The location keys removed, every other key kept (#672 UI/UX + Fable's B1/B2).
 *
 * Three callers, one rule: the alert list and the realtime alert event for a guardian who was given
 * `alerts` but not `location` (ADR-0014 amendment, decision 3), and the nightly purge once an alert is
 * older than the location window (ADR-0028 decision 5). In all three the alert survives and only the
 * place goes — a parent must not lose the record of an SOS because of where it was sent from.
 *
 * Returns `null` when there was nothing to remove, so a caller can send the original object untouched.
 */
export function stripAlertLocation(metadata: unknown): Record<string, unknown> | null {
  if (typeof metadata !== "object" || metadata === null) return null;
  const values = metadata as Record<string, unknown>;
  if (!ALERT_LOCATION_KEYS.some((key) => key in values)) return null;
  const out: Record<string, unknown> = { ...values };
  for (const key of ALERT_LOCATION_KEYS) delete out[key];
  return out;
}

/**
 * The same rule applied to an alert **row or realtime event**: a copy whose `metadata` has no location,
 * or the value itself when it carries none.
 */
export function withoutAlertLocation<T>(alert: T): T {
  if (typeof alert !== "object" || alert === null) return alert;
  const row = alert as Record<string, unknown>;
  const stripped = stripAlertLocation(row.metadata);
  return stripped === null ? alert : ({ ...row, metadata: stripped } as T);
}
