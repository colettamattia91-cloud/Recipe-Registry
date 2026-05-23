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
