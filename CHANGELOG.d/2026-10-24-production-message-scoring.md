### Docs — where a child's message is scored in production: ADR-0033, proposed (roadmap 4.1, 4.4)

- A real child's message is scored only on Amazon Bedrock inside the EU (Frankfurt in-region, the EU profile, or in-region in another EU region), with Bedrock's data retention set to `none` and no message text in our logs. DeepSeek's own API stays for synthetic eval messages.
- The model is chosen by measurement: the cheapest candidate that passes the Phase 4 gate on the held-out `test` split twice, with hard-negative false alarms ≤ 0.05 per language and refusals counted as flagged. Nine EU candidates are priced in the ADR, from about $0.11 to $1.24 per family per month.
- When the model cannot answer, the keyword rules do, as today; a per-family daily cap and an AWS Budgets action put a ceiling on spend.
- Our own model (4.4) becomes the path at scale. Three points wait for Karim: the model terms, the monthly ceiling ($50 proposed for the beta) and the privacy wording.
