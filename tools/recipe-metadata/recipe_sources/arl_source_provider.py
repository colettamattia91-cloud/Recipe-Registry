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
PARSER_VERSION = 1

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

_RECIPE_RE = re.compile(r"\bAddRecipe\((\d+)\s*,")
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
_LOOKUP_NAME_RE = re.compile(r"""(?:L|BB|BFAC)\["((?:[^"\\]|\\.)*)"\]""")
_LOOKUP_ZONE_RE = re.compile(r"""BZ\["((?:[^"\\]|\\.)*)"\]""")


def fetch_file(name, timeout=90, user_agent=DEFAULT_USER_AGENT):
    request = Request(ARL_RAW_BASE + "Database/" + name + ".lua",
                      headers={"User-Agent": user_agent})
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def parse_custom_places(text):
    """id -> zone name, for the places the generic acquire calls point at.

    Only the zone is kept. The name beside it is a locale key -- SUNWELL_RANDOM,
    DISCOVERY_ALCH_XMUTE -- that resolves through ARL's own translation files;
    the zone is already a real name, and the flag has already said what kind of
    thing it is, so the key would add a lookup and no information.
    """
    out = {}
    for match in _CUSTOM_LOOKUP_RE.finditer(text or ""):
        zone = match.group(3)
        if zone:
            out[int(match.group(1))] = zone
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
        out[int(match.group(1))] = {
            "name": name.group(1) if name else None,
            "zone": zone.group(1) if zone else None,
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
        recipes.setdefault(int(match.group(1)), {
            "faction": FACTION_BOTH,
            "acquires": {},
            "flagKind": None,
            "places": [],
        })

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


def summarize_recipe(entry, lookups, custom_places=None, max_names=3, max_zones=4):
    """Flatten one recipe into the fields the addon renders."""
    acquires = entry.get("acquires") or {}
    kind = next((candidate for candidate in KIND_PRIORITY if candidate in acquires), None)

    if kind is None:
        # No acquire call named anybody. The flag still says what kind of thing
        # this is, and the generic acquire still says where -- which together
        # are the whole answer for a raid drop, where there was never an NPC to
        # name in the first place.
        kind = entry.get("flagKind")
        places = [custom_place for custom_place in (
            (custom_places or {}).get(place_id) for place_id in entry.get("places") or ())
            if custom_place]
        seen = []
        for place in places:
            if place not in seen:
                seen.append(place)
        return {
            "faction": entry.get("faction", FACTION_BOTH),
            "kind": kind,
            "worldDrop": kind == "worldDrop",
            "names": [],
            "zones": [] if kind == "worldDrop" else seen[:max_zones],
        }

    npc_ids = acquires.get(kind or "", [])
    names, zones = [], []
    for npc_id in npc_ids:
        npc = _resolve(lookups, kind, npc_id)
        if not npc:
            continue
        if npc["name"] and npc["name"] not in names:
            names.append(npc["name"])
        if npc["zone"] and npc["zone"] not in zones:
            zones.append(npc["zone"])

    # A world drop has nowhere to point at, and a recipe every trainer in the
    # game teaches is not helped by naming three of them. The test counts the
    # NPCs the source lists, not the ones whose names happened to resolve:
    # naming the single trainer we could look up, out of thirty-two, is worse
    # than naming none.
    world_drop = kind == "worldDrop"
    if world_drop or (kind == "trainer" and len(npc_ids) > max_names):
        names, zones = [], []

    return {
        "faction": entry.get("faction", FACTION_BOTH),
        "kind": kind,
        "worldDrop": world_drop,
        "names": names[:max_names],
        "zones": zones[:max_zones],
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
    for entry in by_spell_id.values():
        factions[entry["faction"]] = factions.get(entry["faction"], 0) + 1
        key = entry["kind"] or "unknown"
        kinds[key] = kinds.get(key, 0) + 1
    return {
        "source": "ackis-recipe-list",
        "parserVersion": PARSER_VERSION,
        "sourceStats": {
            "records": len(by_spell_id),
            "npcsResolved": lookup_count,
            "byProfession": dict(sorted(per_profession.items())),
            "byFaction": dict(sorted(factions.items())),
            "byKind": dict(sorted(kinds.items())),
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
