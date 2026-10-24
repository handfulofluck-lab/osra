# ADR-0033 — A child's message is scored on Amazon Bedrock inside the EU; DeepSeek's own API stays for made-up test messages

- **Status:** proposed. The technical half is Claude's (architecture). Three points are Karim's and are
  listed under *What Karim decides*. No real family's message goes to a model until all three are settled.
- **Date:** 2026-10-24
- **Deciders:** Claude (architecture + testing); Karim for the model terms, the spend cap and the privacy wording
- **Related:** roadmap 4.1 and 4.4 (the decision both rows defer to), ADR-0006 (snippets, not chats),
  ADR-0016 (`play` and `full`), ADR-0028 and ADR-0030 (hosting, Frankfurt), `services/ai-engine/EVAL.md`

## Context

**Today a real family's phone would be checked by English keyword rules only.**

- **On the phone:** the agent redacts what it captures (`social/TextRedaction.kt`: card numbers, phone
  numbers, addresses) and posts it to `POST /v1/social/scan`.
- **In the API:** it asks `AI_ENGINE_URL/analyze`, with a 5-second timeout, and falls back to
  `localKeywordCheck` (`routes/social.ts`, `routes/content.ts`).
- **In the ai-engine:** it scores with DistilBERT only when `MODEL_PATH` points at a model. None exists, so it
  runs the English regexes in `model.py`.
- **On staging:** the ECS stack (`infra/terraform/env`) has no ai-engine and sets no `AI_ENGINE_URL`, so every
  scan goes straight to the API's own keyword check.

On the committed evaluation set, the rules layer flags **12 %** of harmful English rows and **0 %** of harmful
Arabic rows, in all seven categories (`EVAL.md`). The first launch market speaks Arabic.

**The one scorer that has passed the Phase 4 gate is DeepSeek's own API.** It was measured on 21 October as an
evaluation scorer (`eval/deepseek_scorer.py`, roadmap 4.1). It reached recall ≥ 0.85 on `self_harm` and
`grooming` at precision ≥ 0.6, in both languages.

It was kept out of production on purpose. An evaluation sends messages we wrote about children who do not exist,
and a production scorer would send a real child's message. DeepSeek's privacy policy (last updated 10 February
2026) says it "collect[s], process[es] and store[s] your Personal Data in People's Republic of China". It also
lists user input among the data it uses to train its models. In addition, `docs/SPEC-CONTENT-SAFETY.md` promises
that search queries are "never … forwarded to external third parties".

**Our own model (4.4) cannot be built yet.** The set has 1,179 synthetic rows. That is enough to measure a scorer
and too few to train one. There are no real labelled messages, and there should be none until a consented way to
collect them exists.

So the question both roadmap rows defer to is: which model scores a real child's message, where does it run, and
what happens to the text.

## Decision

1. **Where.** A real child's message is scored only by a model on **Amazon Bedrock, in our own AWS account,
   inside the EU**, called from Frankfurt (`eu-central-1`, ADR-0030). The call takes one of three routes:
   - in-region in Frankfurt;
   - Bedrock's **EU** cross-region inference profile (model IDs prefixed `eu.`), which keeps processing in EU
     member-state regions;
   - in-region in another EU member-state region, such as Stockholm (`eu-north-1`).

   **Never a global profile, never a non-EU region, and never an endpoint outside AWS.** Staging calls the same
   way and only ever sends synthetic messages.

2. **The model is chosen by measurement, not by name.** A new `eval/bedrock_scorer.py` scores the set with the
   **same system prompt and JSON contract** as `deepseek_scorer.py`. Both scorers read the prompt from one shared
   module, so a prompt change re-scores both.

   Every candidate under *Candidates* runs twice on `--split test`, which is held out from tuning and has never
   been run, and once on `all`. A candidate **passes** when all four of these hold:
   - it meets the Phase 4 gate on `test` in both languages, on both runs;
   - its hard-negative false-positive rate is ≤ 0.05 in each language. That is DeepSeek's Arabic rate, and a
     false alarm is what a parent sees.
   - a refusal or an unreadable answer is scored as flagged, never as safe, so refusals on safe rows show up as
     false positives and count against this limit;
   - it runs with Bedrock's `data_retention_mode` set to `none` (decision 3).

   Among the candidates that pass, the lowest measured cost per 1,000 scans wins. At equal cost, in-region beats
   the EU profile. The measured cost comes from each response's token counts, not from this ADR's estimate.

   **If no candidate passes, nothing ships, and the rules layer stays visibly the floor.** DeepSeek's own API is
   not the fallback.

