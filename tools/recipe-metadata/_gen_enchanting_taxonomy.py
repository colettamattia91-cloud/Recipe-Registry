"""One-shot helper: emit the enchanting.yaml taxonomy with explicit per-spellId
classification for all 223 Vanilla+TBC enchanting recipes.

Architecture:
- 192 recipes are pure enchantments (no createdItem) — classified by SLOT
  (weapon, 2h_weapon, shield, chest, bracer, gloves, cloak, boots, ring).
  Slot was extracted from the spell name pattern "Enchant <SLOT> - <Effect>"
  via a one-shot wago fetch and baked into SPELLS below.
- 31 recipes produce items: rods, wands, oils, materials (shards/dusts/spheres),
  and a few misc transmutes.

Usage: python tools/recipe-metadata/_gen_enchanting_taxonomy.py
"""

from pathlib import Path

CATEGORIES = [
    ("enchants",  "Enchants",       10),
    ("oils",      "Weapon Oils",    20),
    ("materials", "Materials",      30),  # Dusts, shards, spheres + Enchanted Bar/Leather transmutes
    ("rods",      "Rods",           40),  # Runed enchanting rods
    ("wands",     "Wands",          50),
    ("misc",      "Miscellaneous", 999),
]

SUBCATEGORIES = {
    "enchants": [
        ("weapon",    "Weapon (1H)",     10),
        ("2h_weapon", "Weapon (2H)",     20),
        ("shield",    "Shield",          30),
        ("chest",     "Chest",           40),
        ("bracer",    "Bracer",          50),
        ("gloves",    "Gloves",          60),
        ("cloak",     "Cloak",           70),
        ("boots",     "Boots",           80),
        ("ring",      "Ring",            90),
    ],
    "oils": [
        ("wizard", "Wizard Oils", 10),
        ("mana",   "Mana Oils",   20),
    ],
}

