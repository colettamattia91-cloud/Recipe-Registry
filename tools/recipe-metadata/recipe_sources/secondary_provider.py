"""Secondary static metadata source.

DB2-derived rows are authoritative, but a few semantic flags are not cleanly
available from the compact snapshots. This provider supplies those fields in a
deterministic offline file.
"""

import json
from pathlib import Path

from recipe_sources.arl_source_provider import load_acquisition
from recipe_sources.manual_acquisition import (
    load_manual_acquisition,
    merge_acquisition,
)
from recipe_sources.removed_recipes import load_removed
from recipe_sources.wowhead_source_provider import load_sources
from recipe_sources.wowhead_specialization_provider import load_specializations


def load_secondary_sources(snapshot_dir):
    # Specializations live in their own snapshot file rather than in
    # secondary_static.json: they come from a different source on a different
    # refresh cadence, and secondary_static.json is rewritten wholesale by a
    # Wago refetch, which would silently drop them.
    specializations = load_specializations(snapshot_dir)
    # Same reasoning for the obtain-side data: its own file, its own refresh
    # cadence, and safe from a Wago refetch rewriting secondary_static.json.
    sources, zones = load_sources(snapshot_dir)
    # Where a recipe is obtained, keyed by spell ID. Its own file for the
    # same reason as the others: a different source on a different cadence,
    # and safe from a Wago refetch rewriting secondary_static.json.
    # Hand-verified records sit on top: they exist precisely for the recipes
    # the bulk source could not place, and a person who opened the page
    # outranks a parse of someone else's reconstruction.
    acquisition = merge_acquisition(
        load_acquisition(snapshot_dir),
        load_manual_acquisition(snapshot_dir),
    )
    # Recipes the client data carries but the game does not. Kept as a flag on
    # the record rather than a deletion, so one that turns out to be real is
    # put back with an override instead of a refetch.
    removed = load_removed(snapshot_dir)

    path = Path(snapshot_dir) / "secondary_static.json"
    if not path.exists():
        return {
            "selfOnlyOutputlessBySpellId": {},
            "bopOutputBySpellId": {},
            "recipeItemBySpellId": {},
            "createdItemBySpellId": {},
            "expansionBySpellId": {},
            "specializationBySpellId": specializations,
            "sourcesByRecipeItemId": sources,
            "zonesById": zones,
            "acquisitionBySpellId": acquisition,
            "removedBySpellId": removed,
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
        "specializationBySpellId": specializations,
        "sourcesByRecipeItemId": sources,
        "zonesById": zones,
        "acquisitionBySpellId": acquisition,
        "removedBySpellId": removed,
    }
