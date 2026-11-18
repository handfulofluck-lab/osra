"""#918: the row log, tested offline against a mock transport.

The two things worth pinning here are not "does JSON parse": they are (1) the row-log shape a Bedrock
run can be diffed against, including the refusal column, and (2) the policy guard — a row whose labels
fall outside hate/bullying/violence/safe must never reach the network, because that rule is a child's
data rule and not a preference.
"""

import json

import httpx
import pytest

from eval.deepseek_rows import (
    POLICY_ALLOWED,
    entry_for,
    is_peak,
    load_scored_ids,
    main,
    policy_refusal,
    price_period,
    read_rows,
    score_rows,
)
from eval.deepseek_scorer import DeepSeekScorer


def _reply(categories: dict, prompt_tokens: int = 410, completion_tokens: int = 38) -> dict:
    return {
        "choices": [{"message": {"role": "assistant", "content": json.dumps({"categories": categories})}}],
        "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens},
    }


def _scorer(handler, tmp_path, **kwargs) -> DeepSeekScorer:
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return DeepSeekScorer(
        api_key="test-key",
        client=client,
        cache_path=None,
        sleep=lambda _s: None,
        log=lambda _m: None,
        **kwargs,
    )


def _row(row_id: str, text: str, labels=("cyberbullying",)) -> dict:
    return {"id": row_id, "lang": "en", "text": text, "labels": list(labels)}


def _write_jsonl(path, rows) -> str:
    path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    return str(path)


def test_a_row_is_written_in_the_row_log_shape(tmp_path):
    def handler(request):
        return httpx.Response(200, json=_reply({"cyberbullying": 0.82, "safe": 0.18}))

    scorer = _scorer(handler, tmp_path)
    output = str(tmp_path / "out.jsonl")
    summary = score_rows([_row("r1", "you are worthless")], scorer, output)

    lines = [json.loads(line) for line in open(output, encoding="utf-8")]
    assert len(lines) == 1
    entry = lines[0]
    assert set(entry) == {"id", "text", "probs", "refused", "latency_ms", "tokens_in", "tokens_out"}
    assert entry["id"] == "r1"
    assert len(entry["probs"]) == 8
    assert entry["probs"]["cyberbullying"] == 0.82
    assert entry["refused"] is False
    # Real accounting, from the reply's own `usage`, not a guess.
    assert entry["tokens_in"] == 410
    assert entry["tokens_out"] == 38
    assert entry["latency_ms"] >= 0
    assert summary["written"] == 1
    assert summary["usage"]["input_tokens"] == 410


def test_a_refusal_is_a_boolean_and_the_row_still_lands(tmp_path):
    def handler(request):
        return httpx.Response(
            200,
            json={"choices": [{"message": {"role": "assistant", "content": "I can't help with that."}}],
                  "usage": {"prompt_tokens": 100, "completion_tokens": 9}},
        )

    scorer = _scorer(handler, tmp_path)
    output = str(tmp_path / "out.jsonl")
    score_rows([_row("r1", "call me names")], scorer, output)

    entry = json.loads(open(output, encoding="utf-8").read())
    # One unreadable answer is a datapoint, not the end of the run. `refused_probs` scores every
    # harmful category 1.0 on purpose (a refusal must not read as a miss in recall) and flags itself,
    # so what lands in the log is that shape minus the marker.
    assert entry["refused"] is True
    assert entry["probs"]["safe"] == 0.0
    assert entry["probs"]["grooming"] == 1.0


def test_resume_skips_ids_already_in_the_output(tmp_path):
    calls = []

    def handler(request):
        calls.append(json.loads(request.content))
        return httpx.Response(200, json=_reply({"safe": 0.9}))

    scorer = _scorer(handler, tmp_path)
    output = tmp_path / "out.jsonl"
    rows = [_row("r1", "a"), _row("r2", "b")]
    score_rows(rows, scorer, str(output))
    assert len(calls) == 2

    summary = score_rows(rows, scorer, str(output))
    # Second pass: nothing re-sent, both counted as resumed, no duplicate lines.
    assert len(calls) == 2
    assert summary["resumed"] == 2
    assert summary["written"] == 0
    assert len(open(output, encoding="utf-8").readlines()) == 2


def test_a_half_written_last_line_does_not_stop_the_resume(tmp_path):
    output = tmp_path / "out.jsonl"
    output.write_text('{"id": "r1", "text": "a"}\n{"id": "r2", "te', encoding="utf-8")
    assert load_scored_ids(str(output)) == {"r1"}


