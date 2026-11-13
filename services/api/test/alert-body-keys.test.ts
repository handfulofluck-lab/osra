import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { raiseAlert } from "../src/lib/alerts.js";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("../src/realtime/gateway.js", () => ({ publishFamilyEvent: vi.fn(async () => undefined) }));
vi.mock("../src/lib/push/notify.js", () => ({ notifyParentsOfAlert: vi.fn(async () => undefined) }));

const srcRoot = fileURLToPath(new URL("../src", import.meta.url));

function sourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    return entry.isFile() && entry.name.endsWith(".ts") ? [path] : [];
  });
}

describe("alert body keys (#711)", () => {
  beforeEach(() => resetPrismaMock());

  it("requires every raiseAlert producer to supply a bodyKey", () => {
    const missing: string[] = [];
    const producers: string[] = [];
    for (const path of sourceFiles(srcRoot)) {
      const source = ts.createSourceFile(path, readFileSync(path, "utf8"), ts.ScriptTarget.ES2022, true);
      const visit = (node: ts.Node): void => {
        if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "raiseAlert") {
          const name = relative(srcRoot, path).replaceAll("\\", "/");
          producers.push(name);
          const input = node.arguments[0];
          const keyed = input && ts.isObjectLiteralExpression(input) && input.properties.some((property) =>
            (ts.isPropertyAssignment(property) || ts.isShorthandPropertyAssignment(property))
            && ts.isIdentifier(property.name) && property.name.text === "bodyKey",
          );
          if (!keyed) missing.push(name);
        }
        ts.forEachChild(node, visit);
      };
      visit(source);
    }
    expect(producers).toHaveLength(5);
    expect(missing).toEqual([]);
  });

  it("round-trips bodyKey and bodyParams through the row's JSON metadata with the English fallback", async () => {
    prismaMock.alert.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({ id: "alert-1", ...data }));
    const alert = await raiseAlert({
      childId: "child-1",
      familyId: "fam-1",
      severity: "warning",
      category: "ai_concern",
      title: "Search query concern on Google",
      body: "A concerning search was conducted on Google",
      bodyKey: "alertBodySearchFlagged",
      params: { engine: "Google" },
      metadata: { source: "test" },
    } as Parameters<typeof raiseAlert>[0]);

    expect(alert.body).toBe("A concerning search was conducted on Google");
    expect(alert.metadata).toEqual({
      source: "test",
      bodyKey: "alertBodySearchFlagged",
      bodyParams: { engine: "Google" },
    });
  });

  it("raises the alert with the English body when a required parameter is missing (#718 review)", async () => {
    // A missing param costs the KEY, not the alert. Throwing here dropped a child-safety alert entirely on a
    // path where the source field can legitimately be empty, which is the regression this row now pins.
    await raiseAlert({
      childId: "child-1",
      familyId: "fam-1",
      severity: "critical",
      category: "tamper",
      title: "Device stopped reporting",
      body: "Pixel 7a has not reported for 45 minutes.",
      bodyKey: "alertBodyDeviceSilent",
      params: { model: "Pixel 7a" },
    });
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    const data = prismaMock.alert.create.mock.calls[0][0].data as { metadata?: { bodyKey?: string }; body: string };
    expect(data.metadata?.bodyKey).toBeUndefined();
    expect(data.body).toBe("Pixel 7a has not reported for 45 minutes.");
  });

  it("raises a flagged video that carries no channel, with no bodyKey (#718 review)", async () => {
    // YouTubeWatchSchema defaults `channel` to "", so this is a real payload, not a hostile one. `channel` is
    // no longer a required param for exactly this case.
    await raiseAlert({
      childId: "child-1",
      familyId: "fam-1",
      severity: "warning",
      category: "web_threat",
      title: "Flagged video",
      body: "A flagged video was watched.",
      bodyKey: "alertBodyYouTubeFlagged",
      params: { channel: "" },
    });
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    const data = prismaMock.alert.create.mock.calls[0][0].data as { metadata?: { bodyKey?: string } };
    expect(data.metadata?.bodyKey).toBe("alertBodyYouTubeFlagged");
  });
});
