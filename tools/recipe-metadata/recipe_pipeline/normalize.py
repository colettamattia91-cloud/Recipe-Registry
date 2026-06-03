from recipe_pipeline.classify_expansion import classify_expansion
from recipe_pipeline.derive_categories import derive_category
from recipe_pipeline.derive_items import derive_created_item_id, derive_recipe_item_id
from recipe_pipeline.derive_reagents import derive_reagents
from recipe_pipeline.records import RecipeRecord


def normalize_records(primary, secondary, taxonomies, overrides=None, flavor="tbc"):
    overrides = overrides or {}
    diagnostics = {
        "excluded": [],
        "categoryFallbacks": [],
    }
    records = []

    for recipe in sorted(primary.get("recipes", ()), key=lambda row: int(row["spellId"])):
        spell_id = int(recipe["spellId"])
        expansion = overrides.get("expansionBySpellId", {}).get(spell_id) or classify_expansion(recipe, secondary)
        if expansion not in ("vanilla", "tbc"):
            diagnostics["excluded"].append({
                "spellId": spell_id,
                "reason": "unsupported-expansion",
                "expansion": recipe.get("firstSeenExpansion"),
            })
            continue

        profession_key = recipe.get("profession")
        recipe_item_id = derive_recipe_item_id(recipe, secondary, overrides)
        created_item_id = derive_created_item_id(recipe, secondary, overrides)
        reagents = derive_reagents(spell_id, primary, secondary)
        category_key, subcategory_key, sort_order = derive_category(recipe, profession_key, taxonomies, diagnostics)

        category_override = overrides.get("categoryBySpellId", {}).get(spell_id)
        if isinstance(category_override, dict):
            category_key = category_override.get("category", category_key)
            subcategory_key = category_override.get("subcategory", subcategory_key)
            sort_order = int(category_override.get("sortOrder", sort_order))

        outputless = spell_id in secondary.get("selfOnlyOutputlessBySpellId", {})
        outputless = overrides.get("selfOnlyOutputlessBySpellId", {}).get(spell_id, outputless)

        bop_output = None
        if spell_id in overrides.get("bopOutputBySpellId", {}):
            bop_output = overrides["bopOutputBySpellId"][spell_id]
        elif spell_id in secondary.get("bopOutputBySpellId", {}):
            bop_output = secondary["bopOutputBySpellId"][spell_id]
        elif created_item_id is not None:
            bind_type = primary.get("bindTypeByItemId", {}).get(created_item_id)
            if bind_type is not None:
                bop_output = int(bind_type) == 1

        records.append(RecipeRecord(
            spell_id=spell_id,
            profession_key=profession_key,
            expansion=expansion,
            recipe_item_id=recipe_item_id,
            created_item_id=created_item_id,
            reagents=reagents,
            category_key=category_key,
            subcategory_key=subcategory_key,
            sort_order=sort_order,
            required_skill=recipe.get("requiredSkill"),
            is_outputless_self_only=outputless is True,
            bop_output=bop_output,
        ))

    return tuple(records), diagnostics
