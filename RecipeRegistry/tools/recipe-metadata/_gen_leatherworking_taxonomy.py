"""One-shot helper: emit the leatherworking.yaml taxonomy with explicit per-spellId
classification for all 379 Vanilla+TBC leatherworking recipes.

Architecture:
- 301 armor recipes (leather + mail): split into TWO top-level categories
  (leather, mail), each subdivided by slot. Subcategory auto-derived from
  item_sparse.inventorySlot (robe collapsed into chest).
- 78 non-armor recipes manually classified (cloaks, bags, drums, leg/glove
  armors, armor kits, materials, misc).

Usage: python tools/recipe-metadata/_gen_leatherworking_taxonomy.py
"""

import json
from pathlib import Path

SNAPSHOT_DIR = Path(__file__).parent / "snapshots" / "tbc-2.5.5"

CATEGORIES = [
    ("leather",    "Leather Armor",  10),
    ("mail",       "Mail Armor",     20),
    ("cloaks",     "Cloaks",         30),
    ("bags",       "Bags & Quivers", 40),
    ("drums",      "Drums",          50),
    ("kits",       "Kits",           60),
    ("materials",  "Materials",      70),
    ("misc",       "Miscellaneous", 999),
]

# Slot subcategories are the same for leather and mail.
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
    "leather": _ARMOR_SLOT_SUBS,
    "mail":    _ARMOR_SLOT_SUBS,
    "kits": [
        ("armor", "Armor Kits",         10),  # Light/Medium/Heavy/Thick/Rugged/Knothide/Resistance kits
        ("slot",  "Slot Reinforcements", 20),  # Leg armors + Glove Reinforcements
    ],
}

# Robe (InventoryType=20) is a visual variant of chest; merge.
SLOT_TO_ARMOR_SUB = {
    "head": "head", "shoulder": "shoulder",
    "chest": "chest", "robe": "chest",
    "waist": "waist", "legs": "legs", "feet": "feet",
    "hands": "hands", "wrist": "wrist",
}

# Manual classification for non-armor items (DB2 armorType is leather/mail for
# 301 wearable pieces auto-derived; everything else is listed here).
# (category, subcategory, sortOrder)
MANUAL_SPELLS = {
    # ----- Cloaks (DB2 armorType=cloth but conceptually LW cloaks, back slot) -----
    2159:  ("cloaks", None,   1),  # Fine Leather Cloak
    2162:  ("cloaks", None,  65),  # Embossed Leather Cloak
    2168:  ("cloaks", None, 110),  # Dark Leather Cloak
    3760:  ("cloaks", None,   1),  # Hillman's Cloak
    7153:  ("cloaks", None, 125),  # Guardian Cloak
    7953:  ("cloaks", None,  90),  # Deviate Scale Cloak
    9058:  ("cloaks", None,   1),  # Handstitched Leather Cloak
    9070:  ("cloaks", None, 100),  # Black Whelp Cloak
    9198:  ("cloaks", None,   1),  # Frost Leather Cloak
    10550: ("cloaks", None, 230),  # Nightscape Cloak
    10562: ("cloaks", None, 240),  # Big Voodoo Cloak
    10574: ("cloaks", None, 250),  # Wild Leather Cloak
    19093: ("cloaks", None, 300),  # Onyxia Scale Cloak
    22926: ("cloaks", None, 300),  # Chromatic Cloak
    22927: ("cloaks", None, 300),  # Hide of the Wild
    22928: ("cloaks", None, 300),  # Shifting Cloak
    42546: ("cloaks", None, 360),  # Cloak of Darkness

    # ----- Drums (TBC) -----
    35540: ("drums", None,   1),  # Drums of War
    35544: ("drums", None, 345),  # Drums of Speed
    35539: ("drums", None, 350),  # Drums of Restoration
    35543: ("drums", None, 365),  # Drums of Battle
    35538: ("drums", None, 370),  # Drums of Panic
    351768: ("drums", None, 345),  # Greater Drums of Speed
    351769: ("drums", None, 350),  # Greater Drums of Restoration
    351771: ("drums", None, 365),  # Greater Drums of Battle
    351770: ("drums", None, 370),  # Greater Drums of Panic
    351766: ("drums", None, 375),  # Greater Drums of War

    # ----- Slot Reinforcements (leg armors + glove reinforcements) -----
    35549: ("kits", "slot", 335),  # Cobrahide Leg Armor
    35555: ("kits", "slot", 335),  # Clefthide Leg Armor
    35554: ("kits", "slot", 365),  # Nethercobra Leg Armor
    35557: ("kits", "slot", 365),  # Nethercleft Leg Armor
    44770: ("kits", "slot",   1),  # Glove Reinforcements

    # ----- Armor Kits (generic, apply to any armor piece) -----
    2152:  ("kits", "armor",   1),  # Light Armor Kit
    2165:  ("kits", "armor",  75),  # Medium Armor Kit
    3780:  ("kits", "armor",   1),  # Heavy Armor Kit
    10487: ("kits", "armor",   1),  # Thick Armor Kit
    19058: ("kits", "armor",   1),  # Rugged Armor Kit
    22727: ("kits", "armor", 300),  # Core Armor Kit
    32456: ("kits", "armor",   1),  # Knothide Armor Kit
    44970: ("kits", "armor",   1),  # Heavy Knothide Armor Kit
    32457: ("kits", "armor", 325),  # Vindicator's Armor Kit
    32458: ("kits", "armor", 325),  # Magister's Armor Kit
    35520: ("kits", "armor", 340),  # Shadow Armor Kit
    35521: ("kits", "armor", 340),  # Flame Armor Kit
    35522: ("kits", "armor", 340),  # Frost Armor Kit
    35523: ("kits", "armor", 340),  # Nature Armor Kit
    35524: ("kits", "armor", 340),  # Arcane Armor Kit

    # ----- Materials (leather processing + cured hides) -----
    2881:  ("materials", None,   1),  # Light Leather
    20648: ("materials", None,   1),  # Medium Leather
    20649: ("materials", None,   1),  # Heavy Leather
    20650: ("materials", None,   1),  # Thick Leather
    22331: ("materials", None,   1),  # Rugged Leather
    3816:  ("materials", None,   1),  # Cured Light Hide
    3817:  ("materials", None,   1),  # Cured Medium Hide
    3818:  ("materials", None,   1),  # Cured Heavy Hide
    10482: ("materials", None,   1),  # Cured Thick Hide
    19047: ("materials", None,   1),  # Cured Rugged Hide
    32454: ("materials", None,   1),  # Knothide Leather
    32455: ("materials", None, 325),  # Heavy Knothide Leather

    # ----- Bags, Quivers, Ammo Pouches -----
    5244:  ("bags", None,  40),  # Kodo Hide Bag
    9060:  ("bags", None,   1),  # Light Leather Quiver
    9062:  ("bags", None,   1),  # Small Leather Ammo Pouch
    9193:  ("bags", None,   1),  # Heavy Quiver
    9194:  ("bags", None,   1),  # Heavy Leather Ammo Pouch
    14930: ("bags", None,   1),  # Quickdraw Quiver
    14932: ("bags", None,   1),  # Thick Leather Ammo Pouch
    35530: ("bags", None, 325),  # Reinforced Mining Bag
    44343: ("bags", None,   1),  # Knothide Ammo Pouch
    44344: ("bags", None,   1),  # Knothide Quiver
    44359: ("bags", None, 350),  # Quiver of a Thousand Feathers
    44768: ("bags", None, 350),  # Netherscale Ammo Pouch
    45100: ("bags", None,   1),  # Leatherworker's Satchel
    45117: ("bags", None, 360),  # Bag of Many Hides

    # ----- Misc (trinkets, toys, transforms, cloth boots) -----
    22815: ("misc", None,   1),  # Gordok Ogre Suit (transform toy)
    23190: ("misc", None, 150),  # Heavy Leather Ball (toy)
    32461: ("misc", None, 350),  # Riding Crop (trinket)
    32482: ("misc", None, 300),  # Comfortable Insoles (trinket)
    44953: ("misc", None, 285),  # Winter Boots (cloth boots, quest LW)
}


