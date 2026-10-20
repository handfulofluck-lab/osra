const EARTH_RADIUS_M = 6371000;

/** Great-circle distance in meters between two lat/lng coordinates (haversine formula). */
export function haversineMeters(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(a));
}

/** Return true when a coordinate lies within a circular geofence. */
export function isInsideFence(
  lat: number,
  lng: number,
  fence: { lat: number; lng: number; radiusM: number },
): boolean {
  return haversineMeters(lat, lng, fence.lat, fence.lng) <= fence.radiusM;
}

/**
 * Quiet period, in minutes, beyond which an enter/exit comparison is described as stale
 * (issue #243). Six hours: longer than a normal evening of the phone being off, so the ordinary
 * overnight case stays silent about the gap; a comparison across it still raises the alert, it
 * just says how old the "before" position was.
 */
const GEOFENCE_STALE_GAP_MINUTES = 360;

/** A ping as far as the transition rule is concerned: where it was, and when it was taken. */
export type GeofencePoint = { lat: number; lng: number; timestamp?: Date | string | null };

/**
 * A ping with the millisecond value the pair was ordered by (issue #247).
 *
 * `pickTransitionPair` already resolves a missing `timestamp` to the request's receive time in order
 * to sort, and then threw that value away — so a timestamp-less ping was ordered as "now" but had no
 * `timestamp` for the gap, and a real 14-hour silence went unmentioned. Carrying `ms` makes the gap
 * use the same clock as the ordering, so the note cannot disagree with the comparison.
 */
export type TransitionPoint = GeofencePoint & { ms: number };

export type GeofenceTransition =
  | { kind: "none"; gapMinutes: null }
  | { kind: "entered" | "exited"; gapMinutes: number | null };

/**
 * What to judge, or why there is nothing to judge:
 * - `{ before, now }` — compare these two.
 * - `{ baseline: true }` — the first ping we have ever stored, so there is nothing to arrive from.
 * - `null` — the upload is not newer than what is already stored: nothing new happened.
 */
export type TransitionPair =
  | { before: TransitionPoint; now: TransitionPoint }
  | { baseline: true }
  | null;

/** A ping's time in ms; a ping without one counts as received at `fallback`. */
function timestampMs(point: GeofencePoint, fallback: number): number {
  if (point.timestamp === null || point.timestamp === undefined) return fallback;
  const ms = new Date(point.timestamp).getTime();
  return Number.isFinite(ms) ? ms : fallback;
}

/**
 * Choose the two pings a geofence transition is judged between (issue #243 review, F1 + F2).
 *
 * An upload is not in time order: the Android agent sends fresh in-memory pings first and the older
 * Room-buffered ones after (`LocationService.kt:262`). So the upload is sorted by `timestamp` — a
 * ping without one counts as received now — and the stored previous ping is merged in. The **newest**
 * entry is "now"; the entry **just before it** is "before". A batch of buffered pings therefore gives
 * a short gap by itself, and a hole inside a batch is named by the age of the ping either side of it.
 *
 * - Upload not newer than the stored previous (`latest.ts <= previous.ts`): `null`, nothing to
 *   evaluate — a re-sent or delayed batch must not raise an old alert as if it were fresh.
 * - No previous ping and a single-ping upload: `{ baseline: true }`. You cannot arrive somewhere we
 *   never knew you were, so there is no alert and no routine nudge.
 * - No previous ping but two or more upload pings: "before" is the second-newest upload ping — a real
 *   transition, not a baseline.
 * - A previous ping with no usable timestamp is treated as older than the upload (there is nothing to
 *   order it by) and gives no `gapMinutes`, so the age is not claimed either way.
 */
export function pickTransitionPair(
  previous: GeofencePoint | null | undefined,
  upload: GeofencePoint[],
  receivedAt: Date | number = Date.now(),
): TransitionPair {
  const receivedMs = typeof receivedAt === "number" ? receivedAt : receivedAt.getTime();
  const entries = upload.map((point, index) => ({ point, ms: timestampMs(point, receivedMs), index }));
  if (previous) entries.unshift({ point: previous, ms: timestampMs(previous, Number.NEGATIVE_INFINITY), index: -1 });
  // Ascending by time; the array position breaks ties, so the same upload always picks the same pair.
  entries.sort((a, b) => a.ms - b.ms || a.index - b.index);
  if (entries.length === 0) return null;

  const newest = entries[entries.length - 1];
  if (previous && newest.ms <= timestampMs(previous, Number.NEGATIVE_INFINITY)) return null;
  if (entries.length === 1) return { baseline: true };
  const before = entries[entries.length - 2];
  return { before: { ...before.point, ms: before.ms }, now: { ...newest.point, ms: newest.ms } };
}

/**
 * Decide a geofence enter/exit between two pings chosen by `pickTransitionPair` (issue #243).
 *
 * A previous position at any age is compared normally: suppressing the alert on age would drop the
 * ordinary case where a phone is off at home overnight and on at school in the morning. Only when
 * the gap between them is over `GEOFENCE_STALE_GAP_MINUTES` does the transition say so via
 * `gapMinutes`, and the caller puts it in the alert. A `before` with no usable timestamp gives
 * `gapMinutes: null` — unknown age, so no claim either way.
 *
 * The returned `kind` is the transition only; the caller applies `notifyOnEnter`/`notifyOnExit`.
 */
export function geofenceTransition(
  before: GeofencePoint,
  now: GeofencePoint,
  fence: { lat: number; lng: number; radiusM: number },
): GeofenceTransition {
  const insideNow = isInsideFence(now.lat, now.lng, fence);
  const insideBefore = isInsideFence(before.lat, before.lng, fence);
  if (insideNow === insideBefore) return { kind: "none", gapMinutes: null };
  return {
    kind: insideNow ? "entered" : "exited",
    gapMinutes: pairGapMinutes(before, now),
  };
}

/**
 * Gap in whole minutes for a pair, or null when the age of "before" is unknown.
 *
 * Prefers the `ms` the pair was ordered by (issue #247): a ping without a `timestamp` still has a
 * real receive time, and the note must agree with the ordering rather than fall silent. Plain
 * `GeofencePoint` callers keep the timestamp-only behaviour. A `before` with no usable time at all
 * (ordered as `-Infinity`) gives null — the age is not claimed either way.
 */
function pairGapMinutes(before: TransitionPoint | GeofencePoint, now: TransitionPoint | GeofencePoint): number | null {
  const beforeMs = typeof (before as TransitionPoint).ms === "number" ? (before as TransitionPoint).ms : null;
  const nowMs = typeof (now as TransitionPoint).ms === "number" ? (now as TransitionPoint).ms : null;
  if (beforeMs !== null && nowMs !== null) {
    if (!Number.isFinite(beforeMs) || !Number.isFinite(nowMs)) return null;
    const minutes = Math.floor((nowMs - beforeMs) / 60000);
    return minutes > GEOFENCE_STALE_GAP_MINUTES ? minutes : null;
  }
  return staleGapMinutes(before.timestamp, now.timestamp);
}

/** Gap in whole minutes when it exceeds the stale threshold, otherwise null. */
function staleGapMinutes(
  beforeTs: Date | string | null | undefined,
  nowTs: Date | string | null | undefined,
): number | null {
  if (!beforeTs || !nowTs) return null;
  const from = new Date(beforeTs).getTime();
  const to = new Date(nowTs).getTime();
  if (!Number.isFinite(from) || !Number.isFinite(to)) return null;
  const gap = Math.floor((to - from) / 60000);
  return gap > GEOFENCE_STALE_GAP_MINUTES ? gap : null;
}
