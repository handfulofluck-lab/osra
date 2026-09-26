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
