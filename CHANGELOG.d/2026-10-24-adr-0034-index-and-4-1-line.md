### Docs — ADR-0034 in the ADR index, and roadmap 4.1 names the Bedrock measurement tool (#370, #371)
- `docs/adr/README.md` gains the index row for ADR-0034 (accepted). The row was pushed after #371 had
  merged, so it missed that PR.
- `docs/ROADMAP.md` 4.1 says the Bedrock scorer, its workflow and its EU-only role are merged (#370), and
  that no model has been measured yet: that waits on the base stack and the `AWS_BEDROCK_EVAL_ROLE_ARN` secret.
