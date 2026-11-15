import argon2 from "argon2";
import type { z } from "zod";
import type { ReauthSchema } from "./accountDeletion.js";
import { verifyTotpDetailed } from "./mfaVerify.js";

export type ReauthProofFailure = "bad_password" | "bad_totp" | "totp_replay" | "mfa_reenroll_required";

type ParentForReauth = {
  id: string;
  passwordHash: string;
  mfaEnabled: boolean;
  mfaSecret: string | null;
};

export async function verifyReauthProof(
  parent: ParentForReauth,
  body: z.infer<typeof ReauthSchema>,
): Promise<ReauthProofFailure | null> {
  const passwordOk = await argon2.verify(parent.passwordHash, body.password).catch(() => false);
  if (!passwordOk) return "bad_password";
  if (!parent.mfaEnabled) return null;
  if (!parent.mfaSecret) return "mfa_reenroll_required";
  if (!body.mfaCode) return "bad_totp";
  const result = await verifyTotpDetailed(parent.id, parent.mfaSecret, body.mfaCode);
  if (result === "valid") return null;
  return result === "replay" ? "totp_replay" : "bad_totp";
}
