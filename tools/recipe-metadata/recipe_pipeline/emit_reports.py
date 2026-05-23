import json
from collections import Counter
from pathlib import Path

from recipe_pipeline.validate import SUPPORTED_PROFESSIONS, collect_unresolved


def _percent(resolved, total):
    if total == 0:
        return "100%"
    return "{0:.0f}%".format((resolved * 100.0) / total)


def build_reports(records, diagnostics, primary):
    unresolved = collect_unresolved(records, diagnostics)
    release_blocking = [item for item in unresolved if item["severity"] == "release-blocking"]
    counts = Counter(record.profession_key for record in records)

    coverage_lines = [
        "# Recipe Metadata Coverage",
        "",
        "Snapshot: {0}".format(primary.get("manifest", {}).get("snapshot", "unknown")),
        "Records: {0}".format(len(records)),
        "Release-blocking unresolved: {0}".format(len(release_blocking)),
        "",
        "| Profession | Recipes | Expansion | Profession | Category |",
        "|---|---:|---:|---:|---:|",
    ]
    for profession in SUPPORTED_PROFESSIONS:
        profession_records = [record for record in records if record.profession_key == profession]
        total = len(profession_records)
        expansion_resolved = sum(1 for record in profession_records if record.expansion in ("vanilla", "tbc"))
        profession_resolved = sum(1 for record in profession_records if record.profession_key == profession)
        category_resolved = sum(1 for record in profession_records if record.category_key)
        coverage_lines.append("| {0} | {1} | {2} | {3} | {4} |".format(
            profession,
            total,
            _percent(expansion_resolved, total),
            _percent(profession_resolved, total),
            _percent(category_resolved, total),
        ))

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
        "professionCounts": dict(sorted(counts.items())),
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
