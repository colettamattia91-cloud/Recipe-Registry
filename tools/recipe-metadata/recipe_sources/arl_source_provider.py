"""Recipe acquisition data (faction, source kind, NPC names, zones) from the
Ackis Recipe List database files.

Why this source. Where a recipe comes from is server-side data: vendor
inventories, loot tables and trainer lists have never been published by
Blizzard in any form, which is why every project that answers "where do I
learn this" -- Wowhead, the emulator databases, ARL itself -- reconstructs
it. Of the reconstructions, ARL is the one that already answers the exact
question this addon asks, keyed by the exact identifier this addon uses.

Shape. The per-profession files carry one block per recipe, keyed by spell
ID:

    AddRecipe(2661, 35, 2851, Q.COMMON, V.ORIG, 35, 75, 95, 115)
    self:AddRecipeFlags(2661, F.ALLIANCE, F.HORDE, F.TRAINER, ...)
    self:AddRecipeTrainer(2661, 3355, 3174, 29924, ...)

`AddRecipeFlags` states the faction outright -- a recipe carrying only
F.ALLIANCE is Alliance-only -- and the acquire calls name both the kind and
the NPCs. The lookup files then resolve those NPCs:

    AddVendor(340, L["Kendor Kabonka"], BZ["Stormwind City"], 77.5, 53.5, ALLIANCE)

which is where the zone names come from, the one thing the emulator
databases cannot supply (they store spawn coordinates against a map, and
turning those into a zone needs the client's terrain files).

What is extracted is factual game data -- which NPC sells which recipe, in
which zone -- re-derived into this project's own representation.

Parsing is regex over the Lua source rather than an interpreter: the files
are data declarations in a fixed shape, and running third-party Lua to read
them would be a far bigger hammer.
"""

import json
import re
import time
from pathlib import Path
from urllib.request import Request, urlopen


ARL_RAW_BASE = "https://raw.githubusercontent.com/Xurkon/AckisRecipeList/HEAD/"
DEFAULT_USER_AGENT = "RecipeRegistry metadata importer"
DEFAULT_REQUEST_DELAY = 0.5
SNAPSHOT_FILENAME = "acquisition.json"
PARSER_VERSION = 2

# Professions this project supports. ARL also ships Inscription, Runeforging
# and First Aid, which are out of scope here.
PROFESSION_FILES = (
    "Alchemy",
    "Blacksmithing",
    "Cooking",
    "Enchanting",
    "Engineering",
    "Jewelcrafting",
    "Leatherworking",
    "Smelting",
    "Tailoring",
)

LOOKUP_FILES = ("Vendor", "Mob", "Trainer", "Quest", "Reputation")

# Which lookup file answers which kind of acquire. They are kept apart rather
# than merged into one table because quest IDs and NPC IDs are separate
# numbering spaces: quest 564 and NPC 564 are both real, and one flat table
# would silently answer a quest with a vendor's name.
KIND_LOOKUPS = {
    "trainer": "Trainer",
    "vendor": "Vendor",
    "drop": "Mob",
    "quest": "Quest",
}

# NPCs share one numbering space across these three, so a vendor who is also
# listed as a boss resolves either way round.
NPC_LOOKUPS = ("Vendor", "Mob", "Trainer")

# ARL is a multi-expansion addon and its lookup files carry NPCs from later
# expansions than this project targets. Left in, they send a TBC player to
# Northrend: the engineering recipe Nixx Sprocketspring teaches in Tanaris was
# also listing Didi the Wrench in Dalaran, an NPC who does not exist yet.
#
# Two tests, because neither alone is enough. 110 of the 197 offenders are
# simply numbered past the end of TBC's creature range; the other 87 have ids
# inside it but stand in Northrend. And a zone test alone would miss the
# worst of them -- the Inscription trainers WotLK added to Shattrath City,
# Orgrimmar and Ironforge, standing in TBC zones with ids in the 30000s.
#
# Both numbers were checked against the TBC emulator's creature roster: the
# pair catches all 197 with nothing left over, and drops no NPC that roster
# says exists.
LAST_TBC_CREATURE_ID = 29095

