### AI engine — a per-row DeepSeek log, and the model id a run actually calls (#918)
- `eval/deepseek_rows.py` scores JSONL rows with DeepSeek and writes one line per row
  (`{id, text, probs, refused, latency_ms, tokens_in, tokens_out}`) — the shape a Bedrock run can be
  compared against row by row, which `run_eval`'s aggregate table cannot give.
- The default model id is now **`deepseek-flash`** (DeepSeek-V4.1-Flash-1017), not the `deepseek-chat`
  alias, in both the scorer and the `ai-eval-deepseek` workflow.
- Thinking mode is **off** and `temperature: 0` is sent, because the service ignores `temperature`
  while thinking is on: "prompt v3 unchanged, temperature 0" is only a real instruction in that shape.
- Resume is the output file (flushed per row), not a cache, so the reported tokens are the tokens
  billed. Cost is an upper bound at published cache-miss rates, classified peak/off-peak.
- The data rule is enforced in code: rows labelled outside hate/bullying/violence/safe are counted and
  never sent. Terms quoted in the PR: DeepSeek's Open Platform Terms §4.2 permits training on outputs.