def test_a_disallowed_label_is_never_sent(tmp_path):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(200, json=_reply({"safe": 1.0}))

    scorer = _scorer(handler, tmp_path)
    rows = [
        _row("ok", "leave her alone", labels=["cyberbullying"]),
        _row("never", "secret thing", labels=["grooming"]),
        _row("never2", "another", labels=["self_harm"]),
        _row("never3", "another", labels=["sexual_content"]),
    ]
    summary = score_rows(rows, scorer, str(tmp_path / "out.jsonl"))

    # Straight from #918: grooming, sexual and self-harm rows are outside the allowed set.
    assert len(calls) == 1
    assert summary["written"] == 1
    assert summary["skipped_by_policy"] == 3


def test_an_unlabelled_row_is_refused_rather_than_assumed(tmp_path):
    assert policy_refusal({"id": "x", "text": "t"}).startswith("no labels")
    assert policy_refusal({"id": "x", "text": "t", "labels": ["safe"]}) is None
    assert policy_refusal({"id": "x", "text": "t", "category": "violence"}) is None


def test_an_unlabelled_set_may_be_cleared_by_naming_its_provenance(tmp_path):
    """#918's private inputs carry no labels at all, so the provenance statement is the evidence. The
    flag is what puts that decision on the command line instead of in a habit."""
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(200, json=_reply({"safe": 0.9}))

    scorer = _scorer(handler, tmp_path)
    rows = [{"id": "u1", "lang": "ar", "text": "a"}, {"id": "u2", "lang": "en", "text": "b"}]
    output = str(tmp_path / "out.jsonl")

    # Without the flag: refused, nothing sent.
    summary = score_rows(rows, scorer, output)
    assert summary["written"] == 0
    assert summary["skipped_by_policy"] == 2
    assert calls == []

    # With the provenance named: permitted, and the choice is recorded in the summary.
    summary = score_rows(rows, scorer, output, cleared_by="READY (own-model thread, 18 Nov)")
    assert summary["written"] == 2
    assert summary["cleared_by"] == "READY (own-model thread, 18 Nov)"
    assert len(calls) == 2


def test_the_cleared_by_flag_does_not_wave_through_a_labelled_disallowed_row(tmp_path):
    """A mixed set must not be spendable: a row that carries labels is still checked."""
    assert policy_refusal({"id": "x", "text": "t", "labels": ["self_harm"]}, cleared_by="READY") is not None
    assert policy_refusal({"id": "x", "text": "t"}, cleared_by="READY") is None


def test_policy_covers_exactly_the_four_allowed_categories():
    assert POLICY_ALLOWED == {"cyberbullying", "hate_speech", "violence", "safe"}


def test_peak_hours_are_the_published_ones(tmp_path):
    import datetime as dt

    # Monday 02:00 UTC is peak, Monday 05:00 is not, Saturday 02:00 is not.
    assert is_peak(dt.datetime(2026, 11, 16, 2, 0, tzinfo=dt.timezone.utc)) is True
    assert is_peak(dt.datetime(2026, 11, 16, 5, 0, tzinfo=dt.timezone.utc)) is False
    assert is_peak(dt.datetime(2026, 11, 21, 2, 0, tzinfo=dt.timezone.utc)) is False
    assert price_period(dt.datetime(2026, 11, 16, 2, 0, tzinfo=dt.timezone.utc)) == "peak"


def test_the_cost_reported_is_an_upper_bound(tmp_path):
    def handler(request):
        return httpx.Response(200, json=_reply({"safe": 0.9}, prompt_tokens=1_000_000, completion_tokens=0))

    scorer = _scorer(handler, tmp_path)
    summary = score_rows([_row("r1", "a")], scorer, str(tmp_path / "out.jsonl"))
    period = summary["cost"]["price_period_at_end"]
    expected = 0.30 if period == "peak" else 0.15
    # 1M input tokens at the cache-miss rate for the period, and nothing else.
    assert summary["cost"]["usd_upper_bound"] == pytest.approx(expected, abs=1e-4)


def test_entry_for_strips_the_refusal_marker_from_probs():
    entry = entry_for({"id": "r", "text": "t"}, {"safe": 0.4, "_refused": True})
    assert entry["refused"] is True
    assert "_refused" not in entry["probs"]


def test_a_row_without_text_is_a_clear_error(tmp_path):
    path = tmp_path / "rows.jsonl"
    path.write_text('{"id": "r1"}\n', encoding="utf-8")
    with pytest.raises(SystemExit) as exc:
        read_rows(str(path))
    assert "no `text`" in str(exc.value)


def test_the_cli_refuses_without_a_key(tmp_path, monkeypatch):
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    rows = _write_jsonl(tmp_path / "rows.jsonl", [_row("r1", "a")])
    with pytest.raises(SystemExit) as exc:
        main(["--input", rows, "--output", str(tmp_path / "out.jsonl")])
    assert "DEEPSEEK_API_KEY" in str(exc.value) or "unavailable" in str(exc.value)
