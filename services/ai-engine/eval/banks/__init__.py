"""Loader, validator and reference for the evaluation template banks.

A bank is a Python module in this package that exports exactly:

    CATEGORY: str          one of model.CATEGORIES except "safe"
    POSITIVES_EN: [str]    templates for a harmful example; may hold {slot}s
    POSITIVES_AR: [str]    the same in Arabic
    SLOTS_EN: {name: [str]} slot fills used by POSITIVES_EN
    SLOTS_AR: {name: [str]} slot fills used by POSITIVES_AR
    HARD_NEGATIVES_EN: [str]  benign text that *looks* like the category
    HARD_NEGATIVES_AR: [str]  the same in Arabic
    GENERIC_SAFE_EN: [str]    ordinary child messages with no trigger at all
    GENERIC_SAFE_AR: [str]    the same in Arabic
    AGE_RANGE: (int, int)     the child ages this category is drawn from
    ALSO_LABELS_EN: {int: [str]}  optional; template index -> extra labels for a true overlap
    ALSO_LABELS_AR: {int: [str]}  the same in Arabic

Slots that hold a person's name come in gendered pairs -- `name_m`/`name_f`,
`target_m`/`target_f` -- because Arabic marks gender on the verb and the pronoun,
so a mixed slot produces rows like "هنا بكى" (masculine verb, girl's name). A
template uses one side of a pair, never the pair mixed.

Why templates and not a flat list of examples: plan 4.2 wants a set that is
regenerable and auditable. A bank of ~20 templates with slots expands
deterministically to hundreds of distinct snippets, and a reviewer can read the
*pattern* rather than 2,000 individual lines. Provenance is therefore the
template, and every generated row carries its bank, template index and seed.

Content rule (binding, and the reason it is here rather than in a README):
banks describe the *social pattern* a scorer must catch -- secrecy, coercion,
isolation, threats, intent. They never contain method, dosage, or graphic
detail. An evaluation set is not a corpus of harm: a detector that only fires on
method text is a detector that misses grooming, and a repository that carries
method text is a repository that teaches it.

**Name the thing, never the method.** The rule above forbids method, dose,
price, source and graphic detail -- it does not forbid naming the substance or
the act. A positive must be labelable from the message alone: "we're vaping in
the toilets at break, watch the door" carries its category and teaches nothing,
while "delete this chat before your mum sees it" carries no category at all and
belongs in no bank (#262 review). A secrecy or pressure line with no category
signal is not a positive, however much it sounds like one.

True overlaps carry both labels (`ALSO_LABELS_EN` / `ALSO_LABELS_AR`): an adult
asking a child for a photo is `grooming` *and* `sexual_content`, and a scorer
that answers one of the two is not wrong.
"""

import importlib
import pkgutil
import re
from dataclasses import dataclass
from typing import Dict, List, Tuple

import model

SLOT_RE = re.compile(r"\{([a-z_][a-z0-9_]*)\}")
ARABIC_RE = re.compile(r"[\u0600-\u06FF]")

HARMFUL_CATEGORIES: List[str] = [c for c in model.CATEGORIES if c != "safe"]

MIN_POSITIVES = 12
MIN_HARD_NEGATIVES = 8
MIN_GENERIC_SAFE = 5

REQUIRED_EXPORTS = (
    "CATEGORY",
    "POSITIVES_EN",
    "POSITIVES_AR",
    "SLOTS_EN",
    "SLOTS_AR",
    "HARD_NEGATIVES_EN",
    "HARD_NEGATIVES_AR",
    "GENERIC_SAFE_EN",
    "GENERIC_SAFE_AR",
    "AGE_RANGE",
)


@dataclass(frozen=True)
class Bank:
    """One validated category bank."""

    category: str
    module_name: str
    positives_en: List[str]
    positives_ar: List[str]
    slots_en: Dict[str, List[str]]
    slots_ar: Dict[str, List[str]]
    hard_negatives_en: List[str]
    hard_negatives_ar: List[str]
    generic_safe_en: List[str]
    generic_safe_ar: List[str]
    age_range: Tuple[int, int]
    also_labels_en: Dict[int, List[str]]
    also_labels_ar: Dict[int, List[str]]


