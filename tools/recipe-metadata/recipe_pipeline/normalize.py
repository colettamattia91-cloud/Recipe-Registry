from recipe_pipeline.classify_expansion import classify_expansion
from recipe_pipeline.derive_categories import derive_category
from recipe_pipeline.derive_items import derive_created_item_id, derive_recipe_item_id
from recipe_pipeline.derive_reagents import derive_reagents
from recipe_pipeline.records import RecipeRecord

# A pattern that drops from this many distinct creatures out in the world is
# a world drop: listing the creatures answers nothing a player can act on,
# and the zone list would be most of the continent.
WORLD_DROP_NPC_THRESHOLD = 8
MAX_SOURCE_ZONES = 4
MAX_SOURCE_NAMES = 3
# Vendors first: a recipe you can walk up and buy is the actionable answer
# even when it also drops.
SOURCE_KIND_PRIORITY = ("vendor", "drop", "container")


def summarize_source(source):
    """Flatten one obtain-side record into the fields the addon renders.

    Drops split three ways, because "it drops" is not one answer:

    * a boss is named -- "drops from Nightbane" is something you can act on;
    * anything else inside an instance is trash, and naming twenty creatures
      in Karazhan tells you nothing the instance name did not;
    * out in the world, a handful of creatures are worth naming and a long
      tail of them is a world drop.
    """
    if not source:
        return None, None, (), (), False, False

    kinds = source.get("kinds") or []
    kind = next((candidate for candidate in SOURCE_KIND_PRIORITY if candidate in kinds), None)
    providers = source.get("vendors") if kind == "vendor" else (
        source.get("drops") if kind == "drop" else source.get("containers")
    )
    providers = providers or []

    world_drop = False
    trash = False
    if kind == "drop":
        bosses = [row for row in providers if row.get("boss")]
        if bosses:
            # A named boss beats everything else that drops it.
            kind = "boss"
            providers = bosses
        elif any(row.get("instance") for row in providers):
            kind = "trash"
            trash = True
        elif len(providers) >= WORLD_DROP_NPC_THRESHOLD:
            world_drop = True

    # Trash keeps its zones -- the instance name IS the answer -- but not the
    # creature list. A world drop keeps neither.
    zones = () if world_drop else tuple(sorted(source.get("zones") or [])[:MAX_SOURCE_ZONES])
    names = () if (world_drop or trash) else tuple(
        provider["name"] for provider in providers[:MAX_SOURCE_NAMES] if provider.get("name")
    )
    faction = source.get("faction")
    # "both" is the default reading of an absent field, so it is not stored.
    if faction == "both":
        faction = None
    return faction, kind, zones, names, world_drop, trash


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

        specialization = overrides.get("specializationBySpellId", {}).get(spell_id)
        if specialization is None:
            specialization = secondary.get("specializationBySpellId", {}).get(spell_id)

        # Obtain-side data is keyed by the recipe ITEM, not the spell: it is a
        # fact about the pattern you buy or loot. Trainer-taught recipes have
        # no recipe item and so no entry, which is itself the answer.
        source = {}
        if recipe_item_id is not None:
            source = secondary.get("sourcesByRecipeItemId", {}).get(recipe_item_id) or {}
        source = overrides.get("sourceByRecipeItemId", {}).get(recipe_item_id, source)
        (faction, source_kind, source_zones, source_names,
         world_drop, trash_drop) = summarize_source(source)

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
            created_count=recipe.get("createdCount"),
            created_count_max=recipe.get("createdCountMax"),
            specialization=specialization,
            faction=faction,
            source_kind=source_kind,
            source_zones=source_zones,
            source_names=source_names,
            world_drop=world_drop,
            trash_drop=trash_drop,
        ))

    return tuple(records), diagnostics
