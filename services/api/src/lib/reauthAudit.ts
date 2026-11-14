export type ReauthAuditReason = "bad_password" | "bad_totp" | "totp_replay" | "rate_limited";

type ReauthLogger = {
  info: (entry: Record<string, unknown>, message: string) => unknown;
};

export function logParentReauth(
  log: ReauthLogger,
  parentId: string,
  success: boolean,
  reason?: ReauthAuditReason,
): void {
  log.info({
    event: "parent_reauth",
    parentId,
    success,
    ...(reason ? { reason } : {}),
    timestamp: new Date().toISOString(),
  }, "parent_reauth");
}