POST_TBC_ZONES = frozenset((
    "Borean Tundra", "Howling Fjord", "Dragonblight", "Grizzly Hills",
    "Zul'Drak", "Sholazar Basin", "The Storm Peaks", "Icecrown",
    "Crystalsong Forest", "Wintergrasp", "Hrothgar's Landing",
    # TBC has a Dalaran -- the ruined bubble over Alterac -- but nobody in it
    # teaches or sells a recipe. Every ARL entry placed there is the Northrend
    # city.
    "Dalaran",
    "Icecrown Citadel", "Ahn'kahet: The Old Kingdom", "Azjol-Nerub",
    "Drak'Tharon Keep", "Halls of Lightning", "Halls of Stone",
    "The Oculus", "The Nexus", "The Violet Hold",
    "Utgarde Keep", "Utgarde Pinnacle", "Ulduar", "Trial of the Crusader",
))


def is_post_tbc(npc_id, zone):
    """True for an NPC this expansion does not have yet."""
    if npc_id is not None and int(npc_id) > LAST_TBC_CREATURE_ID:
        return True
    return zone in POST_TBC_ZONES

# Custom.lua is a lookup too, but of places rather than NPCs: it is what the
# generic AddRecipeAcquire calls point at, and it is where the raid and
# instance zones live.
CUSTOM_FILE = "Custom"

# ARL acquire call -> the kind this addon reports. Reputation and limited
# vendors are still vendors as far as "go and buy it" is concerned.
ACQUIRE_KINDS = {
    "AddRecipeTrainer": "trainer",
    "AddRecipeVendor": "vendor",
    "AddRecipeLimitedVendor": "vendor",
    "AddRecipeRepVendor": "vendor",
    "AddRecipeMobDrop": "drop",
    "AddRecipeQuest": "quest",
    "AddRecipeWorldDrop": "worldDrop",
}

# The kind to report when a recipe has several. Buying beats killing beats
# questing: it is the order of how directly a player can act on it.
KIND_PRIORITY = ("vendor", "trainer", "quest", "drop", "worldDrop")

# Most recipes are placed by an acquire call naming NPCs. Several hundred are
# not: they carry the generic `AddRecipeAcquire(spell, A.CUSTOM, id)`, which
# points at a place in Custom.lua rather than at anybody, and their kind is
# stated only by the source flag on AddRecipeFlags. Read that flag and the
# recipe is placed -- a raid drop in Sunwell Plateau, an alchemy discovery --
# without which it reads to a player exactly like a recipe nothing knows
# about.
#
# Order matters where a recipe carries more than one: a trainer who happens to
# stand inside an instance is still a trainer you walk up to.
SOURCE_FLAG_KINDS = (
    ("F.TRAINER", "trainer"),
    ("F.VENDOR", "vendor"),
    ("F.REPUTATION", "vendor"),
    ("F.QUEST", "quest"),
    ("F.MOB_DROP", "drop"),
    ("F.RAID", "drop"),
    ("F.INSTANCE", "drop"),
    ("F.WORLD_DROP", "worldDrop"),
    # Neither of these is a place you go. A discovery happens at the anvil or
    # the cauldron, and a world event recipe is only there a week a year --
    # calling either a "drop" would send a player looking for a corpse that
    # does not exist.
    ("F.DISC", "discovery"),
    ("F.SEASONAL", "worldEvent"),
)

FACTION_ALLIANCE = "alliance"
FACTION_HORDE = "horde"
FACTION_BOTH = "both"

# AddRecipe(spell_id, skill_level, item_id, quality, genesis,
#           optimal_level, medium_level, easy_level, trivial_level)
#
# The last four are the difficulty thresholds the game itself colours a recipe
# by: orange until optimal, yellow until medium, green until easy, grey from
# trivial on. They are per recipe and they are not derivable from the skill
# requirement -- the spread runs from ten points to sixty -- which is why an
# approximation from requiredSkill alone got a 335 recipe reading green at
# skill 375. Every guide addon carries these four numbers; there is nothing to
# invent, only something to read.
_RECIPE_RE = re.compile(r"\bAddRecipe\((\d+)\s*,([^)\n]*)\)")
_LEVEL_ARG_RE = re.compile(r"^-?\d+$")


