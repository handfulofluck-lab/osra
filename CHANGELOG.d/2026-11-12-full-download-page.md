### Website — the OSRA Kids Full download page, EN/AR (ADR-0039 PR E, roadmap 5.10)
- `site/android/` (English) and `site/android/ar/` (Arabic, RTL): what Full adds over the Play app, a
  five-step install with the Play Protect warning explained, and how updates arrive. The download link,
  version and size come from `/android/latest.json`.
  The page is published only together with the first Full release (maintainer, 12 Nov), so it never says
  "coming soon".
- A cartoon drawing for each install step and a 45-second silent walk-through video, both in English and
  Arabic (`site/android/img/`, `site/android/video/`), rendered from `scripts/site/full-install-art/`
  (`render.mjs` + `scenes.html`), so a wording change is a re-render, not a redraw.
- "Why it is not on Google Play" section in both languages.
- `site/android/privacy/`: the Full app's privacy notice, covering calls, SMS (first 120 characters),
  chat-app notifications, WhatsApp calls and searches. It is a draft for the maintainer's approval.
- `site/style.css`: long codes wrap instead of widening the page on a phone. The site stack serves `.js`
  as `text/javascript`.
