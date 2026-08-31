from dataclasses import dataclass
from typing import Optional, Tuple


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
    source_zones: Tuple[int, ...] = ()
    source_names: Tuple[str, ...] = ()
    # Set when the recipe drops from so many creatures across so many zones
    # that naming them is noise rather than an answer.
    world_drop: bool = False
    # Set when it drops off non-boss creatures inside an instance: the
    # instance name is the answer, the creature list is not.
    trash_drop: bool = False
