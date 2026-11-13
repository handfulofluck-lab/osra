# ADR-0042 — Ready for many languages: one language registry, a translation pipeline with gates, a language-neutral scorer with a per-language eval gate, and country packs for web blocking

- **Status:** proposed (2026-11-13). Architecture is Claude's call. The items marked **M1–M4** are the
  maintainer's (money, legal, launch scope). **No next language is chosen by this ADR.**
- **Date:** 2026-11-13
- **Deciders:** Claude (architecture, QA); Karim (money, legal, which language and when). Built by Kimi and
  K31; Ahmed for iPhone, Mac and the security review of the blocklist pipeline.
- **Related:** ADR-0006 (snippets), ADR-0015 (Android DNS filter), ADR-0020 (family timezone), ADR-0033
  (scoring on Bedrock in the EU), ADR-0034 (capability report), ADR-0036 (Mac agent), ADR-0041 (seven
  clients). `docs/LOCALIZATION.md`, `services/ai-engine/EVAL.md`. Roadmap rows 3.1, 3.21, 4.1–4.3.

## Context

The maintainer, 2026-11-13 12:26Z: *"no next language decision for now but the app should be built from an
architecture point of view to support many languages … in an efficient and cost effective way, and what are
the changes needed if any to our current architecture."* His working assumption: a list of bad words per
language is easy to get, the list of domains to block is public knowledge, and the rest is interface text
that can follow Samsung's, Apple's and Google's own translations, so new markets should be cheap.

This ADR tests that assumption against the repository (`main@9f9ad8a`) and records what has to change.

### What exists today

| Surface | How it holds text today | Ready for a third language? |
|---|---|---|
| Parent app (Flutter, Android + iPhone) | 835 keys in `app_en.arb` / `app_ar.arb`, ICU plurals, a parity and RTL-overflow test (`localization_test.dart`), language picker | **Mostly.** The picker, `appLocaleFromName` and the parity test name `en` and `ar` by hand. |
| Android child (Play + Full) | `values/strings.xml` (66) and `values-ar` (63), one `<plurals>` | **Partly.** `sos_tile_label` has no Arabic. Seven notification lines and the SOS screen buttons are English literals in Kotlin (`FilterVpnService`, `LocationService`, `CommandPollWorker`, `CommandDispatcher`, `SosActivity`). The manifest does not set `android:supportsRtl`. |
| OSRA Kids (iPhone child) | `Localizable.strings` + `.stringsdict`, EN and AR, 95 lines each, all through `L10n.tr` | **Yes.** The cleanest client. |
| Windows agent | No resource files. Every line a child or parent reads (`PairingDialog`, `LockOverlay`, block notices) is an English literal in C# | **No.** It is English-only, **including for Arabic**, the first launch language. |
| Mac agent | Not built yet (ADR-0036: shares the iPhone Swift core) | Build it on `L10n` from the first line. |
| Server: email | `templates.ts` carries English and Arabic side by side in code and sends **both** in one message, because the server does not know a parent's language (`Locale = "en" | "ar" | "both"`) | **No.** A third language cannot be added to a two-language-in-one email. |
| Server: alerts | The alert **title** is translated in the app from the category. The alert **body** is an English sentence written by the server (`"A concerning search was conducted on …"`, `"… sent a flagged message on …"`) and stored | **No.** An Arabic parent reads an English body today. |
| Server: push | iPhone alerts use loc-keys from the app bundle; Android is data-only and built in the app | **Yes.** |
| Database | `Family.region` (a market) and `Family.timezone`. No language anywhere | **No.** |
| Website | `scripts/site/marketing/build.mjs` + `copy.en.mjs` / `copy.ar.mjs`; privacy, terms and delete-account are single English pages | **Partly.** The builder assumes exactly two languages (`c.other`). |
| Store listings | `app-store/renderer` takes a caption file per language | **Yes.** |
| Message scorer | The prompt says "in English or Arabic"; the eval harness hard-codes `LANGS = ("en", "ar")` and `positives_ar`-style fields | **No**, but the design is right (see below). |
| Web blocking | `data/blocklists/pack.json`: 13 categories, **121 domains typed by hand**, served whole as JSON | **No**, in any language. |

