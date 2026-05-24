from collections import Counter


SUPPORTED_PROFESSIONS = (
    "alchemy",
    "blacksmithing",
    "cooking",
    "enchanting",
    "engineering",
    "jewelcrafting",
    "leatherworking",
    "tailoring",
)
SUPPORTED_EXPANSIONS = ("vanilla", "tbc")


def _as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _coerce_counts(mapping):
    out = {}
    if not isinstance(mapping, dict):
        return out
    for key, count in mapping.items():
        value = _as_int(count)
        if value is not None:
            out[key] = value
    return out


def expected_counts_from_manifest(source_manifest):
    expected = (source_manifest or {}).get("expectedRecipeCounts") or {}
    if not isinstance(expected, dict):
        return {
            "total": None,
            "by_profession": {},
            "by_expansion": {},
            "by_profession_expansion": {},
        }

    by_profession = _coerce_counts(expected.get("byProfession"))
    by_expansion = _coerce_counts(expected.get("byExpansion"))
    by_profession_expansion = {}
    nested = expected.get("byProfessionExpansion")
    if isinstance(nested, dict):
        for profession, expansion_counts in nested.items():
            coerced = _coerce_counts(expansion_counts)
            if coerced:
                by_profession_expansion[profession] = coerced

    # Backwards-compatible shape used by early fixture tests:
    # { "alchemy": 4, "blacksmithing": 2, ... }
    if not by_profession:
        by_profession = _coerce_counts({
            key: value
            for key, value in expected.items()
            if key in SUPPORTED_PROFESSIONS
        })

    return {
        "total": _as_int(expected.get("total")),
        "by_profession": by_profession,
        "by_expansion": by_expansion,
        "by_profession_expansion": by_profession_expansion,
    }


def _missing_expected_sections(expected_counts):
    missing = []
    if not expected_counts.get("by_profession"):
        missing.append("byProfession")
    if not expected_counts.get("by_expansion"):
        missing.append("byExpansion")
    if not expected_counts.get("by_profession_expansion"):
        missing.append("byProfessionExpansion")
    return missing


def collect_unresolved(records, diagnostics=None, source_manifest=None):
    unresolved = []
    recipe_item_ids = {}
    has_source_manifest = source_manifest is not None
    source_manifest = source_manifest or {}

    for record in records:
        def add(field, severity, message):
            unresolved.append({
                "spellId": record.spell_id,
                "field": field,
                "severity": severity,
                "message": message,
            })

        if record.profession_key not in SUPPORTED_PROFESSIONS:
            add("profession", "release-blocking", "missing or unsupported profession")
        if record.expansion not in SUPPORTED_EXPANSIONS:
            add("expansion", "release-blocking", "missing or unsupported expansion")
        if not record.category_key:
            add("category", "release-blocking", "missing category")
        if record.sort_order is None:
            add("sortOrder", "release-blocking", "missing sort order")
        if not record.is_outputless_self_only and record.created_item_id is None:
            add("createdItemId", "release-blocking", "missing created item for normal craft")
        if not record.is_outputless_self_only and not record.reagents:
            add("reagents", "release-blocking", "missing reagents")
        if record.recipe_item_id is not None:
            previous = recipe_item_ids.get(record.recipe_item_id)
            if previous is not None:
                add("recipeItemId", "release-blocking", "recipe item maps to multiple spells")
            recipe_item_ids[record.recipe_item_id] = record.spell_id

    profession_counts = Counter(record.profession_key for record in records)
    expansion_counts = Counter(record.expansion for record in records if record.expansion in SUPPORTED_EXPANSIONS)
    profession_expansion_counts = Counter(
        (record.profession_key, record.expansion)
        for record in records
        if record.profession_key in SUPPORTED_PROFESSIONS and record.expansion in SUPPORTED_EXPANSIONS
    )
    dataset_kind = source_manifest.get("datasetKind") or "fixture"
    if has_source_manifest and dataset_kind != "release-candidate":
        unresolved.append({
            "spellId": None,
            "field": "datasetKind",
            "severity": "release-blocking",
            "message": "strict validation requires a release-candidate dataset, got " + str(dataset_kind),
        })

    expected_counts = expected_counts_from_manifest(source_manifest)
    missing_expected_sections = _missing_expected_sections(expected_counts)
    if has_source_manifest and dataset_kind == "release-candidate" and missing_expected_sections:
        unresolved.append({
            "spellId": None,
            "field": "expectedCoverage",
            "severity": "release-blocking",
            "message": "release-candidate dataset is missing expectedRecipeCounts sections: "
                + ", ".join(missing_expected_sections),
        })

    total_expected = expected_counts.get("total")
    if total_expected is not None and len(records) < total_expected:
        unresolved.append({
            "spellId": None,
            "field": "recipeCoverage",
            "severity": "release-blocking",
            "message": "missing {0} expected total recipe record(s)".format(
                total_expected - len(records),
            ),
        })

    for expansion in SUPPORTED_EXPANSIONS:
        if expansion_counts[expansion] == 0:
            unresolved.append({
                "spellId": None,
                "field": "expansionCoverage",
                "severity": "release-blocking",
                "message": "no records for supported expansion " + expansion,
            })
        expected_count = expected_counts.get("by_expansion", {}).get(expansion)
        if expected_count is not None and expansion_counts[expansion] < expected_count:
            unresolved.append({
                "spellId": None,
                "field": "expansionCoverage",
                "severity": "release-blocking",
                "message": "missing {0} expected {1} recipe record(s)".format(
                    expansion,
                    expected_count - expansion_counts[expansion],
                ),
            })

    for profession in SUPPORTED_PROFESSIONS:
        if profession_counts[profession] == 0:
            unresolved.append({
                "spellId": None,
                "field": "professionCoverage",
                "severity": "release-blocking",
                "message": "no records for supported profession " + profession,
            })
        expected_count = expected_counts.get("by_profession", {}).get(profession)
        if expected_count is not None and profession_counts[profession] < expected_count:
            unresolved.append({
                "spellId": None,
                "field": "recipeCoverage",
                "severity": "release-blocking",
                "message": "missing {0} expected {1} recipe record(s)".format(
                    profession,
                    expected_count - profession_counts[profession],
                ),
            })
        for expansion in SUPPORTED_EXPANSIONS:
            expected_profession_expansion = (
                expected_counts
                .get("by_profession_expansion", {})
                .get(profession, {})
                .get(expansion)
            )
            actual_profession_expansion = profession_expansion_counts[(profession, expansion)]
            if (
                expected_profession_expansion is not None
                and actual_profession_expansion < expected_profession_expansion
            ):
                unresolved.append({
                    "spellId": None,
                    "field": "professionExpansionCoverage",
                    "severity": "release-blocking",
                    "message": "missing {0} {1} expected {2} recipe record(s)".format(
                        profession,
                        expansion,
                        expected_profession_expansion - actual_profession_expansion,
                    ),
                })

    return unresolved


def validate_records(records, diagnostics=None, strict=False, source_manifest=None):
    unresolved = collect_unresolved(records, diagnostics, source_manifest)
    if strict:
        failures = [item for item in unresolved if item["severity"] == "release-blocking"]
    else:
        failures = unresolved
    return failures, unresolved
