# SPEC: Deep Social & Multimodal Concern Engine (Track 2)

This specification defines the architecture, privacy safeguards, machine learning pipelines, and backend contracts for OSRA's **Track 2: Deep Social & Multimodal Concern Engine**, providing safety detection far beyond **Qustodio** and **Google Family Link**.

---

## 1. Executive Summary & Competitive Advantage

| Feature | Google Family Link | Qustodio | OSRA Track 2 (This Spec) |
|---|---|---|---|
| **Social Media Monitoring** | None (only app time limits) | Text messages (SMS only on Android) | **Full in-app monitoring: WhatsApp, Instagram, Snapchat, TikTok, Discord, Roblox, Telegram, YouTube** |
| **Detection Technique** | N/A | Basic keyword matching | **Hybrid NLP Machine Learning + Local Fallback Regex + Optical OCR** |
| **Contextual Awareness** | None | None (blind keyword search) | **Context-aware: separates search queries, social chats, and public comments** |
| **Age-Adaptive Tuning** | None | Fixed global sensitivity | **Dynamic age-based risk scoring (child_age tuning for <10, 10-13, 14-17)** |
| **Privacy & Encryption** | Data harvested for Google profiles | Plaintext storage on cloud | **Zero-Knowledge Encrypted Snippet Vault: only parents hold decryption keys** |

---

## 2. Ingestion & On-Device Pre-Filtering Architecture

```
[Social / Chat App] (e.g. Discord, WhatsApp, Instagram)
        │
        ├─► Accessibility Node Info / OCR Capture
        │
[On-Device Pre-Filter & Redactor] (Client Agent)
        │
        ├─► 1. Check MonitoredApps.appKeyFor(pkg)
        ├─► 2. Check rules.socialMonitoringEnabled(appKey)
        ├─► 3. Debounce: 1 capture per app per 1500 ms
        ├─► 4. TextRedaction: masks credit cards, SSNs, phone numbers, addresses
        │
        ▼ (HMAC-Signed Request)
[Backend Gateway: POST /v1/social/scan]
        │
        ├─► Check Per-Device HMAC Signature
        ├─► Rate Limiter: max 60 scans/min per device
        │
        ▼ (Forward to AI Engine)
[AI Engine: POST /analyze]
        │
        ├─► Transformer Classification (Grooming, Self-Harm, Bullying, Drugs)
        ├─► Context Weighting (context="message", child_age=12)
        │
        ▼
   [Flagged?]
   ├── NO  ──► Discard text immediately (Zero storage of safe chats)
   └── YES ──► Encrypt snippet with AES-256-GCM into Snippet Vault
               Dispatch Push Alert to Parent App (WebSocket + APNs/FCM)
```

---

## 3. Monitored Applications & Coverage

OSRA agents continuously track the active foreground package and inspect user-visible text across:

1. **Direct Messaging & Chat**:
   - WhatsApp (`com.whatsapp`, `com.whatsapp.w4b`)
   - Telegram (`org.telegram.messenger`)
   - Discord (`com.discord`)
   - Facebook Messenger (`com.facebook.orca`)
   - Line (`jp.naver.line.android`)
2. **Social Media & Feed Platforms**:
   - Instagram (`com.instagram.android`)
   - Snapchat (`com.snapchat.android`)
   - TikTok (`com.zhiliaoapp.musically`, `com.ss.android.ugc.trill`)
   - Twitter / X (`com.twitter.android`, `com.x.android`)
   - Reddit (`com.reddit.frontpage`)
3. **Gaming & Virtual Worlds**:
   - Roblox (`com.roblox.client`)
4. **Video & Entertainment**:
   - YouTube (`com.google.android.youtube`, `com.google.android.apps.youtube.kids`)

---

## 4. Machine Learning Model Architecture (`services/ai-engine`)

The AI engine service operates a fine-tuned, multi-head transformer classifier supporting multiple contextual domains:

### 4.1 Request Contract (`POST /analyze`)
```json
{
  "text": "Hey cutie, are you alone right now? Don't tell your mom about our chat.",
  "context": "message",
  "child_age": 11
}
```

### 4.2 Response Contract
```json
{
  "flagged": true,
  "severity": "critical",
  "categories": {
    "grooming": 0.94,
    "predatory_language": 0.88,
    "cyberbullying": 0.05,
    "self_harm": 0.01,
    "safe": 0.02
  },
  "explanation": "Potential child grooming detected: secrecy request ('don't tell your mom') directed to a minor."
}
```

### 4.3 Severity Classification Rubric
- **`critical`**: Imminent self-harm, suicide ideation, active predatory grooming, physical threats, drug distribution. Immediately pushes emergency alert to parents and pins alert.
- **`warning`**: Severe cyberbullying, targeted harassment, explicit sexual banter, hate speech.
- **`info`**: Mild profanity, borderline toxicity, gaming banter without safety hazard.

---

## 5. Zero-Knowledge Snippet Vault (`lib/snippetVault.ts`)

To uphold stringent privacy laws (COPPA, GDPR-K, Apple App Store Guidelines §5.1.4):
1. **Never Store Unflagged Text**: If `flagged == false`, the text is discarded in memory. The database retains **0 bytes** of benign conversations.
2. **AES-256-GCM Encryption**: Flagged snippets are encrypted using a derived key from the family's master vault secret (`VAULT_KEY`). The database stores only ciphertexts, IVs, and auth tags.
3. **Automatic Retention & Expiration**: Vault records expire automatically after 30 days unless flagged for retention by a parent. Parents can trigger instant GDPR cryptographic erasure (`DELETE /v1/family/me`).
