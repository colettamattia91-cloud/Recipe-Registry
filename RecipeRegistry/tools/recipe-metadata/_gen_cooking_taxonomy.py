"""One-shot helper: emit the cooking.yaml taxonomy with explicit per-spellId
classification for all 116 Vanilla+TBC cooking recipes.

Classification axis: PRIMARY STAT BUFF granted by the food's well-fed aura.
The derivation script that produced these mappings traces the DB2 chain
   cooking spell -> created item -> ItemEffect (TriggerType=0) -> use spell
   -> EffectAura=23 (PeriodicTriggerSpell) or Effect=64 (immediate trigger)
   -> ApplyAura ModStat / ModAttackPower / ModPowerRegen / ...
For each food the script picks the non-spirit primary stat (TBC raid foods
typically buff MAIN + SPI; the main stat is the filter axis).

Manual overrides are used for: foods whose buff aura wasn't covered by the
derivation (Skullfish Soup crit, Spicy Hot Talbuk hit), and special foods
(transform, pet food, fishing buff, proc damage).

Usage: python tools/recipe-metadata/_gen_cooking_taxonomy.py
"""

from pathlib import Path

CATEGORIES = [
    ("strength",     "Strength",      10),
    ("agility",      "Agility",       20),
    ("stamina",      "Stamina",       30),
    ("intellect",    "Intellect",     40),
    ("spirit",       "Spirit",        50),
    ("spell_power",  "Spell Power",   60),
    ("mp5",          "Mana Regen",    70),
    ("attack_power", "Attack Power",  80),
    ("crit",         "Crit Rating",   90),
    ("hit",          "Hit Rating",   100),
    ("basic",        "Basic",        110),
    ("special",      "Special",      120),
    ("misc",         "Miscellaneous", 999),
]

SUBCATEGORIES = {}  # Cooking is flat at the category level.

