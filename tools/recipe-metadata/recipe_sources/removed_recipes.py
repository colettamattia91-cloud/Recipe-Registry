"""Recipes that exist in the client data but not in the game.

DB2 still carries spells for recipes that were never implemented, or that were
taken out and never came back. They reach our dataset looking exactly like any
other recipe -- a name, a skill requirement, reagents -- and no obtain-side
source will ever place them, because there is nowhere to go and learn them.

That absence is itself the signal, and it is the one CraftLib uses: a recipe
with no difficulty data on Wowhead is a recipe Wowhead has nothing about,
because nobody has ever learned it in this version of the game. Their list is
the curated result.

Nothing is deleted on the strength of it. The flag rides along with the
record, so a recipe wrongly on the list is put back by one line in
`manual_overrides.yaml` -- `removedBySpellId: {12345: false}` -- and a
regenerate, with no refetch and nothing else touched.
"""

import json
from pathlib import Path
from urllib.request import Request, urlopen


CRAFTLIB_URL = ("https://raw.githubusercontent.com/kaldown/CraftLib/HEAD/"
                "Data/Sources/removed_recipes.json")
DEFAULT_USER_AGENT = "RecipeRegistry metadata importer"
SNAPSHOT_FILENAME = "removed.json"
PARSER_VERSION = 1


def fetch_removed(timeout=60, user_agent=DEFAULT_USER_AGENT):
    request = Request(CRAFTLIB_URL, headers={"User-Agent": user_agent})
    with urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def parse_removed(payload):
    """spell ID -> {profession, name, notes} for every listed recipe."""
    out = {}
    for profession, entries in (payload.get("recipes") or {}).items():
        for entry in entries or ():
            spell_id = entry.get("spellId")
            if spell_id is None:
                continue
            out[int(spell_id)] = {
                "profession": profession,
                "name": entry.get("name"),
                "notes": entry.get("notes"),
            }
    return out


def build_snapshot(by_spell_id, reason=None):
    return {
        "removedBySpellId": {
            str(spell_id): entry for spell_id, entry in sorted(by_spell_id.items())
        },
        "parserVersion": PARSER_VERSION,
        "source": "craftlib-removed-recipes",
        "reason": reason,
        "sourceStats": {"records": len(by_spell_id)},
    }


def write_snapshot(payload, snapshot_dir):
    path = Path(snapshot_dir) / SNAPSHOT_FILENAME
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def load_removed(snapshot_dir):
    """Read the committed snapshot; an absent file means nothing is flagged."""
    path = Path(snapshot_dir) / SNAPSHOT_FILENAME
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    return {int(spell_id): True
            for spell_id in data.get("removedBySpellId", {})}
