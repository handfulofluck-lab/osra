# ADR-0048 — Context around a flagged message: on-request, blurred 1+1, not a 3+3 archive

- **Status:** proposed for Karim's decision. This is a study, not approval to build or to change message
  collection. No real family's message behavior changes under this ADR.
- **Date:** 2026-11-24 (draft for review by 2026-11-25 18:00 UAE)
- **Owners:** Kimi (architecture and cost), Ahmed (privacy and security review), Claude (architecture review)
- **Related:** ADR-0006 (bounded snippets, not chat archives), ADR-0013 (retention and erasure),
  ADR-0030 (EU residency), ADR-0033 (Bedrock scoring and cost), issue #1057

## Context

The own-model alert correctly showed a harmful WhatsApp message and its exact text. Karim asks whether the
parent should also see three messages before and three after it, as some competitors provide, so the parent
can judge context instead of reacting to one isolated sentence.

This is a real product benefit: fewer false alarms, less guesswork about whether a message was a joke, and a
better chance that the parent responds proportionately. It is also a material expansion of surveillance:
OSRA would briefly hold messages that are not themselves harmful, including messages written by the other
person in the conversation. A parent cannot consent on that other person's behalf.

ADR-0006 deliberately chose bounded, event-driven snippets instead of a chat archive. Any context feature
must be an exception measured against that rule, not a quiet route around it. The proposal below is therefore
**off by default**, reveals as little as possible, and does not send context to a model.

## Recommendation

1. **Do not ship a default 3-before/3-after view.** Do not build a continuously uploaded conversation
   history, and do not score surrounding messages with Bedrock merely because they surround an alert.
2. **Offer an explicit, on-request, blurred 1-before/1-after option.** The default parent experience remains
   today's alert and flagged snippet. A parent who taps **Why this alert?** may then choose **Show a little
   context**, which reveals the immediately preceding message and, when it arrives, the immediately following
   message. Both start blurred behind a second tap and a short explanation that they may contain unrelated
   private conversation.
3. **Keep context collection on the phone until a flag occurs.** The Android child maintains a small rolling
   per-contact buffer of the visible notification text needed for the current message and its immediate
   predecessor. It is encrypted with a key protected by Android Keystore, capped at two messages per contact,
   expires within 15 minutes, and is never an unencrypted database or a general chat log. A message is uploaded
   only when the current message is already flagged by the existing detection path.
4. **Treat the following message as an append, never as a reason to delay an alert.** The flagged alert and
   push go immediately as today. If one subsequent message arrives within five minutes, the agent encrypts and
   uploads it as a separate context item linked to the alert. After five minutes the window closes permanently.
   No new screen-reading, OCR, accessibility expansion, or attempt to reconstruct messages the notification
   surface did not expose.
5. **Keep context out of AI.** The current message is scored exactly as today. Preceding and following context
   is display-only and receives no sentiment, category, summary, embedding, or "helpful explanation" call.
   Context therefore adds **zero model calls and zero model-token cost**.
6. **Delete context early.** Context ciphertext and its encryption metadata are deleted after 24 hours; the
   ordinary alert metadata remains subject to its existing retention policy. Erasure of a child, consent
   revocation, or unpairing deletes the context immediately through the same child-scoped cascade and removes
   the device buffers. Context is never included in a family export by default.
7. **Make it a separate, revocable choice.** This is not bundled into the existing monitoring consent. The
   parent enables it per child, sees exactly what is collected and the 24-hour lifetime, and can disable it
   again. For a child below 13, optional context stays off. For 13–15, it requires the parent's explicit
   opt-in plus an age-appropriate notice to the child. For 16–17, it requires the same notice and an
   age-appropriate assent flow. These age bands are a proposed minimum, not a legal conclusion; Ahmed and the
   lawyer packs must confirm them for each launch jurisdiction.
8. **Do not infer the other person's consent.** The UI states that context can contain the other person's
   messages. If a jurisdiction or the lawyer pack requires more than minimisation and notice, the feature does
   not launch there. If that cannot be answered confidently, the answer is **no context**, not a larger vault.

The recommended first experiment is thus **on-request blurred 1+1 with a five-minute following window and
24-hour deletion**. If that does not demonstrably improve parent decisions, it is removed rather than expanded
to 3+3.

## Why not the alternatives

| Option | Disposition |
|---|---|
| **No context** | This remains the privacy-safe default and the fallback wherever consent, legal review, or measurement is unresolved. It is not a rejection of the parent's need; it is the control against scope creep. |
| **On-request blurred 1+1 (recommended)** | Gives the parent the sentence that usually establishes tone without creating a general archive. Collection is still bounded, optional, encrypted, and short-lived. |
| **Default 1+1 for every alert** | Rejected for the first experiment: an interested parent should make an informed choice before unrelated conversation is collected. |
| **3 before and 3 after** | Rejected for launch. It collects six times the surrounding messages, increases the chance of capturing bystanders and sensitive topics, and has not been shown to produce a proportionate benefit. A later study would need evidence from the 1+1 experiment and fresh legal review. |
| **On-request 3+3** | Also not the first step. "On request" reduces how often context is viewed but does not reduce how much was collected and retained. |
| **Score or summarize the context with AI** | Rejected. It adds cost, another opportunity for a misleading model judgment, and more processing without first proving that raw bounded context is useful and lawful. |
| **Keep context for the alert's full 90-day/12-month retention** | Rejected as disproportionate. Context is deleted after 24 hours; only ordinary alert metadata follows the existing lifecycle. |
| **Upload the rolling buffer continuously for server-side detection** | Rejected outright. It recreates the full-chat surveillance design ADR-0006 rejected. |

