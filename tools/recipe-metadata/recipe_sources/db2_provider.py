"""Offline DB2 snapshot provider for the metadata generator.

The committed snapshot is intentionally minimal: it preserves only the
columns the pipeline needs from the DB2-derived source tables.

Tables represented:
- SkillLineAbility: spell -> profession and required skill.
- Spell: spell identity and first supported expansion observed.
- SpellEffect: reagent item/quantity rows for craft spells.
- ItemSparse: created-item bind type for BoP classification.
"""

import json
from pathlib import Path


DEFAULT_SNAPSHOT = "tbc-2.5.5"


def _read_json(path):
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def resolve_snapshot_dir(root, snapshot=DEFAULT_SNAPSHOT):
    return Path(root) / snapshot


def load_committed_snapshots(root, snapshot=DEFAULT_SNAPSHOT):
    snapshot_dir = resolve_snapshot_dir(root, snapshot)
    if not snapshot_dir.exists():
        raise FileNotFoundError("missing metadata snapshot: {0}".format(snapshot_dir))

    manifest = _read_json(snapshot_dir / "manifest.json")
    recipes = _read_json(snapshot_dir / "recipes.json")
    spell_effects = _read_json(snapshot_dir / "spell_effects.json")
    item_sparse = _read_json(snapshot_dir / "item_sparse.json")

    reagents_by_spell_id = {}
    for row in spell_effects:
        if row.get("effectType") != "reagent":
            continue
        spell_id = int(row["spellId"])
        reagents_by_spell_id.setdefault(spell_id, []).append({
            "itemId": int(row["itemId"]),
            "count": int(row["count"]),
        })

    bind_type_by_item_id = {}
    for row in item_sparse:
        bind_type_by_item_id[int(row["itemId"])] = row.get("bindType")

    return {
        "snapshotDir": str(snapshot_dir),
        "manifest": manifest,
        "recipes": recipes,
        "reagentsBySpellId": reagents_by_spell_id,
        "bindTypeByItemId": bind_type_by_item_id,
    }
