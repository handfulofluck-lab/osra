import { describe, expect, it } from "vitest";
import { readAlertLocation, sanitizeAlertMetadata, stripAlertLocation, withoutAlertLocation } from "../src/lib/alertLocation.js";

/**
 * Issue #672: an SOS alert must carry **where**. The agent writes five flat metadata keys
 * (`SosLocationPolicy` in apps/child-android); the parent app renders them as a sentence and drops the
 * alert's pin on the map. This module is the one place between them that decides whether what arrived is
 * a location at all.
 *
 * Two rules shape every row below:
 * - **a valid fix survives in canonical form** (numbers, ISO time) whatever a producer sent, so the app
 *   never has to parse a string with its own idea of "25,2769";
 * - **a bad fix never blocks the alert** — it is dropped, the rest of the metadata is kept, and the SOS is
 *   stored without a location. An SOS a parent never receives because the phone could not say where it was
 *   would be worse than the bug this closes.
 *
 * Mutants, one row each: return `metadata` untouched → [an impossible coordinate is dropped, the rest is
 * kept]; keep a partial location when the coordinates are bad → the same row; drop the whole metadata bag
 * instead of the five keys → [dropping the location keeps every other key]; accept a numeric string for
 * `lat` but store it as a string → [a location sent as strings is stored as numbers].
 */
describe("alert location (issue #672)", () => {
  const now = Date.parse("2026-11-13T19:16:00Z");

  it("reads a fix a producer sent as strings and normalises it", () => {
    const location = readAlertLocation({
      lat: "25.2769",
      lng: "51.5211",
      accuracyM: "12.0",
      takenAt: "2026-11-13T19:11:00Z",
      ageSeconds: "300",
    });
    expect(location).not.toBeNull();
    expect(location!.lat).toBe(25.2769);
    expect(location!.lng).toBe(51.5211);
    expect(location!.accuracyM).toBe(12);
    expect(location!.ageSeconds).toBe(300);
    expect(location!.takenAt?.toISOString()).toBe("2026-11-13T19:11:00.000Z");
  });

  it("answers null when there is no location at all", () => {
    expect(readAlertLocation({ deviceId: "dev-1" })).toBeNull();
    expect(readAlertLocation({})).toBeNull();
    expect(readAlertLocation(undefined)).toBeNull();
  });

  it("answers null for a coordinate that cannot exist", () => {
    expect(readAlertLocation({ lat: 91, lng: 0 })).toBeNull();
    expect(readAlertLocation({ lat: 0, lng: -181 })).toBeNull();
    expect(readAlertLocation({ lat: "north", lng: "east" })).toBeNull();
    // Half a fix is not a fix: the app must never place a pin on one axis.
    expect(readAlertLocation({ lat: 25.2769 })).toBeNull();
    expect(readAlertLocation({ lng: 51.5211 })).toBeNull();
  });

  it("a location sent as strings is stored as numbers", () => {
    const stored = sanitizeAlertMetadata({ deviceId: "dev-1", lat: "25.2769", lng: "51.5211", accuracyM: "9.5" }, now)!;
    expect(stored.lat).toBe(25.2769);
    expect(stored.lng).toBe(51.5211);
    expect(stored.accuracyM).toBe(9.5);
    expect(stored.deviceId).toBe("dev-1");
  });

  it("an impossible coordinate is dropped, the rest is kept", () => {
    const stored = sanitizeAlertMetadata({ deviceId: "dev-1", lat: 991, lng: 51.5211, accuracyM: 5, note: "sos" }, now)!;
    expect(stored).not.toHaveProperty("lat");
    expect(stored).not.toHaveProperty("lng");
    expect(stored).not.toHaveProperty("accuracyM");
    expect(stored.deviceId).toBe("dev-1");
    expect(stored.note).toBe("sos");
  });

  it("dropping the location keeps every other key", () => {
    const stored = sanitizeAlertMetadata(
      { deviceId: "dev-1", battery: 71, lat: 25.2769, lng: "not-a-number" },
      now,
    )!;
    expect(stored.deviceId).toBe("dev-1");
    expect(stored.battery).toBe(71);
    expect(Object.keys(stored).filter((k) => ["lat", "lng", "accuracyM", "takenAt", "ageSeconds"].includes(k))).toEqual([]);
  });

  it("a future or unparseable takenAt is dropped and the coordinates stay", () => {
    const stored = sanitizeAlertMetadata(
      { lat: 25.2769, lng: 51.5211, takenAt: "2030-01-01T00:00:00Z", ageSeconds: "5" },
      now,
    )!;
    expect(stored.lat).toBe(25.2769);
    expect(stored.lng).toBe(51.5211);
    expect(stored).not.toHaveProperty("takenAt");
    // The age is the phone's own figure and stands on its own: an unusable *time* does not make it a lie.
    expect(stored.ageSeconds).toBe(5);

    const unparseable = sanitizeAlertMetadata({ lat: 25.2769, lng: 51.5211, takenAt: "yesterday" }, now)!;
    expect(unparseable).not.toHaveProperty("takenAt");
  });

  it("metadata without a location is returned untouched", () => {
    const stored = sanitizeAlertMetadata({ deviceId: "dev-1", packageId: "com.android.calculator2" }, now)!;
    expect(stored).toEqual({ deviceId: "dev-1", packageId: "com.android.calculator2" });
    expect(sanitizeAlertMetadata(undefined, now)).toBeUndefined();
  });

  // Fable's #672 review, note 2: `Number()` accepts "0x10" and "1e1", so a typo becomes a coordinate.
  // A coordinate is written as an optional sign, digits and an optional fraction — nothing else.
  it("refuses a number that is not written as a decimal", () => {
    expect(readAlertLocation({ lat: "0x10", lng: 51.5 })).toBeNull();
    expect(readAlertLocation({ lat: 25.2, lng: "1e1" })).toBeNull();
    expect(readAlertLocation({ lat: "Infinity", lng: 51.5 })).toBeNull();
    expect(readAlertLocation({ lat: "", lng: 51.5 })).toBeNull();
    expect(readAlertLocation({ lat: "25.2", lng: "51.5" })!.lat).toBe(25.2);
    expect(readAlertLocation({ lat: " -25.2 ", lng: "51.5" })!.lat).toBe(-25.2);
  });

  // B1/B2 share one rule: the alert survives, the place goes, every other key stays.
  it("stripping removes the five keys and nothing else", () => {
    const stripped = stripAlertLocation({ deviceId: "dev-1", lat: 25.2, lng: 51.5, accuracyM: 9, takenAt: "2026-11-13T19:11:00Z", ageSeconds: 60, note: "sos" })!;
    expect(stripped).toEqual({ deviceId: "dev-1", note: "sos" });
    expect(stripAlertLocation({ deviceId: "dev-1" })).toBeNull();
    expect(withoutAlertLocation({ id: "a1", metadata: { deviceId: "d", lat: 1, lng: 2 } })).toEqual({ id: "a1", metadata: { deviceId: "d" } });
    const clean = { id: "a2", metadata: { deviceId: "d" } };
    expect(withoutAlertLocation(clean)).toBe(clean);
  });
});