3. **AWS keeps none of the text.** Bedrock's `data_retention_mode` is set to `none` at account level in every
   region the chosen route can reach. Bedrock's documentation says: "No request or response data is written to
   durable storage by AWS or shared with the model provider". A model that does not list `none` in its
   `allowed_modes` is not eligible unless we are granted zero data retention for it. For Claude models, Anthropic
   grants that, through the AWS account manager. Bedrock's model-invocation logging stays off, and a check fails
   if a Terraform `aws_bedrock_model_invocation_logging_configuration` appears. Only text is sent, never an image
   or a screenshot.

4. **How it runs.**
   - **Service:** the ai-engine becomes a **private ECS Fargate service** in the `env` stack. It has no public
     load balancer, only the API can reach it, and `AI_ENGINE_URL` is set in the API task.
   - **Permissions:** its task role may call `bedrock:InvokeModel` on the chosen model's ARNs (and, for a
     profile, the profile's) and nothing else.
   - **Network:** it reaches Bedrock through a VPC interface endpoint, so the text does not cross the public
     internet.
   - **Logging:** no message text goes into logs, traces or metrics. A log line carries the model ID, latency,
     categories, outcome and token counts.
   - **Storage:** the ai-engine keeps nothing. The API keeps its ADR-0006 rule: safe text is dropped, and a
     flagged snippet is encrypted into the vault.

5. **When the model cannot answer, the rules do.**
   - A Bedrock error, a throttle or a 3-second timeout falls back to the regexes, as today.
   - The response carries `scorer: "rules"`, so a metric counts fallbacks.
   - An alarm fires when more than 5 % of scans fall back within 15 minutes.
   - The API's 5-second timeout stays the outer bound.
   - A refusal is not a fallback. It is scored as flagged (decision 2), because refusals cluster on exactly the
     messages a parent needs to see.

6. **Spend has a ceiling, in two places.**
   - **Per family:** a daily cap of model calls (default 1,000). Above it the rules answer, and a metric counts
     it. This sits on top of the existing limit of 60 scans a minute per device and the phone's 1.5-second
     debounce per app.
   - **For the account:** an AWS Budgets alarm watches Bedrock spend against the monthly figure Karim sets. At 80
     % it emails him. At 100 %, a Budgets action attaches a deny policy to the ai-engine's task role, so scoring
     falls back to the rules instead of the bill growing. Removing that policy restores scoring.

7. **DeepSeek's own API stays where it is.** `eval/deepseek_scorer.py` scores synthetic messages only, and its key
   stays a repository Actions secret. No ECS task definition may carry that key, and `model.py` and the API never
   import from `eval/`.

8. **Our own model (4.4) is the path at scale, not at launch.** 4.4 starts when the Bedrock bill passes $1,000 a
   month or the product reaches 10,000 families, whichever comes first. It builds a first-line classifier that
   answers "clearly safe" inside the ai-engine and sends only the rest to Bedrock: the ~5 % that ADR-0028 assumed.
   It is trained on synthetic sets, public datasets, and the chosen model's labels **on synthetic text**. It is
   never trained on a real child's message unless Karim decides on a consented way to collect them.

## Candidates

Prices are on-demand list prices in US$ per 1M tokens, from AWS's Price List API (October 2026). Availability
comes from each model's Bedrock model card. An entry in the price list does not prove a model is available in
that region. The cards say whether it is.

The monthly figures use these assumptions. They are estimates, and the eval run replaces them with measured
token counts:

- **Volume:** 4,500 scans per family per month (100 a day per child, 1.5 children per family).
- **Input:** 280 tokens per scan. The system prompt is about 240 tokens, and the message is a few dozen; Arabic
  tokenises to more tokens than English.
- **Output:** 60 tokens per scan: eight category scores, with thinking off.

| Model | Route from Frankfurt | In | Out | Per family per month | 1,000 families | Arabic in the model's documentation |
|---|---|---|---|---|---|---|
| Amazon Nova Micro | EU profile (Frankfurt, Stockholm, Ireland, Paris) | 0.046 | 0.184 | $0.11 | $108 | yes |
| GPT OSS Safeguard 20B | in-region | 0.084 | 0.24 | $0.17* | $171* | not stated |
| Amazon Nova Lite | EU profile | 0.078 | 0.312 | $0.18 | $183 | yes |
| Ministral 3 8B | in-region | 0.18 | 0.18 | $0.28 | $275 | yes |
| Claude Haiku 5.5 | EU profile (Frankfurt, Stockholm, Milan, Spain, Ireland, Paris) | 0.11 | 0.55 | $0.29 | $287 | not stated for 5.5 (Haiku 4.5: 92.5 % of English) |
| Ministral 3 14B | in-region | 0.24 | 0.24 | $0.37 | $367 | — |
| Qwen3 32B | in-region | 0.20 | 0.79 | $0.47 | $465 | several Arabic varieties; Gulf Arabic not listed |
| DeepSeek V3.1 | in-region in Stockholm (not offered in Frankfurt) | 0.58 | 1.68 | $1.18 | $1,184 | — |
| Mistral Large 3 | in-region in Stockholm (not offered in Frankfurt) | 0.60 | 1.80 | $1.24 | $1,242 | — |

