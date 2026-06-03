"""One-shot helper: emit the jewelcrafting.yaml taxonomy with explicit per-spellId
classification for all 261 Jewelcrafting recipes (all TBC).

Classification was derived from a wago fetch of DB2 Item.ClassID/SubclassID +
ItemSparse.InventoryType:
  - cls=3 (Gem) -> gems/<color> from SubclassID (0=red, 1=blue, 2=yellow,
    3=purple, 4=green, 5=orange, 6=meta)
  - InventoryType=1 head -> jewelry/crown
  - InventoryType=2 neck -> jewelry/necklace
  - InventoryType=11 finger -> jewelry/ring
  - InventoryType=12 trinket -> jewelry/trinket
  - cls=7 trade good -> materials
  - "Stone Statue" consumables -> statues (shaman off-hand totems)
  - cls=0 misc consumables -> materials (Brilliant Glass)
  - fist weapon -> misc (Heavy Iron Knuckles, the lone JC weapon)

Usage: python tools/recipe-metadata/_gen_jewelcrafting_taxonomy.py
"""

from pathlib import Path

CATEGORIES = [
    ("gems",      "Gems",          10),
    ("jewelry",   "Jewelry",       20),
    ("statues",   "Stone Statues", 30),
    ("materials", "Materials",     40),
    ("misc",      "Miscellaneous", 999),
]

SUBCATEGORIES = {
    "gems": [
        ("red",    "Red",    10),
        ("blue",   "Blue",   20),
        ("yellow", "Yellow", 30),
        ("green",  "Green",  40),
        ("orange", "Orange", 50),
        ("purple", "Purple", 60),
        ("meta",   "Meta",   70),
    ],
    "jewelry": [
        ("ring",     "Rings",     10),
        ("necklace", "Necklaces", 20),
        ("trinket",  "Trinkets",  30),
        ("crown",    "Crowns",    40),
    ],
}