def parse_skill_levels(argument_text):
    """The four difficulty thresholds, or None when the call does not state them.

    Arguments after the spell id are skill_level, item_id, quality, genesis,
    then the four. Quality and genesis are Q./V. constants rather than numbers,
    so the four are taken by position and each is required to be an integer:
    a call that has been shortened, or one whose arguments have moved, yields
    nothing rather than four numbers read off the wrong slots.
    """
    parts = [part.strip() for part in (argument_text or "").split(",")]
    if len(parts) < 8:
        return None
    levels = parts[4:8]
    if not all(_LEVEL_ARG_RE.match(part) for part in levels):
        return None
    values = [int(part) for part in levels]
    # Non-decreasing and non-negative, which is what a threshold ladder is.
    # ARL has a handful of rows with zeros in them, and four zeros says
    # nothing at all.
    if values[0] <= 0 or any(values[index] > values[index + 1] for index in range(3)):
        return None
    return values
_FLAGS_RE = re.compile(r"AddRecipeFlags\((\d+)\s*,([^)]*)\)")
_ACQUIRE_RE = re.compile(r"self:(AddRecipe\w+)\((\d+)\s*,([^)]*)\)")
_NPC_ID_RE = re.compile(r"\b(\d+)\b")
# AddRecipeLimitedVendor(3494, 9179, 1, 8878, 1, 1471, 1) -- vendor id then
# stock count, alternating. Reading every number as an id turns each count
# into a lookup for NPC 1.
_LIMITED_VENDOR_CALL = "AddRecipeLimitedVendor"
# self:AddRecipeAcquire(28580, A.CUSTOM, 3) -- the id is a Custom.lua place,
# never an NPC, so it must not go through the NPC lookup.
_CUSTOM_ACQUIRE_RE = re.compile(r"A\.(?:CUSTOM|SEASONAL)\s*,\s*(\d+)")
# self:addLookupList(DB, 24, L["SUNWELL_RANDOM"], BZ["Sunwell Plateau"], 0, 0)
# The trailing zone is optional: a discovery has no place.
_CUSTOM_LOOKUP_RE = re.compile(
    r"""addLookupList\(\s*DB\s*,\s*
        (\d+)\s*,\s*                       # id
        L\["((?:[^"\\]|\\.)*)"\]           # locale key
        (?:\s*,\s*BZ\["((?:[^"\\]|\\.)*)"\])?  # zone, when there is one
    """,
    re.VERBOSE,
)
# The lookup files come in five shapes, and reading only the first left three
# of the five files resolving nothing at all:
#
#   AddVendor(340, L["Kendor Kabonka"], BZ["Stormwind City"], 77.5, 53.5, ALLIANCE)
#   AddMob(9499, BB["Plugger Spazzring"], BZ["Blackrock Depths"], 0, 0)
#   AddQuest(564, BZ["Hillsbrad Foothills"], 52.4, 56.0, ALLIANCE)
#   self:addLookupList(DB, 514, L["Smith Argus"], BZ["Elwynn Forest"], 41.7, 65.6, 1)
#   self:addLookupList(DB, 59, BFAC["Thorium Brotherhood"], "N/A")
#
# So: find the call and its id, then look for a name and a zone anywhere in
# the arguments rather than at fixed positions. A name may be in any of three
# Babble tables -- BB is bosses, which is exactly where the named drops live
# -- and a quest has no name at all, only the zone you go to.
_LOOKUP_CALL_RE = re.compile(
    r"""(?:self:)?(?:Add(?:Vendor|Mob|Trainer|Quest|Reputation)|addLookupList)\(
        \s*(?:DB\s*,\s*)?      # addLookupList passes the table first
        (\d+)\s*,              # id
        ([^\n]*)               # the rest of the arguments
    """,
    re.VERBOSE,
)
_LOOKUP_NAME_RE = re.compile(r"""(L|BB|BFAC)\["((?:[^"\\]|\\.)*)"\]""")
_LOOKUP_ZONE_RE = re.compile(r"""BZ\["((?:[^"\\]|\\.)*)"\]""")
# The two numbers after the zone are the map coordinates, and the argument
# after them is the faction the NPC belongs to. Vendor.lua and Mob.lua spell
# the faction with ARL's own locals (NEUTRAL = 0, ALLIANCE = 1, HORDE = 2);
# Trainer.lua passes the number. Both are read.
_LOOKUP_COORD_RE = re.compile(
    r"""BZ\["(?:[^"\\]|\\.)*"\]\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)""")
