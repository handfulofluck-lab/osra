"""The dev/test split of the evaluation set — **per pattern, never per row**.

Why per pattern and not per template position. A template list is not a list of
independent items across languages. `POSITIVES_AR` is a translation of
`POSITIVES_EN` with the Arabic gender twins inserted, so from the first twin
onward EN *i* and AR *i* are different sentences and a translation sits at
another index with an independent coin flip. Hashing the position therefore cut
meaning in half: 8 of 14 adjacent twin pairs landed on opposite sides, and
translation pairs such as `self_harm` EN 5 <-> AR 6 and EN 7 <-> AR 10 did too.
One prompt scores both languages, so a dev sentence whose translation or whose
other-gender twin sat in test is exactly the paraphrase leak this split exists to
prevent. "All rows from one template share a side" was true and still leaked:
the pattern — a template, its translation and its gender twin under one id — is
the unit of meaning, not the position.

Why not per row. Five rows share one pattern's wording (the generator caps a
pattern at five fills), so a model that recognises one fill very likely
recognises its siblings. Splitting rows individually would place paraphrases of
the same sentence on both sides, and a "held-out" number measured that way is the
tuning set wearing a different label.

Why a hash and not a counter. `pattern % 2` is deterministic too, but it is
positional: inserting one pattern in the middle of a list flips the side of every
pattern after it, silently moving rows already measured from test into dev (or
the reverse). A later run would then report a held-out number against a
partition nobody chose, with no diff that shows it happened. Hashing
`bank:pattern` makes a pattern's side depend only on its own identity, so a new
pattern costs one new bit and leaves every existing assignment alone. That
stability is also why the choices below are pinned by hardcoded tests: if the
hash input ever changes, the split is re-cut, and that must be a failing test
rather than a quiet re-partition.

One consequence worth knowing: pattern ids run per list (positives, hard
negatives and generic safe each number from zero), so pattern `i` of all three
lands on the same side. That is a coarser partition than three independent ones,
but it is never a leak — rows from one pattern are still all on one side — and it
keeps the rule a pure function of `(bank, pattern)`, which is exactly what
provenance records.
"""

import hashlib

DEV = "dev"
TEST = "test"
SPLITS = (DEV, TEST)


def split_of(bank: str, pattern: int) -> str:
    """The side of the split a pattern belongs to, as a pure function of its identity."""
    digest = hashlib.sha256(f"{bank}:{pattern}".encode("utf-8")).digest()
    return DEV if digest[0] % 2 == 0 else TEST