\* GPT OSS Safeguard always reasons before it answers. Its reasoning tokens are billed as output and are not in
this estimate.

- **Prices on the EU profile** are 10 % above the global profile's. That 10 % is the price of decision 1.
- **Not available from the EU:** Llama 3.x and 4, DeepSeek R1, and Cohere Command R/R+. Claude 3 Haiku reached
  end of life in Frankfurt on 2026-09-10.
- **Prompt caching does not help yet.** The prompt is below even Claude Haiku 5.5's 512-token minimum, so every
  scan pays full input price.
- **Batch inference** is half price, but its answers arrive hours later. That is no use for a self-harm alert.

For scale, ADR-0028 puts hosting at $0.43 per family per month at 1,000 families and $0.12 at 10,000. Even the
cheapest candidate is a visible share of the bill, and Claude Haiku 5.5 at 10,000 families (~$2,900) would cost
more than all the hosting together. That is why decision 8 makes 4.4 the scale path.

## Reasoning

- **AWS is already where the child's data lives.** Location history, alerts and the encrypted snippets are in
  our AWS account in Frankfurt (ADR-0030). Bedrock runs inside the same account, under the same AWS agreement.
  So scoring a message there adds no new company that holds a child's data. With `data_retention_mode: none`,
  it also adds no new copy. Bedrock's FAQ says inputs and outputs "are not shared with any model providers", and
  that AWS and the providers "will not use any inputs to or outputs from Amazon Bedrock to train" models.
- **The EU profile keeps the residency promise.** AWS: "Cross-region inference requests to an inference profile
  tied to a geography (such as US, EU, and APAC) stay within that geography." Every destination listed for the
  candidates is an EU member state. The global profile is cheaper because it may leave the EU, and that is
  exactly what decision 1 rules out.
- **We measure rather than pick, because the published numbers do not answer our question.** No model card
  reports recall on Arabic grooming messages sent to teenagers. Our set does, and it has a held-out half that no
  prompt was tuned on. The same gate that kept DeepSeek out of production decides here, with a second run and a
  false-alarm limit added, because "one model, one run" is the limit `EVAL.md` already states.
- **A refusal counts as flagged, because a silent drop to the rules is what we are leaving.** A model that
  declines a grooming message, and is then treated as "safe", reproduces the 0 % Arabic recall this ADR exists
  to end. Scoring refusals as flagged makes their cost visible in the eval as false alarms, and the 0.05 limit
  prices it.
- **A hard ceiling on spend, not just an alarm.** A bug that loops scans on one phone, or a family whose teenager
  chats all night, must not become an open-ended bill. The worst a family can cost on Claude Haiku 5.5 at the
  1,000-call cap is about $0.06 a day. The Budgets action makes the account ceiling real, and the failure mode
  at the ceiling is today's behaviour, not an outage.

## Alternatives rejected

- **DeepSeek's own API in production.** It is the scorer we have measured, and the cheapest route to
  "measured". Rejected: by its own policy, DeepSeek processes and stores data in the People's Republic of China
  and may train on what it receives. Sending a real child's message there is a transfer the product cannot
  explain to a parent, and it would break the promise in `SPEC-CONTENT-SAFETY.md`. The same model family on
  Bedrock in Stockholm is a candidate above, at about four times Claude Haiku 5.5's price.
- **The global cross-region profile.** 10 % cheaper on every token. Rejected: it can route outside the EU, and
  ADR-0030 already tells Gulf families that their data is stored in the EU.
- **Hosting an open model ourselves on a GPU instance.** Full control and no per-token price. Rejected for now:
  one always-on GPU instance per region costs hundreds of dollars a month before the first scan, plus patching,
  scaling and a model to serve. It becomes worth pricing again at the decision-8 threshold, alongside 4.4.
- **Training our own model first (4.4 before 4.1).** Rejected: 1,179 synthetic rows cannot train a classifier
  that meets the gate, and there is no consented source of real messages.
- **Keeping the rules for the closed beta.** Free, and nothing leaves the API. Rejected: Arabic recall is 0 in
  every category, and the beta families are in the Middle East.
