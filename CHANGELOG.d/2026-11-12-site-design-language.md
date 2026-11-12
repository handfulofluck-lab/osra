### Site — osratech.com wears the app's design language (ADR-0038, roadmap 3.19)
- **Before:** the site had its own look: an indigo link colour (`#3949ab`), a white page, the system font and bare
  lists. None of it matched the Calm (light) and Control room (dark) themes the maintainer chose on 2026-11-11.
- **After:** `site/style.css` takes every colour and radius from `docs/design/tokens.json` under the token's own
  name, light and dark, and follows the reader's setting. Type is IBM Plex Sans and IBM Plex Sans Arabic, served
  from `site/fonts/` (no third-party request). Every page has the same top bar with the OSRA «أسرة» wordmark, one
  card, and the same footer. Links in the top bar and rows are at least 44 high. The sheet names no physical side,
  so an Arabic page mirrors with `dir="rtl"` alone. The words of the privacy and deletion pages are unchanged.
- `docs/design/WEBSITE.md` is the site's part of the design language. `docs/design/tokens.json` arrives with this
  change, byte for byte the file of the 3.10 PR (#557), because the check reads it.
- New gate `scripts/check-site-design.mjs` in `workflow-lint.yml`, with a 21-case `--selftest`; two cases run the script as a command, and the workflow asserts the summary line of each run, so a run that prints nothing fails (it was silent on Windows until the #592 review: the entry-point test now uses `pathToFileURL`).
- `infra/terraform/site/main.tf`: `.woff2` is served as `font/woff2`. Nothing is applied by this change; the live
  site changes only at the next `terraform apply` of the site stack.
- The top bar and the browser tab show the OSRA logo the maintainer chose on 2026-11-12 (`site/icon.svg`,
  `site/apple-touch-icon.png`; roadmap 3.20).