_LOOKUP_FACTION_RE = re.compile(
    r"""BZ\["(?:[^"\\]|\\.)*"\]\s*,\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*,\s*(ALLIANCE|HORDE|NEUTRAL|\d)""")
_LOOKUP_FACTION_BY_TOKEN = {
    "ALLIANCE": FACTION_ALLIANCE, "1": FACTION_ALLIANCE,
    "HORDE": FACTION_HORDE, "2": FACTION_HORDE,
    "NEUTRAL": None, "0": None,
}


def parse_place_faction(arguments):
    match = _LOOKUP_FACTION_RE.search(arguments)
    if not match:
        return None
    return _LOOKUP_FACTION_BY_TOKEN.get(match.group(1))


def parse_place_coords(arguments):
    """The NPC's position in its zone, or None when there is not one.

    ARL writes 0, 0 for an entity it has no position for -- a world drop, a
    faction quartermaster whose stall moves -- and the map's own origin is not
    a place, so that pair is read as absent rather than as the top-left corner.
    """
    match = _LOOKUP_COORD_RE.search(arguments)
    if not match:
        return None, None
    x, y = float(match.group(1)), float(match.group(2))
    if x == 0 and y == 0:
        return None, None
    if not (0 <= x <= 100 and 0 <= y <= 100):
        return None, None
    return round(x, 1), round(y, 1)


def fetch_file(name, timeout=90, user_agent=DEFAULT_USER_AGENT):
    request = Request(ARL_RAW_BASE + "Database/" + name + ".lua",
                      headers={"User-Agent": user_agent})
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


# Custom places that are not creatures at all. The recipe is picked up: a
# chest, a book that spawns on a shelf, a schematic lying on the floor. Calling
# any of them a drop sends a player to kill something for an item nothing is
# holding.
CONTAINER_PLACE_KEYS = frozenset((
    "DM_CACHE",             # the Dire Maul library cache
    "DM_TRIBUTE",           # the tribute run chest
    "BRD_RANDOM_ROOM",      # the plans that spawn in the Blackrock Depths rooms
    "STRATH_BS_PLANS",      # plans that spawn in Stratholme
    "ENG_GNOMER",           # floor items in Gnomeregan
    "ENG_FLOOR_ITEM_BRD",   # the Field Repair Bot schematic, on the floor
))


def parse_custom_places(text):
    """id -> {key, zone}, for the places the generic acquire calls point at.

    The key is ARL's locale string -- SUNWELL_RANDOM, DM_CACHE -- and it says
    what kind of place this is where the flag only says "raid". The zone is
    already a real name and needs no translation.
    """
    out = {}
    for match in _CUSTOM_LOOKUP_RE.finditer(text or ""):
        key, zone = match.group(2), match.group(3)
        if zone or key in CONTAINER_PLACE_KEYS:
            out[int(match.group(1))] = {"key": key, "zone": zone}
    return out


def parse_source_flags(flag_text):
    """The kind a recipe's flags state, or None when they state none."""
    for flag, kind in SOURCE_FLAG_KINDS:
        if flag in (flag_text or ""):
            return kind
    return None


