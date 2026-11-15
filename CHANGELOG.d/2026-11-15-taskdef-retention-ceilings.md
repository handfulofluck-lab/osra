### CI — the production task definition check enforces the privacy policy's retention ceilings (gate #637)
- `scripts/check-production-taskdef.mjs` now fails `ROLLUP_RETENTION_DAYS` above 365 and `ALERT_RETENTION_DAYS`
  above 365. The policy promises daily totals for 365 days and alerts for 12 months; the API accepts any larger
  `ROLLUP_RETENTION_DAYS` (`services/api/src/lib/usageModel.ts`), so until now nothing stopped a production setting
  that kept daily totals longer than promised. Found while answering the review of #780. Three self-test rows
  (71 checks); the existing `RETENTION_DAYS` ceiling gets the row it lacked.
