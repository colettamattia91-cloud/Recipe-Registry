def _optional_int(value):
    if value is None:
        return None
    return int(value)


def derive_recipe_item_id(recipe, secondary, overrides):
    spell_id = int(recipe["spellId"])
    if spell_id in overrides.get("recipeItemBySpellId", {}):
        return _optional_int(overrides["recipeItemBySpellId"][spell_id])
    if spell_id in secondary.get("recipeItemBySpellId", {}):
        return _optional_int(secondary["recipeItemBySpellId"][spell_id])
    return _optional_int(recipe.get("recipeItemId"))


def derive_created_item_id(recipe, secondary, overrides):
    spell_id = int(recipe["spellId"])
    if spell_id in overrides.get("createdItemBySpellId", {}):
        return _optional_int(overrides["createdItemBySpellId"][spell_id])
    if spell_id in secondary.get("createdItemBySpellId", {}):
        return _optional_int(secondary["createdItemBySpellId"][spell_id])
    return _optional_int(recipe.get("createdItemId"))
