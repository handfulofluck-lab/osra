import type { FastifyInstance } from "fastify";
import { Prisma } from "@prisma/client";
import { z } from "zod";
import { prisma } from "../db.js";
import { requireParent } from "../middleware/requireFamily.js";
import { registerParentPushToken, type ParentSessionClaims } from "../lib/sessions.js";
import { ReauthSchema, checkReauth, consentHeldElsewhere, eraseParentAccount } from "../lib/accountDeletion.js";
import { AUTH_RATE_LIMIT } from "../lib/rateLimits.js";
import { consentCopyFor } from "../lib/consentCopy.js";
import {
  TERMS_PURPOSE,
  consentHistory,
  consentWriteFor,
  currentConsents,
  recordConsent,
} from "../lib/parentConsent.js";

/** ADR-0043 D2: where an app tick happened. Sign-up uses `app_signup`, written by the register route. */
const SETTINGS_SURFACE = "app_settings";

/**
 * Parent-self routes (Phase 2a): push-token registry for the signed-in parent, and (#442) deleting
 * one's own account.
 * A token belongs to one parent; re-registering an existing token (new install, token refresh
 * on the same device, or a second parent logging in on that phone) moves it to the caller.
 */

const PushTokenSchema = z.object({
  token: z.string().min(20).max(4096),
  platform: z.enum(["android", "ios", "web"]),
  appVersion: z.string().max(40).optional(),
});

type AuthedUser = ParentSessionClaims & { sub: string; familyId: string };

/** ADR-0043 D3: a write from the app. The version and locale are the wording the parent was shown. */
const ConsentWriteSchema = z.object({
  granted: z.boolean(),
  textVersion: z.string().min(1).max(64),
  locale: z.string().min(2).max(16),
});

export async function meRoutes(app: FastifyInstance) {
  app.post("/push-token", { preHandler: requireParent }, async (req, reply) => {
    const parsed = PushTokenSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const { token, platform, appVersion } = parsed.data;
    const row = await registerParentPushToken({ user, token, platform, appVersion });
    if (!row) {
      return reply.code(401).send({ error: "session_revoked" });
    }
    return reply.code(201).send({ id: row.id, platform: row.platform, registeredAt: row.createdAt });
  });

  /** Called on logout so a shared phone stops receiving the previous parent's alerts. */
  app.delete("/push-token", { preHandler: requireParent }, async (req, reply) => {
    const parsed = z.object({ token: z.string().min(1) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const result = await prisma.parentPushToken.deleteMany({ where: { token: parsed.data.token, parentId: user.sub } });
    return { removed: result.count };
  });

  app.get("/push-tokens", { preHandler: requireParent }, async (req) => {
    const user = req.user as AuthedUser;
    const { parent, rows } = await prisma.$transaction(
      async (tx) => {
        const p = await tx.parent.findUnique({ where: { id: user.sub }, select: { sessionVersion: true } });
        const list = await tx.parentPushToken.findMany({
          where: { parentId: user.sub },
          select: { id: true, platform: true, appVersion: true, sessionVersion: true, createdAt: true, lastSeenAt: true },
          orderBy: { lastSeenAt: "desc" },
        });
        return { parent: p, rows: list };
      },
      { isolationLevel: Prisma.TransactionIsolationLevel.RepeatableRead },
    );
    const minVersion = typeof parent?.sessionVersion === "number" ? parent.sessionVersion : 0;
    const tokens = rows
      .filter((r) => (typeof r.sessionVersion === "number" ? r.sessionVersion : 0) >= minVersion)
      .map(({ id, platform, appVersion, createdAt, lastSeenAt }) => ({ id, platform, appVersion, createdAt, lastSeenAt }));
    return { tokens };
  });

  /**
   * ADR-0043 D3/D4 / #846 part A step 3: the parent's own consent state, with the copy to show.
   *
   * `requiresAcceptance` is the re-accept signal D6 asks for: an account created before step 2 — or one
   * whose `terms_privacy` row predates a wording change — has no granted row at the version served today,
   * and the app blocks on the re-accept screen until it does. The server decides that, not the app, so a
   * phone with a stale copy cannot decide it has already agreed.
   */
  app.get("/consents", { preHandler: requireParent }, async (req) => {
    const user = req.user as AuthedUser;
    const current = await currentConsents(user.sub);
    // Ahmed's B1 on #886: the copy served here must be the copy a later write records the hash of. Serving
    // English and writing Arabic would put the Arabic hash beside text the parent never saw.
    const requested = (req.query as { locale?: unknown } | undefined)?.locale;
    const copy = consentCopyFor(typeof requested === "string" ? requested : undefined);
    const terms = current[TERMS_PURPOSE];
    return {
      requiresAcceptance: !(terms?.granted === true && terms.textVersion === copy.textVersion),
      purposes: [
        {
          key: TERMS_PURPOSE,
          required: true,
          granted: terms?.granted ?? false,
          at: terms?.at ?? null,
          textVersion: terms?.textVersion ?? null,
          copy: copy.purposes[0],
        },
      ],
    };
  });

  /** ADR-0043 D3: the parent's own rows, oldest and newest alike — a data-subject answer, not a UI feed. */
  app.get("/consents/history", { preHandler: requireParent }, async (req) => {
    const user = req.user as AuthedUser;
    return { items: await consentHistory(user.sub) };
  });

  /**
   * ADR-0043 D3/D5/D8: tick a purpose from the app. Withdrawing the terms is account deletion, and the two
   * parked purposes are refused while their switches are off — both by name, so the app can say why.
   */
  app.put("/consents/:purpose", { preHandler: requireParent }, async (req, reply) => {
    const parsed = ConsentWriteSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const { purpose } = req.params as { purpose: string };
    const write = consentWriteFor({ purpose, ...parsed.data });
    if (!write.ok) return reply.code(400).send({ error: write.reason });
    const clientVersion = (req as unknown as { client?: { version?: string } }).client?.version ?? null;
    const { recorded } = await recordConsent(user.sub, { purpose, ...parsed.data }, write.fields, write.action, SETTINGS_SURFACE, clientVersion);
    // 201 when a row was appended; 200 when the newest row already said exactly this (Ahmed's N1).
    return reply
      .code(recorded ? 201 : 200)
      .send({ purpose, granted: write.action === "granted", textVersion: write.fields.textVersion, recorded });
  });

  /**
   * #442 (Play account deletion): a co-parent or guardian deletes their own account — their `Parent`
   * row and the rows that are theirs alone. The family and the children stay. The owner deletes the
   * whole family instead (`DELETE /v1/family`), so here they get `409 owner_must_delete_family`:
   * ownership transfer is a later feature, and a family with no owner could not be managed or deleted.
   *
   * Same re-authentication as the family deletion: `{ password, mfaCode? }`, `401 reauth_failed`, and
   * the same `409 consent_records_held` (`consentHeldElsewhere`).
   */
  app.delete("/", { preHandler: requireParent, config: { rateLimit: AUTH_RATE_LIMIT } }, async (req, reply) => {
    const parsed = ReauthSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const parent = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!parent) return reply.code(404).send({ error: "parent_not_found" });
    if (parent.role === "owner") return reply.code(409).send({ error: "owner_must_delete_family" });
    const refusal = await checkReauth(parent, parsed.data);
    if (refusal) return reply.code(401).send({ error: refusal });
    if ((await consentHeldElsewhere([parent.id], parent.familyId)) > 0) {
      return reply.code(409).send({ error: "consent_records_held" });
    }
    return reply.code(200).send(await eraseParentAccount(parent));
  });
}
