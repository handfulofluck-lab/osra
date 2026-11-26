import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
// @ts-expect-error the QA probe helper is plain JavaScript outside the TypeScript build.
import { EXPECTED_INSTALLED_APP_KEYS, checkG25InstalledApps, describeInstalledAppKeys, isValidInstalledAppIconUrl } from "../scripts/qa-probe-g25.mjs";

const PROBE_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "../scripts/qa-probe.mjs");

const PNG_DATA_URI = `data:image/png;base64,${Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]).toString("base64")}`;
const WEBP_DATA_URI = `data:image/webp;base64,${Buffer.concat([Buffer.from("RIFF"), Buffer.from([0x20, 0, 0, 0]), Buffer.from("WEBPVP8 ")]).toString("base64")}`;

function validAppsRead(overrides: { status?: number; data?: Record<string, unknown>; apps?: Array<Record<string, unknown>> } = {}) {
  const apps = overrides.apps ?? [
    {
      packageId: "com.example.game",
      label: "Game",
      isSystem: false,
      essential: false,
      iconUrl: null,
    },
    {
      packageId: "com.android.settings",
      label: "Settings",
      isSystem: true,
      essential: true,
      iconUrl: null,
    },
  ];
  return {
    status: overrides.status ?? 200,
    data: {
      deviceId: "dev-1",
      version: 1,
      reportedAt: "2026-11-25T00:00:00.000Z",
      count: apps.length,
      apps,
      ...(overrides.data ?? {}),
    },
  };
}

/**
 * Issue #1102: `GET /v1/devices/:id/apps` added `iconUrl` (`null` or PNG/WebP data URI from `appIconDataUri`
 * in `src/routes/devices.ts`). G25 must accept `iconUrl` while keeping every existing `essential`, `isSystem`,
 * `label` and `packageId` check intact and still failing on any unexpected extra key.
 *
 * Mutants for AGENTS.md §3:
 * 1. Replace `Object.keys(a).sort().join(",") === EXPECTED_INSTALLED_APP_KEYS` with a subset check that ignores
 *    extra keys -> the "rejects any unexpected extra key" row fails.
 * 2. Replace `isValidInstalledAppIconUrl(a.iconUrl)` with `true` or `a.iconUrl === null || Boolean(a.iconUrl)` ->
 *    the "rejects invalid iconUrl values" row fails on numbers, objects, SVG data URIs and `javascript:` URLs.
 * 3. Drop any of the `essential` / `isSystem` / `packageId` value checks -> the preserved-invariants row fails.
 */
