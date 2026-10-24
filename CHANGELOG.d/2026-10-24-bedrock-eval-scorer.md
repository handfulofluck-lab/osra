### AI — the tool that measures each EU-hosted model on the test set (roadmap 4.1, ADR-0033)

- New `services/ai-engine/eval/bedrock_scorer.py` scores the evaluation set with a candidate model on Amazon Bedrock, using the same prompt as the DeepSeek scorer. The prompt, the reply parser and the cache key now live in `eval/prompt.py`, so both scorers answer the same question.
- Only EU routes run: a global or non-EU profile, an ARN, or a region outside the EU is refused before any request.
- A refused, filtered or unreadable answer counts as flagged, never as safe, and the run reports how many there were.
- Each run adds up its tokens and, given prices, reports its cost per 1,000 scans.
- `python -m eval.run_eval` gains `--scorer bedrock` and `--fail-over-hard-fp`, the false-alarm limit ADR-0033 adds to the gate.
- New manual workflow `ai-eval-bedrock.yml`, one candidate per run. It assumes a new OIDC role (`infra/terraform/base/oidc.tf`, `bedrock_eval`) that may call Bedrock models in EU regions and nothing else.
- Setup still to do: apply `base`, then set the repository variable `AWS_BEDROCK_EVAL_ROLE_ARN`.
- No production code path changes, and no candidate has been measured yet.
