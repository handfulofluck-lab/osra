### AI engine — the eval cache is keyed on the prompt, not just the model and the text (#NNN)
- The DeepSeek evaluation cache was keyed on `(model, text)`, so editing `SYSTEM_PROMPT` changed what
  every row should score while leaving every key valid. The next run served the previous prompt's answers
  as cache hits, and the table in `services/ai-engine/EVAL.md` would have described a prompt that no
  longer existed. A cache hit looks exactly like a cheap success, which is why this would have been found
  by comparing numbers rather than by watching a run.
- The key is now `sha256(model + NUL + sha256(prompt) + NUL + text)`. The prompt enters as its own digest,
  so the key stays a fixed size however long the prompt grows and a separator inside a prompt cannot make
  two pairs collide.
- The prompt is instance state rather than a module constant, so the key and the request cannot disagree
  about which prompt produced a cached score — and a test can prove that a changed prompt misses.
- **One-off cost:** the first run after this change re-scores every row (about US$0.10 on the current set),
  because every existing key is a miss. That is the fix, not a regression.