def _load_snapshot():
    items = json.loads((SNAPSHOT_DIR / "item_sparse.json").read_text(encoding="utf-8"))
    item_lookup = {it["itemId"]: it for it in items}
    recipes = json.loads((SNAPSHOT_DIR / "recipes.json").read_text(encoding="utf-8"))
    return recipes, item_lookup


def _classify_recipe(recipe, item_lookup):
    spell_id = recipe["spellId"]
    if spell_id in MANUAL_SPELLS:
        return MANUAL_SPELLS[spell_id]

    info = item_lookup.get(recipe.get("createdItemId"), {})
    sort_order = recipe.get("requiredSkill") or 1
    armor = info.get("armorType")
    if armor in ("leather", "mail"):
        slot = info.get("inventorySlot")
        sub = SLOT_TO_ARMOR_SUB.get(slot)
        if sub:
            return (armor, sub, sort_order)
        raise AssertionError(
            f"LW spellId={spell_id} ({info.get('name')}) is {armor} armor "
            f"but has unrecognised inventorySlot={slot!r}."
        )
    raise AssertionError(
        f"LW spellId={spell_id} createdItem={recipe.get('createdItemId')} "
        f"({info.get('name')}) has no manual classification and is not "
        f"leather/mail armor. Add to MANUAL_SPELLS."
    )


HEADER = (
    "# Leatherworking taxonomy and per-spellId classification whitelist.\n"
    "# Generated by tools/recipe-metadata/_gen_leatherworking_taxonomy.py — re-run\n"
    "# that helper if you need to regenerate from the Python source of truth.\n"
    "# Armor (leather/mail) is auto-derived from DB2 Item.ClassID=4/SubclassID\n"
    "# via the snapshot's armorType field.\n"
)


def main():
    recipes, item_lookup = _load_snapshot()
    lw = [r for r in recipes if r["profession"] == "leatherworking"]

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
    for recipe in lw:
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

    expected_count = 379
    actual_count = len(classified)
    assert actual_count == expected_count, (
        f"Classified {actual_count} entries, expected {expected_count} LW recipes"
    )

    target = Path(__file__).parent / "remediation" / "taxonomy" / "leatherworking.yaml"
    target.write_text("".join(out), encoding="utf-8")
    print(f"Wrote {actual_count} spell classifications to {target}")


if __name__ == "__main__":
    main()
