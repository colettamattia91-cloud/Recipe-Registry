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

FACTION_ALLIANCE = "alliance"
FACTION_HORDE = "horde"
FACTION_BOTH = "both"

_RECIPE_RE = re.compile(r"\bAddRecipe\((\d+)\s*,")
_FLAGS_RE = re.compile(r"AddRecipeFlags\((\d+)\s*,([^)]*)\)")
_ACQUIRE_RE = re.compile(r"self:(AddRecipe\w+)\((\d+)\s*,([^)]*)\)")
_NPC_ID_RE = re.compile(r"\b(\d+)\b")
# AddVendor(340, L["Kendor Kabonka"], BZ["Stormwind City"], 77.5, 53.5, ALLIANCE)
_LOOKUP_RE = re.compile(
    r"""Add(?:Vendor|Mob|Trainer|Quest|Reputation)\(\s*
        (\d+)\s*,\s*                       # id
        L\["((?:[^"\\]|\\.)*)"\]\s*,\s*    # name
        (?:BZ\["((?:[^"\\]|\\.)*)"\]|[^,]+)  # zone, sometimes a bare string
    """,
    re.VERBOSE,
)


def fetch_file(name, timeout=90, user_agent=DEFAULT_USER_AGENT):
    request = Request(ARL_RAW_BASE + "Database/" + name + ".lua",
                      headers={"User-Agent": user_agent})
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def parse_lookup(text):
    """id -> {name, zone} from one of the NPC lookup files."""
    out = {}
    for match in _LOOKUP_RE.finditer(text or ""):
        npc_id = int(match.group(1))
        out[npc_id] = {
            "name": match.group(2),
            "zone": match.group(3) or None,
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
    """spell ID -> {faction, acquires: {kind: [npc ids]}} for one profession."""
    recipes = {}
    for match in _RECIPE_RE.finditer(text or ""):
        recipes.setdefault(int(match.group(1)), {"faction": FACTION_BOTH, "acquires": {}})

    for match in _FLAGS_RE.finditer(text or ""):
        spell_id = int(match.group(1))
        if spell_id in recipes:
            recipes[spell_id]["faction"] = parse_faction(match.group(2))

    for match in _ACQUIRE_RE.finditer(text or ""):
        kind = ACQUIRE_KINDS.get(match.group(1))
        if not kind:
            continue
        spell_id = int(match.group(2))
        if spell_id not in recipes:
            continue
        npc_ids = [int(value) for value in _NPC_ID_RE.findall(match.group(3))]
        # A world drop names no NPC; the call is the whole statement.
        recipes[spell_id]["acquires"].setdefault(kind, []).extend(npc_ids)

    return recipes


def summarize_recipe(entry, lookups, max_names=3, max_zones=4):
    """Flatten one recipe into the fields the addon renders."""
    acquires = entry.get("acquires") or {}
    kind = next((candidate for candidate in KIND_PRIORITY if candidate in acquires), None)

    npc_ids = acquires.get(kind or "", [])
    names, zones = [], []
    for npc_id in npc_ids:
        npc = lookups.get(npc_id)
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
    lookup_table = {}
    for index, name in enumerate(lookups):
        if index and delay:
            time.sleep(delay)
        lookup_table.update(parse_lookup(fetch(name, timeout=timeout)))

    by_spell_id = {}
    per_profession = {}
    for name in professions:
        if delay:
            time.sleep(delay)
        recipes = parse_profession(fetch(name, timeout=timeout))
        per_profession[name] = len(recipes)
        for spell_id, entry in recipes.items():
            by_spell_id[spell_id] = summarize_recipe(entry, lookup_table)

    return by_spell_id, per_profession, lookup_table


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
