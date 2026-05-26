"""One-shot helper: emit the engineering.yaml taxonomy with explicit per-spellId
classification for all 250 Vanilla+TBC engineering recipes.

Goggle subcategory (cloth/leather/mail/plate) is auto-derived from the snapshot's
item_sparse.json `armorType` field, which the Wago provider extracts from the
DB2 Item table's ClassID/SubclassID. The script asserts that every goggle has
a resolvable armor type — re-run after a snapshot refetch if anything changes.

Usage: python tools/recipe-metadata/_gen_engineering_taxonomy.py
Writes: tools/recipe-metadata/remediation/taxonomy/engineering.yaml
"""

import json
from pathlib import Path

SNAPSHOT_DIR = Path(__file__).parent / "snapshots" / "tbc-2.5.5"

CATEGORIES = [
    ("weapons",    "Weapons",     10),   # Guns, rifles, shotguns, scopes
    ("ammo",       "Ammunition",  20),   # Bullets, shells, shot
    ("explosives", "Explosives",  30),   # Bombs, dynamite, grenades, charges, blasting powders
    ("fireworks",  "Fireworks",   40),   # Rockets, fireworks, launchers
    ("goggles",    "Goggles",     50),   # Equippable head-slot engineering gear
    ("devices",    "Devices",     60),   # Trinkets, consumables, transporters, reflectors, tools
    ("pets",       "Pets",        70),   # Mechanical companions
    ("parts",      "Parts",       80),   # Crafting components for other engineering recipes
    ("misc",       "Miscellaneous", 999),
]

SUBCATEGORIES = {
    "weapons": [
        ("firearms", "Firearms", 10),
        ("scopes",   "Scopes",   20),
    ],
    "explosives": [
        ("powders",  "Blasting Powders", 10),
        ("dynamite", "Dynamite",         20),
        ("bombs",    "Bombs",            30),
        ("grenades", "Grenades",         40),
        ("charges",  "Charges",          50),
    ],
    "fireworks": [
        ("rockets",   "Rockets",   10),
        ("fireworks", "Fireworks", 20),
        ("launchers", "Launchers", 30),
    ],
    "goggles": [
        ("cloth",   "Cloth",   10),
        ("leather", "Leather", 20),
        ("mail",    "Mail",    30),
        ("plate",   "Plate",   40),
    ],
    "devices": [
        ("trinkets",     "Trinkets",     10),
        ("consumables",  "Consumables",  20),
        ("transporters", "Transporters", 30),
        ("reflectors",   "Reflectors",   40),
        ("tools",        "Tools",        50),
    ],
}


def _load_snapshot_armor_types():
    """Map createdItemId -> armorType ('cloth'|'leather'|'mail'|'plate'|None)."""
    items = json.loads((SNAPSHOT_DIR / "item_sparse.json").read_text(encoding="utf-8"))
    return {it["itemId"]: it.get("armorType") for it in items}


def _resolve_goggle_subcategory(spell_id, created_item_id_by_spell, armor_by_item):
    created = created_item_id_by_spell.get(spell_id)
    armor = armor_by_item.get(created)
    if armor not in ("cloth", "leather", "mail", "plate"):
        raise AssertionError(
            f"Goggle spellId={spell_id} createdItemId={created} has no resolvable armorType "
            f"in snapshot (got {armor!r}). Refetch the wago snapshot or override manually."
        )
    return armor


def _load_snapshot_created_items():
    recipes = json.loads((SNAPSHOT_DIR / "recipes.json").read_text(encoding="utf-8"))
    return {r["spellId"]: r["createdItemId"] for r in recipes}

