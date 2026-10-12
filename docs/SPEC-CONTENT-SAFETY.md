# SPEC: Advanced Content & YouTube Monitoring (Track 1)

This specification defines the architecture, enforcement mechanisms, and data contracts for OSRA's **Track 1: Advanced Web & YouTube Monitoring**, establishing technical superiority over **Qustodio** and **Google Family Link**.

---

## 1. Executive Summary & Competitive Advantage

| Feature | Google Family Link | Qustodio | OSRA Track 1 (This Spec) |
|---|---|---|---|
| **YouTube Filtering** | Restricted Mode toggle in Google account | Web block or SafeSearch toggle | **Strict Header Injection (`YouTube-Restrict: Strict`) + DNS CNAME + Search extraction** |
| **Search Engine Coverage** | Google Search only | Google, Bing, Yahoo | **Google, Bing, YouTube, DuckDuckGo, Ecosia, Yahoo** |
| **Search Query Visibility** | None (Hidden inside Google account) | Web query log (delayed sync) | **Real-time search query extraction + immediate AI concern evaluation** |
| **Platform Enforcement** | Android only | Browser extension / Local VPN | **Cross-platform: Windows WinINET proxy, Android Accessibility/VPN, iOS ContentFilter** |
| **SafeSearch Bypass Resistance** | Bypassed by Incognito or other browsers | Bypassed if VPN disabled | **System-level self-healing proxy + browser lockdown + DNS-level CNAME fallback** |

---

## 2. YouTube Restricted Mode & SafeSearch Architecture

### 2.1 HTTP Request Header Injection
When `rules.safeSearchEnforced == true`, OSRA agents on all platforms intercept requests to Google and YouTube properties and inject mandatory policy headers:

1. **YouTube Strict Enforcement Header**:
   - Header: `YouTube-Restrict: Strict`
   - Target hosts: `*.youtube.com`, `m.youtube.com`, `youtubei.googleapis.com`
   - Result: Google's edge servers enforce Strict Restricted Mode for all video streams, comments, and recommendations, regardless of whether the user is logged into a Google account or incognito.
2. **Google SafeSearch Header**:
   - Header: `X-SafeSearch: true`
   - Target hosts: `google.*`, `*.google.*`

### 2.2 Query Parameter Rewriting (Defense-in-Depth)
For unencrypted HTTP proxies or transparent web filtering, query parameters are rewritten in-flight:
- **Google**: Appends or replaces `safe=strict`.
- **Bing**: Appends or replaces `adlt=strict`.
- **YouTube**: Appends `safe=strict` and forces `/results` filtering.

### 2.3 Search Query Extraction Pipeline

When a child performs a web or video search, the agent extracts the query text:

```
[Child Browser / App]
       │
       ▼ (Search query: "how to tie a noose")
[OSRA Agent Proxy / Accessibility]
       │
       ├─► 1. Extract query parameter (e.g. ?q= or ?search_query=)
       ├─► 2. Log search telemetry: (Host, Query, Timestamp)
       ▼
[Backend: POST /v1/content/search-event]
       │
       ▼ (Forward to AI Engine: context="search")
[AI Engine: POST /analyze]
       │
       ├─► Flagged: true (Category: "self_harm", Severity: "critical")
       ▼
[Alert Dispatcher + Snippet Vault]
       │
       ├─► Store encrypted query in Snippet Vault
       └─► Push high-priority WebSocket + APNs/FCM Alert to Parent App
```

---

## 3. Data Contracts & API Schema

### 3.1 Search Query Event (`POST /v1/content/search-event`)
- **Authentication**: Per-device HMAC signature via `X-FamilyShield-Signature`.
- **Payload Schema**:
```json
{
  "childId": "uuid-child",
  "deviceId": "uuid-device",
  "engine": "google" | "youtube" | "bing" | "duckduckgo",
  "query": "string (unredacted search query)",
  "url": "https://www.youtube.com/results?search_query=...",
  "timestamp": "ISO-8601 string"
}
```

- **Response (`201 Created`)**:
```json
{
  "id": "uuid-event",
  "flagged": true,
  "severity": "critical",
  "concernTypes": ["self_harm"],
  "action": "alert_dispatched"
}
```

### 3.2 YouTube Video Metadata Ingestion (`POST /v1/content/youtube-watch`)
- **Payload Schema**:
```json
{
  "childId": "uuid-child",
  "deviceId": "uuid-device",
  "videoId": "string (11 chars, e.g. dQw4w9WgXcQ)",
  "title": "string (extracted via DOM / Accessibility)",
  "channel": "string (extracted channel name)",
  "timestamp": "ISO-8601 string"
}
```

---

## 4. Multi-Platform Implementation Matrix

| Platform | SafeSearch & Header Injection | Query & Video Extraction |
|---|---|---|
| **Windows Desktop** | `WebFilterProxy.cs` + Titanium Web Proxy: injects `YouTube-Restrict: Strict` headers on `BeforeRequest`; rewrites `SafeSearch.TryRewrite`. | `SafeSearch.ExtractQuery(host, url)` parses query and queues `SearchReporter`. |
| **Android Agent** | `AccessibilityMonitorService.kt` scans URL bars in Chrome, Firefox, Edge; local VPN service injects SafeSearch VIPs. | `AccessibilityMonitorService.kt` extracts `com.google.android.youtube` title, channel, and search input nodes. |
| **iOS Agent** | `ScreenTimeController.swift` ManagedSettings `webContent.blockedByFilter` + NetworkExtension Content Filter. | NetworkExtension Content Filter inspects outbound URLs and extracts query terms. |
| **macOS Agent** | Local System Proxy / NetworkExtension Content Filter. | Local proxy parses HTTP headers and search queries. |

---

## 5. Security & Privacy Invariants

1. **Zero Secret Leakage**: Search events are signed with the per-device HMAC secret (`device.internalSecret`).
2. **Encrypted Query Storage**: Any search query flagged for safety concerns (self-harm, grooming, weapons) is stored in the AES-256-GCM **Snippet Vault** (`lib/snippetVault.ts`) using the family's master encryption key.
3. **No Third-Party Query Tracking**: Search queries are only analyzed by the local OSRA backend / AI Engine; they are never sold, logged to analytics, or forwarded to external third parties.
