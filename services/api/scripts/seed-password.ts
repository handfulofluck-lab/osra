/**
 * Resolves the demo parent's password for the seed (scripts/seed.ts).
 *
 * Extracted so the production refusal can be tested without a database: `seed.ts` runs Prisma at
 * import time, so a test cannot import it. The default is public (it is in this repository's history
 * and in the API's docs), so it must never reach a deployment that NODE_ENV=production gates.
 */
export function resolveDemoPassword(env: NodeJS.ProcessEnv = process.env): string {
  const password =
    env.SEED_DEMO_PASSWORD ??
    (env.NODE_ENV === "production" ? undefined : "CorrectHorseBatteryStaple!");

  if (!password) {
    throw new Error(
      "SEED_DEMO_PASSWORD is required when NODE_ENV=production: the default demo password is public",
    );
  }

  return password;
}
