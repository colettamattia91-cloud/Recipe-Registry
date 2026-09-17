"""One-shot helper: emit the tailoring.yaml taxonomy with explicit per-spellId
classification for all 329 Vanilla+TBC tailoring recipes.

Architecture:
- 257 cloth armor recipes: subcategory auto-derived from item_sparse.inventorySlot
  (head, shoulder, chest [merges robe], waist, legs, feet, hands, wrist, back).
- 72 non-armor recipes manually classified (bags, shirts, cloth materials,
  spellthreads, misc).

Usage: python tools/recipe-metadata/_gen_tailoring_taxonomy.py
"""

import json
from pathlib import Path

SNAPSHOT_DIR = Path(__file__).parent / "snapshots" / "tbc-2.5.5"

CATEGORIES = [
    ("armor",        "Cloth Armor",   10),
    ("bags",         "Bags",          20),
    ("shirts",       "Shirts",        30),
    ("cloth",        "Cloth & Bolts", 40),
    ("spellthreads", "Spellthreads",  50),
    ("misc",         "Miscellaneous", 999),
]

SUBCATEGORIES = {
    "armor": [
        ("head",     "Head",     10),
        ("shoulder", "Shoulder", 20),
        ("chest",    "Chest",    30),
        ("waist",    "Waist",    40),
        ("legs",     "Legs",     50),
        ("feet",     "Feet",     60),
        ("hands",    "Hands",    70),
        ("wrist",    "Wrist",    80),
        ("back",     "Back",     90),
    ],
}

# Auto-derive maps inventorySlot -> armor subcategory. Robe (InventoryType=20)
# is the same slot as chest visually; merge.
SLOT_TO_ARMOR_SUB = {
    "head": "head",
    "shoulder": "shoulder",
    "chest": "chest",
    "robe":  "chest",
    "waist": "waist",
    "legs":  "legs",
    "feet":  "feet",
    "hands": "hands",
    "wrist": "wrist",
    "back":  "back",
}

