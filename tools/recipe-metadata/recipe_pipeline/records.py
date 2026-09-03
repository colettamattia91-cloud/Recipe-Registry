from dataclasses import dataclass
from typing import Optional, Tuple, NamedTuple


class SourcePlace(NamedTuple):
    """One place a recipe can be had, as one entity rather than as columns.

    Name and zone travel together because two parallel lists cannot say which
    vendor stands in which city. The position and the faction travel with them
    for the same reason: a recipe sold by an Alliance vendor in Stormwind and a
    Horde one in Orgrimmar is available to everybody, and saying so at the
    recipe level tells a Horde player nothing about which of the two they can
    walk up to. Either half of the position may be absent; so may the faction,
    which then means "no restriction" rather than "unknown".
    """
    name: Optional[str] = None
    zone: Optional[str] = None
    x: Optional[float] = None
    y: Optional[float] = None
    faction: Optional[str] = None


@dataclass(frozen=True)
class ReagentRecord:
    item_id: int
    quantity: int


@dataclass(frozen=True)
class RecipeRecord:
    spell_id: int
    profession_key: str
    expansion: str
    recipe_item_id: Optional[int]
    created_item_id: Optional[int]
    reagents: Tuple[ReagentRecord, ...]
    category_key: Optional[str]
    subcategory_key: Optional[str]
    sort_order: int
    required_skill: Optional[int]
    is_outputless_self_only: bool = False
    bop_output: Optional[bool] = None
    source_notes: Tuple[str, ...] = ()
    # Units produced per craft. None means the source did not state one and
    # consumers should assume 1; created_count_max is set only for the few
    # recipes whose output is a random range.
    created_count: Optional[int] = None
    created_count_max: Optional[int] = None
    # Spell ID of the profession specialization required to learn this recipe,
    # or None when any practitioner can learn it. Not derivable from client
    # data — see wowhead_specialization_provider.
    specialization: Optional[int] = None
    # Where the recipe comes from, when it is taught by an item. None means
    # "not known" rather than "available to everyone"; "both" is the explicit
    # answer and is what the emitter omits, since it is the common case.
    # See wowhead_source_provider.
    faction: Optional[str] = None
    source_kind: Optional[str] = None
    # Where the recipe comes from, one entry per place, as (name, zone).
    # Either half may be None: a quest gives a zone and no name, and a recipe
    # every trainer teaches gives neither. They are pairs rather than two
    # lists because two lists cannot say which vendor stands in which zone.
    # Zones are NAMES, not IDs -- each source numbers zones differently, so
    # names are the only shared vocabulary; the emitter interns them.
    source_places: Tuple["SourcePlace", ...] = ()
    # The four difficulty thresholds the game colours a recipe by: orange up to
    # optimal, yellow up to medium, green up to easy, grey from trivial on.
    # Stated per recipe by the source -- the spread runs from ten points to
    # sixty, so it cannot be derived from required_skill. None when the source
    # did not state a usable ladder.
    skill_levels: Optional[Tuple[int, int, int, int]] = None
    # Set when the recipe drops from so many creatures across so many zones
    # that naming them is noise rather than an answer.
    world_drop: bool = False
    # Set when several bosses drop it: the row says so and names the places,
    # rather than listing creatures a player would have to cross-reference.
    boss_drop: bool = False
    # In the client data but not in the game: never implemented, or taken out
    # and never returned. The record is kept whole rather than dropped, so
    # putting one back is an override and a regenerate rather than an
    # archaeology exercise. See removed_recipes.
    removed: bool = False
