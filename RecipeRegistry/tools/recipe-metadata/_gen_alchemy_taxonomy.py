"""One-shot helper: emit the alchemy.yaml taxonomy with explicit per-spellId
classification for all 186 Vanilla+TBC alchemy recipes. Run once, then delete.

Usage: python tools/recipe-metadata/_gen_alchemy_taxonomy.py
Writes:  tools/recipe-metadata/remediation/taxonomy/alchemy.yaml
"""

from pathlib import Path

CATEGORIES = [
    ("potions",    "Potions",          10),
    ("elixirs",    "Elixirs",          20),
    ("flasks",     "Flasks",           30),
    ("oils",       "Weapon Oils",      40),
    ("transmutes", "Transmutes",       50),
    ("cauldrons",  "Cauldrons",        60),
    ("stones",     "Alchemist Stones", 70),
    ("misc",       "Miscellaneous",   999),
]

SUBCATEGORIES = {
    "potions": [
        ("healing",      "Healing",      10),
        ("mana",         "Mana",         20),
        ("rejuvenation", "Rejuvenation", 30),
        ("protection",   "Protection",   40),
        ("combat",       "Combat",       50),
        ("utility",      "Utility",      60),
    ],
    "elixirs": [
        ("battle",   "Battle Elixirs",   10),
        ("guardian", "Guardian Elixirs", 20),
        ("utility",  "Utility Elixirs",  30),
    ],
    "transmutes": [
        ("elemental", "Elemental", 10),
        ("metal",     "Metal",     20),
        ("gem",       "Gem",       30),
        ("special",   "Special",   40),
    ],
    "stones": [
        ("basic",     "Basic",     10),
        ("specialty", "Specialty", 20),
    ],
}

