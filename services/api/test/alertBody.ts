import { expect } from "vitest";
import * as sharedTypes from "@familyshield/shared-types";

export function expectKeyedAlertBody(
  data: { body?: unknown; metadata?: unknown },
  bodyKey: string,
  bodyParams: Record<string, string | number>,
): void {
  const keys = (sharedTypes as { ALERT_BODY_KEYS?: readonly string[] }).ALERT_BODY_KEYS ?? [];
  expect(keys).toContain(bodyKey);
  expect(typeof data.body).toBe("string");
  expect((data.body as string).trim()).not.toBe("");
  expect(data.metadata).toMatchObject({ bodyKey });
  expect((data.metadata as { bodyParams: unknown }).bodyParams).toEqual(bodyParams);
}
