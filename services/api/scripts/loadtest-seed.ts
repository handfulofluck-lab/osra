/**
 * Synthetic families for the load-test stack (load-test plan, 27 Nov 2026; loadtest/README.md).
 *
 * Writes N fake families straight into Postgres in batches: parents, two children each, 2 or 3 devices,
 * consent, rules, two geofences and an optional day of location history. Sign-up through the API would hit
 * the 20-a-minute auth bucket, and this is not what the test measures.
 *
 * Every id is derived from the family number (loadtest/k6/lib/ids.js has the same rule), so the k6 scripts
 * can address any family and mint its tokens without a file of credentials. Nothing here is real: names are
 * "LT Family 000042", e-mails end in `.invalid`, push tokens are absent, coordinates are random.
 *
 * Refuses unless OSRA_DEPLOYMENT_SCOPE=loadtest (only the load-test Terraform sets it) and
 * LOADTEST_SEED_CONFIRM=synthetic-only. Idempotent per family: a family that exists is skipped.
 *
 *   LOADTEST_FAMILIES=10000 LOADTEST_HISTORY_DAYS=1 node_modules/.bin/tsx scripts/loadtest-seed.ts
 */
import { createHmac, randomBytes } from "node:crypto";
import { PrismaClient } from "@prisma/client";
import argon2 from "argon2";
import { DEFAULT_BLOCKED_CATEGORIES } from "@familyshield/shared-types";

if (process.env.OSRA_DEPLOYMENT_SCOPE !== "loadtest" || process.env.LOADTEST_SEED_CONFIRM !== "synthetic-only") {
  console.error("refusing: loadtest-seed runs only on the load-test stack (OSRA_DEPLOYMENT_SCOPE=loadtest, LOADTEST_SEED_CONFIRM=synthetic-only)");
  process.exit(2);
}
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET) {
  console.error("refusing: JWT_SECRET is needed to derive the device secrets the k6 scripts sign with");
  process.exit(2);
}

// dist in the image, src in a checkout (tsx resolves the .js to the .ts).
const { encryptSecret } = await import("../dist/lib/secretVault.js").catch(() => import("../src/lib/secretVault.js"));

const FAMILIES = Number(process.env.LOADTEST_FAMILIES ?? 1000);
const FIRST = Number(process.env.LOADTEST_FIRST_FAMILY ?? 0);
const HISTORY_DAYS = Number(process.env.LOADTEST_HISTORY_DAYS ?? 1);
const BATCH = Number(process.env.LOADTEST_BATCH ?? 250);

// --- The id rule, kept identical to loadtest/k6/lib/ids.js ------------------------------------------------
const KIND = { family: "1", parent: "2", child: "3", device: "4" } as const;
const hex12 = (n: number) => n.toString(16).padStart(12, "0");
export const ltId = (kind: keyof typeof KIND, family: number, sub = 0) => `0000000${KIND[kind]}-1000-4000-8000-${hex12(family * 16 + sub)}`;
/** Per-device HMAC secret: derived, so k6 can sign `/v1/social/scan` without reading the database. */
export const ltDeviceSecret = (deviceId: string) => createHmac("sha256", JWT_SECRET!).update(`lt-device:${deviceId}`).digest("hex");
/** Family shape: even families have 2 parents and 3 devices, odd ones 1 parent and 2 (averages 1.5 and 2.5). */
export const ltShape = (family: number) => ({ parents: family % 2 === 0 ? 2 : 1, devicesPerChild: family % 2 === 0 ? [2, 1] : [1, 1] });
// -----------------------------------------------------------------------------------------------------------

const prisma = new PrismaClient();
const rnd = (min: number, max: number) => min + Math.random() * (max - min);

