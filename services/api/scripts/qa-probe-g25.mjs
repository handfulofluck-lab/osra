/**
 * Pure contract helpers for `qa-probe.mjs` check G25 (`GET /v1/devices/:id/apps`, issue #1102).
 *
 * Extracted so `test/qa-probe-g25.test.ts` exercises the exact predicate `qa-probe.mjs` calls.
 */

/**
 * Exact sorted key set allowed on every item returned by `GET /v1/devices/:id/apps` (`routes/devices.ts`).
 * Any missing field or unexpected extra field (e.g. raw `icon`, `deviceId`, `secret`, `token`) fails G25.
 */
export const EXPECTED_INSTALLED_APP_KEYS = "essential,iconUrl,isSystem,label,packageId";

const DATA_ICON_URI = /^data:image\/(?:png|webp);base64,([A-Za-z0-9+/]+={0,2})$/;

/**
 * True when `iconUrl` satisfies the parent-facing installed-app icon contract:
 * - `null` when no launcher icon is stored (`routes/devices.ts` maps absent `icon` to `null`),
 * - a `data:image/png;base64,...` or `data:image/webp;base64,...` URI (`appIconDataUri` in `routes/devices.ts`), or
 * - a non-empty `https://` or `http://` URL string with a host and no whitespace.
 */
export function isValidInstalledAppIconUrl(iconUrl) {
  if (iconUrl === null) return true;
  if (typeof iconUrl !== "string" || iconUrl.length === 0 || /\s/.test(iconUrl)) return false;
  const dataMatch = DATA_ICON_URI.exec(iconUrl);
  if (dataMatch) {
    return dataMatch[1].length > 0 && dataMatch[1].length % 4 === 0;
  }
  try {
    const parsed = new URL(iconUrl);
    return (parsed.protocol === "https:" || parsed.protocol === "http:") && parsed.hostname.length > 0;
  } catch {
    return false;
  }
}

/** Diagnostic summary of sorted keys observed across `apps` rows. */
export function describeInstalledAppKeys(appInventory) {
  if (!Array.isArray(appInventory) || appInventory.length === 0) return "";
  return [
    ...new Set(
      appInventory.map((app) =>
        app !== null && typeof app === "object" && !Array.isArray(app)
          ? Object.keys(app).sort().join(",")
          : String(app),
      ),
    ),
  ].join(" | ");
}

/**
 * Full G25 predicate over `GET /v1/devices/:id/apps` after G24's 2-app upload:
 * preserves every existing `essential` / `isSystem` / `label` / `packageId` check on the response,
 * asserts `iconUrl` on every row, and rejects any unexpected or missing key on any row.
 */
export function checkG25InstalledApps(appsRead) {
  const appInventory = appsRead?.data?.apps;
  if (!Array.isArray(appInventory)) return false;
  const everyRowMatchesContract = appInventory.every(
    (a) =>
      a !== null &&
      typeof a === "object" &&
      !Array.isArray(a) &&
      Object.keys(a).sort().join(",") === EXPECTED_INSTALLED_APP_KEYS &&
      typeof a.packageId === "string" &&
      a.packageId.length > 0 &&
      typeof a.label === "string" &&
      a.label.length > 0 &&
      typeof a.isSystem === "boolean" &&
      (a.essential === null || typeof a.essential === "boolean") &&
      isValidInstalledAppIconUrl(a.iconUrl),
  );
  return (
    appsRead?.status === 200 &&
    appsRead.data?.version === 1 &&
    appsRead.data?.count === 2 &&
    appInventory.length === 2 &&
    everyRowMatchesContract &&
    appInventory.some((a) => a.packageId === "com.android.settings" && a.isSystem === true) &&
    appInventory.some((a) => a.packageId === "com.android.settings" && a.essential === true) &&
    appInventory.some((a) => a.packageId === "com.example.game" && a.essential === false)
  );
}
