"""The dev/test split of the evaluation set — **per template, never per row**.

Why per template. Five rows share one template's wording (the generator caps a
template at five fills), so a model that recognises one fill very likely
recognises its siblings. Splitting rows individually would place paraphrases of
the same sentence on both sides, and a "held-out" number measured that way is
the tuning set wearing a different label. The unit of the split is therefore
the template, the same unit provenance already names.

Why a hash and not a counter. `template_index % 2` is deterministic too, but it
is positional: inserting one template in the middle of a bank flips the side of
every template after it, silently moving rows already measured from test into
dev (or the reverse). A later run would then report a held-out number against a
partition nobody chose, with no diff that shows it happened. Hashing
`bank:template_index` makes a template's side depend only on its own identity,
so a new template costs one new bit and leaves every existing assignment alone.
That stability is also why the choices below are pinned by hardcoded tests: if
the hash input ever changes, the split is re-cut, and that must be a failing
test rather than a quiet re-partition.

One consequence worth knowing: `template_index` is a position within a bank's
list, and the positives, hard-negative and generic-safe lists are each numbered
from zero, so index `i` of all three lands on the same side. That is a coarser
partition than three independent ones, but it is never a leak — rows from one
template are still all on one side — and it keeps the rule a pure function of
`(bank, template_index)`, which is exactly what provenance records.
"""

import hashlib

DEV = "dev"
TEST = "test"
SPLITS = (DEV, TEST)


def split_of(bank: str, template_index: int) -> str:
    """The side of the split a template belongs to, as a pure function of its identity."""
    digest = hashlib.sha256(f"{bank}:{template_index}".encode("utf-8")).digest()
    return DEV if digest[0] % 2 == 0 else TEST
