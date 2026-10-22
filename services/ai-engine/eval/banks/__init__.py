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
    PATTERN_EN: [int]      optional; pattern id per POSITIVES_EN entry
    PATTERN_AR: [int]      the same for POSITIVES_AR
    PATTERN_HARD_NEG_EN / PATTERN_HARD_NEG_AR   the same for HARD_NEGATIVES_<LANG>
    PATTERN_SAFE_EN / PATTERN_SAFE_AR           the same for GENERIC_SAFE_<LANG>
    LANGUAGE_ONLY: {str}   optional; "<list>:<pattern>" keys that only one language has

A **pattern** is the unit of meaning the dev/test split is cut on (`eval/split.py`):
a template, its translation in the other language and its gender twin all carry
one id, so none of them can land on the other side of the split. A list with no
`PATTERN_*` companion is index-as-pattern, which is correct for a list whose two
languages are translations of each other in the same order.

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
from typing import Dict, FrozenSet, List, Tuple

import model

SLOT_RE = re.compile(r"\{([a-z_][a-z0-9_]*)\}")
ARABIC_RE = re.compile(r"[\u0600-\u06FF]")

HARMFUL_CATEGORIES: List[str] = [c for c in model.CATEGORIES if c != "safe"]

MIN_POSITIVES = 12
MIN_HARD_NEGATIVES = 8
MIN_GENERIC_SAFE = 5

# The three template lists of a bank, and the companion export that carries a pattern id per entry.
# A missing companion means index-as-pattern.
LISTS: Tuple[str, ...] = ("positives", "hard_negatives", "generic_safe")

PATTERN_EXPORTS: Dict[str, Tuple[str, str]] = {
    "positives": ("PATTERN_EN", "PATTERN_AR"),
    "hard_negatives": ("PATTERN_HARD_NEG_EN", "PATTERN_HARD_NEG_AR"),
    "generic_safe": ("PATTERN_SAFE_EN", "PATTERN_SAFE_AR"),
}

TEMPLATE_FIELDS: Dict[str, Tuple[str, str]] = {
    "positives": ("positives_en", "positives_ar"),
    "hard_negatives": ("hard_negatives_en", "hard_negatives_ar"),
    "generic_safe": ("generic_safe_en", "generic_safe_ar"),
}

LANG_INDEX = {"en": 0, "ar": 1}

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
    # list name -> pattern id per template index
    patterns_en: Dict[str, List[int]]
    patterns_ar: Dict[str, List[int]]
    language_only: FrozenSet[str]

    def templates(self, list_name: str, lang: str) -> List[str]:
        """The templates of one list in one language."""
        return getattr(self, TEMPLATE_FIELDS[list_name][LANG_INDEX[lang]])

    def patterns(self, list_name: str, lang: str) -> List[int]:
        """The pattern id of every template in one list and language, in template order."""
        return (self.patterns_en if lang == "en" else self.patterns_ar)[list_name]

    def pattern_map(self, list_name: str, lang: str) -> Dict[int, int]:
        """Template index -> pattern id for one list and language."""
        return dict(enumerate(self.patterns(list_name, lang)))


def _validate_patterns(module_name, export, patterns, templates, list_name, lang):
    """A pattern list names one id per template; a second list would silently shift the split."""
    if patterns is None:
        return []
    where = f"{module_name}.{export}"
    if len(patterns) != len(templates):
        return [f"{where}: {len(patterns)} ids for {len(templates)} templates "
                f"({list_name}, {lang})"]
    return [f"{where}[{index}]: pattern id must be a non-negative int, got {value!r}"
            for index, value in enumerate(patterns)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0]


def _validate_language_only(module_name, language_only, patterns):
    """A `LANGUAGE_ONLY` key must name a pattern that exists on exactly one side."""
    errors = []
    for key in language_only:
        where = f"{module_name}.LANGUAGE_ONLY[{key!r}]"
        if not isinstance(key, str) or ":" not in key:
            errors.append(f"{where}: expected '<list>:<pattern>'")
            continue
        list_name, _, raw = key.partition(":")
        if list_name not in LISTS:
            errors.append(f"{where}: unknown list {list_name!r} (expected one of {', '.join(LISTS)})")
            continue
        try:
            pattern = int(raw)
        except ValueError:
            errors.append(f"{where}: pattern id must be an int")
            continue
        in_en = pattern in patterns["en"][list_name]
        in_ar = pattern in patterns["ar"][list_name]
        if in_en == in_ar:
            errors.append(
                f"{where}: not a one-language pattern — it is "
                f"{'present in both lists' if in_en else 'in neither list'}")
    return errors


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
    patterns = {lang: _module_patterns(module, lang) for lang in ("en", "ar")}
    for list_name in LISTS:
        for lang, index in (("en", 0), ("ar", 1)):
            export = PATTERN_EXPORTS[list_name][index]
            errors += _validate_patterns(name, export, getattr(module, export, None),
                                         module_templates(module, list_name, lang), list_name, lang)
    errors += _validate_language_only(name, getattr(module, "LANGUAGE_ONLY", frozenset()), patterns)
    return errors


def module_templates(module, list_name: str, lang: str) -> List[str]:
    """The templates of one list and language of a raw bank module."""
    return list(getattr(module, TEMPLATE_FIELDS[list_name][LANG_INDEX[lang]].upper(), []))


def _module_patterns(module, lang: str) -> Dict[str, List[int]]:
    """Every list's pattern ids for one language; a missing companion is index-as-pattern."""
    out: Dict[str, List[int]] = {}
    for list_name in LISTS:
        export = PATTERN_EXPORTS[list_name][LANG_INDEX[lang]]
        templates = module_templates(module, list_name, lang)
        raw = getattr(module, export, None)
        out[list_name] = list(raw) if raw is not None else list(range(len(templates)))
    return out


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
            patterns_en=_module_patterns(module, "en"),
            patterns_ar=_module_patterns(module, "ar"),
            language_only=frozenset(getattr(module, "LANGUAGE_ONLY", frozenset())),
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
