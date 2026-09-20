"""Wowhead importer for per-recipe profession specialization requirements.

Why a second source at all: the specialization a recipe requires is enforced
by the trainer, server-side, so it is absent from the client data the Wago
Tools DB2 snapshot is built from. Every `SkillLineAbility` row for an
Armorsmith or Gnomish Engineering recipe is byte-identical to a plain one,
`SkillLine` has no specialization lines, and `ItemSparse.RequiredAbility` is
empty on every recipe item. Wowhead carries the field explicitly.

Where the field lives: not in Wowhead's tooltip API and not in the rendered
prose, but in the inline `new Listview({... data: [...]})` blob of the HTML.
One request per profession returns every recipe of that profession, so the
whole dataset costs nine requests rather than one per recipe.

Row shape (abridged), for Gnomish Battle Chicken:

    {"id":12906,"name":"Gnomish Battle Chicken","skill":[202],
     "learnedat":230,"creates":[10725,1,1],"source":[6],
     "specialization":20219,"trainingcost":2400}

`specialization` is the spell ID of the specialization itself, matching the
IDs the addon already uses in `Data.lua` PROFESSION_SPECIALIZATIONS.

The blob is not valid JSON (some keys are unquoted), so rows are scanned with
a regex per field instead of parsed wholesale. Rows are accepted only when the
specialization is one of the known TBC specialization spells, which keeps
unrelated listviews on the same page from leaking in.
"""

import json
import re
import time
from urllib.request import Request, urlopen


WOWHEAD_BASE_URL = "https://www.wowhead.com"
DEFAULT_FLAVOR = "tbc"
DEFAULT_REQUEST_DELAY = 1.5
DEFAULT_USER_AGENT = "RecipeRegistry metadata importer"

PROFESSION_SLUGS = (
    "alchemy",
    "blacksmithing",
    "cooking",
    "enchanting",
    "engineering",
    "jewelcrafting",
    "leatherworking",
    "mining",
    "tailoring",
)

# Specialization spell IDs recognised for TBC, mirroring Data.lua. Anything
# outside this set is treated as noise from an unrelated listview.
SPECIALIZATION_SPELL_IDS = {
    28672: "Transmutation Master",
    28675: "Potion Master",
    28677: "Elixir Master",
    9787: "Weaponsmith",
    9788: "Armorsmith",
    17039: "Master Swordsmith",
    17040: "Master Hammersmith",
    17041: "Master Axesmith",
    26797: "Spellfire Tailoring",
    26798: "Mooncloth Tailoring",
    26801: "Shadoweave Tailoring",
    10656: "Dragonscale Leatherworking",
    10658: "Elemental Leatherworking",
    10660: "Tribal Leatherworking",
    20219: "Gnomish Engineering",
    20222: "Goblin Engineering",
}

# Which profession each specialization belongs to. A profession page embeds
# unrelated listviews (related items, popularity widgets) whose rows would
# otherwise be accepted, so rows are held to the page they came from. The
# union across pages is unchanged — the duplicates were already covered by
# their own profession's page — but the per-page counts become truthful and a
# future layout change cannot inject foreign rows.
SPECIALIZATION_PROFESSIONS = {
    28672: "alchemy",
    28675: "alchemy",
    28677: "alchemy",
    9787: "blacksmithing",
    9788: "blacksmithing",
    17039: "blacksmithing",
    17040: "blacksmithing",
    17041: "blacksmithing",
    26797: "tailoring",
    26798: "tailoring",
    26801: "tailoring",
    10656: "leatherworking",
    10658: "leatherworking",
    10660: "leatherworking",
    20219: "engineering",
    20222: "engineering",
}

_ROW_RE = re.compile(r"\{[^{}]*\}")
_ID_RE = re.compile(r'"id":(\d+)')
_SPEC_RE = re.compile(r'"specialization":(\d+)')


def parse_listview_specializations(html, profession=None):
    """Extract {spellId: specializationSpellId} from one profession page.

    Rows whose id equals their specialization are the spells that teach the
    specialization itself, not recipes gated behind it, so they are dropped.
    Passing `profession` restricts rows to specializations of that profession.
    """
    found = {}
    for row in _ROW_RE.findall(html or ""):
        spec_match = _SPEC_RE.search(row)
        if not spec_match:
            continue
        specialization = int(spec_match.group(1))
        if specialization not in SPECIALIZATION_SPELL_IDS:
            continue
        if profession is not None and SPECIALIZATION_PROFESSIONS[specialization] != profession:
            continue
        id_match = _ID_RE.search(row)
        if not id_match:
            continue
        spell_id = int(id_match.group(1))
        if spell_id == specialization:
            continue
        found[spell_id] = specialization
    return found


def fetch_profession_page(profession, flavor=DEFAULT_FLAVOR, timeout=90, user_agent=DEFAULT_USER_AGENT):
    url = "{0}/{1}/spells/professions/{2}".format(WOWHEAD_BASE_URL, flavor, profession)
    request = Request(url, headers={"User-Agent": user_agent})
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def fetch_specializations(
    flavor=DEFAULT_FLAVOR,
    professions=PROFESSION_SLUGS,
    timeout=90,
    delay=DEFAULT_REQUEST_DELAY,
    fetch_page=fetch_profession_page,
):
    """Collect specialization requirements across every supported profession.

    `delay` throttles between requests; it is a courtesy to Wowhead, not a
    correctness requirement, and tests inject a fetcher and set it to zero.
    """
    by_spell_id = {}
    per_profession = {}
    for index, profession in enumerate(professions):
        if index and delay:
            time.sleep(delay)
        html = fetch_page(profession, flavor=flavor, timeout=timeout)
        found = parse_listview_specializations(html, profession=profession)
        per_profession[profession] = len(found)
        by_spell_id.update(found)
    return by_spell_id, per_profession


def build_specialization_snapshot(by_spell_id, per_profession, flavor=DEFAULT_FLAVOR):
    """Deterministic snapshot payload — no timestamps, so refetches that find
    nothing new produce a byte-identical file and an empty diff."""
    counts = {}
    for specialization in by_spell_id.values():
        name = SPECIALIZATION_SPELL_IDS[specialization]
        counts[name] = counts.get(name, 0) + 1
    return {
        "source": "wowhead-listview",
        "flavor": flavor,
        "sourceStats": {
            "records": len(by_spell_id),
            "byProfessionPage": dict(sorted(per_profession.items())),
            "bySpecialization": dict(sorted(counts.items())),
        },
        "specializationBySpellId": {
            str(spell_id): specialization
            for spell_id, specialization in sorted(by_spell_id.items())
        },
    }


def load_specializations(snapshot_dir):
    """Read the committed snapshot; absent file means "no data", not an error,
    so the pipeline keeps working for anyone who has not fetched it."""
    from pathlib import Path

    path = Path(snapshot_dir) / "specializations.json"
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    return {
        int(spell_id): int(specialization)
        for spell_id, specialization in data.get("specializationBySpellId", {}).items()
    }


def write_specialization_snapshot(payload, snapshot_dir):
    from pathlib import Path

    path = Path(snapshot_dir) / "specializations.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path