# Manual classification for non-armor items.
MANUAL_SPELLS = {
    # ----- Bags (Vanilla) -----
    3755:  ("bags", None,   1),  # Linen Bag
    3757:  ("bags", None,   1),  # Woolen Bag
    3813:  ("bags", None,   1),  # Small Silk Pack
    6686:  ("bags", None,  70),  # Red Linen Bag
    3758:  ("bags", None,  95),  # Green Woolen Bag
    6688:  ("bags", None, 115),  # Red Woolen Bag
    6693:  ("bags", None, 175),  # Green Silk Pack
    6695:  ("bags", None, 185),  # Black Silk Pack
    12065: ("bags", None,   1),  # Mageweave Bag
    12079: ("bags", None,   1),  # Red Mageweave Bag
    27658: ("bags", None, 225),  # Enchanted Mageweave Pouch
    18405: ("bags", None, 260),  # Runecloth Bag
    26085: ("bags", None, 260),  # Soul Pouch
    27659: ("bags", None, 275),  # Enchanted Runecloth Bag
    27724: ("bags", None, 275),  # Cenarion Herb Bag
    26086: ("bags", None, 285),  # Felcloth Bag
    18445: ("bags", None, 300),  # Mooncloth Bag
    18455: ("bags", None, 300),  # Bottomless Bag
    26087: ("bags", None, 300),  # Core Felcloth Bag
    27660: ("bags", None, 300),  # Big Bag of Enchantment
    27725: ("bags", None, 300),  # Satchel of Cenarius
    # ----- Bags (TBC) -----
    26746: ("bags", None,   1),  # Netherweave Bag
    26749: ("bags", None, 340),  # Imbued Netherweave Bag
    31459: ("bags", None, 340),  # Bag of Jewels
    26755: ("bags", None, 375),  # Spellfire Bag
    26759: ("bags", None, 375),  # Ebon Shadowbag
    26763: ("bags", None, 375),  # Primal Mooncloth Bag
    50194: ("bags", None, 375),  # Mycah's Botanical Bag

    # ----- Shirts (body slot, cosmetic) -----
    2392:  ("shirts", None,   1),  # Red Linen Shirt
    2393:  ("shirts", None,   1),  # White Linen Shirt
    2394:  ("shirts", None,   1),  # Blue Linen Shirt
    2396:  ("shirts", None,   1),  # Green Linen Shirt
    2406:  ("shirts", None,   1),  # Gray Woolen Shirt
    3915:  ("shirts", None,   1),  # Brown Linen Shirt
    3866:  ("shirts", None,   1),  # Stylish Red Shirt
    3871:  ("shirts", None,   1),  # Formal White Shirt
    8483:  ("shirts", None,   1),  # White Swashbuckler's Shirt
    8489:  ("shirts", None,   1),  # Red Swashbuckler's Shirt
    12061: ("shirts", None,   1),  # Orange Mageweave Shirt
    7892:  ("shirts", None, 120),  # Stylish Blue Shirt
    7893:  ("shirts", None, 120),  # Stylish Green Shirt
    3869:  ("shirts", None, 135),  # Bright Yellow Shirt
    3870:  ("shirts", None, 155),  # Dark Silk Shirt
    3872:  ("shirts", None, 185),  # Rich Purple Silk Shirt
    21945: ("shirts", None, 190),  # Green Holiday Shirt
    3873:  ("shirts", None, 200),  # Black Swashbuckler's Shirt
    12064: ("shirts", None, 220),  # Orange Martial Shirt
    12075: ("shirts", None, 230),  # Lavender Mageweave Shirt
    12080: ("shirts", None, 235),  # Pink Mageweave Shirt
    12085: ("shirts", None, 240),  # Tuxedo Shirt

    # ----- Cloth & Bolts (materials) -----
    2963:  ("cloth", None,   1),  # Bolt of Linen Cloth
    2964:  ("cloth", None,   1),  # Bolt of Woolen Cloth
    3839:  ("cloth", None,   1),  # Bolt of Silk Cloth
    3865:  ("cloth", None,   1),  # Bolt of Mageweave
    18401: ("cloth", None,   1),  # Bolt of Runecloth
    26745: ("cloth", None,   1),  # Bolt of Netherweave
    26747: ("cloth", None, 325),  # Bolt of Imbued Netherweave
    26750: ("cloth", None, 345),  # Bolt of Soulcloth
    18560: ("cloth", None, 250),  # Mooncloth
    26751: ("cloth", None, 350),  # Primal Mooncloth
    31373: ("cloth", None, 350),  # Spellcloth
    36686: ("cloth", None, 350),  # Shadowcloth

    # ----- Spellthreads (TBC caster leg enhancers) -----
    31430: ("spellthreads", None, 335),  # Mystic Spellthread
    31431: ("spellthreads", None, 335),  # Silver Spellthread
    31432: ("spellthreads", None, 375),  # Runic Spellthread
    31433: ("spellthreads", None, 375),  # Golden Spellthread

    # ----- Misc (dresses, nets, transform) -----
    8465:  ("misc", None,   1),  # Simple Dress
    12077: ("misc", None,   1),  # Simple Black Dress
    26407: ("misc", None, 250),  # Festival Suit
    22813: ("misc", None,   1),  # Gordok Ogre Suit (transform)
    31460: ("misc", None,   1),  # Netherweave Net (fishing)
    31461: ("misc", None, 325),  # Heavy Netherweave Net (fishing)
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
    if info.get("armorType") == "cloth":
        slot = info.get("inventorySlot")
        sub = SLOT_TO_ARMOR_SUB.get(slot)
        if sub:
            return ("armor", sub, sort_order)
    raise AssertionError(
        f"Tailoring spellId={spell_id} createdItem={recipe.get('createdItemId')} "
        f"({info.get('name')}) has no manual classification and is not "
        f"a recognised cloth armor slot. Add to MANUAL_SPELLS."
    )


HEADER = (
    "# Tailoring taxonomy and per-spellId classification whitelist.\n"
    "# Generated by tools/recipe-metadata/_gen_tailoring_taxonomy.py — re-run\n"
    "# that helper if you need to regenerate from the Python source of truth.\n"
    "# Cloth armor slots auto-derived from DB2 ItemSparse.InventoryType via the\n"
    "# snapshot's inventorySlot field (robe collapsed into chest).\n"
)


def main():
    recipes, item_lookup = _load_snapshot()
    ta = [r for r in recipes if r["profession"] == "tailoring"]

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
    for recipe in ta:
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

    expected_count = 329
    actual_count = len(classified)
    assert actual_count == expected_count, (
        f"Classified {actual_count} entries, expected {expected_count} tailoring recipes"
    )

    target = Path(__file__).parent / "remediation" / "taxonomy" / "tailoring.yaml"
    target.write_text("".join(out), encoding="utf-8")
    print(f"Wrote {actual_count} spell classifications to {target}")


if __name__ == "__main__":
    main()
