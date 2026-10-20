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

export type GeofenceTransition =
  | { kind: "baseline"; gapMinutes: null }
  | { kind: "none"; gapMinutes: null }
  | { kind: "entered" | "exited"; gapMinutes: number | null };

/**
 * Decide a geofence enter/exit from the previous ping and this upload (issue #243, Claude's rule).
 *
 * - No previous ping for the device (first ping ever, or retention deleted them all): the ping is
 *   a **baseline**. There is no `before` to compare against, so nothing happened — you cannot
 *   arrive somewhere we never knew you were. No alert, no routine nudge.
 * - A previous ping at any age is compared as before: a real last position, however old, still
 *   gives a true arrived/left. Suppressing the alert on age would drop the ordinary case where a
 *   phone is off at home overnight and on at school in the morning.
 * - If the gap between the previous ping and the **earliest ping in this upload** is over
 *   `GEOFENCE_STALE_GAP_MINUTES`, the transition says so via `gapMinutes`; the caller puts it in
 *   the alert. Measured from the earliest ping because a batch of offline-buffered pings covers
 *   the gap and must not claim one that did not happen. A previous ping with no usable timestamp
 *   gives `gapMinutes: null` — unknown age, so no claim either way.
 *
 * The returned `kind` is the transition only; the caller applies `notifyOnEnter`/`notifyOnExit`.
 */
export function geofenceTransition(
  previous: { lat: number; lng: number; timestamp?: Date | string | null } | null | undefined,
  earliestNewTs: Date | string | null | undefined,
  current: { lat: number; lng: number },
  fence: { lat: number; lng: number; radiusM: number },
): GeofenceTransition {
  if (!previous) return { kind: "baseline", gapMinutes: null };
  const insideNow = isInsideFence(current.lat, current.lng, fence);
  const insideBefore = isInsideFence(previous.lat, previous.lng, fence);
  if (insideNow === insideBefore) return { kind: "none", gapMinutes: null };
  return {
    kind: insideNow ? "entered" : "exited",
    gapMinutes: staleGapMinutes(previous.timestamp, earliestNewTs),
  };
}

/** Gap in whole minutes when it exceeds the stale threshold, otherwise null. */
function staleGapMinutes(
  previousTs: Date | string | null | undefined,
  earliestNewTs: Date | string | null | undefined,
): number | null {
  if (!previousTs || !earliestNewTs) return null;
  const from = new Date(previousTs).getTime();
  const to = new Date(earliestNewTs).getTime();
  if (!Number.isFinite(from) || !Number.isFinite(to)) return null;
  const gap = Math.floor((to - from) / 60000);
  return gap > GEOFENCE_STALE_GAP_MINUTES ? gap : null;
}