SPELLS = {
    # ===== Materials =====
    25255: ("materials", None, 1),    # Delicate Copper Wire
    25278: ("materials", None, 1),    # Bronze Setting
    25615: ("materials", None, 1),    # Mithril Filigree
    26880: ("materials", None, 1),    # Thorium Setting
    38068: ("materials", None, 1),    # Mercurial Adamantite
    47280: ("materials", None, 1),    # Brilliant Glass

    # ===== Stone Statues (shaman off-hand totems) =====
    32259: ("statues", None,   1),    # Rough Stone Statue
    32801: ("statues", None,   1),    # Coarse Stone Statue
    32807: ("statues", None,   1),    # Heavy Stone Statue
    32808: ("statues", None,   1),    # Solid Stone Statue
    32809: ("statues", None,   1),    # Dense Stone Statue
    32810: ("statues", None, 300),    # Primal Stone Statue

    # ===== Misc =====
    25612: ("misc", None, 125),       # Heavy Iron Knuckles (fist weapon)

    # ===== Jewelry: rings =====
    25280: ("jewelry", "ring",   1),  # Elegant Silver Ring
    25283: ("jewelry", "ring",   1),  # Inlaid Malachite Ring
    25284: ("jewelry", "ring",   1),  # Simple Pearl Ring
    25287: ("jewelry", "ring",   1),  # Gloom Band
    25305: ("jewelry", "ring",   1),  # Heavy Silver Ring
    25317: ("jewelry", "ring",   1),  # Ring of Silver Might
    25318: ("jewelry", "ring",   1),  # Ring of Twilight Shadows
    25490: ("jewelry", "ring",   1),  # Solid Bronze Ring
    25493: ("jewelry", "ring",   1),  # Braided Copper Ring
    25613: ("jewelry", "ring",   1),  # Golden Dragon Ring
    25620: ("jewelry", "ring",   1),  # Engraved Truesilver Ring
    25621: ("jewelry", "ring",   1),  # Citrine Ring of Rapid Healing
    26874: ("jewelry", "ring",   1),  # Aquamarine Signet
    26885: ("jewelry", "ring",   1),  # Truesilver Healing Ring
    26902: ("jewelry", "ring",   1),  # Simple Opal Ring
    26903: ("jewelry", "ring",   1),  # Sapphire Signet
    26907: ("jewelry", "ring",   1),  # Onslaught Ring
    26916: ("jewelry", "ring",   1),  # Band of Natural Fire
    26925: ("jewelry", "ring",   1),  # Woven Copper Ring
    26926: ("jewelry", "ring",   1),  # Heavy Copper Ring
    31048: ("jewelry", "ring",   1),  # Fel Iron Blood Ring
    31049: ("jewelry", "ring",   1),  # Golden Draenite Ring
    31050: ("jewelry", "ring",   1),  # Azure Moonstone Ring
    31052: ("jewelry", "ring",   1),  # Heavy Adamantite Ring
    32179: ("jewelry", "ring",   1),  # Tigerseye Band
    34955: ("jewelry", "ring",   1),  # Golden Ring of Power
    34959: ("jewelry", "ring",   1),  # Truesilver Commander's Ring
    34960: ("jewelry", "ring",   1),  # Glowing Thorium Band
    34961: ("jewelry", "ring",   1),  # Emerald Lion Ring
    36524: ("jewelry", "ring",   1),  # Heavy Jade Ring
    36525: ("jewelry", "ring",   1),  # Red Ring of Destruction
    36526: ("jewelry", "ring",   1),  # Diamond Focus Ring
    37818: ("jewelry", "ring",   1),  # Bronze Band of Force
    41414: ("jewelry", "ring",   1),  # Brilliant Pearl Band
    41415: ("jewelry", "ring",   1),  # The Black Pearl
    25323: ("jewelry", "ring", 125),  # Wicked Moonstone Ring
    25617: ("jewelry", "ring", 150),  # Blazing Citrine Ring
    25619: ("jewelry", "ring", 170),  # The Jade Eye
    26887: ("jewelry", "ring", 245),  # The Aquamarine Ward
    26896: ("jewelry", "ring", 250),  # Gem Studded Band
    26910: ("jewelry", "ring", 285),  # Ring of Bitter Shadows
    31058: ("jewelry", "ring", 345),  # Heavy Felsteel Ring
    31053: ("jewelry", "ring", 350),  # Khorium Band of Shadows
    31054: ("jewelry", "ring", 355),  # Khorium Band of Frost
    31055: ("jewelry", "ring", 355),  # Khorium Inferno Band
    31060: ("jewelry", "ring", 355),  # Delicate Eternium Ring
    31056: ("jewelry", "ring", 360),  # Khorium Band of Leaves
    37855: ("jewelry", "ring", 360),  # Ring of Arcane Shielding
    31057: ("jewelry", "ring", 365),  # Arcane Khorium Band
    31061: ("jewelry", "ring", 365),  # Blazing Eternium Band
    46122: ("jewelry", "ring", 365),  # Loop of Forged Power
    46123: ("jewelry", "ring", 365),  # Ring of Flowing Life
    46124: ("jewelry", "ring", 365),  # Hard Khorium Band
    38503: ("jewelry", "ring", 375),  # The Frozen Eye
    38504: ("jewelry", "ring", 375),  # The Natural Ward

    # ===== Jewelry: necklaces =====
    25498: ("jewelry", "necklace",   1),  # Barbaric Iron Collar
    26876: ("jewelry", "necklace",   1),  # Aquamarine Pendant of the Warrior
    26883: ("jewelry", "necklace",   1),  # Ruby Pendant of Fire
    26908: ("jewelry", "necklace",   1),  # Sapphire Pendant of Winter Night
    26911: ("jewelry", "necklace",   1),  # Living Emerald Pendant
    26927: ("jewelry", "necklace",   1),  # Thick Bronze Necklace
    26928: ("jewelry", "necklace",   1),  # Ornate Tigerseye Necklace
    31051: ("jewelry", "necklace",   1),  # Thick Adamantite Necklace
    32178: ("jewelry", "necklace",   1),  # Malachite Pendant
    36523: ("jewelry", "necklace",   1),  # Brilliant Necklace
    38175: ("jewelry", "necklace",   1),  # Bronze Torc
    40514: ("jewelry", "necklace",   1),  # Necklace of the Deep
    25339: ("jewelry", "necklace", 110),  # Amulet of the Moon
    25610: ("jewelry", "necklace", 120),  # Pendant of the Agate Shield
    25614: ("jewelry", "necklace", 145),  # Silver Rose Pendant
    25320: ("jewelry", "necklace", 150),  # Heavy Golden Necklace of Battle
    25618: ("jewelry", "necklace", 160),  # Jade Pendant of Blasting
    25622: ("jewelry", "necklace", 190),  # Citrine Pendant of Golden Healing
    26897: ("jewelry", "necklace", 250),  # Opal Necklace of Impact
    26915: ("jewelry", "necklace", 305),  # Necklace of the Diamond Tower
    26918: ("jewelry", "necklace", 315),  # Arcanite Sword Pendant
    31067: ("jewelry", "necklace", 355),  # Thick Felsteel Necklace
    31068: ("jewelry", "necklace", 355),  # Living Ruby Pendant
    31062: ("jewelry", "necklace", 360),  # Pendant of Frozen Flame
    31063: ("jewelry", "necklace", 360),  # Pendant of Thawing
    31064: ("jewelry", "necklace", 360),  # Pendant of Withering
    31065: ("jewelry", "necklace", 360),  # Pendant of Shadow's End
    31066: ("jewelry", "necklace", 360),  # Pendant of the Null Rune
    31070: ("jewelry", "necklace", 360),  # Braided Eternium Chain
    31071: ("jewelry", "necklace", 360),  # Eye of the Night
    31072: ("jewelry", "necklace", 365),  # Embrace of the Dawn
    31076: ("jewelry", "necklace", 365),  # Chain of the Twilight Owl
    46125: ("jewelry", "necklace", 365),  # Pendant of Sunfire
    46126: ("jewelry", "necklace", 365),  # Amulet of Flowing Life
    46127: ("jewelry", "necklace", 365),  # Hard Khorium Choker

    # ===== Jewelry: trinkets (Figurines) =====
    26872: ("jewelry", "trinket",   1),  # Figurine - Jade Owl
    26873: ("jewelry", "trinket", 200),  # Figurine - Golden Hare
    26875: ("jewelry", "trinket", 215),  # Figurine - Black Pearl Panther
    26881: ("jewelry", "trinket", 225),  # Figurine - Truesilver Crab
    26882: ("jewelry", "trinket", 235),  # Figurine - Truesilver Boar
    26900: ("jewelry", "trinket", 260),  # Figurine - Ruby Serpent
    26909: ("jewelry", "trinket", 285),  # Figurine - Emerald Owl
    26912: ("jewelry", "trinket", 300),  # Figurine - Black Diamond Crab
    26914: ("jewelry", "trinket", 300),  # Figurine - Dark Iron Scorpid
    31079: ("jewelry", "trinket", 370),  # Figurine - Felsteel Boar
    31080: ("jewelry", "trinket", 370),  # Figurine - Dawnstone Crab
    31081: ("jewelry", "trinket", 370),  # Figurine - Living Ruby Serpent
    31082: ("jewelry", "trinket", 370),  # Figurine - Talasite Owl
    31083: ("jewelry", "trinket", 370),  # Figurine - Nightseye Panther
    46775: ("jewelry", "trinket", 375),  # Figurine - Empyrean Tortoise
    46776: ("jewelry", "trinket", 375),  # Figurine - Khorium Boar
    46777: ("jewelry", "trinket", 375),  # Figurine - Crimson Serpent
    46778: ("jewelry", "trinket", 375),  # Figurine - Shadowsong Panther
    46779: ("jewelry", "trinket", 375),  # Figurine - Seaspray Albatross

    # ===== Jewelry: crowns (cloth head pieces) =====
    25321: ("jewelry", "crown",   1),  # Moonsoul Crown
    41418: ("jewelry", "crown",   1),  # Crown of the Sea Witch
    26878: ("jewelry", "crown", 225),  # Ruby Crown of Restoration
    26906: ("jewelry", "crown", 275),  # Emerald Crown of Destruction
    26920: ("jewelry", "crown", 325),  # Blood Crown
    31077: ("jewelry", "crown", 370),  # Coronet of Verdant Flame
    31078: ("jewelry", "crown", 370),  # Circlet of Arcane Might

    # ===== Gems: red =====
    41420: ("gems", "purple",   1),  # Purified Jaggal Pearl
    41429: ("gems", "purple",   1),  # Purified Shadow Pearl
    28903: ("gems", "red",    300),  # Teardrop Blood Garnet
    28905: ("gems", "red",    305),  # Bold Blood Garnet
    34590: ("gems", "red",    305),  # Bright Blood Garnet
    28906: ("gems", "red",    315),  # Runed Blood Garnet
    28907: ("gems", "red",    325),  # Delicate Blood Garnet
    31084: ("gems", "red",    350),  # Bold Living Ruby
    31085: ("gems", "red",    350),  # Delicate Living Ruby
    31087: ("gems", "red",    350),  # Teardrop Living Ruby
    31088: ("gems", "red",    350),  # Runed Living Ruby
    31089: ("gems", "red",    350),  # Bright Living Ruby
    31090: ("gems", "red",    350),  # Subtle Living Ruby
    31091: ("gems", "red",    350),  # Flashing Living Ruby
    42558: ("gems", "red",    360),  # Don Julio's Heart
    42588: ("gems", "red",    360),  # Kailee's Rose
    42589: ("gems", "red",    360),  # Crimson Sun
    39705: ("gems", "red",    375),  # Bold Crimson Spinel
    39706: ("gems", "red",    375),  # Delicate Crimson Spinel
    39710: ("gems", "red",    375),  # Teardrop Crimson Spinel
    39711: ("gems", "red",    375),  # Runed Crimson Spinel
    39712: ("gems", "red",    375),  # Bright Crimson Spinel
    39713: ("gems", "red",    375),  # Subtle Crimson Spinel
    39714: ("gems", "red",    375),  # Flashing Crimson Spinel

    # ===== Gems: blue =====
    28950: ("gems", "blue", 300),  # Solid Azure Moonstone
    28953: ("gems", "blue", 305),  # Sparkling Azure Moonstone
    28955: ("gems", "blue", 315),  # Stormy Azure Moonstone
    28957: ("gems", "blue", 325),  # Lustrous Azure Moonstone
    31092: ("gems", "blue", 350),  # Solid Star of Elune
    31094: ("gems", "blue", 350),  # Lustrous Star of Elune
    31095: ("gems", "blue", 350),  # Stormy Star of Elune
    31149: ("gems", "blue", 350),  # Sparkling Star of Elune
    42590: ("gems", "blue", 360),  # Falling Star
    39715: ("gems", "blue", 375),  # Solid Empyrean Sapphire
    39716: ("gems", "blue", 375),  # Sparkling Empyrean Sapphire
    39717: ("gems", "blue", 375),  # Lustrous Empyrean Sapphire
    39718: ("gems", "blue", 375),  # Stormy Empyrean Sapphire

    # ===== Gems: yellow =====
    28938: ("gems", "yellow", 300),  # Brilliant Golden Draenite
    28944: ("gems", "yellow", 305),  # Gleaming Golden Draenite
    28947: ("gems", "yellow", 315),  # Thick Golden Draenite
    28948: ("gems", "yellow", 325),  # Rigid Golden Draenite
    34069: ("gems", "yellow", 325),  # Smooth Golden Draenite
    39451: ("gems", "yellow", 325),  # Great Golden Draenite
    31096: ("gems", "yellow", 350),  # Brilliant Dawnstone
    31097: ("gems", "yellow", 350),  # Smooth Dawnstone
    31098: ("gems", "yellow", 350),  # Rigid Dawnstone
    31099: ("gems", "yellow", 350),  # Gleaming Dawnstone
    31100: ("gems", "yellow", 350),  # Thick Dawnstone
    31101: ("gems", "yellow", 350),  # Mystic Dawnstone
    39452: ("gems", "yellow", 350),  # Great Dawnstone
    46403: ("gems", "yellow", 350),  # Quick Dawnstone
    42591: ("gems", "yellow", 360),  # Stone of Blades
    42592: ("gems", "yellow", 360),  # Blood of Amber
    42593: ("gems", "yellow", 360),  # Facet of Eternity
    39719: ("gems", "yellow", 375),  # Brilliant Lionseye
    39720: ("gems", "yellow", 375),  # Smooth Lionseye
    39721: ("gems", "yellow", 375),  # Rigid Lionseye
    39722: ("gems", "yellow", 375),  # Gleaming Lionseye
    39723: ("gems", "yellow", 375),  # Thick Lionseye
    39724: ("gems", "yellow", 375),  # Mystic Lionseye
    39725: ("gems", "yellow", 375),  # Great Lionseye
    47056: ("gems", "yellow", 375),  # Quick Lionseye

    # ===== Gems: green =====
    28916: ("gems", "green", 300),  # Radiant Deep Peridot
    28917: ("gems", "green", 305),  # Jagged Deep Peridot
    28918: ("gems", "green", 315),  # Enduring Deep Peridot
    28924: ("gems", "green", 325),  # Dazzling Deep Peridot
    31110: ("gems", "green", 350),  # Enduring Talasite
    31111: ("gems", "green", 350),  # Radiant Talasite
    31112: ("gems", "green", 350),  # Dazzling Talasite
    31113: ("gems", "green", 350),  # Jagged Talasite
    43493: ("gems", "green", 350),  # Steady Talasite
    46405: ("gems", "green", 350),  # Forceful Talasite
    39739: ("gems", "green", 375),  # Enduring Seaspray Emerald
    39740: ("gems", "green", 375),  # Radiant Seaspray Emerald
    39741: ("gems", "green", 375),  # Dazzling Seaspray Emerald
    39742: ("gems", "green", 375),  # Jagged Seaspray Emerald
    47053: ("gems", "green", 375),  # Forceful Seaspray Emerald
    47054: ("gems", "green", 375),  # Steady Seaspray Emerald

    # ===== Gems: orange =====
    28910: ("gems", "orange", 300),  # Inscribed Flame Spessarite
    28912: ("gems", "orange", 305),  # Luminous Flame Spessarite
    28914: ("gems", "orange", 315),  # Glinting Flame Spessarite
    28915: ("gems", "orange", 325),  # Potent Flame Spessarite
    39466: ("gems", "orange", 325),  # Veiled Flame Spessarite
    39467: ("gems", "orange", 325),  # Wicked Flame Spessarite
    31106: ("gems", "orange", 350),  # Inscribed Noble Topaz
    31107: ("gems", "orange", 350),  # Potent Noble Topaz
    31108: ("gems", "orange", 350),  # Luminous Noble Topaz
    31109: ("gems", "orange", 350),  # Glinting Noble Topaz
    39470: ("gems", "orange", 350),  # Veiled Noble Topaz
    39471: ("gems", "orange", 350),  # Wicked Noble Topaz
    46404: ("gems", "orange", 350),  # Reckless Noble Topaz
    39733: ("gems", "orange", 375),  # Inscribed Pyrestone
    39734: ("gems", "orange", 375),  # Potent Pyrestone
    39735: ("gems", "orange", 375),  # Luminous Pyrestone
    39736: ("gems", "orange", 375),  # Glinting Pyrestone
    39737: ("gems", "orange", 375),  # Veiled Pyrestone
    39738: ("gems", "orange", 375),  # Wicked Pyrestone
    47055: ("gems", "orange", 375),  # Reckless Pyrestone

    # ===== Gems: purple =====
    28925: ("gems", "purple", 300),  # Glowing Shadow Draenite
    28927: ("gems", "purple", 305),  # Royal Shadow Draenite
    28933: ("gems", "purple", 315),  # Shifting Shadow Draenite
    28936: ("gems", "purple", 325),  # Sovereign Shadow Draenite
    39455: ("gems", "purple", 325),  # Balanced Shadow Draenite
    39458: ("gems", "purple", 325),  # Infused Shadow Draenite
    31102: ("gems", "purple", 350),  # Sovereign Nightseye
    31103: ("gems", "purple", 350),  # Shifting Nightseye
    31104: ("gems", "purple", 350),  # Glowing Nightseye
    31105: ("gems", "purple", 350),  # Royal Nightseye
    39462: ("gems", "purple", 350),  # Infused Nightseye
    39463: ("gems", "purple", 350),  # Balanced Nightseye
    46803: ("gems", "purple", 350),  # Regal Nightseye
    39727: ("gems", "purple", 375),  # Sovereign Shadowsong Amethyst
    39728: ("gems", "purple", 375),  # Shifting Shadowsong Amethyst
    39729: ("gems", "purple", 375),  # Balanced Shadowsong Amethyst
    39730: ("gems", "purple", 375),  # Infused Shadowsong Amethyst
    39731: ("gems", "purple", 375),  # Glowing Shadowsong Amethyst
    39732: ("gems", "purple", 375),  # Royal Shadowsong Amethyst
    48789: ("gems", "purple", 375),  # Purified Shadowsong Amethyst

    # ===== Gems: meta =====
    32866: ("gems", "meta", 365),  # Powerful Earthstorm Diamond
    32867: ("gems", "meta", 365),  # Bracing Earthstorm Diamond
    32868: ("gems", "meta", 365),  # Tenacious Earthstorm Diamond
    32869: ("gems", "meta", 365),  # Brutal Earthstorm Diamond
    32870: ("gems", "meta", 365),  # Insightful Earthstorm Diamond
    32871: ("gems", "meta", 365),  # Destructive Skyfire Diamond
    32872: ("gems", "meta", 365),  # Mystical Skyfire Diamond
    32873: ("gems", "meta", 365),  # Swift Skyfire Diamond
    32874: ("gems", "meta", 365),  # Enigmatic Skyfire Diamond
    39961: ("gems", "meta", 365),  # Relentless Earthstorm Diamond
    39963: ("gems", "meta", 365),  # Thundering Skyfire Diamond
    44794: ("gems", "meta", 365),  # Chaotic Skyfire Diamond
    46597: ("gems", "meta", 370),  # Eternal Earthstorm Diamond
    46601: ("gems", "meta", 370),  # Ember Skyfire Diamond
}


HEADER = (
    "# Jewelcrafting taxonomy and per-spellId classification whitelist.\n"
    "# Generated by tools/recipe-metadata/_gen_jewelcrafting_taxonomy.py — re-run\n"
    "# that helper if you need to regenerate from the Python source of truth.\n"
    "# Gem colors derived from DB2 Item.ClassID=3 / SubclassID.\n"
    "# Jewelry slots derived from DB2 ItemSparse.InventoryType.\n"
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

    expected_count = 261
    actual_count = len(SPELLS)
    assert actual_count == expected_count, (
        f"Whitelist has {actual_count} entries, expected {expected_count} JC recipes"
    )

    target = Path(__file__).parent / "remediation" / "taxonomy" / "jewelcrafting.yaml"
    target.write_text("".join(out), encoding="utf-8")
    print(f"Wrote {actual_count} spell classifications to {target}")


if __name__ == "__main__":
    main()