Text-handling traps checked: the C# agent uses `OrdinalIgnoreCase` / invariant casing everywhere (35 uses,
no culture-sensitive `ToLower()`), so the Turkish dotted-i problem does not bite host matching. Kotlin,
Dart and Swift casing calls are locale-independent by default.

### The assumption, tested

**1. "A bad-word list per language is easy to get."** Getting one is easy. It is the wrong tool, and our own
numbers say so:

- `EVAL.md`: the English keyword rules in `model.py` flag **30 %** of harmful English messages and **5 %**
  of self-harm ones. Grooming, self-harm and bullying are said in ordinary words ("don't tell your mum",
  "nobody would miss me"). Word lists find swearing, which is the least dangerous category.
- A list also raises false alarms on innocent words, and children defeat it with spelling tricks and by
  writing their language in Latin letters (Arabizi, Roman Urdu, Hinglish).
- The public lists are thin and unevenly licensed. LDNOOBW (CC BY 4.0) has 28 languages and no Urdu,
  Indonesian, Malay or Bengali; its authors call it a "best guess". HurtLex covers 50+ languages but is
  **non-commercial** (CC BY-NC-SA), so we cannot ship it.

The good news is that OSRA does not depend on word lists. ADR-0033 already scores messages with a large
model, and such a model reads most major languages without a per-language rebuild. So content safety in a
new language costs **a test set and a measurement, not an engineering project**. That is cheaper than the
maintainer feared on engineering and dearer than he hoped on review: about 2–4 weeks of team time and
$1–3K of native review per language (earlier estimate, `strategy/2026-11-13-next-languages-markets.md`).

**2. "The domain list is public knowledge."** True, with three corrections:

- **Licences.** UT1 (University of Toulouse, ~4.6 M adult entries) is CC BY-SA 4.0: usable commercially, with
  attribution, and our compiled list must be offered under the same licence. HaGeZi (78 K adult, up to 633 K
  gambling) is GPL-3.0, which is a harder fit inside a closed app. Cloudflare's family resolver publishes no
  permission to build a paid product on it. A lawyer reads the chosen licences once (**M2**).
- **It is mostly not a language problem.** Adult sites are global, so one worldwide list does most of the
  work in every market, and SafeSearch does much of the rest. What differs by **country** is betting,
  dating and local sites, where public lists are weakest, and what is legal (betting is lawful in the UK
  and banned in Türkiye and the Gulf).
- **Our architecture cannot carry such a list today.** 121 hand-typed domains in one JSON file is a demo.
  The real work is the pack format and pipeline (D8), needed for English and Arabic too.

