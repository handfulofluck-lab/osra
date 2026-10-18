/**
 * Redis side of test hygiene (AGENTS.md §7). The SQL script restores the database; it cannot see
 * Redis, so per-device keys accumulate across runs and nothing owns them.
 *
 * Usage:
 *   node scripts/cleanup-test-redis.mjs            # dry run: classify every key, delete nothing
 *   node scripts/cleanup-test-redis.mjs --apply     # delete ONLY keys whose owner row is gone
 *
 * What it will delete (owner row absent from the database):
 *   device:<deviceId>:<suffix>      - the legacy Redis command mirror and any device-scoped key
 *   auth:session-version:<parentId> - the parent's revocation counter (ADR-0025). It has no TTL on
 *                                     purpose, so a parent deleted by the test run leaves it behind;
 *                                     the counter means nothing without the Parent row, and a
 *                                     re-created parent gets a new id.
 *
 * What it will NEVER delete, and why:
 *   revoked:device:<deviceId>       - security state. Device JWTs are minted with a 10-year life
 *                                     (routes/devices.ts:181) and the Device row is deleted in the
 *                                     same request that writes this key (devices.ts:344-348), so this
 *                                     key is the ONLY thing that still answers 401 device_revoked.
 *                                     Deleting it re-enables a revoked token; see issue #56 (the
 *                                     correct fix is a TTL bound in the unpair path, not a reap).
 *
 * Keys with a TTL are reported and left alone - they expire on their own.
 */
import { Redis } from "ioredis";
import { PrismaClient } from "@prisma/client";

const apply = process.argv.includes("--apply");
const prisma = new PrismaClient();
const redis = new Redis(process.env.REDIS_URL ?? "redis://127.0.0.1:6379");

async function liveIds() {
  const [devices, children, families, parents] = await Promise.all([
    prisma.device.findMany({ select: { id: true } }),
    prisma.child.findMany({ select: { id: true } }),
    prisma.family.findMany({ select: { id: true } }),
    prisma.parent.findMany({ select: { id: true } }),
  ]);
  return {
    all: new Set([...devices, ...children, ...families, ...parents].map((r) => r.id)),
    parents: new Set(parents.map((r) => r.id)),
  };
}

const keys = await redis.keys("*");
const live = await liveIds();
const ttlOf = new Map();
for (const key of keys) ttlOf.set(key, await redis.ttl(key));

const expiring = [];
const orphanedKeys = [];
const keptControls = [];
const unclassified = [];

for (const key of keys) {
  const ttl = ttlOf.get(key);
  const deviceMatch = key.match(/^device:([^:]+):(.+)$/);
  const sessionVersionMatch = key.match(/^auth:session-version:(.+)$/);
  if (key.startsWith("revoked:device:")) {
    const id = key.slice("revoked:device:".length);
    // Never deleted, live device or not: see the header.
    keptControls.push({ key, ttl, note: live.all.has(id) ? "live device" : "device row gone — still a control (#56)" });
  } else if (sessionVersionMatch) {
    if (live.parents.has(sessionVersionMatch[1])) {
      keptControls.push({ key, ttl, note: "live parent — persistent by design (ADR-0025)" });
    } else {
      orphanedKeys.push({ key, ttl });
    }
  } else if (deviceMatch) {
    if (live.all.has(deviceMatch[1])) expiring.push({ key, ttl });
    else orphanedKeys.push({ key, ttl });
  } else if (ttl === -1) {
    unclassified.push({ key, ttl });
  } else {
    expiring.push({ key, ttl });
  }
}

const line = (entry) => `  ${entry.key}  (TTL ${entry.ttl}${entry.note ? ` — ${entry.note}` : ""})`;
const section = (title, entries) => {
  console.log(`\n=== ${title} (${entries.length}) ===`);
  for (const entry of entries.slice(0, 25)) console.log(line(entry));
  if (entries.length > 25) console.log(`  … and ${entries.length - 25} more`);
};

console.log(`Redis ${process.env.REDIS_URL ?? "redis://127.0.0.1:6379"} — ${keys.length} keys, ${live.all.size} live entity ids in the database`);
section("orphaned keys — would be deleted", orphanedKeys);
section("kept: revocation controls (never reaped)", keptControls);
section("kept: keys with a TTL (expire on their own)", expiring);
section("REVIEW: persistent keys with no known owner", unclassified);

if (!apply) {
  console.log("\nDRY RUN — nothing deleted. Re-run with --apply to remove the orphaned keys.");
} else if (orphanedKeys.length === 0) {
  console.log("\nAPPLIED — nothing to delete.");
} else {
  const deleted = await redis.del(...orphanedKeys.map((entry) => entry.key));
  console.log(`\nAPPLIED — deleted ${deleted} orphaned key(s); ${keptControls.length} revocation control(s) untouched.`);
}

await prisma.$disconnect();
redis.disconnect();
