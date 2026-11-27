import { z } from "zod";
import { prisma } from "../db.js";
import { publishJson } from "../redis.js";
import { checkActiveConsent } from "./consent.js";
import { defaultRuleSetRow } from "./defaultRules.js";
import { toMessage, ttlFor, wakeForDeviceCommand } from "./deviceCommands.js";
import { filterAgentRules, toApiRuleSet } from "./ruleSync.js";

export const timeDecisionSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("grant"), minutes: z.union([z.literal(15), z.literal(30)]) }).strict(),
  z.object({ action: z.literal("decline") }).strict(),
]);

type TimeDecision = z.infer<typeof timeDecisionSchema>;

export function timeRequestMinutes(alert: { category: string; metadata: unknown }): 15 | 30 | null {
  if (alert.category !== "app_blocked" || typeof alert.metadata !== "object" || alert.metadata === null) return null;
  const metadata = alert.metadata as Record<string, unknown>;
  if (metadata.requestType !== "time" || metadata.reason !== "daily_limit") return null;
  if (metadata.minutes === 15 || metadata.minutes === "15") return 15;
  if (metadata.minutes === 30 || metadata.minutes === "30") return 30;
  return null;
}

export async function resolveTimeRequest(
  alertId: string,
  parentId: string,
  familyId: string,
  decision: TimeDecision,
) {
  const result = await prisma.$transaction(async (tx) => {
    // Serialize all decisions for this alert, including retries. Keep the grant, command
    // rows, server-owned receipt and acknowledgement together until commit.
    const [locked] = await tx.$queryRaw<{ id: string }[]>`
      SELECT id FROM "Alert" WHERE id = ${alertId} FOR UPDATE
    `;
    if (!locked) return { status: "not_found" } as const;

    const alert = await tx.alert.findUnique({
      where: { id: alertId },
      include: {
        child: { select: { familyId: true, family: { select: { region: true } } } },
        timeRequestResolution: true,
      },
    });
    if (!alert || alert.heldDuringSetup || timeRequestMinutes(alert) === null) {
      return { status: "not_found" } as const;
    }
    const parent = await tx.parent.findUnique({
      where: { id: parentId },
      select: { familyId: true, displayName: true },
    });
    if (alert.child.familyId !== familyId || parent?.familyId !== familyId) {
      return { status: "forbidden" } as const;
    }
    const consent = await checkActiveConsent(alert.childId, alert.child.family.region, tx);
    if (!consent.active) {
      return { status: "consent_required", reason: consent.reason, jurisdiction: consent.jurisdiction } as const;
    }
    if (alert.acknowledged || alert.timeRequestResolution) {
      return { status: "already_resolved", resolution: alert.timeRequestResolution } as const;
    }

    const resolvedAt = new Date();
    const minutes = decision.action === "grant" ? decision.minutes : null;
    const ruleSet = minutes === null
      ? null
      : await tx.ruleSet.upsert({
          where: { childId: alert.childId },
          create: { ...defaultRuleSetRow(alert.childId), bonusMinutesToday: minutes },
          update: { bonusMinutesToday: { increment: minutes }, rulesVersion: { increment: 1 } },
        });
    const devices = minutes === null ? [] : await tx.device.findMany({
      where: { childId: alert.childId, pairedAt: { not: null } },
      select: { id: true },
    });
    const commands = devices.length === 0 ? [] : await tx.deviceCommand.createManyAndReturn({
      data: devices.map(({ id: deviceId }) => ({
        deviceId,
        type: "bonus_time",
        payload: { minutes },
        requestedBy: parentId,
        createdAt: resolvedAt,
        expiresAt: new Date(resolvedAt.getTime() + ttlFor("bonus_time") * 1000),
      })),
    });
    const resolution = await tx.timeRequestResolution.create({
      data: { alertId, action: decision.action, minutes, actorName: parent.displayName, resolvedAt },
    });
    await tx.alert.update({ where: { id: alertId }, data: { acknowledged: true } });
    return { status: "resolved", resolution, commands, ruleSet, childId: alert.childId } as const;
  });

  if (result.status !== "resolved") return result;
  for (const command of result.commands) {
    void wakeForDeviceCommand(toMessage(command)).catch(() => undefined);
  }
  if (result.ruleSet) {
    const rules = toApiRuleSet(result.ruleSet as unknown as Record<string, unknown>);
    void filterAgentRules(result.childId, rules)
      .then((filtered) => publishJson(`child:${result.childId}:rules`, filtered))
      .catch(() => undefined);
  }
  return { status: result.status, resolution: result.resolution } as const;
}
