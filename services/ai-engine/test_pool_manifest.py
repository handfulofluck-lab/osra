"""Rows for the pool manifest (#617 units). Mutants each row names are the reason it exists.

Every test builds its own tiny shard in a temp directory: the real pools are hundreds of megabytes and
must never be a test fixture.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pool_manifest import CATEGORIES, FIELDS, build_manifest, check_row, text_sha256


def row(**over) -> dict:
    base = {
        "id": "r-1",
        "lang": "tr",
        "script": "latn",
        "variety": "tr",
        "text": "merhaba",
        "label": "harmful",
        "category": "cyberbullying",
        "pair_id": "p-1",
        "kind": "harmful",   # the delivered pools write a harmful row this way; see test_kind_must_agree_with_label
        "age_band": "13-15",
        "platform": "whatsapp",
        "tone": "hostile",
        "writer_model": "k31",
        "source_batch": "b-1",
        "source_file": "shard-1.jsonl",
        "source_sha256": "0" * 64,
        "text_sha256": text_sha256("merhaba"),
    }
    base.update(over)
    return base


def write_shard(tmp_path: Path, name: str, rows: list) -> Path:
    path = tmp_path / name
    path.write_text("\n".join(json.dumps(r) if isinstance(r, dict) else r for r in rows) + "\n", encoding="utf-8")
    return path


def test_a_complete_row_passes_every_gate():
    assert check_row(row(), "tr") is None


def test_the_seventeen_fields_are_the_contract():
    # Mutant: dropping a field from FIELDS would let a pool ship rows the judge join cannot read.
    assert len(FIELDS) == 17
    missing_one = {k: v for k, v in row().items() if k != "tone"}
    assert check_row(missing_one, "tr") == "missing fields: tone"


def test_a_wrong_language_row_is_refused():
    assert check_row(row(lang="id"), "tr") == "lang is 'id', expected 'tr'"


def test_a_text_hash_that_does_not_match_the_text_is_refused():
    # Mutant: trusting the stored hash would let a pool carry a join key that points at different text.
    assert check_row(row(text_sha256="f" * 64), "tr") == "text_sha256 does not match the text"


def test_an_unpaired_safe_row_must_carry_category_none():
    # kind "plain" is the unpaired shape; the first version of this validator had the kinds wrong (it
    # allowed plain/lookalike only) and refused half of the delivered `ar` pool. Caught by a dry run, pinned here.
    assert check_row(row(label="safe", kind="plain", pair_id=None, category="none"), "tr") is None
    assert (
        check_row(row(label="safe", kind="plain", pair_id=None, category="cyberbullying"), "tr")
        == "an unpaired safe row must carry category 'none'"
    )


def test_kind_must_agree_with_label():
    assert check_row(row(label="harmful", kind="lookalike"), "tr") == "a harmful row must carry kind 'harmful', not 'lookalike'"
    assert check_row(row(label="safe", kind="harmful"), "tr") == "a safe row must be kind 'lookalike' or 'plain', not 'harmful'"
    # The paired shapes are accepted as the delivered pool writes them.
    assert check_row(row(label="harmful", kind="harmful", pair_id="p-1"), "tr") is None
    assert check_row(row(label="safe", kind="lookalike", pair_id="p-1", category="none"), "tr") is None


def test_a_paired_kind_needs_a_pair_id_and_plain_must_not_have_one():
    assert check_row(row(label="harmful", kind="harmful", pair_id=None), "tr") == "kind harmful/lookalike is paired, so pair_id must be set"
    assert check_row(row(label="safe", kind="plain", pair_id="p-1", category="none"), "tr") == "kind 'plain' means unpaired, so pair_id must be null"


def test_a_category_outside_brief_v3_is_refused():
    assert "Brief v3" in (check_row(row(category="spam"), "tr") or "")
    assert set(CATEGORIES) == {
        "cyberbullying",
        "hate_speech",
        "violence",
        "self_harm",
        "grooming",
        "sexual_content",
        "substance_use",
        "scam",
        "extremism",
        "dangerous_challenges",
        "none",
    }


def test_duplicate_text_counts_once_and_a_different_row_counts(tmp_path: Path):
    shard = write_shard(
        tmp_path,
        "s.jsonl",
        [row(), row(id="r-2"), row(id="r-3", text="başka", text_sha256=text_sha256("başka"))],
    )
    manifest = build_manifest([shard], "tr")
    assert manifest["totals"]["lines"] == 3
    assert manifest["totals"]["valid"] == 3
    assert manifest["totals"]["duplicates"] == 1


def test_a_malformed_line_is_a_failure_and_the_rest_still_count(tmp_path: Path):
    shard = write_shard(tmp_path, "s.jsonl", [row(), "{not json", row(id="r-2", text="iyi", text_sha256=text_sha256("iyi"))])
    manifest = build_manifest([shard], "tr")
    assert manifest["totals"]["failures"] == 1
    assert manifest["totals"]["valid"] == 2
    assert "not JSON" in manifest["failures"][0]


def test_the_manifest_carries_no_row_text(tmp_path: Path):
    shard = write_shard(tmp_path, "s.jsonl", [row()])
    manifest = build_manifest([shard], "tr")
    serialised = json.dumps(manifest)
    assert "merhaba" not in serialised
    assert text_sha256("merhaba") not in serialised  # not even the per-row digest


def test_the_set_digest_changes_when_a_shard_changes(tmp_path: Path):
    first = write_shard(tmp_path, "a.jsonl", [row()])
    manifest_one = build_manifest([first], "tr")
    assert manifest_one["totals"]["failures"] == 0
    write_shard(tmp_path, "a.jsonl", [row(id="r-2")])
    manifest_two = build_manifest([first], "tr")
    assert manifest_one["set_digest"] != manifest_two["set_digest"]


def test_a_directory_input_finds_every_shard_in_order(tmp_path: Path):
    write_shard(tmp_path, "b.jsonl", [row(text="b", text_sha256=text_sha256("b"))])
    write_shard(tmp_path, "a.jsonl", [row(text="a", text_sha256=text_sha256("a"))])
    manifest = build_manifest([tmp_path], "tr")
    assert [Path(s["path"]).name for s in manifest["shards"]] == ["a.jsonl", "b.jsonl"]
    assert manifest["units"] == {"tr": 2}


def test_a_missing_dupclasses_script_is_reported_not_swallowed(tmp_path: Path):
    shard = write_shard(tmp_path, "s.jsonl", [row()])
    manifest = build_manifest([shard], "tr", tmp_path / "does-not-exist.py")
    assert manifest["dupclasses"]["status"] != "ok"
