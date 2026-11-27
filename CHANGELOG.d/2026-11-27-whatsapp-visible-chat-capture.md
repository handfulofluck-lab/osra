### Child Android — open WhatsApp conversations scan every new bubble (#1233)
- WhatsApp and WhatsApp Business now queue new visible incoming and sent message bubbles instead of selecting the longest text node. Conversation headers, presence/date lines and encryption notices are excluded.
- Bounded per-conversation history suppresses redraws and notification/screen duplicates while occurrence-aware dedupe still allows a genuinely new line with repeated text.
- JVM coverage includes short lines beside banners, sent lines, repeated text, scrolling/redraws, old history, bounded state and cross-source dedupe. Device verification remains a separate hardware row.
