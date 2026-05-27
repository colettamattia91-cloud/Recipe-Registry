"""One-shot helper: emit the blacksmithing.yaml taxonomy with explicit per-spellId
classification for all 385 Vanilla+TBC blacksmithing recipes.

Architecture:
- Armor recipes (mail/plate): split into TWO top-level categories (mail, plate),
  each subdivided by slot. Subcategory auto-derived from
  item_sparse.inventorySlot (robe collapsed into chest).
- Weapon recipes (sword/axe/mace/dagger/polearm/thrown/fist): subcategory auto-
  derived from item_sparse.weaponClass (DB2 Item.ClassID=2 / SubclassID).
- Everything else (stones, rods, keys, materials, wards, shields) is manually
  classified below.

Usage: python tools/recipe-metadata/_gen_blacksmithing_taxonomy.py
"""

import json
from pathlib import Path

SNAPSHOT_DIR = Path(__file__).parent / "snapshots" / "tbc-2.5.5"

CATEGORIES = [
    ("weapons",      "Weapons",          10),
    ("mail",         "Mail Armor",       20),
    ("plate",        "Plate Armor",      30),
    ("enhancements", "Enhancements",     40),  # Sharpening / weightstone / shield spike / weapon chain / rune
    ("rods",         "Rods",             50),  # Enchanter's rods
    ("materials",    "Materials",        60),  # Grinding stones + structural parts
    ("keys",         "Skeleton Keys",    70),
    ("misc",         "Miscellaneous",   999),
]

_ARMOR_SLOT_SUBS = [
    ("head",     "Head",     10),
    ("shoulder", "Shoulder", 20),
    ("chest",    "Chest",    30),
    ("waist",    "Waist",    40),
    ("legs",     "Legs",     50),
    ("feet",     "Feet",     60),
    ("hands",    "Hands",    70),
    ("wrist",    "Wrist",    80),
]

SUBCATEGORIES = {
    "weapons": [
        ("sword",   "Swords",      10),
        ("axe",     "Axes",        20),
        ("mace",    "Maces",       30),
        ("dagger",  "Daggers",     40),
        ("polearm", "Polearms",    50),
        ("thrown",  "Thrown",      60),
        ("fist",    "Fist Weapons", 70),
    ],
    "mail":  _ARMOR_SLOT_SUBS,
    "plate": _ARMOR_SLOT_SUBS,
    "enhancements": [
        ("sharpening",   "Sharpening Stones", 10),
        ("weightstone",  "Weightstones",      20),
        ("shield_spike", "Shield Spikes",     30),
        ("weapon_chain", "Weapon Chains",     40),
        ("rune",         "Runes of Warding",  50),
    ],
}

# Robe (InventoryType=20) is a visual variant of chest; merge.
SLOT_TO_ARMOR_SUB = {
    "head": "head", "shoulder": "shoulder",
    "chest": "chest", "robe": "chest",
    "waist": "waist", "legs": "legs", "feet": "feet",
    "hands": "hands", "wrist": "wrist",
}

# Manual classification for items that aren't armor/weapon by DB2 class.
# (category, subcategory, sortOrder)
MANUAL_SPELLS = {
    # ----- Sharpening Stones -----
    2660:  ("enhancements", "sharpening",   10),  # Rough Sharpening Stone
    2665:  ("enhancements", "sharpening",   20),  # Coarse Sharpening Stone (75)
    2674:  ("enhancements", "sharpening",   30),  # Heavy Sharpening Stone (125)
    9918:  ("enhancements", "sharpening",   40),  # Solid Sharpening Stone
    16641: ("enhancements", "sharpening",   50),  # Dense Sharpening Stone
    22757: ("enhancements", "sharpening",   60),  # Elemental Sharpening Stone (300)
    29654: ("enhancements", "sharpening",   70),  # Fel Sharpening Stone
    29656: ("enhancements", "sharpening",   80),  # Adamantite Sharpening Stone

    # ----- Weightstones -----
    3115:  ("enhancements", "weightstone",  10),  # Rough Weightstone
    3116:  ("enhancements", "weightstone",  20),  # Coarse Weightstone
    3117:  ("enhancements", "weightstone",  30),  # Heavy Weightstone
    9921:  ("enhancements", "weightstone",  40),  # Solid Weightstone
    16640: ("enhancements", "weightstone",  50),  # Dense Weightstone
    34607: ("enhancements", "weightstone",  60),  # Fel Weightstone
    34608: ("enhancements", "weightstone",  70),  # Adamantite Weightstone

    # ----- Shield Spikes -----
    7221:  ("enhancements", "shield_spike", 10),  # Iron Shield Spike
    9939:  ("enhancements", "shield_spike", 20),  # Mithril Shield Spike
    16651: ("enhancements", "shield_spike", 30),  # Thorium Shield Spike
    29657: ("enhancements", "shield_spike", 40),  # Felsteel Shield Spike

    # ----- Weapon Chains -----
    7224:  ("enhancements", "weapon_chain", 10),  # Steel Weapon Chain
    42688: ("enhancements", "weapon_chain", 20),  # Adamantite Weapon Chain

    # ----- Runes of Warding (shield enchants) -----
    32284: ("enhancements", "rune",         10),  # Lesser Rune of Warding
    32285: ("enhancements", "rune",         20),  # Greater Rune of Warding

    # ----- Rods (for enchanters) -----
    7818:  ("rods", None, 10),  # Silver Rod
    14379: ("rods", None, 20),  # Golden Rod
    14380: ("rods", None, 30),  # Truesilver Rod
    20201: ("rods", None, 40),  # Arcanite Rod
    32655: ("rods", None, 50),  # Fel Iron Rod
    32656: ("rods", None, 60),  # Adamantite Rod
    32657: ("rods", None, 70),  # Eternium Rod

    # ----- Skeleton Keys -----
    19666: ("keys", None, 10),  # Silver Skeleton Key
    19667: ("keys", None, 20),  # Golden Skeleton Key
    19668: ("keys", None, 30),  # Truesilver Skeleton Key
    19669: ("keys", None, 40),  # Arcanite Skeleton Key

    # ----- Materials (reagents + structural parts) -----
    3320:  ("materials", None, 10),  # Rough Grinding Stone
    3326:  ("materials", None, 20),  # Coarse Grinding Stone
    3337:  ("materials", None, 30),  # Heavy Grinding Stone
    9920:  ("materials", None, 40),  # Solid Grinding Stone
    16639: ("materials", None, 50),  # Dense Grinding Stone
    8768:  ("materials", None, 60),  # Iron Buckle
    7222:  ("materials", None, 70),  # Iron Counterweight
    9964:  ("materials", None, 80),  # Mithril Spurs
    11454: ("materials", None, 90),  # Inlaid Mithril Cylinder

    # ----- Misc (Wards off-hand items + Jagged Obsidian Shield) -----
    29728: ("misc", None, 10),  # Lesser Ward of Shielding (off-hand)
    29729: ("misc", None, 20),  # Greater Ward of Shielding (off-hand)
    27586: ("misc", None, 30),  # Jagged Obsidian Shield (only BS-crafted shield)
}


