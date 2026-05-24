import json
from collections import Counter
from pathlib import Path

from recipe_pipeline.validate import (
    SUPPORTED_EXPANSIONS,
    SUPPORTED_PROFESSIONS,
    collect_unresolved,
    expected_counts_from_manifest,
)


def _percent(resolved, total):
    if total == 0:
        return "100%"
    return "{0:.0f}%".format((resolved * 100.0) / total)


def build_reports(records, diagnostics, primary):
    source_manifest_data = primary.get("manifest", {})
    unresolved = collect_unresolved(records, diagnostics, source_manifest_data)
    release_blocking = [item for item in unresolved if item["severity"] == "release-blocking"]
    profession_counts = Counter(record.profession_key for record in records)
    expansion_counts = Counter(record.expansion for record in records if record.expansion in SUPPORTED_EXPANSIONS)
    profession_expansion_counts = Counter(
        (record.profession_key, record.expansion)
        for record in records
        if record.profession_key in SUPPORTED_PROFESSIONS and record.expansion in SUPPORTED_EXPANSIONS
    )
    expected_counts = expected_counts_from_manifest(source_manifest_data)
    expected_by_profession = expected_counts.get("by_profession", {})
    expected_by_expansion = expected_counts.get("by_expansion", {})
    expected_by_profession_expansion = expected_counts.get("by_profession_expansion", {})

    coverage_lines = [
        "# Recipe Metadata Coverage",
        "",
        "Snapshot: {0}".format(primary.get("manifest", {}).get("snapshot", "unknown")),
        "Dataset kind: {0}".format(source_manifest_data.get("datasetKind", "fixture")),
        "Records: {0}".format(len(records)),
        "Release-blocking unresolved: {0}".format(len(release_blocking)),
        "",
        "| Profession | Recipes | Expected | Missing | Expansion | Profession | Category |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for profession in SUPPORTED_PROFESSIONS:
        profession_records = [record for record in records if record.profession_key == profession]
        total = len(profession_records)
        expected = expected_by_profession.get(profession, total)
        missing = max(0, expected - total)
        expansion_resolved = sum(1 for record in profession_records if record.expansion in ("vanilla", "tbc"))
        profession_resolved = sum(1 for record in profession_records if record.profession_key == profession)
        category_resolved = sum(1 for record in profession_records if record.category_key)
        coverage_lines.append("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |".format(
            profession,
            total,
            expected,
            missing,
            _percent(expansion_resolved, total),
            _percent(profession_resolved, total),
            _percent(category_resolved, total),
        ))

    coverage_lines.extend([
        "",
        "## Expansion Coverage",
        "",
        "| Expansion | Recipes | Expected | Missing |",
        "|---|---:|---:|---:|",
    ])
    for expansion in SUPPORTED_EXPANSIONS:
        actual = expansion_counts[expansion]
        expected = expected_by_expansion.get(expansion, actual)
        missing = max(0, expected - actual)
        coverage_lines.append("| {0} | {1} | {2} | {3} |".format(
            expansion,
            actual,
            expected,
            missing,
        ))

    coverage_lines.extend([
        "",
        "## Profession / Expansion Coverage",
        "",
        "| Profession | Vanilla | Expected Vanilla | Missing Vanilla | TBC | Expected TBC | Missing TBC |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ])
    for profession in SUPPORTED_PROFESSIONS:
        row = [profession]
        for expansion in SUPPORTED_EXPANSIONS:
            actual = profession_expansion_counts[(profession, expansion)]
            expected = expected_by_profession_expansion.get(profession, {}).get(expansion, actual)
            missing = max(0, expected - actual)
            row.extend([actual, expected, missing])
        coverage_lines.append("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |".format(*row))

    reagent_records = [record for record in records if not record.is_outputless_self_only]
    reagent_resolved = sum(1 for record in reagent_records if record.reagents)
    reagent_lines = [
        "# Recipe Metadata Reagent Coverage",
        "",
        "Recipes requiring reagent metadata: {0}".format(len(reagent_records)),
        "Resolved reagents: {0}".format(reagent_resolved),
        "Coverage: {0}".format(_percent(reagent_resolved, len(reagent_records))),
        "",
        "| Spell ID | Profession | Reagents |",
        "|---:|---|---:|",
    ]
    for record in reagent_records:
        reagent_lines.append("| {0} | {1} | {2} |".format(record.spell_id, record.profession_key, len(record.reagents)))

    category_lines = [
        "# Category Remediation",
        "",
    ]
    fallbacks = diagnostics.get("categoryFallbacks", []) if diagnostics else []
    if not fallbacks:
        category_lines.append("No category fallbacks were required.")
    else:
        category_lines.append("| Spell ID | Profession | Hint |")
        category_lines.append("|---:|---|---|")
        for fallback in fallbacks:
            category_lines.append("| {0} | {1} | {2} |".format(
                fallback.get("spellId"),
                fallback.get("profession"),
                fallback.get("hint"),
            ))

    source_manifest = {
        "source": primary.get("manifest", {}),
        "records": len(records),
        "supportedProfessions": list(SUPPORTED_PROFESSIONS),
        "supportedExpansions": list(SUPPORTED_EXPANSIONS),
        "professionCounts": dict(sorted(profession_counts.items())),
        "expansionCounts": dict(sorted(expansion_counts.items())),
        "professionExpansionCounts": {
            profession: {
                expansion: profession_expansion_counts[(profession, expansion)]
                for expansion in SUPPORTED_EXPANSIONS
            }
            for profession in SUPPORTED_PROFESSIONS
        },
        "excluded": diagnostics.get("excluded", []) if diagnostics else [],
    }

    return {
        "coverage.md": "\n".join(coverage_lines) + "\n",
        "reagent-coverage.md": "\n".join(reagent_lines) + "\n",
        "category-remediation.md": "\n".join(category_lines) + "\n",
        "unresolved.json": json.dumps(unresolved, indent=2, sort_keys=True) + "\n",
        "source-manifest.json": json.dumps(source_manifest, indent=2, sort_keys=True) + "\n",
    }


def emit_reports(records, diagnostics, primary, output_dir):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    reports = build_reports(records, diagnostics, primary)
    for name, content in reports.items():
        (output_dir / name).write_text(content, encoding="utf-8")
    return reports
