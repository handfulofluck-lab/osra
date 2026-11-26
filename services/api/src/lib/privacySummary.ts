import { alertRetentionDays, locationRetentionDays, retentionDays, rollupRetentionDays } from "./usageModel.js";

/**
 * P-23 "Privacy and data": what the parent app shows as "kept, then deleted automatically".
 *
 * The app windows come from the same functions the cleanup job uses (`usageModel.ts`), so the screen
 * cannot promise a period the job doesn't apply. Server logs and backups are set in Terraform
 * (`log_retention_days`, `db_backup_retention_days`); the API only knows them through
 * `PRIVACY_LOG_RETENTION_DAYS` / `PRIVACY_BACKUP_RETENTION_DAYS`, defaulting to the published privacy
 * policy §11 values (90 and 14 days). The app never hard-codes a number.
 */
export interface PrivacySummary {
  retention: {
    locationDays: number;
    activityDays: number;
    messageExcerptDays: number;
    dailyTotalsDays: number;
    alertDays: number;
    serverLogDays: number;
    backupDays: number;
  };
  /** Where family data is stored, as a key the app localizes. `null` = unknown, so the app hides the row. */
  storage: { area: "eu"; location: "frankfurt" | "stockholm" | "ireland" } | null;
  /** Days a deletion can be cancelled. The server deletes at once after re-authentication (no grace period). */
  deletionCancelDays: number | null;
  /** The published policy (§11 retention, §12 rights and deletion), per app language. */
  policyUrls: { en: string; ar: string };
}

const EU_LOCATIONS: Record<string, "frankfurt" | "stockholm" | "ireland"> = {
  "eu-central-1": "frankfurt",
  "eu-north-1": "stockholm",
  "eu-west-1": "ireland",
};

function positiveInt(raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw.trim() === "") return fallback;
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 && n <= 3650 ? n : fallback;
}

export function privacySummary(env: NodeJS.ProcessEnv = process.env): PrivacySummary {
  const region = (env.AWS_REGION ?? env.AWS_DEFAULT_REGION ?? "").trim();
  const location = EU_LOCATIONS[region];
  return {
    retention: {
      locationDays: locationRetentionDays(env),
      activityDays: retentionDays(env),
      messageExcerptDays: retentionDays(env),
      dailyTotalsDays: rollupRetentionDays(env),
      alertDays: alertRetentionDays(env),
      serverLogDays: positiveInt(env.PRIVACY_LOG_RETENTION_DAYS, 90),
      backupDays: positiveInt(env.PRIVACY_BACKUP_RETENTION_DAYS, 14),
    },
    storage: location ? { area: "eu", location } : null,
    deletionCancelDays: null,
    policyUrls: { en: "https://osratech.com/privacy", ar: "https://osratech.com/ar/privacy" },
  };
}
