from recipe_pipeline.classify_expansion import classify_expansion
from recipe_pipeline.derive_categories import derive_category
from recipe_pipeline.derive_items import derive_created_item_id, derive_recipe_item_id
from recipe_pipeline.derive_reagents import derive_reagents
from recipe_pipeline.records import RecipeRecord, SourcePlace

MAX_SOURCE_PLACES = 4


def summarize_source(source):
    """Flatten one obtain-side record into the fields the addon renders.

    The source already states the kind, the faction and the places; what is
    decided here is only what to keep. A world drop has nowhere to point at,
    so it keeps none. Everything else is capped at four places, which is as
    much as a table row can carry and as much as a player needs in order to
    go and look.
    """
    if not source:
        return None, None, (), False, False, None, None

    kind = source.get("kind")
    world_drop = source.get("worldDrop") is True
    if world_drop:
        kind = "worldDrop"

    places = ()
    if not world_drop:
        places = tuple(
            SourcePlace(
                name=place.get("name") or None,
                zone=place.get("zone") or None,
                x=place.get("x"),
                y=place.get("y"),
                faction=place.get("faction") or None,
            )
            for place in (source.get("places") or [])[:MAX_SOURCE_PLACES]
            if place.get("name") or place.get("zone")
        )

    faction = source.get("faction")
    # "both" is the default reading of an absent field, so it is not stored.
    if faction == "both":
        faction = None
    levels = source.get("skillLevels")
    if levels and len(levels) == 4:
        levels = tuple(int(value) for value in levels)
    else:
        levels = None
    required = source.get("skillLevel")
    if required is not None:
        required = int(required)
    return faction, kind, places, world_drop, source.get("bossDrop") is True, levels, required


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

        # Obtain-side data is keyed by the spell, which is this project's own
        # recipe key, so trainer-taught recipes are covered too rather than
        # only the ones that come from a pattern.
        # A recipe in the client data but not in the game. The override can
        # force it either way, so putting one back is one line and a
        # regenerate -- which is the whole reason the record is kept.
        removed = overrides.get("removedBySpellId", {}).get(spell_id)
        if removed is None:
            removed = secondary.get("removedBySpellId", {}).get(spell_id, False)

        source = secondary.get("acquisitionBySpellId", {}).get(spell_id) or {}
        source = overrides.get("acquisitionBySpellId", {}).get(spell_id, source)
        (faction, source_kind, source_places,
         world_drop, boss_drop, skill_levels, sourced_skill) = summarize_source(source)

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
            # The primary snapshot leaves this unset on a third of the
            # records -- SkillLineAbility does not carry it for a
            # trainer-taught recipe -- and a third of the Skill column read as
            # a dash because of it. The obtain-side source states the number on
            # the same line the difficulty ladder comes from, and it is only
            # ever a fallback: where the primary states one, the primary wins.
            required_skill=recipe.get("requiredSkill") or sourced_skill,
            is_outputless_self_only=outputless is True,
            bop_output=bop_output,
            created_count=recipe.get("createdCount"),
            created_count_max=recipe.get("createdCountMax"),
            specialization=specialization,
            faction=faction,
            source_kind=source_kind,
            source_places=source_places,
            skill_levels=skill_levels,
            world_drop=world_drop,
            boss_drop=boss_drop,
            removed=removed is True,
        ))

    return tuple(records), diagnostics