# (category, subcategory, sortOrder) keyed by spellId. sortOrder uses
# requiredSkill (or 1 for skill-less starter recipes).
SPELLS = {
    # ===== TBC =====
    37836: ("basic",        None,   1),  # Spice Bread
    42296: ("basic",        None,   1),  # Stewed Trout
    42302: ("stamina",      None,   1),  # Fisherman's Feast (+30 STA via feast aura)
    42305: ("mp5",          None,   1),  # Hot Buttered Trout
    33276: ("stamina",      None,   1),  # Lynx Steak
    33277: ("stamina",      None,   1),  # Roasted Moongraze Tenderloin
    43779: ("special",      None,   1),  # Delicious Chocolate Cake ("Very Happy")
    33278: ("stamina",      None,  50),  # Bat Bites
    28267: ("stamina",      None,  60),  # Crunchy Spider Surprise
    45695: ("special",      None, 100),  # Captain Rumsey's Lager (fishing buff)
    46684: ("attack_power", None, 250),  # Charred Bear Kabobs
    46688: ("spell_power",  None, 250),  # Juicy Bear Burger
    33279: ("stamina",      None, 300),  # Buzzard Bites
    33284: ("attack_power", None, 300),  # Ravager Dog
    33290: ("basic",        None, 300),  # Blackened Trout
    33291: ("stamina",      None, 300),  # Feltail Delight
    36210: ("stamina",      None, 300),  # Clam Bar
    43758: ("special",      None, 300),  # Stormchops (lightning proc damage)
    43761: ("basic",        None, 300),  # Broiled Bloodfin
    43772: ("special",      None, 300),  # Kibler's Bits (pet food: +20 AP to pet)
    33285: ("stamina",      None, 310),  # Sporeling Snack
    33292: ("stamina",      None, 310),  # Blackened Sporefish (+20 STA + 8 MP5)
    33286: ("spell_power",  None, 315),  # Blackened Basilisk
    33293: ("agility",      None, 320),  # Grilled Mudfish
    33294: ("spell_power",  None, 320),  # Poached Bluefish
    33287: ("strength",     None, 325),  # Roasted Clefthoof
    33288: ("agility",      None, 325),  # Warp Burger
    33289: ("stamina",      None, 325),  # Talbuk Steak
    33295: ("spirit",       None, 325),  # Golden Fish Sticks
    43707: ("crit",         None, 325),  # Skullfish Soup (+20 spell crit rating)
    43765: ("hit",          None, 325),  # Spicy Hot Talbuk (+20 hit rating)
    45022: ("stamina",      None, 325),  # Hot Apple Cider (stamina + mp5)
    38867: ("stamina",      None, 335),  # Mok'Nathal Shortribs
    38868: ("spell_power",  None, 335),  # Crunchy Serpent
    33296: ("stamina",      None, 350),  # Spicy Crawdad

    # ===== Vanilla =====
    2538:  ("basic",        None,   1),  # Charred Wolf Meat
    2540:  ("basic",        None,   1),  # Roasted Boar Meat
    6499:  ("stamina",      None,   1),  # Boiled Clams
    6500:  ("stamina",      None,   1),  # Goblin Deviled Clams
    13028: ("mp5",          None,   1),  # Goldthorn Tea (mana regen)
    21175: ("stamina",      None,   1),  # Spider Sausage
    24801: ("strength",     None,   1),  # Smoked Desert Dumplings
    7751:  ("basic",        None,   1),  # Brilliant Smallfish
    7752:  ("basic",        None,   1),  # Slitherskin Mackerel
    8604:  ("stamina",      None,   1),  # Herb Baked Egg
    15935: ("stamina",      None,   1),  # Crispy Bat Wing
    21143: ("stamina",      None,   1),  # Gingerbread Cookie
    2795:  ("stamina",      None,  10),  # Beer Basted Boar Ribs
    6412:  ("stamina",      None,  10),  # Kaldorei Spider Kabob
    6413:  ("basic",        None,  20),  # Scorpid Surprise
    2539:  ("stamina",      None,  30),  # Spiced Wolf Meat
    6414:  ("stamina",      None,  35),  # Roasted Kodo Meat
    21144: ("stamina",      None,  35),  # Egg Nog (winter veil food)
    8607:  ("basic",        None,  40),  # Smoked Bear Meat
    2542:  ("stamina",      None,  50),  # Goretusk Liver Pie
    6415:  ("stamina",      None,  50),  # Fillet of Frenzy
    6416:  ("stamina",      None,  50),  # Strider Stew
    7753:  ("basic",        None,  50),  # Longjaw Mud Snapper
    7754:  ("basic",        None,  50),  # Loch Frenzy Delight
    7827:  ("basic",        None,  50),  # Rainbow Fin Albacore
    3371:  ("stamina",      None,  60),  # Blood Sausage
    9513:  ("special",      None,  60),  # Thistle Tea (restores 100 energy for rogues)
    2541:  ("stamina",      None,  65),  # Coyote Steak
    2543:  ("basic",        None,  75),  # Westfall Stew
    2544:  ("stamina",      None,  75),  # Crab Cake
    3370:  ("stamina",      None,  80),  # Crocolisk Steak
    25704: ("mp5",          None,  80),  # Smoked Sagefish
    2545:  ("mp5",          None,  85),  # Cooked Crab Claw
    8238:  ("special",      None,  85),  # Savory Deviate Delight (transform)
    3372:  ("stamina",      None,  90),  # Murloc Fin Soup
    6417:  ("basic",        None,  90),  # Dig Rat Stew
    6501:  ("basic",        None,  90),  # Clam Chowder
    2547:  ("stamina",      None, 100),  # Redridge Goulash
    2549:  ("stamina",      None, 100),  # Seasoned Wolf Kabob
    6418:  ("stamina",      None, 100),  # Crispy Lizard Tail
    7755:  ("basic",        None, 100),  # Bristle Whisker Catfish
    2546:  ("stamina",      None, 110),  # Dry Pork Ribs
    2548:  ("basic",        None, 110),  # Succulent Pork Ribs
    3377:  ("stamina",      None, 110),  # Gooey Spider Cake
    3397:  ("stamina",      None, 110),  # Big Bear Steak
    6419:  ("stamina",      None, 110),  # Lean Venison
    3373:  ("stamina",      None, 120),  # Crocolisk Gumbo
    3398:  ("stamina",      None, 125),  # Hot Lion Chops
    15853: ("stamina",      None, 125),  # Lean Wolf Steak
    3376:  ("stamina",      None, 130),  # Curiously Tasty Omelet
    3399:  ("stamina",      None, 150),  # Tasty Lion Steak
    24418: ("stamina",      None, 150),  # Heavy Crocolisk Stew
    3400:  ("stamina",      None, 175),  # Soothing Turtle Bisque
    4094:  ("stamina",      None, 175),  # Barbecued Buzzard Wing
    7213:  ("stamina",      None, 175),  # Giant Clam Scorcho
    7828:  ("basic",        None, 175),  # Rockscale Cod
    15855: ("stamina",      None, 175),  # Roast Raptor
    15856: ("stamina",      None, 175),  # Hot Wolf Ribs
    15861: ("stamina",      None, 175),  # Jungle Stew
    15863: ("stamina",      None, 175),  # Carrion Surprise
    15865: ("stamina",      None, 175),  # Mystery Stew
    20916: ("basic",        None, 175),  # Mithril Head Trout
    25954: ("mp5",          None, 175),  # Sagefish Delight
    15906: ("special",      None, 200),  # Dragonbreath Chili (fire damage proc)
    15910: ("stamina",      None, 200),  # Heavy Kodo Stew
    15915: ("stamina",      None, 225),  # Spiced Chili Crab
    15933: ("stamina",      None, 225),  # Monster Omelet
    18238: ("basic",        None, 225),  # Spotted Yellowtail
    18239: ("stamina",      None, 225),  # Cooked Glossy Mightfish
    18241: ("basic",        None, 225),  # Filet of Redgill
    20626: ("basic",        None, 225),  # Undermine Clam Chowder
    22480: ("stamina",      None, 225),  # Tender Wolf Steak
    18240: ("agility",      None, 240),  # Grilled Squid
    18242: ("spirit",       None, 240),  # Hot Smoked Bass
    18243: ("mp5",          None, 250),  # Nightfin Soup
    18244: ("basic",        None, 250),  # Poached Sunscale Salmon
    18245: ("basic",        None, 275),  # Lobster Stew
    18246: ("stamina",      None, 275),  # Mightfish Steak
    18247: ("basic",        None, 275),  # Baked Salmon
    22761: ("intellect",    None, 275),  # Runn Tum Tuber Surprise
    25659: ("stamina",      None, 300),  # Dirge's Kickin' Chimaerok Chops
}


HEADER = (
    "# Cooking taxonomy: classification by PRIMARY STAT BUFF.\n"
    "# Generated by tools/recipe-metadata/_gen_cooking_taxonomy.py — re-run that\n"
    "# helper if you need to regenerate from the Python source of truth.\n"
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

    expected_count = 116
    actual_count = len(SPELLS)
    assert actual_count == expected_count, (
        f"Whitelist has {actual_count} entries, expected {expected_count} cooking recipes"
    )

    target = Path(__file__).parent / "remediation" / "taxonomy" / "cooking.yaml"
    target.write_text("".join(out), encoding="utf-8")
    print(f"Wrote {actual_count} spell classifications to {target}")


if __name__ == "__main__":
    main()