SPELLS = {
    # ===== Enchant recipes (no createdItem), classified by slot =====
    # TBC
    27899: ("enchants", "bracer",    1),
    27905: ("enchants", "bracer",    1),
    27944: ("enchants", "shield",    1),
    27957: ("enchants", "chest",     1),
    27961: ("enchants", "cloak",     1),
    33990: ("enchants", "chest",     1),
    33991: ("enchants", "chest",     1),
    33993: ("enchants", "gloves",    1),
    33995: ("enchants", "gloves",    1),
    33996: ("enchants", "gloves",    1),
    34001: ("enchants", "bracer",    1),
    34002: ("enchants", "bracer",    1),
    34004: ("enchants", "cloak",     1),
    44383: ("enchants", "shield",    1),
    27948: ("enchants", "boots",   305),
    27906: ("enchants", "bracer",  320),
    27950: ("enchants", "boots",   320),
    27911: ("enchants", "bracer",  325),
    27945: ("enchants", "shield",  325),
    27958: ("enchants", "chest",   325),
    34003: ("enchants", "cloak",   325),
    34009: ("enchants", "shield",  325),
    27962: ("enchants", "cloak",   330),
    27913: ("enchants", "bracer",  335),
    27946: ("enchants", "shield",  340),
    27951: ("enchants", "boots",   340),
    27967: ("enchants", "weapon",  340),
    27968: ("enchants", "weapon",  340),
    27960: ("enchants", "chest",   345),
    33992: ("enchants", "chest",   345),
    27914: ("enchants", "bracer",  350),
    27971: ("enchants", "2h_weapon", 350),
    27972: ("enchants", "weapon",  350),
    27975: ("enchants", "weapon",  350),
    33999: ("enchants", "gloves",  350),
    34005: ("enchants", "cloak",   350),
    34006: ("enchants", "cloak",   350),
    34010: ("enchants", "weapon",  350),
    42620: ("enchants", "weapon",  350),
    46578: ("enchants", "weapon",  350),
    27917: ("enchants", "bracer",  360),
    27920: ("enchants", "ring",    360),
    27924: ("enchants", "ring",    360),
    27947: ("enchants", "shield",  360),
    27977: ("enchants", "2h_weapon", 360),
    28003: ("enchants", "weapon",  360),
    28004: ("enchants", "weapon",  360),
    33994: ("enchants", "gloves",  360),
    33997: ("enchants", "gloves",  360),
    34007: ("enchants", "boots",   360),
    34008: ("enchants", "boots",   360),
    46594: ("enchants", "chest",   360),
    27926: ("enchants", "ring",    370),
    27954: ("enchants", "boots",   370),
    27927: ("enchants", "ring",    375),
    27981: ("enchants", "weapon",  375),
    27982: ("enchants", "weapon",  375),
    27984: ("enchants", "weapon",  375),
    42974: ("enchants", "weapon",  375),
    47051: ("enchants", "cloak",   375),
    # Vanilla
    7418:  ("enchants", "bracer",    1),
    7420:  ("enchants", "chest",     1),
    7426:  ("enchants", "chest",     1),
    7428:  ("enchants", "bracer",    1),
    7454:  ("enchants", "cloak",     1),
    7457:  ("enchants", "bracer",    1),
    7745:  ("enchants", "2h_weapon", 1),
    7748:  ("enchants", "chest",     1),
    7779:  ("enchants", "bracer",    1),
    7788:  ("enchants", "weapon",    1),
    7857:  ("enchants", "chest",     1),
    7861:  ("enchants", "cloak",     1),
    13378: ("enchants", "shield",    1),
    13421: ("enchants", "cloak",     1),
    13485: ("enchants", "shield",    1),
    13501: ("enchants", "bracer",    1),
    13503: ("enchants", "weapon",    1),
    13529: ("enchants", "2h_weapon", 1),
    13538: ("enchants", "chest",     1),
    13607: ("enchants", "chest",     1),
    13622: ("enchants", "bracer",    1),
    13626: ("enchants", "chest",     1),
    13631: ("enchants", "shield",    1),
    13635: ("enchants", "cloak",     1),
    13637: ("enchants", "boots",     1),
    13640: ("enchants", "chest",     1),
    13642: ("enchants", "bracer",    1),
    13644: ("enchants", "boots",     1),
    13648: ("enchants", "bracer",    1),
    13657: ("enchants", "cloak",     1),
    13659: ("enchants", "shield",    1),
    13661: ("enchants", "bracer",    1),
    13663: ("enchants", "chest",     1),
    13693: ("enchants", "weapon",    1),
    13695: ("enchants", "2h_weapon", 1),
    13700: ("enchants", "chest",     1),
    13746: ("enchants", "cloak",     1),
    13794: ("enchants", "cloak",     1),
    13815: ("enchants", "gloves",    1),
    13822: ("enchants", "bracer",    1),
    13836: ("enchants", "boots",     1),
    13858: ("enchants", "chest",     1),
    13887: ("enchants", "gloves",    1),
    13890: ("enchants", "boots",     1),
    13905: ("enchants", "shield",    1),
    13917: ("enchants", "chest",     1),
    13935: ("enchants", "boots",     1),
    13937: ("enchants", "2h_weapon", 1),
    13939: ("enchants", "bracer",    1),
    13941: ("enchants", "chest",     1),
    13943: ("enchants", "weapon",    1),
    13948: ("enchants", "gloves",    1),
    7443:  ("enchants", "chest",    20),
    7766:  ("enchants", "bracer",   60),
    7776:  ("enchants", "chest",    80),
    7782:  ("enchants", "bracer",   80),
    7771:  ("enchants", "cloak",    90),
    7786:  ("enchants", "weapon",   90),
    7793:  ("enchants", "2h_weapon", 100),
    13380: ("enchants", "2h_weapon", 110),
    13419: ("enchants", "cloak",   110),
    13464: ("enchants", "shield",  115),
    7859:  ("enchants", "bracer",  120),
    7863:  ("enchants", "boots",   125),
    7867:  ("enchants", "boots",   125),
    13522: ("enchants", "cloak",   135),
    13536: ("enchants", "bracer",  140),
    13612: ("enchants", "gloves",  145),
    13617: ("enchants", "gloves",  145),
    13620: ("enchants", "gloves",  145),
    13646: ("enchants", "bracer",  170),
    13653: ("enchants", "weapon",  175),
    13655: ("enchants", "weapon",  175),
    13687: ("enchants", "boots",   190),
    21931: ("enchants", "weapon",  190),
    13689: ("enchants", "shield",  195),
    13698: ("enchants", "gloves",  200),
    13817: ("enchants", "shield",  210),
    13841: ("enchants", "gloves",  215),
    13846: ("enchants", "bracer",  220),
    13868: ("enchants", "gloves",  225),
    13882: ("enchants", "cloak",   225),
    13915: ("enchants", "weapon",  230),
    13931: ("enchants", "bracer",  235),
    13933: ("enchants", "shield",  235),
    13945: ("enchants", "bracer",  245),
    13947: ("enchants", "gloves",  250),
    20008: ("enchants", "bracer",  255),
    20020: ("enchants", "boots",   260),
    13898: ("enchants", "weapon",  265),
    20014: ("enchants", "cloak",   265),
    20017: ("enchants", "shield",  265),
    20009: ("enchants", "bracer",  270),
    20012: ("enchants", "gloves",  270),
    20024: ("enchants", "boots",   275),
    20026: ("enchants", "chest",   275),
    20016: ("enchants", "shield",  280),
    20015: ("enchants", "cloak",   285),
    20029: ("enchants", "weapon",  285),
    20028: ("enchants", "chest",   290),
    23799: ("enchants", "weapon",  290),
    23800: ("enchants", "weapon",  290),
    23801: ("enchants", "bracer",  290),
    27837: ("enchants", "2h_weapon", 290),
    20010: ("enchants", "bracer",  295),
    20013: ("enchants", "gloves",  295),
    20023: ("enchants", "boots",   295),
    20030: ("enchants", "2h_weapon", 295),
    20033: ("enchants", "weapon",  295),
    20011: ("enchants", "bracer",  300),
    20025: ("enchants", "chest",   300),
    20031: ("enchants", "weapon",  300),
    20032: ("enchants", "weapon",  300),
    20034: ("enchants", "weapon",  300),
    20035: ("enchants", "2h_weapon", 300),
    20036: ("enchants", "2h_weapon", 300),
    22749: ("enchants", "weapon",  300),
    22750: ("enchants", "weapon",  300),
    23802: ("enchants", "bracer",  300),
    23803: ("enchants", "weapon",  300),
    23804: ("enchants", "weapon",  300),
    25072: ("enchants", "gloves",  300),
    25073: ("enchants", "gloves",  300),
    25074: ("enchants", "gloves",  300),
    25078: ("enchants", "gloves",  300),
    25079: ("enchants", "gloves",  300),
    25080: ("enchants", "gloves",  300),
    25081: ("enchants", "cloak",   300),
    25082: ("enchants", "cloak",   300),
    25083: ("enchants", "cloak",   300),
    25084: ("enchants", "cloak",   300),
    25086: ("enchants", "cloak",   300),

    # ===== Items WITH createdItem =====
    # --- Rods (Runed Copper -> Eternium) ---
    7421:  ("rods", None,  10),  # Runed Copper Rod
    7795:  ("rods", None,  20),  # Runed Silver Rod
    13628: ("rods", None,  30),  # Runed Golden Rod
    13702: ("rods", None,  40),  # Runed Truesilver Rod
    20051: ("rods", None,  50),  # Runed Arcanite Rod
    32664: ("rods", None,  60),  # Runed Fel Iron Rod
    32665: ("rods", None,  70),  # Runed Adamantite Rod
    32667: ("rods", None,  80),  # Runed Eternium Rod

    # --- Wands ---
    14293: ("wands", None, 10),  # Lesser Magic Wand
    14807: ("wands", None, 20),  # Greater Magic Wand
    14809: ("wands", None, 30),  # Lesser Mystic Wand
    14810: ("wands", None, 40),  # Greater Mystic Wand

    # --- Wizard Oils (spell power) ---
    25124: ("oils", "wizard",  10),  # Minor Wizard Oil (45)
    25126: ("oils", "wizard",  20),  # Lesser Wizard Oil (200)
    25128: ("oils", "wizard",  30),  # Wizard Oil (275)
    25129: ("oils", "wizard",  40),  # Brilliant Wizard Oil (300)
    28019: ("oils", "wizard",  50),  # Superior Wizard Oil (340)

    # --- Mana Oils (mp5) ---
    25125: ("oils", "mana",    10),  # Minor Mana Oil (150)
    25127: ("oils", "mana",    20),  # Lesser Mana Oil (250)
    25130: ("oils", "mana",    30),  # Brilliant Mana Oil (300)
    28016: ("oils", "mana",    40),  # Superior Mana Oil (310)

    # --- Materials (transmutes) ---
    28021: ("materials", None, 10),  # Arcane Dust (TBC transmute)
    42613: ("materials", None, 20),  # Small Prismatic Shard (variant 1)
    42615: ("materials", None, 21),  # Small Prismatic Shard (variant 2)
    28022: ("materials", None, 30),  # Large Prismatic Shard (variant 1)
    45765: ("materials", None, 31),  # Large Prismatic Shard (variant 2)
    28027: ("materials", None, 40),  # Prismatic Sphere
    28028: ("materials", None, 50),  # Void Sphere
    17180: ("materials", None, 60),  # Enchanted Thorium Bar (vanilla)
    17181: ("materials", None, 70),  # Enchanted Leather (vanilla)

    # --- Misc ---
    15596: ("misc", None, 10),  # Smoking Heart of the Mountain (rare elemental transmute)
}