## Architecture sketch

```text
Visible notification (existing Full-only path)
  -> per-contact encrypted rolling buffer, at most 2 messages, 15-minute TTL
  -> existing concern detection on current message only
       -> not flagged: buffer expires; no context leaves the phone
       -> flagged: immediate alert as today + encrypted predecessor context
            -> at most one following message, encrypted separately, five-minute window
                 -> EU snippet-vault path, owning-family read only, 24-hour deletion
```

Required implementation invariants, if Karim later approves a build:

- A context item is never written to logs, push payloads, alert titles, or lock-screen text.
- The parent read is owner/family scoped exactly like the current snippet vault and returns only the fields
  needed for display. It does not become a searchable conversation endpoint.
- The buffer cap, expiry, upload-on-flag-only, following-window close, family isolation, revocation, and
  24-hour deletion each need a fail-before test. The negative case is "five harmless messages leave no server
  row and are not retained on the phone after expiry".
- A late following message cannot create a second alert or trigger another model call. It can only append to
  the already identified alert's closed context window.
- The feature must not be represented as seeing an entire WhatsApp thread. Notification collapse, dedupe,
  sender identity uncertainty, and messages missed while the listener is off remain visible limitations.

## Cost and scale

These are planning estimates, not a quote. They assume **300 flagged alerts per family per month** (10 per
day), 200 bytes of text per context message, and 100 bytes for metadata plus AES-GCM packaging. They exclude
existing alerts and existing snippet traffic. Rounded values are deliberate; a production estimate must be
replaced with measured alert frequency, text size, and storage pricing.

| Context shape | Extra messages per alert | Approx. bytes per alert | 10k families / month | 100k families / month |
|---|---:|---:|---:|---:|
| 1 before + 1 after | 2 | 600 B | 1.8 GB | 18 GB |
| 3 before + 3 after | 6 | 1.8 KB | 5.4 GB | 54 GB |

At an illustrative $0.10/GB transfer price, that is **$0.18 vs $0.54 per month at 10k families**, and
**$1.80 vs $5.40 at 100k**. Transfer and raw storage are therefore not the main objection. Database rows,
indexes, vault reads/writes, operational review, and breach impact dominate. A 90-day context retention would
roughly triple the vault's total steady-state ciphertext volume; the recommended 24-hour deletion avoids that growth.

**AI cost is $0 under the recommendation** because context is not scored. For comparison only, if surrounding
messages were also sent to the model, a reasonable estimate is about **30% more tokens for 1+1** and **90%
more for 3+3** over the current per-scan input. Applying those multipliers to ADR-0033's existing volume
assumptions gives:

| Scoring assumption | 10k families, 1+1 / 3+3 | 100k families, 1+1 / 3+3 |
|---|---:|---:|
| Nova Micro baseline $108 per 1k families/month | $1,404 / $2,052 | $14,040 / $20,520 |
| Claude Haiku 5.5 baseline $287 per 1k families/month | $3,731 / $5,453 | $37,310 / $54,530 |

Those figures are not the cost of displaying context; they show why "just score the context too" is a
material product decision requiring its own evaluation and spend cap. Even if only flagged alerts and their
context were scored, the token multiplier and the same per-model formula would apply to that subset. No extra
Bedrock call is justified for the proposed experiment.

## Privacy, legal, and safety review required from Ahmed

- Whether GDPR-K data minimisation allows even on-device rolling context, and whether the five-minute
  following window and 24-hour retention are defensible under the proposed purpose limitation.
- The exact consent/assent wording and age bands, including how the child is told that the parent can reveal
  messages written by other people.
- Whether notification text from the other person creates additional duties, and how those duties vary across
  US COPPA, EU GDPR-K, UK, and the intended Gulf launch markets.
- Whether existing lawyer packs need a new data-processing record, subprocessor description, retention notice,
  DPIA, or an outright prohibition for some cohorts.
- Confirmation that EU-only storage, Android Keystore protection, the existing vault design, revocation, and
  erasure are sufficient technical controls, or whether stronger isolation is required.
- The breach analysis: unlike today's single flagged excerpt, context can expose unrelated health, religious,
  sexual, political, or identifying information about the child and bystanders. That risk cannot be answered
  by encryption alone.
- Whether family export, backups, support access, analytics, and crash reporting can all be guaranteed to
  exclude context.

If any of these answers is uncertain, the privacy recommendation is **no context**.

## Benefit versus risk

The benefit is not "more data". It is a parent making a better judgment with less uncertainty. The experiment
should therefore measure a product outcome, not engagement: reduced parent-reported false alarms, fewer
unnecessary escalations, and faster appropriate responses, without an increase in time spent reading other
people's conversations. A failed or ambiguous experiment ends at **no context**; it does not justify moving to
3+3.

## Decision points for Karim

1. Approve **no context**, the recommended on-request blurred **1+1** experiment, or another option.
2. Approve or change the five-minute following window and 24-hour deletion period.
3. Decide whether the age-band proposal is acceptable after Ahmed and legal review.
4. Decide whether any measured parent benefit justifies a later 3+3 study. No such build is authorized here.