# (category, subcategory, sortOrder) keyed by spellId.
# sortOrder reflects tier/skill ordering WITHIN the subcategory, intended to
# drive the UI's per-subcategory sort.
SPELLS = {
    # ---- Vanilla potions ----
    # Healing tier: Minor(10) → Discolored(15) → Lesser(20) → Healing(30) → Greater(40) → Superior(50) → Major(60)
    2330:  ("potions", "healing",      10),  # Minor Healing Potion
    4508:  ("potions", "healing",      15),  # Discolored Healing Potion
    2337:  ("potions", "healing",      20),  # Lesser Healing Potion
    3447:  ("potions", "healing",      30),  # Healing Potion
    7181:  ("potions", "healing",      40),  # Greater Healing Potion
    11457: ("potions", "healing",      50),  # Superior Healing Potion
    17556: ("potions", "healing",      60),  # Major Healing Potion

    # Mana tier: Minor(10) → Lesser(20) → Mana(30) → Greater(40) → Superior(50) → Major(60) → Mageblood(70)
    2331:  ("potions", "mana",         10),  # Minor Mana Potion
    3173:  ("potions", "mana",         20),  # Lesser Mana Potion
    3452:  ("potions", "mana",         30),  # Mana Potion
    11448: ("potions", "mana",         40),  # Greater Mana Potion
    17553: ("potions", "mana",         50),  # Superior Mana Potion
    17580: ("potions", "mana",         60),  # Major Mana Potion

    # Rejuvenation
    2332:  ("potions", "rejuvenation", 10),  # Minor Rejuvenation Potion
    11452: ("potions", "rejuvenation", 20),  # Restorative Potion
    3170:  ("potions", "rejuvenation", 30),  # Weak Troll's Blood Potion
    3176:  ("potions", "rejuvenation", 40),  # Strong Troll's Blood Potion
    3451:  ("potions", "rejuvenation", 50),  # Mighty Troll's Blood Potion
    24368: ("potions", "rejuvenation", 60),  # Major Troll's Blood Potion
    22732: ("potions", "rejuvenation", 70),  # Major Rejuvenation Potion

    # Protection (schools sorted: holy/shadow/fire/frost/nature/arcane)
    # Vanilla regular tier (10-60), Greater tier (110-160)
    7255:  ("potions", "protection",    10),  # Holy Protection Potion
    7256:  ("potions", "protection",    20),  # Shadow Protection Potion
    7257:  ("potions", "protection",    30),  # Fire Protection Potion
    7258:  ("potions", "protection",    40),  # Frost Protection Potion
    7259:  ("potions", "protection",    50),  # Nature Protection Potion
    3172:  ("potions", "protection",    55),  # Minor Magic Resistance Potion
    11453: ("potions", "protection",    60),  # Magic Resistance Potion
    17579: ("potions", "protection",   110),  # Greater Holy Protection
    17578: ("potions", "protection",   120),  # Greater Shadow Protection
    17574: ("potions", "protection",   130),  # Greater Fire Protection
    17575: ("potions", "protection",   140),  # Greater Frost Protection
    17576: ("potions", "protection",   150),  # Greater Nature Protection
    17577: ("potions", "protection",   160),  # Greater Arcane Protection

    # Combat
    6617:  ("potions", "combat",        10),  # Rage Potion
    6618:  ("potions", "combat",        20),  # Great Rage Potion
    17552: ("potions", "combat",        30),  # Mighty Rage Potion
    6624:  ("potions", "combat",        40),  # Free Action Potion
    24367: ("potions", "combat",        50),  # Living Action Potion
    4942:  ("potions", "combat",        60),  # Lesser Stoneshield Potion
    17570: ("potions", "combat",        70),  # Greater Stoneshield Potion
    3175:  ("potions", "combat",        80),  # Limited Invulnerability Potion

    # Utility
    2335:  ("potions", "utility",       10),  # Swiftness Potion
    7841:  ("potions", "utility",       20),  # Swim Speed Potion
    3174:  ("potions", "utility",       30),  # Potion of Curing
    17572: ("potions", "utility",       35),  # Purification Potion
    3448:  ("potions", "utility",       40),  # Lesser Invisibility Potion
    11464: ("potions", "utility",       50),  # Invisibility Potion
    15833: ("potions", "utility",       60),  # Dreamless Sleep Potion
    24366: ("potions", "utility",       70),  # Greater Dreamless Sleep Potion
    11458: ("potions", "utility",       80),  # Wildvine Potion
    24266: ("potions", "utility",       90),  # Gurubashi Mojo Madness
    6619:  ("potions", "utility",       95),  # Cowardly Flight Potion
    11456: ("potions", "utility",      100),  # Goblin Rocket Fuel

    # ---- Vanilla elixirs ----
    # Battle: rough tier by item power
    2329:  ("elixirs", "battle",        10),  # Elixir of Lion's Strength
    3230:  ("elixirs", "battle",        15),  # Elixir of Minor Agility
    2333:  ("elixirs", "battle",        20),  # Elixir of Lesser Agility
    3188:  ("elixirs", "battle",        25),  # Elixir of Ogre's Strength
    3171:  ("elixirs", "battle",        30),  # Elixir of Wisdom
    7845:  ("elixirs", "battle",        40),  # Elixir of Firepower
    11449: ("elixirs", "battle",        50),  # Elixir of Agility
    11461: ("elixirs", "battle",        60),  # Arcane Elixir
    11465: ("elixirs", "battle",        70),  # Elixir of Greater Intellect
    11467: ("elixirs", "battle",        80),  # Elixir of Greater Agility
    11472: ("elixirs", "battle",        90),  # Elixir of Giants
    11476: ("elixirs", "battle",       100),  # Elixir of Shadow Power
    11477: ("elixirs", "battle",       105),  # Elixir of Demonslaying
    21923: ("elixirs", "battle",       110),  # Elixir of Frost Power
    26277: ("elixirs", "battle",       120),  # Elixir of Greater Firepower
    17555: ("elixirs", "battle",       130),  # Elixir of the Sages
    17557: ("elixirs", "battle",       140),  # Elixir of Brute Force
    17571: ("elixirs", "battle",       150),  # Elixir of the Mongoose
    17573: ("elixirs", "battle",       160),  # Greater Arcane Elixir
    24365: ("elixirs", "battle",       170),  # Mageblood Potion (vanilla mp/5 elixir)

    # Guardian
    7183:  ("elixirs", "guardian",      10),  # Elixir of Minor Defense
    2334:  ("elixirs", "guardian",      20),  # Elixir of Minor Fortitude
    3177:  ("elixirs", "guardian",      30),  # Elixir of Defense
    3450:  ("elixirs", "guardian",      40),  # Elixir of Fortitude
    11450: ("elixirs", "guardian",      50),  # Elixir of Greater Defense
    17554: ("elixirs", "guardian",      60),  # Elixir of Superior Defense

    # Utility
    8240:  ("elixirs", "utility",       10),  # Elixir of Giant Growth
    2336:  ("elixirs", "utility",       15),  # Elixir of Tongues (NYI)
    7179:  ("elixirs", "utility",       20),  # Elixir of Water Breathing
    22808: ("elixirs", "utility",       25),  # Elixir of Greater Water Breathing
    11447: ("elixirs", "utility",       30),  # Elixir of Water Walking
    3453:  ("elixirs", "utility",       40),  # Elixir of Detect Lesser Invisibility
    11460: ("elixirs", "utility",       50),  # Elixir of Detect Undead
    11478: ("elixirs", "utility",       60),  # Elixir of Detect Demon
    12609: ("elixirs", "utility",       70),  # Catseye Elixir
    11468: ("elixirs", "utility",       80),  # Elixir of Dream Vision

    # ---- Vanilla flasks (no sub) ----
    17634: ("flasks", None, 10),  # Flask of Petrification
    17635: ("flasks", None, 20),  # Flask of the Titans
    17636: ("flasks", None, 30),  # Flask of Distilled Wisdom
    17637: ("flasks", None, 40),  # Flask of Supreme Power
    17638: ("flasks", None, 50),  # Flask of Chromatic Resistance

    # ---- Vanilla oils (no sub) ----
    7836:  ("oils", None, 10),  # Blackmouth Oil
    7837:  ("oils", None, 20),  # Fire Oil
    11451: ("oils", None, 30),  # Oil of Immolation
    3449:  ("oils", None, 40),  # Shadow Oil
    3454:  ("oils", None, 50),  # Frost Oil
    17551: ("oils", None, 60),  # Stonescale Oil

    # ---- Vanilla transmutes ----
    11479: ("transmutes", "metal",     10),  # Gold Bar
    11480: ("transmutes", "metal",     20),  # Truesilver Bar
    17187: ("transmutes", "metal",     30),  # Arcanite Bar
    25146: ("transmutes", "elemental",  5),  # Elemental Fire
    17559: ("transmutes", "elemental", 10),  # Essence of Fire
    17560: ("transmutes", "elemental", 20),  # Essence of Earth
    17565: ("transmutes", "elemental", 21),  # Essence of Earth (alt direction)
    17561: ("transmutes", "elemental", 30),  # Essence of Water
    17563: ("transmutes", "elemental", 31),  # Essence of Water (alt direction)
    17562: ("transmutes", "elemental", 40),  # Essence of Air
    17564: ("transmutes", "elemental", 50),  # Essence of Undeath
    17566: ("transmutes", "elemental", 60),  # Living Essence

    # ---- Vanilla stones (basic) ----
    11459: ("stones", "basic", 10),  # Philosopher's Stone
    17632: ("stones", "basic", 20),  # Alchemist's Stone

    # ---- Vanilla misc ----
    11473: ("misc", None, 10),  # Ghost Dye
    11466: ("misc", None, 20),  # Gift of Arthas

    # ==== TBC potions ====
    28551: ("potions", "healing",      70),  # Super Healing Potion
    33732: ("potions", "healing",      80),  # Volatile Healing Potion
    28555: ("potions", "mana",         70),  # Super Mana Potion
    33733: ("potions", "mana",         80),  # Unstable Mana Potion
    38961: ("potions", "mana",         85),  # Fel Mana Potion
    28586: ("potions", "rejuvenation", 80),  # Super Rejuvenation Potion
    # TBC protection (Major tier)
    28577: ("potions", "protection",  210),  # Major Holy Protection Potion
    28576: ("potions", "protection",  220),  # Major Shadow Protection Potion
    28571: ("potions", "protection",  230),  # Major Fire Protection Potion
    28572: ("potions", "protection",  240),  # Major Frost Protection Potion
    28573: ("potions", "protection",  250),  # Major Nature Protection Potion
    28575: ("potions", "protection",  260),  # Major Arcane Protection Potion
    # TBC combat
    38962: ("potions", "combat",       90),  # Fel Regeneration Potion
    28550: ("potions", "combat",      100),  # Insane Strength Potion
    28563: ("potions", "combat",      110),  # Heroic Potion
    28564: ("potions", "combat",      120),  # Haste Potion
    28565: ("potions", "combat",      130),  # Destruction Potion
    28579: ("potions", "combat",      140),  # Ironshield Potion
    # TBC utility
    28546: ("potions", "utility",     110),  # Sneaking Potion
    28554: ("potions", "utility",     120),  # Shrouding Potion
    28562: ("potions", "utility",     130),  # Major Dreamless Sleep Potion
    45061: ("potions", "utility",     140),  # Mad Alchemist's Potion

    # ==== TBC elixirs ====
    28543: ("elixirs", "utility",      90),  # Elixir of Camouflage
    28552: ("elixirs", "utility",     100),  # Elixir of the Searching Eye
    28545: ("elixirs", "battle",      200),  # Elixir of Healing Power
    33741: ("elixirs", "battle",      210),  # Elixir of Mastery
    33740: ("elixirs", "battle",      220),  # Adept's Elixir
    39638: ("elixirs", "battle",      230),  # Elixir of Draenic Wisdom
    28570: ("elixirs", "battle",      240),  # Elixir of Major Mageblood
    28549: ("elixirs", "battle",      250),  # Elixir of Major Frost Power
    28553: ("elixirs", "battle",      260),  # Elixir of Major Agility
    38960: ("elixirs", "battle",      270),  # Fel Strength Elixir
    28544: ("elixirs", "battle",      280),  # Elixir of Major Strength
    28556: ("elixirs", "battle",      290),  # Elixir of Major Firepower
    28558: ("elixirs", "battle",      300),  # Elixir of Major Shadow Power
    33738: ("elixirs", "battle",      310),  # Onslaught Elixir
    28578: ("elixirs", "battle",      320),  # Elixir of Empowerment
    39636: ("elixirs", "guardian",     70),  # Elixir of Major Fortitude
    28557: ("elixirs", "guardian",     80),  # Elixir of Major Defense
    39639: ("elixirs", "guardian",     90),  # Elixir of Ironskin
    39637: ("elixirs", "guardian",    100),  # Earthen Elixir

    # ==== TBC flasks ====
    28587: ("flasks", None,  60),  # Flask of Fortification
    28588: ("flasks", None,  70),  # Flask of Mighty Restoration
    28589: ("flasks", None,  80),  # Flask of Relentless Assault
    28590: ("flasks", None,  90),  # Flask of Blinding Light
    28591: ("flasks", None, 100),  # Flask of Pure Death
    42736: ("flasks", None, 110),  # Flask of Chromatic Wonder

    # ==== TBC cauldrons ====
    41458: ("cauldrons", None, 10),  # Cauldron of Major Arcane Protection
    41500: ("cauldrons", None, 20),  # Cauldron of Major Fire Protection
    41501: ("cauldrons", None, 30),  # Cauldron of Major Frost Protection
    41502: ("cauldrons", None, 40),  # Cauldron of Major Nature Protection
    41503: ("cauldrons", None, 50),  # Cauldron of Major Shadow Protection

    # ==== TBC stones ====
    47046: ("stones", "specialty", 10),  # Guardian's Alchemist Stone
    47048: ("stones", "specialty", 20),  # Sorcerer's Alchemist Stone
    47049: ("stones", "specialty", 30),  # Redeemer's Alchemist Stone
    47050: ("stones", "specialty", 40),  # Assassin's Alchemist Stone

    # ==== TBC transmutes ====
    28580: ("transmutes", "elemental",  70),  # Primal Water
    28581: ("transmutes", "elemental",  80),  # Primal Shadow
    28582: ("transmutes", "elemental",  90),  # Primal Fire
    28583: ("transmutes", "elemental", 100),  # Primal Mana
    28584: ("transmutes", "elemental", 110),  # Primal Earth
    28585: ("transmutes", "elemental", 120),  # Primal Life
    # Discovered transmutes (Earth↔Life, Water↔Air, Fire↔Mana etc.) – skill 350 variants
    28567: ("transmutes", "elemental", 130),  # Primal Water (alt)
    28569: ("transmutes", "elemental", 140),  # Primal Air
    28566: ("transmutes", "elemental", 150),  # Primal Fire (alt)
    28568: ("transmutes", "elemental", 160),  # Primal Earth (alt)
    29688: ("transmutes", "special",    10),  # Primal Might
    38070: ("transmutes", "special",    20),  # Mercurial Stone
    32765: ("transmutes", "gem",        10),  # Earthstorm Diamond
    32766: ("transmutes", "gem",        20),  # Skyfire Diamond
}


HEADER = (
    "# Alchemy taxonomy and per-spellId classification whitelist.\n"
    "# Generated by tools/recipe-metadata/_gen_alchemy_taxonomy.py — re-run that\n"
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

    expected_count = 186
    actual_count = len(SPELLS)
    assert actual_count == expected_count, (
        f"Whitelist has {actual_count} entries, expected {expected_count} alchemy recipes"
    )

    target = Path(__file__).parent / "remediation" / "taxonomy" / "alchemy.yaml"
    target.write_text("".join(out), encoding="utf-8")
    print(f"Wrote {actual_count} spell classifications to {target}")


if __name__ == "__main__":
    main()
