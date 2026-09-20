#!/usr/bin/env python3
"""
Compare AtlasLootClassic_Crafting recipe lists against our Generated
recipe metadata snapshots. Surfaces:
  * IDs AtlasLoot lists that we DON'T have (possible missing recipes)
  * IDs we have that AtlasLoot DOESN'T list (possible extra recipes
    or recipes AtlasLoot doesn't catalog — informational)
  * IDs both have but with mismatched profession (likely metadata bugs
    on our side, since AtlasLoot is a long-stable community DB)

AtlasLoot's data files are Lua but the structure is regular enough
to parse with a few regexes. Each profession block opens with
`data["<Key>"] = {` and the items array uses `{ idx, id }` rows.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ATLAS_DIR_DEFAULT = Path(
    r"C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns\AtlasLootClassic_Crafting"
)
REPO_ROOT = Path(__file__).resolve().parents[2]
SNAPSHOT_PATH = REPO_ROOT / "tools" / "recipe-metadata" / "snapshots" / "tbc-2.5.5" / "recipes.json"

# AtlasLoot key -> our canonical profession key
PROFESSION_KEY_MAP = {
    "Alchemy": "alchemy",
    "AlchemyBC": "alchemy",
    "Blacksmithing": "blacksmithing",
    "BlacksmithingBC": "blacksmithing",
    "Enchanting": "enchanting",
    "EnchantingBC": "enchanting",
    "Engineering": "engineering",
    "EngineeringBC": "engineering",
    "Jewelcrafting": "jewelcrafting",
    "JewelcraftingBC": "jewelcrafting",
    "Leatherworking": "leatherworking",
    "LeatherworkingBC": "leatherworking",
    "Tailoring": "tailoring",
    "TailoringBC": "tailoring",
    "Cooking": "cooking",
    "CookingBC": "cooking",
    "Mining": "mining",
    "MiningBC": "mining",
    "FirstAid": "first_aid",
    "FirstAidBC": "first_aid",
    "Fishing": "fishing",
    "FishingBC": "fishing",
    "Herbalism": "herbalism",
    "Skinning": "skinning",
}

# Match `data["Foo"] = {` ... up to the matching closing brace level.
SECTION_START_RE = re.compile(r'^\s*data\["(\w+)"\]\s*=\s*\{')
ITEM_ROW_RE = re.compile(r"\{\s*\d+\s*,\s*(\d+)\s*\}\s*,?\s*(?:--\s*(.+))?")
NAMED_GROUP_RE = re.compile(r'name\s*=\s*[^,\n]*\b(?:AL|ALIL)\[\s*"([^"]+)"\s*\]')


def parse_atlas_file(path):
    """Walk an AtlasLoot data file and yield (profession_key, group_name, id, comment)."""
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    current_section = None
    current_group = None
    brace_depth = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        section_match = SECTION_START_RE.match(line)
        if section_match:
            current_section = section_match.group(1)
            brace_depth = 1
            current_group = None
            i += 1
            continue
        if current_section:
            # Track brace depth so we know when we leave the section.
            open_count = line.count("{") - line.count("}")
            brace_depth += open_count
            if brace_depth <= 0:
                current_section = None
                current_group = None
                i += 1
                continue
            group_match = NAMED_GROUP_RE.search(line)
            if group_match:
                current_group = group_match.group(1)
            row_match = ITEM_ROW_RE.search(line)
            if row_match and current_section:
                yield current_section, current_group or "(uncategorized)", int(row_match.group(1)), (row_match.group(2) or "").strip()
        i += 1


def load_our_metadata(snapshot_path):
    with snapshot_path.open() as f:
        records = json.load(f)
    by_spell = {}
    by_created_item = {}
    by_recipe_item = {}
    for r in records:
        sid = r.get("spellId")
        if sid is not None:
            by_spell[int(sid)] = r
        cid = r.get("createdItemId")
        if cid is not None:
            by_created_item.setdefault(int(cid), []).append(r)
        rid = r.get("recipeItemId")
        if rid is not None:
            by_recipe_item.setdefault(int(rid), []).append(r)
    return by_spell, by_created_item, by_recipe_item


def lookup_id(id_int, by_spell, by_created_item, by_recipe_item):
    """Return list of matching records by trying spellId, then createdItem, then recipeItem."""
    matches = []
    if id_int in by_spell:
        matches.append(("spellId", by_spell[id_int]))
    for r in by_created_item.get(id_int, []):
        matches.append(("createdItemId", r))
    for r in by_recipe_item.get(id_int, []):
        matches.append(("recipeItemId", r))
    return matches


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--atlas-dir", type=Path, default=ATLAS_DIR_DEFAULT)
    ap.add_argument("--snapshot", type=Path, default=SNAPSHOT_PATH)
    ap.add_argument("--show-extra", action="store_true", help="Also print our records that AtlasLoot doesn't list")
    args = ap.parse_args()

    if not args.atlas_dir.exists():
        print(f"AtlasLoot dir not found: {args.atlas_dir}", file=sys.stderr)
        return 1
    if not args.snapshot.exists():
        print(f"Snapshot not found: {args.snapshot}", file=sys.stderr)
        return 1

    by_spell, by_created_item, by_recipe_item = load_our_metadata(args.snapshot)

    files = [
        (args.atlas_dir / "data.lua", "vanilla"),
        (args.atlas_dir / "data-tbc.lua", "tbc"),
    ]

    atlas_ids_per_profession = {}
    atlas_records_by_id = {}
    missing_by_profession = {}
    mismatched_by_profession = {}

    for path, label in files:
        if not path.exists():
            print(f"  (skipping missing file {path.name})")
            continue
        for section, group, atlas_id, comment in parse_atlas_file(path):
            prof_key = PROFESSION_KEY_MAP.get(section)
            if not prof_key:
                continue  # not a profession block we map
            atlas_ids_per_profession.setdefault(prof_key, set()).add(atlas_id)
            atlas_records_by_id[(prof_key, atlas_id)] = {
                "atlasSection": section,
                "atlasGroup": group,
                "atlasComment": comment,
                "atlasFile": label,
            }
            matches = lookup_id(atlas_id, by_spell, by_created_item, by_recipe_item)
            if not matches:
                missing_by_profession.setdefault(prof_key, []).append({
                    "id": atlas_id,
                    "group": group,
                    "comment": comment,
                    "file": label,
                })
            else:
                # Profession mismatch?
                ok = False
                for source, rec in matches:
                    if rec.get("profession") == prof_key:
                        ok = True
                        break
                if not ok:
                    found_profs = sorted({rec.get("profession") for _, rec in matches if rec.get("profession")})
                    mismatched_by_profession.setdefault(prof_key, []).append({
                        "id": atlas_id,
                        "group": group,
                        "comment": comment,
                        "file": label,
                        "ourProfessions": found_profs,
                        "ourSources": [s for s, _ in matches],
                    })

    print("=" * 70)
    print("MISSING (AtlasLoot lists IDs not present in our metadata)")
    print("=" * 70)
    total_missing = 0
    for prof in sorted(missing_by_profession):
        items = missing_by_profession[prof]
        total_missing += len(items)
        print(f"\n{prof}: {len(items)} missing")
        for it in items:
            print(f"  [{it['file']}] {it['id']:>7}  group={it['group']!r}  -- {it['comment']}")
    print(f"\nTotal missing across all professions: {total_missing}")

    print()
    print("=" * 70)
    print("PROFESSION MISMATCHES (we have the recipe but tag it differently)")
    print("=" * 70)
    total_mismatch = 0
    for prof in sorted(mismatched_by_profession):
        items = mismatched_by_profession[prof]
        total_mismatch += len(items)
        print(f"\nAtlasLoot says {prof}: {len(items)} mismatches")
        for it in items:
            print(f"  {it['id']:>7}  group={it['group']!r}  weSay={it['ourProfessions']}  via={it['ourSources']}  -- {it['comment']}")
    print(f"\nTotal mismatches: {total_mismatch}")

    if args.show_extra:
        print()
        print("=" * 70)
        print("EXTRA (we have records AtlasLoot doesn't list — informational)")
        print("=" * 70)
        all_our_records = list(by_spell.values())
        for prof in sorted(atlas_ids_per_profession):
            atlas_set = atlas_ids_per_profession[prof]
            extra = []
            for r in all_our_records:
                if r.get("profession") != prof:
                    continue
                # Check if any of our IDs are in atlas set
                sid = r.get("spellId")
                cid = r.get("createdItemId")
                rid = r.get("recipeItemId")
                if sid in atlas_set or (cid and cid in atlas_set) or (rid and rid in atlas_set):
                    continue
                extra.append(r)
            print(f"\n{prof}: {len(extra)} not in AtlasLoot")
            for r in extra[:40]:  # cap printing
                print(f"  spell={r.get('spellId'):>7}  createdItem={r.get('createdItemId')}  expansion={r.get('firstSeenExpansion')}")
            if len(extra) > 40:
                print(f"  ... ({len(extra) - 40} more)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