def _load_snapshot():
    items = json.loads((SNAPSHOT_DIR / "item_sparse.json").read_text(encoding="utf-8"))
    item_lookup = {it["itemId"]: it for it in items}
    recipes = json.loads((SNAPSHOT_DIR / "recipes.json").read_text(encoding="utf-8"))
    return recipes, item_lookup


def _classify_recipe(recipe, item_lookup, skill_default=1):
    """Return (category, subcategory, sortOrder) for a BS recipe."""
    spell_id = recipe["spellId"]
    if spell_id in MANUAL_SPELLS:
        return MANUAL_SPELLS[spell_id]

    created = recipe.get("createdItemId")
    info = item_lookup.get(created, {})
    sort_order = recipe.get("requiredSkill") or skill_default

    armor = info.get("armorType")
    if armor in ("mail", "plate"):
        slot = info.get("inventorySlot")
        sub = SLOT_TO_ARMOR_SUB.get(slot)
        if sub:
            return (armor, sub, sort_order)
        raise AssertionError(
            f"BS spellId={spell_id} ({info.get('name')}) is {armor} armor "
            f"but has unrecognised inventorySlot={slot!r}."
        )

    weapon = info.get("weaponClass")
    if weapon in ("sword", "axe", "mace", "dagger", "polearm", "thrown", "fist"):
        return ("weapons", weapon, sort_order)

    raise AssertionError(
        f"BS spellId={spell_id} createdItem={created} ({info.get('name')}) "
        f"has no manual classification AND no armor/weapon class in snapshot. "
        f"Add to MANUAL_SPELLS or refetch."
    )


HEADER = (
    "# Blacksmithing taxonomy and per-spellId classification whitelist.\n"
    "# Generated by tools/recipe-metadata/_gen_blacksmithing_taxonomy.py — re-run\n"
    "# that helper if you need to regenerate from the Python source of truth.\n"
    "# Armor (mail/plate) and weapons (sword/axe/mace/dagger/polearm/thrown/fist)\n"
    "# are auto-derived from the DB2 Item.ClassID/SubclassID via the snapshot.\n"
)


def main():
    recipes, item_lookup = _load_snapshot()
    bs = [r for r in recipes if r["profession"] == "blacksmithing"]

    out = [HEADER, "categories:\n"]
    for key, label, order in CATEGORIES:
        out.append(f"  - key: {key}, label: {label}, order: {order}\n")
    out.append("subcategories:\n")
    for cat_key, _, _ in CATEGORIES:
        subs = SUBCATEGORIES.get(cat_key)
        if not subs:
            continue
        out.append(f"  {cat_key}:\n")
        for key, label, order in subs:
            out.append(f"    - key: {key}, label: {label}, order: {order}\n")

    classified = {}
    for recipe in bs:
        cat, sub, sort_order = _classify_recipe(recipe, item_lookup)
        classified[recipe["spellId"]] = (cat, sub, sort_order)

    out.append("spells:\n")
    for spell_id in sorted(classified):
        category, subcategory, sort_order = classified[spell_id]
        parts = [f"category: {category}"]
        if subcategory is not None:
            parts.append(f"subcategory: {subcategory}")
        parts.append(f"sortOrder: {sort_order}")
        out.append(f"  {spell_id}: " + ", ".join(parts) + "\n")

    expected_count = 385
    actual_count = len(classified)
    assert actual_count == expected_count, (
        f"Classified {actual_count} entries, expected {expected_count} BS recipes"
    )

    target = Path(__file__).parent / "remediation" / "taxonomy" / "blacksmithing.yaml"
    target.write_text("".join(out), encoding="utf-8")
    print(f"Wrote {actual_count} spell classifications to {target}")


if __name__ == "__main__":
    main()
