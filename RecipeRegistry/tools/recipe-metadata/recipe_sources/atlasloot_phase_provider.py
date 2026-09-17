"""Content phase from AtlasLoot Classic's own loot tables.

`derive_phase` reads the phase off the ZONE a recipe comes from, which answers
"this content did not exist yet" and stops there. It has a blind spot that is
not rare: a vendor added in a later patch who stands in a launch zone. Ontuvo
sells twelve jewelcrafting designs from Shattrath City -- a day-one zone -- but
he is a Shattered Sun vendor, creature entry 27666, and nobody could buy from
him until the Isle opened.

AtlasLoot classifies the ITEM rather than the place, so it catches those. Its
TBC data marks whole tables with `ContentPhaseBC`:

    SerpentshrineCavern 2   HyjalSummit 3   ZulAman 4   MagistersTerrace 5
    TempestKeep 2           BlackTemple 3               SunwellPlateau 5
    ShatteredSunOffensive 5

Every item id inside such a table carries that table's phase. Measured against
the zone derivation on 2026-09-06: **76 recipes where both have an opinion, 76
agreements, no conflicts**, and 12 recipes AtlasLoot places that the zone rule
missed -- all twelve sold by Ontuvo or Shaani.

What it does NOT have is a per-item table for TBC. `ContentPhase:GetForItemID`
exists and is populated for Classic (1913 items) and Wrath (4443), but the
Burning Crusade branch is an empty table in both the upstream repo and the
installed copy. So a launch-zone recipe Blizzard held back that is in no raid
or faction table -- the Adamantite Arrow Maker case -- is still not answered
here, and stays a job for `phaseBySpellId` in the overrides.

Matching is on the RECIPE item, the pattern or schematic that drops, never on
what the recipe creates: a crafted item turns up in loot tables and vendor
lists all over the game, and its phase is not the recipe's.
"""

import json
import re
from pathlib import Path
from urllib.request import Request, urlopen

RAW_BASE = "https://raw.githubusercontent.com/Hoizame/AtlasLootClassic/master/"
DEFAULT_USER_AGENT = "RecipeRegistry metadata importer"

# The two modules whose TBC tables carry a phase. The crafting module has none
# -- it lists what professions make, not when the game let you make it.
SOURCE_FILES = (
    "AtlasLootClassic_DungeonsAndRaids/data-tbc.lua",
    "AtlasLootClassic_Factions/data-tbc.lua",
)

# A top-level table: `data["BlackTemple"] = {`.
TABLE_START = re.compile(r'^data\["([^"]+)"\]\s*=\s*\{', re.M)
# The marker, at the start of a line so a commented-out one is not read.
PHASE_MARKER = re.compile(r'^\s*ContentPhaseBC\s*=\s*(\d+)', re.M)
# A loot entry: `{ 12, 34659 }`. Entries whose second field is a string are
# reputation and set placeholders, and are skipped by requiring digits.
LOOT_ENTRY = re.compile(r'\{\s*\d+\s*,\s*(\d+)')


def fetch_file(name, timeout=90, user_agent=DEFAULT_USER_AGENT):
    request = Request(RAW_BASE + name, headers={"User-Agent": user_agent})
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def phase_tables(text):
    """Each top-level table that carries a phase, as (name, phase, item ids)."""
    starts = [(m.start(), m.group(1)) for m in TABLE_START.finditer(text)]
    for index, (position, name) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
        body = text[position:end]
        marker = PHASE_MARKER.search(body)
        if not marker:
            continue
        item_ids = {int(value) for value in LOOT_ENTRY.findall(body)}
        yield name, int(marker.group(1)), item_ids


def build_phases(texts, spell_id_by_recipe_item):
    """recipe item -> spell id, mapped to the earliest phase that places it.

    The earliest, because an item in two tables is obtainable as soon as the
    first of them opens.
    """
    by_item, tables = {}, {}
    for text in texts:
        for name, phase, item_ids in phase_tables(text):
            tables[name] = {"phase": phase, "items": len(item_ids)}
            for item_id in item_ids:
                if item_id in by_item:
                    by_item[item_id] = min(by_item[item_id], phase)
                else:
                    by_item[item_id] = phase

    out = {}
    for item_id, phase in by_item.items():
        spell_id = spell_id_by_recipe_item.get(item_id)
        if spell_id is not None:
            out[int(spell_id)] = phase
    return out, tables


def build_snapshot(by_spell_id, tables):
    return {
        "source": {
            "provider": "atlasloot-classic",
            "files": list(SOURCE_FILES),
            "marker": "ContentPhaseBC",
        },
        "sourceStats": {
            "tables": tables,
            "records": len(by_spell_id),
        },
        "phaseBySpellId": {
            str(spell_id): phase for spell_id, phase in sorted(by_spell_id.items())
        },
    }


def write_snapshot(payload, snapshot_dir):
    path = Path(snapshot_dir) / "phases.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def load_phases(snapshot_dir):
    """Absent file means "not fetched", not an error: the pipeline still runs
    and every recipe falls back to the zone derivation."""
    path = Path(snapshot_dir) / "phases.json"
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    return {
        int(spell_id): int(phase)
        for spell_id, phase in data.get("phaseBySpellId", {}).items()
    }
