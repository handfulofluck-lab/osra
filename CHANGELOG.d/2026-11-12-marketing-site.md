### Website — osratech.com becomes the marketing front, in English and Arabic (roadmap 3.21)
- **Home:** a hero with the parent app's dashboard drawn in the design tokens (Calm in light, Control room in
  dark), eight feature cards, how it works in three steps, "Questions to ask any family app" with OSRA's answer
  to each, platforms with their beta status, the trust promise, an FAQ and a closing call to join the December
  beta by email.
- **Download page:** parent app and OSRA Kids cards with store buttons marked "coming with the beta", Windows and
  Mac cards, and an OSRA Kids Full card with no link until its release gate is signed. No installer is served.
- **Public guide:** install, pair, rules, commands and their delivery states, location, alerts and SOS, more
  devices, a second parent, troubleshooting and privacy, with a contents list.
- **Arabic** at `/ar/` for all three pages, pending the Arabic Language Bureau.
- **One generator:** `scripts/site/marketing/build.mjs` writes the six pages and the new top bar and footer of
  the legal pages (their text is unchanged); `--check` runs in `workflow-lint`.
