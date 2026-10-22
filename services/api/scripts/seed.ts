import { PrismaClient } from "@prisma/client";
import { DEFAULT_BLOCKED_CATEGORIES } from "@familyshield/shared-types";
import argon2 from "argon2";
import { resolveDemoPassword } from "./seed-password.js";

const prisma = new PrismaClient();

/** Idempotent seed per spec §3: running twice must not duplicate rows. */
async function main() {
  // Resolved first: in production the seed must fail before it writes anything without a password.
  const passwordHash = await argon2.hash(resolveDemoPassword());

  const family =
    (await prisma.family.findFirst({ where: { name: "Demo Family" } })) ??
    (await prisma.family.create({ data: { name: "Demo Family", region: "US" } }));

  const parent = await prisma.parent.upsert({
    where: { email: "demo@familyshield.dev" },
    update: {},
    create: {
      familyId: family.id,
      email: "demo@familyshield.dev",
      passwordHash,
      displayName: "Demo Parent",
      role: "owner",
    },
  });

  const child =
    (await prisma.child.findFirst({
      where: { familyId: family.id, displayName: "Alex" },
    })) ??
    (await prisma.child.create({
      data: { familyId: family.id, displayName: "Alex", birthYear: 2013 },
    }));

  // Valid, active sms_plus consent in the US jurisdiction (non-revoked, non-expired).
  const existingConsent = await prisma.consentRecord.findFirst({
    where: { childId: child.id, method: "sms_plus", jurisdiction: "US" },
  });
  const consent =
    existingConsent ??
    (await prisma.consentRecord.create({
      data: {
        childId: child.id,
        parentId: parent.id,
        method: "sms_plus",
        jurisdiction: "US",
        expiresAt: new Date("2099-01-01T00:00:00Z"),
      },
    }));

  const device =
    (await prisma.device.findFirst({
      where: { childId: child.id, model: "Pixel 7a" },
    })) ??
    (await prisma.device.create({
      data: {
        childId: child.id,
        platform: "android",
        model: "Pixel 7a",
        osVersion: "14",
        status: "online",
        pushToken: "demo-token",
      },
    }));

  await prisma.ruleSet.upsert({
    where: { childId: child.id },
    update: {},
    create: {
      childId: child.id,
      dailyLimitMinutes: 180,
      weekendLimitMinutes: 300,
      bedtimeStart: "21:00",
      bedtimeEnd: "07:00",
      blockedCategories: [...DEFAULT_BLOCKED_CATEGORIES],
      allowedDomains: [],
      blockedDomains: [],
      safeSearchEnforced: true,
      appRules: [],
      routines: [],
    },
  });

  for (const fence of [
    { label: "Home", lat: 40.7128, lng: -74.006, radiusM: 150 },
    { label: "School", lat: 40.7178, lng: -74.016, radiusM: 200 },
  ]) {
    const existing = await prisma.geofence.findFirst({
      where: { childId: child.id, label: fence.label },
    });
    if (!existing) await prisma.geofence.create({ data: { childId: child.id, ...fence } });
  }

  const sampleAlerts = [
    { severity: "info", category: "geofence", title: "Arrived at School", body: "Alex entered geofence \"School\"." },
    { severity: "warning", category: "screen_time_exceeded", title: "Screen time limit reached", body: "Alex exceeded the daily screen time limit." },
    { severity: "critical", category: "self_harm", title: "Potential self-harm content detected", body: "AI engine flagged a message for review." },
  ];
  for (const alert of sampleAlerts) {
    const existing = await prisma.alert.findFirst({
      where: { childId: child.id, title: alert.title },
    });
    if (!existing) {
      await prisma.alert.create({
        data: { childId: child.id, deviceId: device.id, metadata: {}, ...alert },
      });
    }
  }

  console.log("Seed complete:", {
    family: family.id,
    parent: parent.email,
    child: child.id,
    consent: consent.id,
    device: device.id,
  });
}

main()
  .catch((err) => {
    console.error(err);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
