import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { FastifyInstance } from "fastify";
import type { BlocklistPack } from "@familyshield/shared-types";
import { requireAuth } from "../middleware/requireFamily.js";

// NOTE: resolved relative to this file so the pack loads from src (tsx/vitest) and dist alike.
const packPath = fileURLToPath(new URL("../../data/blocklists/pack.json", import.meta.url));

/** Serve the versioned blocklist pack to any verified parent or device JWT. */
export async function blocklistRoutes(app: FastifyInstance) {
  app.get("/", { preHandler: requireAuth }, async () =>
    JSON.parse(readFileSync(packPath, "utf8")) as BlocklistPack,
  );
}
