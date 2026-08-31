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
