from recipe_pipeline.records import ReagentRecord, RecipeRecord


METADATA_VERSION = "2026.05.23.1"
SCHEMA_VERSION = 1
FLAVOR = "tbc"


def sample_records():
    return (
        RecipeRecord(2329, "alchemy", "vanilla", None, 2454, (ReagentRecord(2449, 1), ReagentRecord(765, 1),), "potions", "combat", 20, 1, bop_output=False),
        RecipeRecord(2330, "alchemy", "vanilla", None, 118, (ReagentRecord(2447, 1), ReagentRecord(765, 1),), "potions", "healing", 30, 1, bop_output=False),
        RecipeRecord(28543, "alchemy", "tbc", 22907, 22823, (ReagentRecord(22787, 1), ReagentRecord(22785, 2),), "potions", "mana", 110, 305, bop_output=False),
        RecipeRecord(28596, "alchemy", "tbc", 22900, 22845, (ReagentRecord(22790, 7), ReagentRecord(22791, 3),), "flasks", "guardian_elixirs", 120, 300, bop_output=False),
        RecipeRecord(3918, "engineering", "vanilla", None, 4357, (ReagentRecord(2835, 1),), "explosives", "powders", 10, 1, bop_output=False),
        RecipeRecord(30303, "engineering", "tbc", 23799, 23761, (ReagentRecord(23446, 4), ReagentRecord(23783, 2),), "devices", "weapons", 120, 350, bop_output=False),
        RecipeRecord(27924, "enchanting", "tbc", None, None, (ReagentRecord(22449, 10), ReagentRecord(22445, 8),), "ring_enchants", "self_only", 100, 360, is_outputless_self_only=True, bop_output=None),
        RecipeRecord(35530, "leatherworking", "tbc", 29664, 29540, (ReagentRecord(23793, 6), ReagentRecord(22452, 4),), "armor", "bop", 160, 375, bop_output=True),
        RecipeRecord(26745, "tailoring", "tbc", None, 21840, (ReagentRecord(21877, 5),), "cloth", "bolts", 20, 325, bop_output=False),
        RecipeRecord(26746, "tailoring", "tbc", None, 21840, (ReagentRecord(21840, 1), ReagentRecord(14341, 1),), "cloth", "bolts", 30, 325, bop_output=False),
    )


def categories_by_profession():
    return {
        "alchemy": (
            {"key": "potions", "label": "Potions", "order": 10},
            {"key": "flasks", "label": "Flasks", "order": 20},
            {"key": "misc", "label": "Miscellaneous", "order": 999},
        ),
        "enchanting": (
            {"key": "ring_enchants", "label": "Ring Enchants", "order": 40},
            {"key": "misc", "label": "Miscellaneous", "order": 999},
        ),
        "engineering": (
            {"key": "explosives", "label": "Explosives", "order": 10},
            {"key": "devices", "label": "Devices", "order": 20},
            {"key": "misc", "label": "Miscellaneous", "order": 999},
        ),
        "leatherworking": (
            {"key": "armor", "label": "Armor", "order": 10},
            {"key": "misc", "label": "Miscellaneous", "order": 999},
        ),
        "tailoring": (
            {"key": "cloth", "label": "Cloth", "order": 10},
            {"key": "misc", "label": "Miscellaneous", "order": 999},
        ),
    }


def subcategories_by_profession():
    return {
        "alchemy": {
            "potions": (
                {"key": "combat", "label": "Combat", "order": 10},
                {"key": "healing", "label": "Healing", "order": 20},
                {"key": "mana", "label": "Mana", "order": 30},
            ),
            "flasks": (
                {"key": "guardian_elixirs", "label": "Guardian Elixirs", "order": 10},
            ),
        },
        "enchanting": {
            "ring_enchants": (
                {"key": "self_only", "label": "Self Only", "order": 10},
            ),
        },
        "engineering": {
            "explosives": (
                {"key": "powders", "label": "Powders", "order": 10},
            ),
            "devices": (
                {"key": "weapons", "label": "Weapons", "order": 10},
            ),
        },
        "leatherworking": {
            "armor": (
                {"key": "bop", "label": "Bind on Pickup", "order": 30},
            ),
        },
        "tailoring": {
            "cloth": (
                {"key": "bolts", "label": "Bolts", "order": 10},
            ),
        },
    }
