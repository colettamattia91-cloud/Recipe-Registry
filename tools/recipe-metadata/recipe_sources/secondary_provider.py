"""Secondary static metadata source.

DB2-derived rows are authoritative, but a few semantic flags are not cleanly
available from the compact snapshots. This provider supplies those fields in a
deterministic offline file.
"""

import json
from pathlib import Path


def load_secondary_sources(snapshot_dir):
    path = Path(snapshot_dir) / "secondary_static.json"
    if not path.exists():
        return {
            "selfOnlyOutputlessBySpellId": {},
            "bopOutputBySpellId": {},
            "recipeItemBySpellId": {},
            "createdItemBySpellId": {},
            "expansionBySpellId": {},
        }

    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    def int_keyed(name):
        return {int(key): value for key, value in data.get(name, {}).items()}

    return {
        "selfOnlyOutputlessBySpellId": {int(spell_id): True for spell_id in data.get("selfOnlyOutputlessSpellIds", [])},
        "bopOutputBySpellId": int_keyed("bopOutputBySpellId"),
        "recipeItemBySpellId": int_keyed("recipeItemBySpellId"),
        "createdItemBySpellId": int_keyed("createdItemBySpellId"),
        "expansionBySpellId": int_keyed("expansionBySpellId"),
    }
