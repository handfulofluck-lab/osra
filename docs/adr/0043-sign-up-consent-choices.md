# ADR-0043 — Three separate choices at parent sign-up: terms, helping train OSRA's model, and marketing email

- **Status:** proposed (2026-11-16). Architecture is Claude's call. **All wording in this ADR is a DRAFT for
  the maintainer's lawyer** and must not ship to anyone outside the team until the lawyer has approved it
  (see "Legal hold" below).
- **Date:** 2026-11-16
- **Deciders:** Claude (architecture, QA); Karim (legal, product); the lawyer (final word on wording and
  legal basis). UI/UX Bureau (screens), Arabic Language Bureau (all Arabic). Built by Kimi / K31.
- **Related:** ADR-0002 (consent gate, per child), ADR-0013 (retention and erasure), ADR-0014 (family
  roles), ADR-0033 (production message scoring), ADR-0038 (design language). Privacy policy and terms
  (#649). The own-model training design (AI plan, "training" section).

## Context

The maintainer, 2026-11-16 (14:59 UAE), passing on a hint from his lawyer: sign-up should be simple, with
three things to tick: (1) accept the general terms and conditions, (2) help make OSRA's protection smarter
by sharing usage feedback (the separate training opt-in), (3) agree to receive offers and marketing updates
by email.

He wrote "radio buttons". Radio buttons let you pick **one** of several answers, so they cannot carry three
independent yes/no choices. This ADR uses **three separate checkboxes**. Only the first is required; the
other two start **unticked**. This is what the UAE data-protection law (PDPL, Federal Decree-Law 45/2021,
art. 6) and the GDPR (art. 7 and recital 32: a separate, specific, unambiguous, freely given consent;
silence or a pre-ticked box is not consent) expect, and what Google Play's and Apple's family policies
expect too.

What exists today (checked on `main@77a5e4f9`):

1. **Parent sign-up lives only in the parent app** (Flutter, one code base for Android and iPhone):
   the "Create account" section under the sign-in form in `apps/parent-app/lib/features/auth/login_screen.dart`,
   which calls `POST /v1/auth/register` (`services/api/src/routes/auth.ts`). There is no web sign-up: the
   invite page (`routes/linkPages.ts`, #804) only lets an existing account join a family and tells a new
   person to install the app first.
2. **No acceptance of the terms or privacy policy is recorded anywhere.** `RegisterSchema` takes email,
   password, names, region and time zone only; the app shows no link to either page. So the terms
   published in #649 bind nobody yet (already noted as a follow-up of #649).
3. **No marketing or training choice exists.** The server sends no marketing email today.
4. `ConsentRecord` in `schema.prisma` is the **per-child** monitoring consent of ADR-0002 (method,
   jurisdiction, granted/revoked). It is a different thing and is not changed here.
5. Parent thumbs up/down on alerts is not in the app yet. In the AI plan, step 1 (the answer, category,
   language and model version, no message text) is ordinary product use; step 2 (keeping short,
   de-identified parts of chats to train OSRA's own model) needs the opt-in in this ADR **and** a
   DPIA **and** the lawyer's yes. No real message is kept before all three.

## Decision

### D1. Three purposes, recorded separately

| Key | What the parent agrees to | Required? | Default | Can be withdrawn |
|---|---|---|---|---|
| `terms_privacy` | the Terms of Use and the Privacy Policy, at the shown version | yes, to create an account | unticked | only by deleting the account (existing delete flow) |
| `ai_improvement` | OSRA may keep short, de-identified parts of some of the family's chats to train OSRA's safety model (AI plan, step 2) | no | **unticked** | any time, in Settings; deletion within 30 days, per the AI plan |
| `marketing_email` | offers and product news by email | no | **unticked** | any time, in Settings, and by the unsubscribe link in every marketing email |

Nothing in the app depends on ticking box 2 or 3: protection, alerts and every feature work the same.

### D2. Data model: an append-only consent log

New table `ParentConsentEvent` (one row per tick or untick; rows are never updated or deleted while the
account exists):

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `parentId` | fk → Parent | cascade on account deletion (ADR-0013); see D7 for the deletion proof |
| `purpose` | text, one of the three keys | |
| `action` | `granted` \| `withdrawn` | |
| `textVersion` | text | id of the exact wording shown, e.g. `signup-v1` (see D4) |
| `documentVersion` | text, nullable | for `terms_privacy`: the published version of each page, e.g. `terms:2026-11-12,privacy:2026-11-12` |
| `locale` | `en` \| `ar` (later more) | the language the parent saw |
| `textHash` | char(64) | SHA-256 of the exact text shown in that language, from the server's copy table |
| `surface` | `app_signup` \| `app_settings` \| `app_reaccept` \| `email_unsubscribe` | where it happened |
| `clientVersion` | text, nullable | from `X-OSRA-Client` (ADR-0034) |
| `createdAt` | timestamptz(3), server clock | never the phone's clock |

No IP address and no device id are stored (data minimisation; question L5 for the lawyer).

The **current** state of a purpose is the newest row for (parent, purpose). A small read helper
`currentConsents(parentId)` returns `{ purpose: { granted, at, textVersion } }`; nothing else reads the
table directly.

### D3. API

- `POST /v1/auth/register` gains a required `consents` object:
  `{ termsPrivacy: true, aiImprovement: boolean, marketingEmail: boolean, textVersion, locale }`.
  The server refuses with `400 terms_not_accepted` if `termsPrivacy` is not `true`, and refuses an unknown
  or retired `textVersion` with `400 consent_text_outdated` (the app then refetches the copy). The account and
  its first consent rows are written in **one transaction**: no account exists without its acceptance row.
- `GET /v1/me/consents` returns the current state and, for each purpose, the copy to show (D4).
- `PUT /v1/me/consents/{purpose}` with `{ granted: boolean, textVersion, locale }` writes one row. Refused
  for `terms_privacy` with `granted:false` (withdrawal of the terms is account deletion). A guardian
  (ADR-0014) can change only their own `marketing_email`; `ai_improvement` is the owner's (D5).
- `GET /v1/me/consents/history` returns the parent's own rows (a data-subject access answer).
- One-click unsubscribe (RFC 8058, `List-Unsubscribe-Post`) on every marketing email writes
  `marketing_email / withdrawn / email_unsubscribe` without sign-in. The link carries a single-purpose
  signed token, never the parent id in clear.
- Older app versions that send no `consents` get `426 client_update_required`, the same path ADR-0034 uses,
  once this ships to production. On staging the field is optional until both apps have the new build.

### D4. Wording lives on the server, versioned

The exact checkbox text for each language is a server-side table keyed by `textVersion` + `locale`
(`services/api/src/lib/consentCopy.ts`), served by `GET /v1/me/consents` and by a public
`GET /v1/consent-copy?locale=` for the sign-up screen. The app renders that text; it does not carry its own
copy of the legal sentences. This is what makes `textHash` mean something, and it lets the lawyer's
changes ship without an app release.

Any change of meaning makes a new `textVersion`. A new **terms/privacy** version shows the re-accept screen
(D6) at the next sign-in. A new **ai_improvement** or **marketing_email** version does **not** carry an old
yes forward: an old yes stays valid only for what it said; a wider use needs a new yes.

### D5. Who decides for the family on training

Training uses the family's children's messages, so `ai_improvement` is effective for a family only while
the family **owner** has it granted. A guardian's tick is recorded but does not switch it on; a guardian's
untick is passed to the owner as a notice. The child's own yes from 13 (AI plan) is a separate, later
screen on the child app and is out of scope here. Question L3 asks the lawyer whether any parent's "no"
should stop it for the whole family instead.

### D6. Screens (to be designed with the UI/UX Bureau)

1. **Sign-up:** under the existing fields, three checkbox rows, each a full-width `CheckboxListTile`
   (48 dp minimum target, label tappable, links to the Terms and the Privacy Policy open
   `osratech.com/terms` and `/privacy` in the in-app browser, with `/ar/…` in Arabic). The Create account
   button stays enabled; pressing it without box 1 shows an inline error under box 1 and moves focus there
   (WCAG 3.3.1), rather than a greyed button the parent cannot explain. Box 2 has a "Learn more" link to a
   short plain-language sheet (what is kept, how names are replaced, 24 months maximum, how to stop).
2. **Settings → Privacy choices:** two switches (box 2, box 3), each with the date it was last changed,
   and a line "You accepted the Terms and Privacy Policy on {date}" with links. Turning a switch off takes
   one tap and no confirmation dialog, so withdrawing is as easy as giving (GDPR art. 7(3)).
3. **Re-accept screen** at sign-in for every account that has no `terms_privacy` row at the current
   version (all accounts created before this ships, and anyone after a terms change): box 1 required, boxes
   2 and 3 shown unticked. It blocks the app until box 1 is ticked; "Sign out" is the other way out.

### D7. Retention and deletion

Consent rows are kept for the life of the account. On account deletion (ADR-0013) they go with it, except
a minimal proof row kept for **up to 3 years** in a deletion-only table (`ConsentProof`: random id, purpose,
action, textVersion, createdAt; no email, no name), so OSRA can show that a consent existed if asked by a
regulator. Question L4 asks the lawyer whether to keep this proof at all and for how long.

### D8. Legal hold and switches

- **Box 1** is needed for the 2 Dec beta: without it the terms bind nobody. It ships with the wording the
  lawyer has seen so far, marked `signup-v1-draft`, and is replaced by `signup-v1` once he approves.
- **Box 2** ships behind the server switch `CONSENT_AI_IMPROVEMENT_VISIBLE` (off). While off, the box is not
  shown and the server refuses `aiImprovement: true`. It turns on only after the lawyer approves the
  wording **and** the DPIA is done (AI plan; January earliest). Even with the switch on, no message is kept
  until the separate collection switch of the AI plan is on.
- **Box 3** ships behind `CONSENT_MARKETING_VISIBLE` (off) until the lawyer approves and an email provider
  with one-click unsubscribe exists. No marketing email is sent today.

## Draft wording (English, DRAFT for the lawyer, `signup-v1-draft`)

1. *(required)* "I accept OSRA's [Terms of Use] and [Privacy Policy]." Error if not ticked: "To create an
   account, please accept the Terms of Use and Privacy Policy."
2. *(optional)* "Help make OSRA's protection smarter. OSRA may keep short parts of some of my children's
   chats, with names and other personal details replaced, to train OSRA's safety model, for up to 24 months.
   This is off unless I tick it, and I can turn it off at any time in Settings. [Learn more]"
3. *(optional)* "Email me OSRA offers and product news. I can unsubscribe at any time."

The maintainer's phrase "sharing usage feedback" is softer than what box 2 actually allows. The AI plan
records the rule that the opt-in's first sentence must say plainly that messages are kept, so the draft says
so. All Arabic goes through the Arabic Language Bureau; the Bureau's earlier title for this choice is
«ساعد في تحسين تنبيهات السلامة» (draft, not signed).

## Questions for the lawyer

- **L1** Is the wording of the three boxes acceptable under UAE PDPL and, for EU families, the GDPR?
- **L2** Should box 1 also confirm "I am 18 or older and the parent or legal guardian of the children I add"?
- **L3** For training, is the owner's yes enough for the family, or must every parent in the family say yes
  (and any one "no" stop it)?
- **L4** May OSRA keep a minimal proof of consent after account deletion, and for how long (draft: 3 years)?
- **L5** Is it right to store no IP address with a consent (draft: none)?
- **L6** Box 2 covers the children's chats. Is the parent's consent the right legal basis for under-13s,
  with the child's own yes from 13 added later?
- **L7** Does the marketing box need a separate line for marketing by push notification or SMS later, or is
  a new box enough when that comes?

## Consequences

- The terms finally bind every account, and every choice can be proven: what was shown, in which language,
  when, and when it was withdrawn.
- One new table, three endpoints, one copy table, two server switches; the parent app gains three checkbox
  rows, one settings screen and one re-accept screen. No change to the child apps.
- Existing accounts (team, pilot family) see the re-accept screen once.
- Not decided here: the child's own 13+ screen, the marketing email provider, the DPIA.

## Build split (issue to follow)

- **Server (Kimi):** migration, `consentCopy.ts`, register change, `/v1/me/consents*`, switches,
  `currentConsents`, deletion proof, tests (register without box 1 refused; old `textVersion` refused; a
  guardian cannot switch on training; withdrawal row written; nothing returned to another parent).
- **Parent app (K31):** sign-up rows, Settings → Privacy choices, re-accept screen, widget tests in EN and
  AR, light and dark screenshots for the UI/UX Bureau (#650), Arabic through the Arabic Bureau (#604).
- **Gate:** normal merge gate; Hydrogen reviews; Antigravity holds the security key (consent is personal
  data); UI/UX Bureau and Arabic Bureau lines before code verification.
