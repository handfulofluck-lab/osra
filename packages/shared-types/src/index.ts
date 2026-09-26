export type UUID = string;
export type ISODate = string;

export enum Platform {
  ANDROID = "android", IOS = "ios", WINDOWS = "windows",
  MACOS = "macos", CHROMEBOOK = "chromebook",
}

export enum DeviceStatus {
  ONLINE = "online", OFFLINE = "offline", LOCKED = "locked", SOS = "sos",
}

export interface Family { id: UUID; name: string; region: "US"|"EU"|"UK"|"OTHER"; createdAt: ISODate; }
export interface Parent { id: UUID; familyId: UUID; email: string; displayName: string;
  role: "owner"|"co-parent"|"guardian"; mfaEnabled: boolean; }
export interface Child { id: UUID; familyId: UUID; displayName: string; birthYear: number;
  avatarUrl?: string; consentRecordId: UUID; }
export interface Device { id: UUID; childId: UUID; platform: Platform; model: string;
  osVersion: string; status: DeviceStatus; batteryPct: number; lastSeen: ISODate; pushToken?: string; }
export interface RuleSet { id: UUID; childId: UUID; screenTime: ScreenTimeRule;
  webFilter: WebFilterRule; appRules: AppRule[]; routines: Routine[]; updatedAt: ISODate; }
export interface ScreenTimeRule { dailyLimitMinutes: number; weekendLimitMinutes: number;
  bedtimeStart: string; bedtimeEnd: string;
  schoolHours: { start: string; end: string; days: number[] }; }
export interface WebFilterRule { blockedCategories: string[]; allowedDomains: string[];
  blockedDomains: string[]; safeSearchEnforced: boolean; }
export interface AppRule { packageId: string; appName: string;
  action: "allow"|"block"|"time_limit"; dailyLimitMinutes?: number; }
export interface Routine { id: UUID; name: string; startTime: string; endTime: string;
  days: number[]; blockedApps: string[]; allowedApps: string[]; }
export interface LocationPing { deviceId: UUID; lat: number; lng: number;
  accuracyM: number; timestamp: ISODate; }
export interface Geofence { id: UUID; childId: UUID; label: string; lat: number; lng: number;
  radiusM: number; notifyOnEnter: boolean; notifyOnExit: boolean; }
export interface Alert { id: UUID; childId: UUID; deviceId?: UUID;
  severity: "info"|"warning"|"critical";
  category: "web_threat"|"app_blocked"|"screen_time_exceeded"|"geofence"|"sos"|
            "ai_concern"|"cyberbullying"|"self_harm"|"grooming";
  title: string; body: string; metadata: Record<string, unknown>;
  createdAt: ISODate; acknowledged: boolean; }
export interface ConsentRecord { id: UUID; childId: UUID; parentId: UUID;
  method: "sms_plus"|"kba"|"face_match"|"credit_card"; jurisdiction: string;
  grantedAt: ISODate; expiresAt?: ISODate; revokedAt?: ISODate; thirdPartySharing: boolean; }

export * from "./world-class.js";
