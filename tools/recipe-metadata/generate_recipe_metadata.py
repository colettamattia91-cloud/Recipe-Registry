#!/usr/bin/env python
import argparse
import json
import shutil
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

from recipe_pipeline.derive_categories import categories_by_profession, load_taxonomies, subcategories_by_profession
from recipe_pipeline.emit_lua import emit_lua
from recipe_pipeline.emit_reports import build_reports, emit_reports
from recipe_pipeline.normalize import normalize_records
from recipe_pipeline.validate import validate_records
from recipe_sources.db2_provider import DEFAULT_SNAPSHOT
from recipe_sources.local_snapshot_provider import load_local_snapshot


OUTPUT_PATH = REPO_ROOT / "RecipeRegistry_Metadata" / "Data" / "RecipeMetadata_Generated.lua"
SNAPSHOT_ROOT = SCRIPT_DIR / "snapshots"
TAXONOMY_ROOT = SCRIPT_DIR / "remediation" / "taxonomy"
OVERRIDES_PATH = SCRIPT_DIR / "remediation" / "manual_overrides.yaml"
REPORT_DIR = REPO_ROOT / "artifacts" / "recipe-metadata"
SCHEMA_VERSION = 1


def _coerce_scalar(value):
    value = value.strip()
    if value in ("true", "True"):
        return True
    if value in ("false", "False"):
        return False
    if value in ("{}", ""):
        return {}
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    try:
        return int(value)
    except ValueError:
        return value


def _load_overrides(path=OVERRIDES_PATH):
    buckets = {
        "expansionBySpellId": {},
        "createdItemBySpellId": {},
        "recipeItemBySpellId": {},
        "categoryBySpellId": {},
        "selfOnlyOutputlessBySpellId": {},
        "bopOutputBySpellId": {},
        "bindTypeByCreatedItemId": {},
    }
    if not Path(path).exists():
        return buckets

    current = None
    for raw_line in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if not raw_line.startswith(" ") and ":" in line:
            key, value = line.split(":", 1)
            current = key.strip()
            if current not in buckets:
                continue
            if value.strip() not in ("", "{}"):
                parsed = _coerce_scalar(value)
                if isinstance(parsed, dict):
                    buckets[current] = parsed
            continue
        if current and ":" in line:
            key, value = line.split(":", 1)
            try:
                numeric_key = int(key.strip())
            except ValueError:
                numeric_key = key.strip()
            value = value.strip()
            if value.startswith("{") and value.endswith("}"):
                entry = {}
                for part in value[1:-1].split(","):
                    if ":" in part:
                        entry_key, entry_value = part.split(":", 1)
                        entry[entry_key.strip()] = _coerce_scalar(entry_value)
                buckets[current][numeric_key] = entry
            else:
                buckets[current][numeric_key] = _coerce_scalar(value)
    return buckets


def _build_pipeline(snapshot=DEFAULT_SNAPSHOT, flavor="tbc"):
    primary, secondary = load_local_snapshot(SNAPSHOT_ROOT, snapshot)
    taxonomies = load_taxonomies(TAXONOMY_ROOT)
    overrides = _load_overrides()
    records, diagnostics = normalize_records(primary, secondary, taxonomies, overrides, flavor)
    metadata_version = primary.get("manifest", {}).get("metadataVersion", "0")
    lua = emit_lua(
        records,
        categories_by_profession(taxonomies),
        subcategories_by_profession(taxonomies),
        metadata_version,
        SCHEMA_VERSION,
        flavor,
    )
    reports = build_reports(records, diagnostics, primary)
    return primary, records, diagnostics, lua, reports


def command_fetch(args):
    if not args.source_dir:
        print("fetch is maintainer-only; pass --source-dir with normalized snapshot JSON files", file=sys.stderr)
        return 2

    source_dir = Path(args.source_dir)
    if not source_dir.exists():
        print("missing source snapshot directory: " + str(source_dir), file=sys.stderr)
        return 2

    target_dir = SNAPSHOT_ROOT / args.snapshot
    required = ("manifest.json", "recipes.json", "spell_effects.json", "item_sparse.json")
    optional = ("secondary_static.json",)
    target_dir.mkdir(parents=True, exist_ok=True)
    for name in required:
        src = source_dir / name
        if not src.exists():
            print("missing required snapshot file: " + str(src), file=sys.stderr)
            return 2
        shutil.copyfile(src, target_dir / name)
    for name in optional:
        src = source_dir / name
        if src.exists():
            shutil.copyfile(src, target_dir / name)

    print("imported normalized snapshot into " + str(target_dir))
    return 0


def command_generate(args):
    if args.flavor != "tbc":
        print("unsupported flavor: " + args.flavor, file=sys.stderr)
        return 2

    primary, records, diagnostics, content, reports = _build_pipeline(args.snapshot, args.flavor)
    if args.check:
        existing = OUTPUT_PATH.read_text(encoding="utf-8") if OUTPUT_PATH.exists() else ""
        if existing != content:
            print(str(OUTPUT_PATH) + " is stale", file=sys.stderr)
            return 1
        for name, expected in sorted(reports.items()):
            path = REPORT_DIR / name
            existing_report = path.read_text(encoding="utf-8") if path.exists() else ""
            if existing_report != expected:
                print(str(path) + " is stale", file=sys.stderr)
                return 1
        print(str(OUTPUT_PATH) + " is current")
        return 0

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(content, encoding="utf-8")
    emit_reports(records, diagnostics, primary, REPORT_DIR)
    print("wrote " + str(OUTPUT_PATH))
    return 0


def command_validate(args):
    primary, records, diagnostics, _content, _reports = _build_pipeline(args.snapshot, args.flavor)
    failures, unresolved = validate_records(
        records,
        diagnostics,
        strict=args.strict,
        source_manifest=primary.get("manifest", {}),
    )
    emit_reports(records, diagnostics, primary, REPORT_DIR)
    if failures:
        for failure in failures:
            print(json.dumps(failure, sort_keys=True), file=sys.stderr)
        return 1

    print("validated " + str(len(records)) + " metadata records; unresolved=" + str(len(unresolved)))
    return 0


def command_report(args):
    primary, records, diagnostics, _content, _reports = _build_pipeline(args.snapshot, args.flavor)
    emit_reports(records, diagnostics, primary, REPORT_DIR)
    print("wrote reports to " + str(REPORT_DIR))
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description="Build Recipe Registry metadata")
    subparsers = parser.add_subparsers(dest="command", required=True)

    fetch = subparsers.add_parser("fetch")
    fetch.add_argument("--flavor", default="tbc")
    fetch.add_argument("--snapshot", default=DEFAULT_SNAPSHOT)
    fetch.add_argument("--source-dir")
    fetch.set_defaults(func=command_fetch)

    generate = subparsers.add_parser("generate")
    generate.add_argument("--flavor", default="tbc")
    generate.add_argument("--snapshot", default=DEFAULT_SNAPSHOT)
    generate.add_argument("--offline", action="store_true")
    generate.add_argument("--check", action="store_true")
    generate.set_defaults(func=command_generate)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--flavor", default="tbc")
    validate.add_argument("--snapshot", default=DEFAULT_SNAPSHOT)
    validate.add_argument("--strict", action="store_true")
    validate.set_defaults(func=command_validate)

    report = subparsers.add_parser("report")
    report.add_argument("--flavor", default="tbc")
    report.add_argument("--snapshot", default=DEFAULT_SNAPSHOT)
    report.set_defaults(func=command_report)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
