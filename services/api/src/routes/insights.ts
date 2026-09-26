import type { FastifyInstance } from "fastify";
import { requireAuth } from "../middleware/requireFamily.js";

/** Curated per-app insight records (review 3.3 — the endpoint the app already calls). */
interface Insight {
  packageId: string;
  appName: string;
  ageRating: string;
  risks: string[];
  alternatives: string[];
}

const INSIGHTS: Insight[] = [
  { packageId: "com.whatsapp", appName: "WhatsApp", ageRating: "16+", risks: ["unsupervised DMs", "group chat exposure"], alternatives: ["Messenger Kids"] },
  { packageId: "com.instagram.android", appName: "Instagram", ageRating: "13+", risks: ["DMs from strangers", "body-image content"], alternatives: ["Pixelfed (supervised)"] },
  { packageId: "com.zhiliaoapp.musically", appName: "TikTok", ageRating: "13+", risks: ["infinite scroll", "unfiltered comments", "Duet with strangers"], alternatives: ["YouTube Kids"] },
  { packageId: "com.snapchat.android", appName: "Snapchat", ageRating: "13+", risks: ["ephemeral messages", "Snap Map location sharing"], alternatives: ["Messenger Kids"] },
  { packageId: "com.twitter.android", appName: "X (Twitter)", ageRating: "17+", risks: ["unfiltered adult content", "harassment"], alternatives: ["News apps with filters"] },
  { packageId: "com.discord", appName: "Discord", ageRating: "13+", risks: ["unknown servers", "voice chat with strangers"], alternatives: ["Family group chats"] },
  { packageId: "com.roblox.client", appName: "Roblox", ageRating: "7+", risks: ["in-game chat", "user-generated content"], alternatives: ["Minecraft (private realms)"] },
  { packageId: "com.mojang.minecraftpe", appName: "Minecraft", ageRating: "7+", risks: ["open multiplayer servers"], alternatives: ["Private realms with allowlist"] },
  { packageId: "com.google.android.youtube", appName: "YouTube", ageRating: "13+", risks: ["recommendation rabbit holes", "comments"], alternatives: ["YouTube Kids"] },
  { packageId: "com.android.chrome", appName: "Chrome", ageRating: "any", risks: ["unrestricted web"], alternatives: ["Filtered browser via OSRA web filter"] },
  { packageId: "com.tencent.ig", appName: "PUBG Mobile", ageRating: "16+", risks: ["voice chat with strangers", "in-app purchases"], alternatives: ["Offline games"] },
  { packageId: "com.supercell.clashofclans", appName: "Clash of Clans", ageRating: "10+", risks: ["in-app purchases", "global chat"], alternatives: ["Single-player strategy"] },
  { packageId: "com.google.android.apps.maps", appName: "Google Maps", ageRating: "any", risks: [], alternatives: [] },
  { packageId: "com.spotify.music", appName: "Spotify", ageRating: "13+", risks: ["explicit lyrics"], alternatives: ["Spotify Kids"] },
  { packageId: "com.netflix.mediaclient", appName: "Netflix", ageRating: "maturity-rated", risks: ["mature profiles"], alternatives: ["Kids profile + PIN"] },
];

/** Serve curated app insights (feature #12): GET /v1/insights/apps?packageId=… */
export async function insightsRoutes(app: FastifyInstance) {
  app.get("/apps", { preHandler: requireAuth }, async (req, reply) => {
    const { packageId } = req.query as { packageId?: string };
    if (!packageId) return reply.code(400).send({ error: "missing_packageId" });
    const hit = INSIGHTS.find((i) => i.packageId.toLowerCase() === packageId.trim().toLowerCase());
    if (!hit) return reply.code(404).send({ error: "no_insight" });
    return hit;
  });
}