def parse_lookup(text):
    """id -> {name, zone} from one of the lookup files.

    Either half can be absent and the entry still worth keeping: a quest gives
    a zone and no name, a reputation gives a faction name and no zone. Only an
    entry with neither is dropped.
    """
    out = {}
    for match in _LOOKUP_CALL_RE.finditer(text or ""):
        arguments = match.group(2)
        name = _LOOKUP_NAME_RE.search(arguments)
        zone = _LOOKUP_ZONE_RE.search(arguments)
        if not name and not zone:
            continue
        x, y = parse_place_coords(arguments)
        out[int(match.group(1))] = {
            "name": name.group(2) if name else None,
            "zone": zone.group(1) if zone else None,
            # Where in the zone, and whose side of the war they are on. Both
            # are per NPC: a recipe sold by one vendor in Stormwind and another
            # in Orgrimmar is available to everyone, and saying so at the
            # recipe level tells a Horde player nothing about which of the two
            # they can actually walk up to.
            "x": x,
            "y": y,
            "faction": parse_place_faction(arguments),
            # Which Babble table the name came from. BB is LibBabble-Boss, and
            # it is ARL's own judgement about which creatures are worth naming
            # -- 63 of the 286 in Mob.lua are in it. That judgement is the
            # difference between "Drop: Mekgineer Thermaplugg (Gnomeregan)"
            # and naming one of the thirteen Wastewander Bandits in Tanaris.
            "boss": bool(name) and name.group(1) == "BB",
        }
    return out


def parse_faction(flag_text):
    alliance = "F.ALLIANCE" in flag_text
    horde = "F.HORDE" in flag_text
    if alliance and horde:
        return FACTION_BOTH
    if alliance:
        return FACTION_ALLIANCE
    if horde:
        return FACTION_HORDE
    # Neither stated: ARL leaves the pair off for recipes nobody is gated
    # from, so this reads as "no restriction", not "unknown".
    return FACTION_BOTH


def parse_profession(text):
    """spell ID -> the raw acquire facts for one profession.

    {faction, acquires: {kind: [npc ids]}, flagKind, places: [custom ids]}
    """
    recipes = {}
    for match in _RECIPE_RE.finditer(text or ""):
        entry = recipes.setdefault(int(match.group(1)), {
            "faction": FACTION_BOTH,
            "acquires": {},
            "flagKind": None,
            "places": [],
            "skillLevels": None,
        })
        if entry["skillLevels"] is None:
            entry["skillLevels"] = parse_skill_levels(match.group(2))

    for match in _FLAGS_RE.finditer(text or ""):
        spell_id = int(match.group(1))
        if spell_id in recipes:
            recipes[spell_id]["faction"] = parse_faction(match.group(2))
            recipes[spell_id]["flagKind"] = parse_source_flags(match.group(2))

    for match in _ACQUIRE_RE.finditer(text or ""):
        call, spell_id = match.group(1), int(match.group(2))
        if spell_id not in recipes:
            continue

        if call == "AddRecipeAcquire":
            # The generic form: its ids are places in Custom.lua, not NPCs,
            # and it names no kind at all -- that is what the flag is for.
            recipes[spell_id]["places"].extend(
                int(value) for value in _CUSTOM_ACQUIRE_RE.findall(match.group(3)))
            continue

        kind = ACQUIRE_KINDS.get(call)
        if not kind:
            continue
        npc_ids = [int(value) for value in _NPC_ID_RE.findall(match.group(3))]
        if call == _LIMITED_VENDOR_CALL:
            # id, count, id, count -- the counts are not NPCs.
            npc_ids = npc_ids[::2]
        # A world drop names no NPC; the call is the whole statement.
        recipes[spell_id]["acquires"].setdefault(kind, []).extend(npc_ids)

    return recipes