def _validate_also_labels(module_name, lang, also, positives, category):
    """`ALSO_LABELS_<LANG> = {template_index: [extra category]}` for a true overlap."""
    errors = []
    for index, extras in also.items():
        where = f"{module_name}.ALSO_LABELS_{lang.upper()}[{index}]"
        if not isinstance(index, int) or not 0 <= index < len(positives):
            errors.append(f"{where}: template index out of range (0..{len(positives) - 1})")
            continue
        for extra in extras:
            if extra not in HARMFUL_CATEGORIES:
                errors.append(f"{where}: unknown category {extra!r}")
            elif extra == category:
                errors.append(f"{where}: repeats the bank's own category {extra!r}")
    return errors


def _validate_language(module_name, lang, positives, slots, hard_negatives, generic_safe):
    """Return a list of human-readable errors for one language of one bank."""
    errors = []
    want_arabic = lang == "ar"

    for label, group in (("POSITIVES", positives), ("HARD_NEGATIVES", hard_negatives),
                         ("GENERIC_SAFE", generic_safe)):
        for idx, text in enumerate(group):
            where = f"{module_name}.{label}_{lang.upper()}[{idx}]"
            if not isinstance(text, str) or not text.strip():
                errors.append(f"{where}: must be a non-empty string")
                continue
            has_arabic = bool(ARABIC_RE.search(text))
            if want_arabic and not has_arabic:
                errors.append(f"{where}: Arabic bank entry has no Arabic characters: {text!r}")
            if not want_arabic and has_arabic:
                errors.append(f"{where}: English bank entry contains Arabic: {text!r}")

    for idx, text in enumerate(positives):
        slots_used = SLOT_RE.findall(text)
        for slot in slots_used:
            if slot not in slots:
                errors.append(
                    f"{module_name}.POSITIVES_{lang.upper()}[{idx}]: unknown slot "
                    f"{{{slot}}} (declare it in SLOTS_{lang.upper()})"
                )
        # A template that names both a masculine and a feminine target contradicts itself: the
        # generator picks one name per slot, so "{target_m} and {target_f}" produced two children in
        # one message. Gendered pairs are separate templates (#262 review).
        if any(s.endswith("_m") for s in slots_used) and any(s.endswith("_f") for s in slots_used):
            errors.append(
                f"{module_name}.POSITIVES_{lang.upper()}[{idx}]: mixes a _m slot with a _f slot; "
                f"write one template per gender"
            )

    for name, fills in slots.items():
        if not isinstance(fills, list) or not fills:
            errors.append(f"{module_name}.SLOTS_{lang.upper()}[{name}]: must be a non-empty list")
            continue
        for fill in fills:
            if not isinstance(fill, str) or not fill.strip():
                errors.append(
                    f"{module_name}.SLOTS_{lang.upper()}[{name}]: fills must be non-empty strings")

    if len(set(positives)) != len(positives):
        errors.append(f"{module_name}.POSITIVES_{lang.upper()}: duplicate templates")
    if len(set(hard_negatives)) != len(hard_negatives):
        errors.append(f"{module_name}.HARD_NEGATIVES_{lang.upper()}: duplicate entries")

    if len(positives) < MIN_POSITIVES:
        errors.append(
            f"{module_name}.POSITIVES_{lang.upper()}: {len(positives)} templates, need >= {MIN_POSITIVES}")
    if len(hard_negatives) < MIN_HARD_NEGATIVES:
        errors.append(
            f"{module_name}.HARD_NEGATIVES_{lang.upper()}: {len(hard_negatives)} entries, "
            f"need >= {MIN_HARD_NEGATIVES}")
    if len(generic_safe) < MIN_GENERIC_SAFE:
        errors.append(
            f"{module_name}.GENERIC_SAFE_{lang.upper()}: {len(generic_safe)} entries, "
            f"need >= {MIN_GENERIC_SAFE}")
    return errors