describe("qa-probe G25 installed-app inventory contract (#1102)", () => {
  it("wires qa-probe.mjs G25 directly to checkG25InstalledApps (no drifted copy)", () => {
    const src = readFileSync(PROBE_PATH, "utf8");
    expect(src).toContain('import { checkG25InstalledApps, describeInstalledAppKeys } from "./qa-probe-g25.mjs";');
    expect(src).toContain(
      'check("G25 installed apps: the parent reads version 1 with package+label+system+essential", checkG25InstalledApps(appsRead),',
    );
  });

  it("accepts the 5-key shape with iconUrl as null, PNG/WebP data URI, or valid http(s) URL", () => {
    expect(EXPECTED_INSTALLED_APP_KEYS).toBe("essential,iconUrl,isSystem,label,packageId");
    expect(checkG25InstalledApps(validAppsRead())).toBe(true);

    expect(
      checkG25InstalledApps(
        validAppsRead({
          apps: [
            {
              packageId: "com.example.game",
              label: "Game",
              isSystem: false,
              essential: false,
              iconUrl: PNG_DATA_URI,
            },
            {
              packageId: "com.android.settings",
              label: "Settings",
              isSystem: true,
              essential: true,
              iconUrl: WEBP_DATA_URI,
            },
          ],
        }),
      ),
    ).toBe(true);

    expect(
      checkG25InstalledApps(
        validAppsRead({
          apps: [
            {
              packageId: "com.example.game",
              label: "Game",
              isSystem: false,
              essential: false,
              iconUrl: "https://cdn.osratech.com/icons/com.example.game.webp",
            },
            {
              packageId: "com.android.settings",
              label: "Settings",
              isSystem: true,
              essential: true,
              iconUrl: "http://127.0.0.1:3000/icons/settings.png",
            },
          ],
        }),
      ),
    ).toBe(true);
  });

  it("rejects any unexpected extra key or missing key on any row in the inventory", () => {
    for (const extraKey of ["secret", "token", "icon", "deviceId", "internalSecret"]) {
      // Leaked on the first row
      const firstRowLeak = validAppsRead();
      firstRowLeak.data.apps[0] = { ...firstRowLeak.data.apps[0], [extraKey]: "leaked" };
      expect(checkG25InstalledApps(firstRowLeak)).toBe(false);

      // Leaked only on the second row (the old `Object.keys(appInventory[0])` check was blind to index 1)
      const secondRowLeak = validAppsRead();
      secondRowLeak.data.apps[1] = { ...secondRowLeak.data.apps[1], [extraKey]: "leaked" };
      expect(checkG25InstalledApps(secondRowLeak)).toBe(false);
      expect(describeInstalledAppKeys(secondRowLeak.data.apps)).toContain(extraKey);
    }

    for (const requiredKey of ["essential", "iconUrl", "isSystem", "label", "packageId"]) {
      const missing = validAppsRead();
      const copy = { ...missing.data.apps[0] };
      delete copy[requiredKey];
      missing.data.apps[0] = copy;
      expect(checkG25InstalledApps(missing)).toBe(false);
    }
  });

  it("rejects invalid iconUrl values (numbers, objects, empty strings, SVG/script URIs, malformed base64)", () => {
    const invalidValues: unknown[] = [
      undefined,
      42,
      0,
      true,
      false,
      {},
      { url: "https://cdn.osratech.com/icon.png" },
      ["https://cdn.osratech.com/icon.png"],
      "",
      "   ",
      "not-a-url",
      "/relative/icon.png",
      "javascript:alert(1)",
      "file:///etc/passwd",
      "https://",
      "https://cdn.osratech.com/icon with spaces.png",
      `data:image/svg+xml;base64,${Buffer.from("<svg onload=x>").toString("base64")}`,
      `data:text/html;base64,${Buffer.from("<script>1</script>").toString("base64")}`,
      "data:image/png;base64,",
      "data:image/png;base64,abc",
    ];

    for (const bad of invalidValues) {
      expect(isValidInstalledAppIconUrl(bad)).toBe(false);
      const sample = validAppsRead();
      sample.data.apps[1] = { ...sample.data.apps[1], iconUrl: bad };
      expect(checkG25InstalledApps(sample)).toBe(false);
    }
  });

  it("keeps all existing status, version, count, essential, isSystem, label and packageId checks enforced", () => {
    expect(checkG25InstalledApps(validAppsRead({ status: 500 }))).toBe(false);
    expect(checkG25InstalledApps(validAppsRead({ data: { version: 2 } }))).toBe(false);
    expect(checkG25InstalledApps(validAppsRead({ data: { count: 3 } }))).toBe(false);
    expect(checkG25InstalledApps(validAppsRead({ apps: [validAppsRead().data.apps[0]] }))).toBe(false);

    const wrongSystem = validAppsRead();
    wrongSystem.data.apps[1] = { ...wrongSystem.data.apps[1], isSystem: false };
    expect(checkG25InstalledApps(wrongSystem)).toBe(false);

    const wrongSettingsEssential = validAppsRead();
    wrongSettingsEssential.data.apps[1] = { ...wrongSettingsEssential.data.apps[1], essential: false };
    expect(checkG25InstalledApps(wrongSettingsEssential)).toBe(false);

    const wrongGameEssential = validAppsRead();
    wrongGameEssential.data.apps[0] = { ...wrongGameEssential.data.apps[0], essential: true };
    expect(checkG25InstalledApps(wrongGameEssential)).toBe(false);

    const emptyLabel = validAppsRead();
    emptyLabel.data.apps[0] = { ...emptyLabel.data.apps[0], label: "" };
    expect(checkG25InstalledApps(emptyLabel)).toBe(false);

    const emptyPackage = validAppsRead();
    emptyPackage.data.apps[0] = { ...emptyPackage.data.apps[0], packageId: "" };
    expect(checkG25InstalledApps(emptyPackage)).toBe(false);
  });
});