# (category, subcategory, sortOrder) keyed by spellId. sortOrder reflects tier
# / skill ordering inside each subcategory.
SPELLS = {
    # ============ Vanilla weapons.firearms ============
    3925:  ("weapons", "firearms",  10),  # Rough Boomstick
    3936:  ("weapons", "firearms",  20),  # Deadly Blunderbuss
    3949:  ("weapons", "firearms",  30),  # Silver-plated Shotgun
    3939:  ("weapons", "firearms",  40),  # Lovingly Crafted Boomstick
    3954:  ("weapons", "firearms",  50),  # Moonsight Rifle
    12595: ("weapons", "firearms",  60),  # Mithril Blunderbuss
    12614: ("weapons", "firearms",  70),  # Mithril Heavy-bore Rifle
    19792: ("weapons", "firearms",  80),  # Thorium Rifle
    19796: ("weapons", "firearms",  90),  # Dark Iron Rifle
    19833: ("weapons", "firearms", 100),  # Flawless Arcanite Rifle
    22795: ("weapons", "firearms", 110),  # Core Marksman Rifle

    # ============ Vanilla weapons.scopes ============
    3977:  ("weapons", "scopes",  10),  # Crude Scope
    3978:  ("weapons", "scopes",  20),  # Standard Scope
    3979:  ("weapons", "scopes",  30),  # Accurate Scope
    6458:  ("weapons", "scopes",  40),  # Ornate Spyglass
    12597: ("weapons", "scopes",  50),  # Deadly Scope
    12620: ("weapons", "scopes",  60),  # Sniper Scope
    22793: ("weapons", "scopes",  70),  # Biznicks 247x128 Accurascope

    # ============ Vanilla ammo ============
    3920:  ("ammo", None, 10),  # Crafted Light Shot
    3930:  ("ammo", None, 20),  # Crafted Heavy Shot
    3947:  ("ammo", None, 30),  # Crafted Solid Shot
    12596: ("ammo", None, 40),  # Hi-Impact Mithril Slugs
    12621: ("ammo", None, 50),  # Mithril Gyro-Shot
    12719: ("ammo", None, 60),  # Explosive Arrow
    19800: ("ammo", None, 70),  # Thorium Shells

    # ============ Vanilla explosives.powders ============
    3918:  ("explosives", "powders", 10),  # Rough Blasting Powder
    3929:  ("explosives", "powders", 20),  # Coarse Blasting Powder
    3945:  ("explosives", "powders", 30),  # Heavy Blasting Powder
    12585: ("explosives", "powders", 40),  # Solid Blasting Powder
    19788: ("explosives", "powders", 50),  # Dense Blasting Powder

    # ============ Vanilla explosives.dynamite ============
    3919:  ("explosives", "dynamite", 10),  # Rough Dynamite
    3931:  ("explosives", "dynamite", 20),  # Coarse Dynamite
    3946:  ("explosives", "dynamite", 30),  # Heavy Dynamite
    12586: ("explosives", "dynamite", 40),  # Solid Dynamite
    23070: ("explosives", "dynamite", 50),  # Dense Dynamite
    8339:  ("explosives", "dynamite", 60),  # Ez-Thro Dynamite
    23069: ("explosives", "dynamite", 70),  # Ez-Thro Dynamite II

    # ============ Vanilla explosives.bombs ============
    3923:  ("explosives", "bombs", 10),  # Rough Copper Bomb
    3937:  ("explosives", "bombs", 20),  # Large Copper Bomb
    3941:  ("explosives", "bombs", 30),  # Small Bronze Bomb
    3950:  ("explosives", "bombs", 40),  # Big Bronze Bomb
    3967:  ("explosives", "bombs", 50),  # Big Iron Bomb
    12603: ("explosives", "bombs", 60),  # Mithril Frag Bomb
    12619: ("explosives", "bombs", 70),  # Hi-Explosive Bomb
    12720: ("explosives", "bombs", 80),  # Goblin "Boom" Box
    12754: ("explosives", "bombs", 90),  # The Big One
    19799: ("explosives", "bombs", 100), # Dark Iron Bomb
    19831: ("explosives", "bombs", 110), # Arcane Bomb

    # ============ Vanilla explosives.grenades ============
    3962:  ("explosives", "grenades", 10),  # Iron Grenade
    8243:  ("explosives", "grenades", 20),  # Flash Bomb (a flash grenade)
    19790: ("explosives", "grenades", 30),  # Thorium Grenade

    # ============ Vanilla explosives.charges ============
    3933:  ("explosives", "charges", 10),  # Small Seaforium Charge
    3972:  ("explosives", "charges", 20),  # Large Seaforium Charge
    23080: ("explosives", "charges", 30),  # Powerful Seaforium Charge
    12760: ("explosives", "charges", 40),  # Goblin Sapper Charge

    # ============ Vanilla fireworks.rockets ============
    26416: ("fireworks", "rockets", 10),  # Small Blue Rocket
    26417: ("fireworks", "rockets", 20),  # Small Green Rocket
    26418: ("fireworks", "rockets", 30),  # Small Red Rocket
    26420: ("fireworks", "rockets", 40),  # Large Blue Rocket
    26421: ("fireworks", "rockets", 50),  # Large Green Rocket
    26422: ("fireworks", "rockets", 60),  # Large Red Rocket
    26423: ("fireworks", "rockets", 70),  # Blue Rocket Cluster
    26424: ("fireworks", "rockets", 80),  # Green Rocket Cluster
    26425: ("fireworks", "rockets", 90),  # Red Rocket Cluster
    26426: ("fireworks", "rockets", 100), # Large Blue Rocket Cluster
    26427: ("fireworks", "rockets", 110), # Large Green Rocket Cluster
    26428: ("fireworks", "rockets", 120), # Large Red Rocket Cluster

    # ============ Vanilla fireworks.fireworks ============
    23066: ("fireworks", "fireworks", 10),  # Red Firework
    23067: ("fireworks", "fireworks", 20),  # Blue Firework
    23068: ("fireworks", "fireworks", 30),  # Green Firework
    23507: ("fireworks", "fireworks", 40),  # Snake Burst Firework

    # ============ Vanilla fireworks.launchers ============
    26442: ("fireworks", "launchers", 10),  # Firework Launcher
    26443: ("fireworks", "launchers", 20),  # Cluster Launcher

    # ============ Vanilla goggles ============
    3934:  ("goggles", None, 10),  # Flying Tiger Goggles
    3956:  ("goggles", None, 20),  # Green Tinted Goggles
    3940:  ("goggles", None, 30),  # Shadow Goggles
    3966:  ("goggles", None, 40),  # Craftsman's Monocle
    12594: ("goggles", None, 50),  # Fire Goggles
    12618: ("goggles", None, 60),  # Rose Colored Goggles
    12587: ("goggles", None, 70),  # Bright-Eye Goggles
    12622: ("goggles", None, 80),  # Green Lens
    12717: ("goggles", None, 90),  # Goblin Mining Helmet
    12718: ("goggles", None, 100), # Goblin Construction Helmet
    12758: ("goggles", None, 110), # Goblin Rocket Helmet
    12897: ("goggles", None, 120), # Gnomish Goggles
    12907: ("goggles", None, 130), # Gnomish Mind Control Cap
    12607: ("goggles", None, 140), # Catseye Ultra Goggles
    12615: ("goggles", None, 150), # Spellpower Goggles Xtreme
    12617: ("goggles", None, 160), # Deepdive Helmet
    19794: ("goggles", None, 170), # Spellpower Goggles Xtreme Plus
    19825: ("goggles", None, 180), # Master Engineer's Goggles
    24356: ("goggles", None, 190), # Bloodvine Goggles
    24357: ("goggles", None, 200), # Bloodvine Lens

    # ============ Vanilla devices.trinkets ============
    3952:  ("devices", "trinkets", 10),  # Minor Recombobulator
    8895:  ("devices", "trinkets", 20),  # Goblin Rocket Boots
    3969:  ("devices", "trinkets", 30),  # Mechanical Dragonling
    3971:  ("devices", "trinkets", 40),  # Gnomish Cloaking Device
    12616: ("devices", "trinkets", 50),  # Parachute Cloak
    12624: ("devices", "trinkets", 60),  # Mithril Mechanical Dragonling
    12903: ("devices", "trinkets", 70),  # Gnomish Harm Prevention Belt
    12905: ("devices", "trinkets", 80),  # Gnomish Rocket Boots
    23079: ("devices", "trinkets", 90),  # Major Recombobulator
    19830: ("devices", "trinkets", 100), # Arcanite Dragonling
    22797: ("devices", "trinkets", 110), # Force Reactive Disk

    # ============ Vanilla devices.consumables ============
    3955:  ("devices", "consumables", 10),  # Explosive Sheep
    3963:  ("devices", "consumables", 20),  # Compact Harvest Reaper Kit
    12716: ("devices", "consumables", 30),  # Goblin Mortar
    13240: ("devices", "consumables", 31),  # Goblin Mortar (alt spell)
    12722: ("devices", "consumables", 40),  # Goblin Radio
    12755: ("devices", "consumables", 50),  # Goblin Bomb Dispenser
    12759: ("devices", "consumables", 60),  # Gnomish Death Ray
    12899: ("devices", "consumables", 70),  # Gnomish Shrink Ray
    12900: ("devices", "consumables", 80),  # Mobile Alarm
    12902: ("devices", "consumables", 90),  # Gnomish Net-o-Matic Projector
    12904: ("devices", "consumables", 100), # Gnomish Ham Radio
    12908: ("devices", "consumables", 110), # Goblin Dragon Gun
    19567: ("devices", "consumables", 120), # Salt Shaker
    9269:  ("devices", "consumables", 130), # Gnomish Universal Remote
    3959:  ("devices", "consumables", 140), # Discombobulator Ray
    3960:  ("devices", "consumables", 150), # Portable Bronze Mortar
    9273:  ("devices", "consumables", 160), # Goblin Jumper Cables
    21940: ("devices", "consumables", 170), # Snowmaster 9000
    3968:  ("devices", "consumables", 180), # Goblin Land Mine
    23078: ("devices", "consumables", 190), # Goblin Jumper Cables XL
    23096: ("devices", "consumables", 200), # Gnomish Alarm-O-Bot
    23129: ("devices", "consumables", 210), # World Enlarger
    28327: ("devices", "consumables", 220), # Steam Tonk Controller

    # ============ Vanilla devices.transporters ============
    23486: ("devices", "transporters", 10),  # Dimensional Ripper - Everlook
    23489: ("devices", "transporters", 20),  # Ultrasafe Transporter: Gadgetzan

    # ============ Vanilla devices.reflectors ============
    3944:  ("devices", "reflectors", 10),  # Flame Deflector
    3957:  ("devices", "reflectors", 20),  # Ice Deflector
    23077: ("devices", "reflectors", 30),  # Gyrofreeze Ice Reflector
    23081: ("devices", "reflectors", 40),  # Hyper-Radiant Flame Reflector
    23082: ("devices", "reflectors", 50),  # Ultra-Flash Shadow Reflector

    # ============ Vanilla devices.tools ============
    3932:  ("devices", "tools", 10),  # Target Dummy
    3965:  ("devices", "tools", 20),  # Advanced Target Dummy
    19814: ("devices", "tools", 30),  # Masterwork Target Dummy
    7430:  ("devices", "tools", 40),  # Arclight Spanner
    8334:  ("devices", "tools", 50),  # Practice Lock
    9271:  ("devices", "tools", 60),  # Aquadynamic Fish Attractor
    15255: ("devices", "tools", 70),  # Mechanical Repair Kit
    22704: ("devices", "tools", 80),  # Field Repair Bot 74A

    # ============ Vanilla pets ============
    3928:  ("pets", None, 10),  # Mechanical Squirrel Box
    12906: ("pets", None, 20),  # Gnomish Battle Chicken
    15628: ("pets", None, 30),  # Pet Bombling
    15633: ("pets", None, 40),  # Lil' Smoky
    19793: ("pets", None, 50),  # Lifelike Mechanical Toad
    26011: ("pets", None, 60),  # Tranquil Mechanical Yeti

    # ============ Vanilla parts ============
    3922:  ("parts", None, 10),  # Handful of Copper Bolts
    3924:  ("parts", None, 20),  # Copper Tube
    3926:  ("parts", None, 30),  # Copper Modulator
    3938:  ("parts", None, 40),  # Bronze Tube
    3942:  ("parts", None, 50),  # Whirring Bronze Gizmo
    3953:  ("parts", None, 60),  # Bronze Framework
    3958:  ("parts", None, 70),  # Iron Strut
    3961:  ("parts", None, 80),  # Gyrochronatom
    3973:  ("parts", None, 90),  # Silver Contact
    12584: ("parts", None, 100), # Gold Power Core
    12589: ("parts", None, 110), # Mithril Tube
    12590: ("parts", None, 120), # Gyromatic Micro-Adjustor
    12591: ("parts", None, 130), # Unstable Trigger
    12599: ("parts", None, 140), # Mithril Casing
    19791: ("parts", None, 150), # Thorium Widget
    19795: ("parts", None, 160), # Thorium Tube
    19815: ("parts", None, 170), # Delicate Arcanite Converter
    19819: ("parts", None, 180), # Voice Amplification Modulator
    23071: ("parts", None, 190), # Truesilver Transformer

    # ============ Vanilla misc ============
    12715: ("misc", None, 10),  # Recipe: Goblin Rocket Fuel (recipe-as-output anomaly)
    12895: ("misc", None, 20),  # Plans: Inlaid Mithril Cylinder (recipe-as-output anomaly)

    # ============ TBC weapons.firearms ============
    30312: ("weapons", "firearms", 120),  # Fel Iron Musket
    30313: ("weapons", "firearms", 130),  # Adamantite Rifle
    30314: ("weapons", "firearms", 140),  # Felsteel Boomstick
    30315: ("weapons", "firearms", 150),  # Ornate Khorium Rifle
    30563: ("weapons", "firearms", 160),  # Goblin Rocket Launcher
    41307: ("weapons", "firearms", 170),  # Gyro-Balanced Khorium Destroyer

    # ============ TBC weapons.scopes ============
    30329: ("weapons", "scopes",  80),  # Adamantite Scope
    30332: ("weapons", "scopes",  90),  # Khorium Scope
    30334: ("weapons", "scopes", 100),  # Stabilized Eternium Scope

    # ============ TBC ammo ============
    30346: ("ammo", None, 80),  # Fel Iron Shells
    30347: ("ammo", None, 90),  # Adamantite Shell Machine (consumable, produces shells)
    43676: ("ammo", None, 100), # Adamantite Arrow Maker (consumable, produces arrows)

    # ============ TBC explosives.powders ============
    30303: ("explosives", "powders", 60),  # Elemental Blasting Powder
    39971: ("explosives", "powders", 70),  # Icy Blasting Primers

    # ============ TBC explosives.bombs ============
    30310: ("explosives", "bombs", 120), # Fel Iron Bomb
    30558: ("explosives", "bombs", 130), # The Bigger One

    # ============ TBC explosives.grenades ============
    30311: ("explosives", "grenades", 40),  # Adamantite Grenade
    39973: ("explosives", "grenades", 50),  # Frost Grenade

    # ============ TBC explosives.charges ============
    30547: ("explosives", "charges", 50),  # Elemental Seaforium Charge
    30560: ("explosives", "charges", 60),  # Super Sapper Charge

    # ============ TBC goggles ============
    30565: ("goggles", None, 210), # Foreman's Enchanted Helmet
    30566: ("goggles", None, 220), # Foreman's Reinforced Helmet
    30574: ("goggles", None, 230), # Gnomish Power Goggles
    30575: ("goggles", None, 240), # Gnomish Battle Goggles
    30316: ("goggles", None, 250), # Cogspinner Goggles
    30317: ("goggles", None, 260), # Power Amplification Goggles
    30318: ("goggles", None, 270), # Ultra-Spectropic Detection Goggles
    30325: ("goggles", None, 280), # Hyper-Vision Goggles
    40274: ("goggles", None, 290), # Furious Gizmatic Goggles
    41311: ("goggles", None, 300), # Justicebringer 2000 Specs
    41312: ("goggles", None, 310), # Tankatronic Goggles
    41314: ("goggles", None, 320), # Surestrike Goggles v2.0
    41315: ("goggles", None, 330), # Gadgetstorm Goggles
    41316: ("goggles", None, 340), # Living Replicator Specs
    41317: ("goggles", None, 350), # Deathblow X11 Goggles
    41318: ("goggles", None, 360), # Wonderheal XT40 Shades
    41319: ("goggles", None, 370), # Magnified Moon Specs
    41320: ("goggles", None, 380), # Destruction Holo-gogs
    41321: ("goggles", None, 390), # Powerheal 4000 Lens
    46106: ("goggles", None, 400), # Wonderheal XT68 Shades
    46107: ("goggles", None, 410), # Justicebringer 3000 Specs
    46108: ("goggles", None, 420), # Powerheal 9000 Lens
    46109: ("goggles", None, 430), # Hyper-Magnified Moon Specs
    46110: ("goggles", None, 440), # Primal-Attuned Goggles
    46111: ("goggles", None, 450), # Annihilator Holo-Gogs
    46112: ("goggles", None, 460), # Lightning Etched Specs
    46113: ("goggles", None, 470), # Surestrike Goggles v3.0
    46114: ("goggles", None, 480), # Mayhem Projection Goggles
    46115: ("goggles", None, 490), # Hard Khorium Goggles
    46116: ("goggles", None, 500), # Quad Deathblow X44 Goggles

    # ============ TBC devices.trinkets ============
    30570: ("devices", "trinkets", 120), # Nigh Invulnerability Belt
    30548: ("devices", "trinkets", 130), # Zapthrottle Mote Extractor
    30556: ("devices", "trinkets", 140), # Rocket Boots Xtreme
    46697: ("devices", "trinkets", 150), # Rocket Boots Xtreme Lite

    # ============ TBC devices.consumables ============
    30341: ("devices", "consumables", 230), # White Smoke Flare
    30342: ("devices", "consumables", 240), # Red Smoke Flare
    30343: ("devices", "consumables", 250), # Blue Smoke Flare
    30344: ("devices", "consumables", 260), # Green Smoke Flare
    32814: ("devices", "consumables", 265), # Purple Smoke Flare
    30549: ("devices", "consumables", 270), # Critter Enlarger
    30551: ("devices", "consumables", 280), # Healing Potion Injector
    30552: ("devices", "consumables", 290), # Mana Potion Injector
    30561: ("devices", "consumables", 300), # Goblin Tonk Controller
    30568: ("devices", "consumables", 310), # Gnomish Flame Turret
    30569: ("devices", "consumables", 320), # Gnomish Poultryizer
    30573: ("devices", "consumables", 330), # Gnomish Tonk Controller

    # ============ TBC devices.transporters ============
    36954: ("devices", "transporters", 30),  # Dimensional Ripper - Area 52
    36955: ("devices", "transporters", 40),  # Ultrasafe Transporter: Toshley's Station

    # ============ TBC devices.tools ============
    30348: ("devices", "tools", 90),   # Fel Iron Toolbox
    30349: ("devices", "tools", 100),  # Khorium Toolbox
    44391: ("devices", "tools", 110),  # Field Repair Bot 110G

    # ============ TBC pets ============
    30337: ("pets", None, 70),  # Crashin' Thrashin' Robot

    # ============ TBC parts ============
    30304: ("parts", None, 200), # Fel Iron Casing
    30305: ("parts", None, 210), # Handful of Fel Iron Bolts
    30306: ("parts", None, 220), # Adamantite Frame
    30307: ("parts", None, 230), # Hardened Adamantite Tube
    30308: ("parts", None, 240), # Khorium Power Core
    30309: ("parts", None, 250), # Felsteel Stabilizer
    39895: ("parts", None, 260), # Fused Wiring
    44155: ("parts", None, 270), # Flying Machine Control
    44157: ("parts", None, 280), # Turbo-Charged Flying Machine Control
}


HEADER = (
    "# Engineering taxonomy and per-spellId classification whitelist.\n"
    "# Generated by tools/recipe-metadata/_gen_engineering_taxonomy.py — re-run\n"
    "# that helper if you need to regenerate from the Python source of truth.\n"
)


def main():
    armor_by_item = _load_snapshot_armor_types()
    created_by_spell = _load_snapshot_created_items()

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
        if category == "goggles" and subcategory is None:
            subcategory = _resolve_goggle_subcategory(spell_id, created_by_spell, armor_by_item)
        parts = [f"category: {category}"]
        if subcategory is not None:
            parts.append(f"subcategory: {subcategory}")
        parts.append(f"sortOrder: {sort_order}")
        out.append(f"  {spell_id}: " + ", ".join(parts) + "\n")

    expected_count = 250
    actual_count = len(SPELLS)
    assert actual_count == expected_count, (
        f"Whitelist has {actual_count} entries, expected {expected_count} engineering recipes"
    )

    target = Path(__file__).parent / "remediation" / "taxonomy" / "engineering.yaml"
    target.write_text("".join(out), encoding="utf-8")
    print(f"Wrote {actual_count} spell classifications to {target}")


if __name__ == "__main__":
    main()