**3. "The rest is interface text; follow Samsung, Apple and Google."** Right for the words those systems
own, and we already do it for Arabic (the Bureau's Samsung «الضبط» vs stock «الإعدادات» table):

- Google: the Android source is Apache-2.0 and carries every Settings string in 80+ languages. Automatable.
- Apple: glossaries are downloadable with a developer account. Use as reference; do not commit them to a
  public repository (redistribution terms are unclear).
- Microsoft: the Terminology Collection is a free download.
- Samsung: no public glossary. Read off a device set to that language, as the Arabic Bureau does.

But system terms are a small share of our text. The maintainer's 75 % rating of the Arabic download page
was about long sentences, not labels: consent wording, block screens, alert text, the guide, store pages.
That prose needs a native reader in every language. Machine drafting makes it cheap, not free.

**What the assumption leaves out** is the largest cash line: local law per country (privacy notice, terms,
registrations, child-consent age), then store listings and support. From the earlier estimate, legal is
$1–6K per country against $1.5–5K for all native review.

**Verdict.** The direction is right: with the changes below, a new Latin-script language is roughly 1–2
team-weeks and $4–16K, most of it lawyers and reviewers, not engineering. The reason is a multilingual
model and a pipeline, not word lists.

## Decision

### D1. One language registry

A single file, `packages/shared-types/locales.json`, lists every language OSRA knows: BCP-47 tag (`ar`,
`tr`, `pt-BR`), direction, script, CLDR plural categories, whether it needs extra line height (Urdu
Nastaliq, Thai, Hindi, Burmese), and a **status per surface**: `draft`, `beta` or `released` for each of
the seven clients, email, site, store, and the scorer. A check fails when a client offers a language the
registry does not mark `beta` or `released` for it. Pickers, parity tests and the site builder read the
registry instead of naming `en` and `ar`.

### D2. Each platform keeps its native catalog; nothing user-visible is a literal

ARB (Flutter), `strings.xml` + `<plurals>` (Android), `.strings` + `.stringsdict` (iPhone and Mac), and new
`.resx` resources for the Windows agent. A lint per client fails the build on a user-visible literal.
Counted text always uses the platform's plural form. Names and times inside a sentence are
direction-isolated (the #506 rule) on every client.

A script, `tools/l10n`, exports all catalogs to one sheet per language (key, English, context note,
screenshot link, current translation) and imports the result. That sheet is what a Bureau and a paid
reviewer work on. No hosted translation service for now (see Alternatives).

### D3. The server learns each parent's language and stops writing sentences

- `Parent.locale` (BCP-47, nullable), sent by the parent app at login and whenever the picker changes, the
  way ADR-0020 handles the timezone. `null` keeps today's English + Arabic email.
- Emails move from two-languages-in-code to one template set per language, chosen by `Parent.locale`.
- An alert carries a **type and parameters** (`search_flagged`, `{engine}`), and the app renders the
  sentence. The server keeps writing the English `body` so older apps still show something.
- The child device reports its language on telemetry (ADR-0034), so a parent screen can say which language
  a child's phone is in.

### D4. Fallback

Exact tag, then the base language, then English (`pt-BR` → `pt` → `en`). One screen never mixes two
languages: a catalog is `released` on a client only when every key is present.

### D5. Translation pipeline and its gates

1. **Source.** English, with a context note on every key.
2. **Platform terms.** A script pulls the matching Android source strings for the language; Apple, Microsoft
   and Samsung terms are looked up by the Bureau. The result is a machine-readable glossary,
   `docs/l10n/<tag>/glossary.json`, with required and banned terms.
3. **Machine draft**, with the glossary and the Bureau's rules.
4. **Language Bureau** (one thread per language, the Arabic model) reviews and signs
   `<Language>-Bureau: reviewed <sha>`.
5. **Paid native reader**, by tier. Tier A (consent, legal, purchase, block screens, alert text, store
   listing): every word. Tier B (main screens): every word once, then changes only. Tier C (rare and
   technical lines): a sample.
6. **CI gates**, per language in the registry: identical key sets; identical placeholders; every CLDR plural
   category present; glossary terms respected; no overflow at 320 px, in RTL for RTL languages and at the
   tall line height for tall scripts; a **pseudo-language** build (longer, accented text) that exposes
   literals and clipped layouts before any real translation exists.
7. The UI/UX Bureau signs screenshots in the new language, as it does today.

### D6. Fonts and layout

System fonts in the apps; a bundled font only where the system has none worth using (the site already
bundles IBM Plex Sans Arabic). Text heights come from line-height tokens, never a fixed pixel height, so a
tall script grows the row instead of clipping.

### D7. The scorer is language-neutral, and each language passes its own gate

- The prompt stops naming languages. Categories and the JSON contract do not change.
- The eval harness takes languages from a list. Banks move from `positives_ar` fields to one directory per
  language. The Phase 4 gate (recall ≥ 0.85 on self-harm and grooming at precision ≥ 0.6, hard-negative
  false positives ≤ 0.05) applies **per language, and per writing form**: Latin-letter Arabic, Roman Urdu
  and code-mixed text get their own rows. The Arabic set forbids transliteration today (`eval/README.md`),
  so **Arabizi is unmeasured now**, in our first market.
- The scorer's row in the registry is `released` for a language only after its gate passes. A message in a
  language that has not passed is **still scored** (a child is not less protected for writing in French),
  but OSRA does not claim that language, and `EVAL.md` shows which languages are measured.
- **Word lists have one job:** the offline floor when Bedrock cannot answer. Per language, a short list of
  high-precision phrases (self-harm first), drafted by the model, checked by the native reader, and
  measured by the same eval. Never the main detector.

### D8. Web blocking: a compiled base pack plus country packs

- **Pack v2.** A build job pulls the chosen sources, records each source's licence and date, and compiles
  a compact binary pack: one worldwide base (adult, proxies, malware-style categories) and small
  **per-country** add-ons (betting, dating, local sites). Devices fetch the base plus the family's country
  pack, with delta updates. The on-device format must hold at least a million names within a few
  megabytes; the exact structure is a spike for Kimi with a memory and lookup-time budget on the Flip4.
- **Category defaults by country**, not by language (`Family.region` is too coarse; a country field is
  needed, **M3**).
- **iPhone:** Apple's own adult filter is the base there; our list is the supplement.
- **Growth loop:** a parent's "report a site", the Bureau reader's local list, and later the scorer
  classifying unknown domains.
- A registry of **messaging apps and search engines per market**: today the agents know WhatsApp,
  Instagram, Snapchat, TikTok, Discord, Telegram and LINE, and Google, Bing, DuckDuckGo. Yandex (Türkiye),
  imo (Gulf, South Asia), BiP, Zalo, KakaoTalk and VK are absent.
- Phone-number and address redaction (`TextRedaction.kt`) is checked against each market's formats.

### D9. Legal and store are per country, tracked in the registry's release checklist

A language is `released` on the store and site surfaces only with: privacy notice and terms in that
language reviewed by a local lawyer; the country's child-consent age in the consent flow; registrations
where the law asks for them; store listing through the renderer; a support answer path in that language.

## What changes, in order

| # | Change | Who | Size (estimate) | When |
|---|---|---|---|---|
| 1 | Android child: move the English literals to resources, add the missing Arabic key, `supportsRtl` | Kimi/K31 | 2–3 days | **Before closed beta A.** These are Arabic defects today |
| 2 | Windows agent: `.resx` resources, Arabic catalog, RTL dialogs | K31 | 1 week | **Before the Windows closed beta (22 Jan).** Same reason |
| 3 | Alerts carry type + parameters; the app renders the body | Kimi | 3–4 days | Before Public 1 if it fits, else first after |
| 4 | `Parent.locale`; emails per language | Kimi | 3–4 days | After Public 1 |
| 5 | Registry (D1), pickers and tests read it; site builder takes N languages | Kimi/K31 | 1 week | After Public 1 |
| 6 | `tools/l10n` export/import, glossary JSON, Android-source term pull, CI gates incl. pseudo-language | K31, Claude verifies | 1–1.5 weeks | After Public 1 |
| 7 | Eval harness per language; neutral prompt; re-run both gates; Arabizi rows | K31 authors, Claude labels blind | 1 week + rows | After Public 1 |
| 8 | Pack v2 pipeline and on-device format (spike first) | Kimi, Ahmed reviews | 2 weeks | After Public 1; needed for EN/AR quality too |
| 9 | Mac agent on `L10n` from the start | Ahmed | no extra cost | With the Mac build |

Rows 1–3 are not "many languages" work: they are places where the first launch language, Arabic, still
shows English. Rows 4–8 are about 5–7 team-weeks, once. Nothing here moves a date in the 13 November
re-plan unless the maintainer says so (**M1**).

After that, a new language is: catalogs drafted and reviewed (D5), eval set authored and gate passed (D7),
country pack and app registry checked (D8), legal and store (D9). For a Latin-script language that is about
1–2 team-weeks plus 3–4 calendar weeks of review, and $4–16K cash, mostly legal. RTL languages reuse the
Arabic work. Urdu, Thai, Hindi and similar scripts add a layout pass on all seven clients.

## What Karim decides

- **M1.** Whether rows 1–3 join the release-readiness list now (recommended: yes; they are Arabic defects).
- **M2.** A one-time lawyer's read of the blocklist licences (CC BY-SA, GPL) before pack v2 ships, or
  instead a paid commercial category feed (needs quotes; expect a yearly fee).
- **M3.** Storing the family's country (for the country pack, consent age and legal text), with the privacy
  wording that goes with it.
- **M4.** The per-language budget, when a language is chosen. Not needed now.

## Alternatives considered

- **Per-language word lists as the detector.** Rejected on our own measurements (30 % English, 0 % Arabic)
  and on licences.
- **A hosted translation platform (Crowdin, Lokalise and similar).** Useful beyond about five languages;
  today it adds a monthly fee and a second source of truth for two languages. The export/import sheet keeps
  the door open.
- **One shared catalog for all clients.** Rejected: each platform's plural and resource system is
  different, and the native formats are what the tools, stores and tests understand.
- **The server renders all text.** Rejected: agents must show a block screen offline.
- **A DNS filtering service instead of our own pack** (Cloudflare family resolver, CleanBrowsing, NextDNS).
  Rejected as the base: the child's lookups would go to a third party, the terms for paid products are
  unclear or priced per user, and the parent's own allow/block rules must still work on the device.
- **Score only languages that passed the gate.** Rejected: it lowers protection for exactly the bilingual
  children OSRA serves.

## Consequences

- Good: a new language becomes a checklist, not a project; Arabic gets fixes it needs anyway; the claim
  "supported language" has a measured meaning.
- Bad: 5–7 team-weeks that ship no visible feature; every new key now needs a context note; each language
  adds standing work on every release (reviewer, eval upkeep, support); a share-alike source would oblige
  us to publish our compiled list; storing a country is one more personal data field.
- Not solved here: image and voice content; a model for languages the Bedrock candidates read poorly
  (measured per language when one is chosen).

## Evidence

- Repository at `main@9f9ad8a`: files named in the table above; `services/ai-engine/EVAL.md` for the
  30 % / 0 % figures; `services/api/data/blocklists/pack.json` for the 121 domains.
- Licences read 2026-11-13: [LDNOOBW](https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words)
  (CC BY 4.0, 28 languages), [HurtLex](https://github.com/valeriobasile/hurtlex) (CC BY-NC-SA 4.0),
  [UT1](https://github.com/olbat/ut1-blacklists) (CC BY-SA 4.0), [HaGeZi](https://github.com/hagezi/dns-blocklists)
  (GPL-3.0), [Cloudflare 1.1.1.1 terms](https://developers.cloudflare.com/1.1.1.1/terms-of-use/).
- Sizes, weeks and dollar figures are Claude's estimates, not quotes.

## Claims a verifier can test

1. On `main@9f9ad8a`, `apps/agent-desktop` contains no `.resx` file and no Arabic text.
2. `values-ar/strings.xml` lacks `sos_tile_label`; the child manifest has no `android:supportsRtl`.
3. `services/api/src/routes/content.ts` and `social.ts` write English alert bodies.
4. `eval/run_eval.py` hard-codes `LANGS = ("en", "ar")`; `eval/README.md` forbids transliterated Arabic.
5. `pack.json` holds 121 domains across 13 categories.
