SUPPORTED_EXPANSIONS = ("vanilla", "tbc")


def classify_expansion(recipe, secondary):
    spell_id = int(recipe["spellId"])
    override = secondary.get("expansionBySpellId", {}).get(spell_id)
    expansion = override or recipe.get("firstSeenExpansion")
    if expansion not in SUPPORTED_EXPANSIONS:
        return None
    return expansion