def _resolve(lookups, kind, entity_id):
    """One id, looked up in the table that answers for this kind of acquire.

    `lookups` may be the per-file mapping this module builds, or one flat
    table -- the flat form is what a caller with a single file has, and it is
    read as-is.
    """
    if not lookups:
        return None
    primary = KIND_LOOKUPS.get(kind)
    if primary not in lookups and not any(name in lookups for name in NPC_LOOKUPS):
        return lookups.get(entity_id)

    found = (lookups.get(primary) or {}).get(entity_id)
    if found or kind == "quest":
        # A quest is never answered from an NPC table: the numbering spaces
        # are different, so a hit there would be a coincidence, not an answer.
        return found
    for name in NPC_LOOKUPS:
        found = (lookups.get(name) or {}).get(entity_id)
        if found:
            return found
    return None


def _add_place(places, name, zone, x=None, y=None, faction=None):
    """Append one place, unless the same pair is already there."""
    if not (name or zone):
        return
    place = {"name": name or None, "zone": zone or None}
    if x is not None and y is not None:
        place["x"] = x
        place["y"] = y
    if faction:
        place["faction"] = faction
    # Identity is still the name and the zone: the same NPC read twice must not
    # become two places because one reading carried coordinates.
    for existing in places:
        if existing.get("name") == place["name"] and existing.get("zone") == place["zone"]:
            for field in ("x", "y", "faction"):
                if field in place and existing.get(field) is None:
                    existing[field] = place[field]
            return
    places.append(place)


def _zones_only(places):
    """Strip the names, keeping each distinct zone once.

    Three Wastewander mobs in Tanaris are three places while their names are
    kept and one place once they are not.
    """
    stripped = []
    for place in places:
        if place["zone"]:
            # A zone with the names dropped is no longer one NPC, so its
            # position and its faction go with the name.
            _add_place(stripped, None, place["zone"])
    return stripped


def summarize_recipe(entry, lookups, custom_places=None, max_places=4, max_names=3):
    """Flatten one recipe into the fields the addon renders."""
    acquires = entry.get("acquires") or {}
    kind = next((candidate for candidate in KIND_PRIORITY if candidate in acquires), None)

    if kind is None:
        # No acquire call named anybody. The flag still says what kind of thing
        # this is, and the generic acquire still says where -- which together
        # are the whole answer for a raid drop, where there was never an NPC to
        # name in the first place.
        kind = entry.get("flagKind")
        places = [place for place in (
            (custom_places or {}).get(place_id) for place_id in entry.get("places") or ())
            if place]
        # A chest or a floor item is not a drop, however the flag reads: the
        # flag only knows the recipe is in a raid or a dungeon, and the place
        # is the only thing that knows nobody has to die for it.
        if kind == "drop" and places and all(
                place["key"] in CONTAINER_PLACE_KEYS for place in places):
            kind = "container"
        seen = []
        if kind != "worldDrop":
            for place in places:
                _add_place(seen, None, place["zone"])
        return {
            "faction": entry.get("faction", FACTION_BOTH),
            "kind": kind,
            "worldDrop": kind == "worldDrop",
            "bossDrop": False,
            "places": seen[:max_places],
            "skillLevels": entry.get("skillLevels"),
        }

    # An NPC from a later expansion is not one of this recipe's sources, so it
    # is dropped before anything counts them -- otherwise a recipe with one
    # TBC trainer and three WotLK ones would look like a recipe four trainers
    # teach, and name none of them.
    # Each NPC becomes one place, name and zone together. Two independent
    # lists cannot express "Xandar Goodbeard in Loch Modan, Hagrus in
    # Orgrimmar" -- a reader is left to guess which name belongs to which
    # zone -- and vendor stock is often limited, so the alternatives are worth
    # showing rather than collapsing.
    kept_ids, places = [], []
    every_name_a_boss = True
    for npc_id in acquires.get(kind or "", []):
        npc = _resolve(lookups, kind, npc_id)
        if npc and is_post_tbc(npc_id, npc.get("zone")):
            continue
        kept_ids.append(npc_id)
        if not npc:
            continue
        if npc["name"] and not npc.get("boss"):
            every_name_a_boss = False
        _add_place(places, npc["name"], npc["zone"], npc.get("x"), npc.get("y"), npc.get("faction"))
    npc_ids = kept_ids

    # A world drop has nowhere to point at, and a recipe every trainer in the
    # game teaches is not helped by naming three of them. The test counts the
    # NPCs the source lists, not the ones whose names happened to resolve:
    # naming the single trainer we could look up, out of thirty-two, is worse
    # than naming none.
    world_drop = kind == "worldDrop"
    if world_drop or (kind == "trainer" and len(npc_ids) > max_names):
        places = []

    # Naming a creature is only worth it when there is one creature to find.
    # An ordinary mob is a species -- there are thirteen Wastewander Bandits in
    # Tanaris -- so naming the one ARL happened to list implies a precision the
    # source does not have, and the zone is the real answer. Several bosses
    # keep neither name nor pretence: the row says they are bosses and where.
    boss_drop = False
    named = [place for place in places if place["name"]]
    if kind == "drop" and named:
        if not every_name_a_boss:
            places = _zones_only(places)
        elif len(named) > 1:
            places, boss_drop = _zones_only(places), True

    return {
        "faction": entry.get("faction", FACTION_BOTH),
        "kind": kind,
        "worldDrop": world_drop,
        "bossDrop": boss_drop,
        "places": places[:max_places],
        "skillLevels": entry.get("skillLevels"),
    }


