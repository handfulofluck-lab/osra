### AI engine — an offline v9b adapter with no fallback (#50)

`services/ai-engine/v9b_adapter.py` scores text with the verified v9b checkpoint and **only** that checkpoint:
the seven category names in the frozen order (checked against the model's own `id2label`), per-language
calibrated thresholds from `compare-v9b.json` behind a SHA-256 check, and `AdapterUnavailable` for every way the
adapter could otherwise answer dishonestly — missing weights or config, a digest mismatch, a label set that is
not the verified seven, or no text at all. The digests that produced a result travel with it.

It exists because `model.py` in the same service is an eight-category positional path that merges rule scores
into the model's numbers and degrades to rules when a checkpoint is unreadable; a v9b row scored through it is
not the v9b model's verdict. Nothing is wired into `app.py`: no HTTP surface, no response-schema change.

Tests: `services/ai-engine/tests/test_v9b_adapter.py`, 16 offline cases (no checkpoint, no network, under a
second) plus one case that loads the real archive and scores a row twice; that one skips without
`V9B_MODEL_DIR`/`V9B_THRESHOLDS` and passed here against the verified archive (weights `158ca1f0…`). Mutants
run and reverted: label order compared as a set, one mean threshold instead of per-label, the thresholds digest
check removed, and the language ignored when choosing a calibration — each reddens one named test.