async function main() {
  const passwordHash = await argon2.hash(randomBytes(24).toString("hex")); // nobody logs in with it
  const started = Date.now();
  let created = 0;
  for (let start = FIRST; start < FIRST + FAMILIES; start += BATCH) {
    const end = Math.min(start + BATCH, FIRST + FAMILIES);
    const ids = Array.from({ length: end - start }, (_, k) => start + k);
    const existing = new Set(
      (await prisma.family.findMany({ where: { id: { in: ids.map((i) => ltId("family", i)) } }, select: { id: true } })).map((f) => f.id),
    );
    const todo = ids.filter((i) => !existing.has(ltId("family", i)));
    if (todo.length === 0) continue;

    const families = [], parents = [], children = [], consents = [], devices = [], rules = [], fences = [], pings = [];
    for (const i of todo) {
      const fam = ltId("family", i);
      const shape = ltShape(i);
      const home = { lat: rnd(24.2, 25.4), lng: rnd(54.3, 55.6) }; // somewhere in the UAE, random
      families.push({ id: fam, name: `LT Family ${String(i).padStart(6, "0")}`, region: "US", timezone: "Asia/Dubai" /* region must match the consent jurisdiction */ });
      for (let p = 0; p < shape.parents; p++) {
        parents.push({
          id: ltId("parent", i, p), familyId: fam, email: `lt-${i}-${p}@loadtest.invalid`, passwordHash,
          displayName: `LT Parent ${p + 1}`, role: p === 0 ? "owner" : "co-parent",
          permissions: p === 0 ? [] : ["rules", "alerts", "location", "social", "devices"],
        });
      }
      let d = 0;
      shape.devicesPerChild.forEach((count, c) => {
        const child = ltId("child", i, c);
        children.push({ id: child, familyId: fam, displayName: `LT Child ${c + 1}`, birthYear: 2012 + c });
        consents.push({ childId: child, parentId: ltId("parent", i, 0), method: "sms_plus", jurisdiction: "US", expiresAt: new Date("2099-01-01T00:00:00Z") });
        rules.push({
          childId: child, dailyLimitMinutes: 180, weekendLimitMinutes: 300, bedtimeStart: "21:00", bedtimeEnd: "07:00",
          blockedCategories: [...DEFAULT_BLOCKED_CATEGORIES], allowedDomains: [], blockedDomains: ["blocked.example"],
          safeSearchEnforced: true, appRules: [], routines: [],
        });
        fences.push({ childId: child, label: "Home", lat: home.lat, lng: home.lng, radiusM: 150 });
        fences.push({ childId: child, label: "School", lat: home.lat + 0.01, lng: home.lng + 0.01, radiusM: 200 });
        for (let k = 0; k < count; k++, d++) {
          const id = ltId("device", i, d);
          devices.push({
            id, childId: child, platform: "android", model: "LT Synthetic", osVersion: "14", status: "online",
            pairedAt: new Date(), setupCompletedAt: new Date(), internalSecret: encryptSecret(ltDeviceSecret(id)),
          });
          for (let h = 0; h < HISTORY_DAYS * 24; h++) {
            pings.push({ childId: child, deviceId: id, lat: home.lat + rnd(-0.02, 0.02), lng: home.lng + rnd(-0.02, 0.02), accuracyM: 15, timestamp: new Date(Date.now() - h * 3_600_000) });
          }
        }
      });
    }
    await prisma.$transaction([
      prisma.family.createMany({ data: families }),
      prisma.parent.createMany({ data: parents }),
      prisma.child.createMany({ data: children }),
      prisma.consentRecord.createMany({ data: consents }),
      prisma.device.createMany({ data: devices }),
      prisma.ruleSet.createMany({ data: rules }),
      prisma.geofence.createMany({ data: fences }),
    ]);
    for (let k = 0; k < pings.length; k += 5000) await prisma.locationPing.createMany({ data: pings.slice(k, k + 5000) });
    created += todo.length;
    console.log(`[loadtest-seed] families ${start}-${end - 1}: +${todo.length} (total new ${created}, ${Math.round((Date.now() - started) / 1000)} s)`);
  }
  console.log(`[loadtest-seed] done: ${created} new families of ${FAMILIES} requested, ${Math.round((Date.now() - started) / 1000)} s`);
}

main()
  .catch((err) => {
    console.error(err);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