def fetch_acquisition(professions=PROFESSION_FILES, lookups=LOOKUP_FILES,
                      timeout=90, delay=DEFAULT_REQUEST_DELAY, fetch=fetch_file):
    """Collect the whole dataset: a dozen small files, not a crawl."""
    # One table per file, not one merged table: see KIND_LOOKUPS.
    lookup_table = {}
    for index, name in enumerate(lookups):
        if index and delay:
            time.sleep(delay)
        lookup_table[name] = parse_lookup(fetch(name, timeout=timeout))

    if delay:
        time.sleep(delay)
    custom_places = parse_custom_places(fetch(CUSTOM_FILE, timeout=timeout))

    by_spell_id = {}
    per_profession = {}
    for name in professions:
        if delay:
            time.sleep(delay)
        recipes = parse_profession(fetch(name, timeout=timeout))
        per_profession[name] = len(recipes)
        for spell_id, entry in recipes.items():
            by_spell_id[spell_id] = summarize_recipe(entry, lookup_table, custom_places)

    resolved = {}
    for table in lookup_table.values():
        resolved.update(table)
    return by_spell_id, per_profession, resolved


def build_snapshot(by_spell_id, per_profession, lookup_count):
    """Deterministic payload: no timestamps, so a refetch that learns nothing
    produces a byte-identical file and an empty diff."""
    factions = {}
    kinds = {}
    with_levels = 0
    with_coords = 0
    for entry in by_spell_id.values():
        factions[entry["faction"]] = factions.get(entry["faction"], 0) + 1
        key = entry["kind"] or "unknown"
        kinds[key] = kinds.get(key, 0) + 1
        if entry.get("skillLevels"):
            with_levels = with_levels + 1
        if any(place.get("x") is not None for place in entry.get("places") or ()):
            with_coords = with_coords + 1
    return {
        "source": "ackis-recipe-list",
        "parserVersion": PARSER_VERSION,
        "sourceStats": {
            "records": len(by_spell_id),
            "npcsResolved": lookup_count,
            "byProfession": dict(sorted(per_profession.items())),
            "byFaction": dict(sorted(factions.items())),
            "byKind": dict(sorted(kinds.items())),
            "withSkillLevels": with_levels,
            "withPlaceCoords": with_coords,
        },
        "acquisitionBySpellId": {
            str(spell_id): entry for spell_id, entry in sorted(by_spell_id.items())
        },
    }


def write_snapshot(payload, snapshot_dir):
    path = Path(snapshot_dir) / SNAPSHOT_FILENAME
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def load_acquisition(snapshot_dir):
    """Read the committed snapshot; an absent file means "not fetched yet",
    not an error, so the pipeline keeps working without it."""
    path = Path(snapshot_dir) / SNAPSHOT_FILENAME
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    return {
        int(spell_id): entry
        for spell_id, entry in data.get("acquisitionBySpellId", {}).items()
    }
