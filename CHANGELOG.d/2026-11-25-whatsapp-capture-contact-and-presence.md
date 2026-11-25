### Child Android — WhatsApp burst dedupe, sender mapping and presence filtering (#1141, #1140)
- Preserves every decoded `MessagingStyle` line while preventing a repeated line from being queued again merely because its notification timestamp changed. Message senders now supply the contact before conversation and notification title fallbacks.
- WhatsApp presence/activity notices (`online`, typing and recording-audio forms across the existing WhatsApp UI locales) are no longer scanned as chat messages, preventing a status word from becoming a false concern contact.
- Android unit coverage uses a `Bundle[]` burst, per-line senders, duplicate redelivery, localized presence notices and a following real message. Hardware verification remains a separate device-gate claim.