HEADER = (
    "# Enchanting taxonomy and per-spellId classification whitelist.\n"
    "# Generated by tools/recipe-metadata/_gen_enchanting_taxonomy.py — re-run\n"
    "# that helper if you need to regenerate from the Python source of truth.\n"
    "# Slot info for 192 pure-enchant recipes was baked from a wago SpellName\n"
    "# fetch (parsed from 'Enchant <SLOT> - <Effect>' name pattern).\n"
)


def main():
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
    out.append("spells:\n")
    for spell_id in sorted(SPELLS):
        category, subcategory, sort_order = SPELLS[spell_id]
        parts = [f"category: {category}"]
        if subcategory is not None:
            parts.append(f"subcategory: {subcategory}")
        parts.append(f"sortOrder: {sort_order}")
        out.append(f"  {spell_id}: " + ", ".join(parts) + "\n")

    expected_count = 223
    actual_count = len(SPELLS)
    assert actual_count == expected_count, (
        f"Whitelist has {actual_count} entries, expected {expected_count} enchanting recipes"
    )

    target = Path(__file__).parent / "remediation" / "taxonomy" / "enchanting.yaml"
    target.write_text("".join(out), encoding="utf-8")
    print(f"Wrote {actual_count} spell classifications to {target}")


if __name__ == "__main__":
    main()
