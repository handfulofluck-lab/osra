// World-class addendum types (docs/SPEC-ADDENDUM-WORLD-CLASS.md is the binding contract).

export type CommandType =
  | "lock" | "unlock" | "ring" | "sos_clear" | "pause" | "resume"
  | "pause_internet" | "resume_internet" | "bonus_time" | "wind_down";

export type AlertCategoryExtended =
  | "web_threat" | "app_blocked" | "screen_time_exceeded" | "geofence" | "sos"
  | "ai_concern" | "cyberbullying" | "self_harm" | "grooming"
  | "social_concern" | "gaming_chat" | "call_sms" | "tamper" | "vpn_detected"
  | "install_request" | "unknown_contact" | "bonus_granted" | "wind_down";

/** Recommended default categories, applied to every new child (Feature #1). */
export const DEFAULT_BLOCKED_CATEGORIES = [
  "pornography", "gambling", "drugs", "violence", "weapons", "hate", "self_harm",
  "dating", "social_media_nsfw", "chat_random", "proxies_vpn", "warez", "ai_chatbots",
] as const;

export interface BlocklistPack {
  version: number;
  updatedAt: string;
  categories: Array<{
    category: string;
    domains: string[];
    appsAndroid: string[];
    appsWindows: string[];
  }>;
}

export interface SocialConcernEvent {
  app: string;
  contact: string;
  preview: string;
  concernTypes: string[];
  severity: "info" | "warning" | "critical";
  capturedAt: string;
}

export interface ActivityEvent {
  id: string;
  childId: string;
  deviceId?: string;
  ts: string;
  type: "url" | "app_usage" | "social" | "call" | "sms";
  payload: Record<string, unknown>;
}

export interface DigestPrefs {
  familyId: string;
  dailyEmail: boolean;
  weeklyEmail: boolean;
  pushEnabled: boolean;
  emails: string[];
}

export interface AppInsight {
  packageId: string;
  appName: string;
  ageRating: string;
  risks: string[];
  alternatives: string[];
}

export interface WellbeingScore {
  childId: string;
  week: string;
  score: number;
  breakdown: Record<string, number>;
}

export interface FamilyInvite {
  id: string;
  familyId: string;
  email: string;
  role: "co-parent" | "guardian";
  permissions: string[];
  status: "pending" | "accepted" | "revoked";
  createdAt: string;
}

export interface LiveActivity {
  childId: string;
  deviceId?: string;
  app: string;
  minutesToday: number;
  ts: string;
}