def validate_module(module) -> List[str]:
    """Validate one imported bank module, returning every problem found."""
    name = module.__name__.split(".")[-1]
    errors = []
    missing = [attr for attr in REQUIRED_EXPORTS if not hasattr(module, attr)]
    if missing:
        return [f"{name}: missing export(s): {', '.join(missing)}"]

    category = module.CATEGORY
    if category not in HARMFUL_CATEGORIES:
        errors.append(
            f"{name}.CATEGORY = {category!r}: must be one of {', '.join(HARMFUL_CATEGORIES)}")
    if name != category:
        errors.append(f"{name}: module name must equal CATEGORY ({category!r})")

    age_range = module.AGE_RANGE
    if (not isinstance(age_range, tuple) or len(age_range) != 2
            or not all(isinstance(v, int) for v in age_range) or not 0 < age_range[0] <= age_range[1] <= 18):
        errors.append(f"{name}.AGE_RANGE = {age_range!r}: must be a (min, max) int tuple inside 1..18")

    errors += _validate_language(name, "en", module.POSITIVES_EN, module.SLOTS_EN,
                                 module.HARD_NEGATIVES_EN, module.GENERIC_SAFE_EN)
    errors += _validate_language(name, "ar", module.POSITIVES_AR, module.SLOTS_AR,
                                 module.HARD_NEGATIVES_AR, module.GENERIC_SAFE_AR)
    errors += _validate_also_labels(name, "en", getattr(module, "ALSO_LABELS_EN", {}),
                                    module.POSITIVES_EN, category)
    errors += _validate_also_labels(name, "ar", getattr(module, "ALSO_LABELS_AR", {}),
                                    module.POSITIVES_AR, category)
    return errors


def load_banks() -> Dict[str, Bank]:
    """Import every bank module, validate it, and return them keyed by category.

    Raises ValueError listing every problem rather than failing on the first:
    a bank author should see all of their mistakes in one run.
    """
    banks: Dict[str, Bank] = {}
    errors: List[str] = []
    for info in sorted(pkgutil.iter_modules(__path__), key=lambda i: i.name):
        if info.name.startswith("_"):
            continue
        module = importlib.import_module(f"{__name__}.{info.name}")
        errors += validate_module(module)
        category = getattr(module, "CATEGORY", None)
        if category in banks:
            errors.append(f"{info.name}: duplicate CATEGORY {category!r} (also {banks[category].module_name})")
            continue
        banks[category] = Bank(
            category=category,
            module_name=info.name,
            positives_en=list(getattr(module, "POSITIVES_EN", [])),
            positives_ar=list(getattr(module, "POSITIVES_AR", [])),
            slots_en=dict(getattr(module, "SLOTS_EN", {})),
            slots_ar=dict(getattr(module, "SLOTS_AR", {})),
            hard_negatives_en=list(getattr(module, "HARD_NEGATIVES_EN", [])),
            hard_negatives_ar=list(getattr(module, "HARD_NEGATIVES_AR", [])),
            generic_safe_en=list(getattr(module, "GENERIC_SAFE_EN", [])),
            generic_safe_ar=list(getattr(module, "GENERIC_SAFE_AR", [])),
            age_range=getattr(module, "AGE_RANGE", (0, 0)),
            also_labels_en=dict(getattr(module, "ALSO_LABELS_EN", {})),
            also_labels_ar=dict(getattr(module, "ALSO_LABELS_AR", {})),
        )

    missing = [c for c in HARMFUL_CATEGORIES if c not in banks]
    if missing:
        errors.append(f"no bank for categor(y|ies): {', '.join(missing)}")
    if errors:
        raise ValueError("invalid evaluation banks:\n  - " + "\n  - ".join(errors))
    return banks


def main(argv=None) -> int:
    """`python -m eval.banks` -- validate every bank and print a short table."""
    import sys

    errors: List[str] = []
    for info in sorted(pkgutil.iter_modules(__path__), key=lambda i: i.name):
        if info.name.startswith("_"):
            continue
        module = importlib.import_module(f"{__name__}.{info.name}")
        errors += validate_module(module)

    if errors:
        print(f"{len(errors)} problem(s):")
        for err in errors:
            print(f"  - {err}")
        return 1

    print(f"{'category':18} {'en':>4} {'ar':>4} {'hard-en':>8} {'hard-ar':>8} {'safe-en':>8} {'safe-ar':>8}")
    try:
        banks = load_banks()
    except ValueError as exc:
        print(exc)
        return 1
    for category, bank in banks.items():
        print(f"{category:18} {len(bank.positives_en):4} {len(bank.positives_ar):4} "
              f"{len(bank.hard_negatives_en):8} {len(bank.hard_negatives_ar):8} "
              f"{len(bank.generic_safe_en):8} {len(bank.generic_safe_ar):8}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