- **A model on the phone.** Nothing leaves the device. Rejected for now: small on-device models are weakest in
  exactly the language we need, and the agent already runs within the battery budget of roadmap 5.8. It is worth
  revisiting with 4.4.

## Costs and consequences

- **New infrastructure in the `env` stack:**
  - the ai-engine service and its task role;
  - the VPC interface endpoint, which has a small fixed hourly cost per Availability Zone;
  - the data-retention setting in each region the chosen route reaches;
  - the Budgets alarm and action.

  If the account has a region guardrail, it must allow each EU destination of the chosen profile.
- **One more network hop on each scan:** API → ai-engine → Bedrock. It stays within the 5-second timeout that
  already exists. A slow model shows up in the fallback metric, never as a stuck request.
- **The eval needs Bedrock in the staging account.** That means a `workflow_dispatch` workflow
  (`ai-eval-bedrock.yml`) with an OIDC role that may call only the candidate models in EU regions, the same
  shape as `ai-eval-deepseek.yml`. Two test runs and one full run of all nine candidates cost a few dollars at
  the prices above.
- **The scorer turns thinking off wherever the model allows it.** It also leaves out sampling parameters that a
  model rejects. The second test run is how the variance gets measured.
- **The privacy policy and the Play data-safety form (5.2) change** (decision 3 of *What Karim decides*). The
  consent record already has a `thirdPartySharing` flag (`schema.prisma`). Whether this processing sets it is
  part of that decision, not this ADR's.
- **Who builds what:**
  - **Claude:** the Bedrock scorer and the eval workflow, because they are measurement.
  - **Kimi:** the production service, the infrastructure, the `scorer` field, the fallback alarm and the
    per-family cap. One roadmap item per PR.

## What Karim decides

1. **Accept the terms for the winning model in the staging and production accounts.** Per the price list, Claude
   models are sold as AWS Marketplace software, which needs Anthropic's one-time use-case form, and zero data
   retention for them is granted through the AWS account manager. The other candidates are billed by AWS
   directly.

   Amazon's own Nova models can be measured in staging before any of this. The run costs under a dollar.
2. **The monthly ceiling for Bedrock.** The proposal is **$50 a month during the closed beta**. Twenty families
   cost under $10 on any candidate except the two in Stockholm. The rest is headroom for eval runs and one heavy
   family.
3. **The privacy wording, and whether this counts as third-party sharing in the consent record.** A draft line,
   for the policy and the consent screen:

   > Messages in the apps you choose to monitor are checked for signs of risk, such as self-harm or grooming, by
   > an AI model that Amazon Web Services runs for OSRA inside the European Union. AWS does not keep these
   > messages or use them to train any model. OSRA keeps only the short excerpts it flags, encrypted, so you can
   > review them. Everything else is discarded as soon as it has been checked.

## Evidence

- Phase 4 gate and the rules layer's 0 % Arabic recall: `services/ai-engine/EVAL.md`, roadmap 4.1 and 4.3.
- Bedrock prices: AWS Price List API, `AmazonBedrock` and `AmazonBedrockFoundationModels` offers for
  `eu-central-1` and `eu-north-1` (October 2026), from
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonBedrockFoundationModels/current/region_index.json>.
  The Claude Haiku 5.5 EU price ($0.11 / $0.55) is Anthropic's own list price ($0.10 / $0.50) plus the 10 %
  EU-profile premium.
- Availability per region: the Bedrock model cards in
  <https://docs.aws.amazon.com/bedrock/latest/userguide/>, for example `model-card-amazon-nova-micro.html`,
  `model-card-anthropic-claude-haiku-5-5.html` and `model-card-mistral-ai-ministral-3-8b.html`.
- Data retention: <https://docs.aws.amazon.com/bedrock/latest/userguide/data-retention.html>.
- Cross-region inference within a geography:
  <https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html>.
- No sharing with model providers, no training: <https://aws.amazon.com/bedrock/faqs/> and
  <https://docs.aws.amazon.com/bedrock/latest/userguide/data-protection.html>.
- Abuse detection: <https://docs.aws.amazon.com/bedrock/latest/userguide/abuse-detection.html>.
- DeepSeek's data location and training use:
  <https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html> (last updated 10 February 2026).
- Arabic support: <https://docs.aws.amazon.com/ai/responsible-ai/nova-micro-lite-pro/overview.html> (Nova),
  <https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512> (Ministral 3 8B),
  <https://qwenlm.github.io/blog/qwen3/> (Qwen3), and
  <https://platform.claude.com/docs/en/build-with-claude/multilingual-support> (Claude).
