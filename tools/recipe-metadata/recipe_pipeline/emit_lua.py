from collections import defaultdict


def _lua_number(value):
    """A coordinate, written without a trailing .0 when it has none."""
    if value == int(value):
        return str(int(value))
    return repr(round(float(value), 1))


def _lua_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _lua_bool(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    return "nil"


def _emit_record(record, zone_ids, indent="        "):
    lines = [indent + "[" + str(record.spell_id) + "] = {"]
    lines.append(indent + "    profession = " + _lua_string(record.profession_key) + ",")
    lines.append(indent + "    expansion = " + _lua_string(record.expansion) + ",")
    if record.recipe_item_id is not None:
        lines.append(indent + "    recipeItemId = " + str(record.recipe_item_id) + ",")
    if record.created_item_id is not None:
        lines.append(indent + "    createdItemId = " + str(record.created_item_id) + ",")
    # Only emitted when the craft yields more than one unit: the overwhelming
    # majority produce exactly one, and a `createdCount = 1` on every record
    # would bloat the generated file for no reader benefit.
    if record.created_count is not None and record.created_count > 1:
        lines.append(indent + "    createdCount = " + str(record.created_count) + ",")
    if record.created_count_max is not None and record.created_count_max != record.created_count:
        lines.append(indent + "    createdCountMax = " + str(record.created_count_max) + ",")
    lines.append(indent + "    category = " + _lua_string(record.category_key or "misc") + ",")
    if record.subcategory_key is not None:
        lines.append(indent + "    subcategory = " + _lua_string(record.subcategory_key) + ",")
    lines.append(indent + "    sortOrder = " + str(record.sort_order) + ",")
    if record.required_skill is not None:
        lines.append(indent + "    requiredSkill = " + str(record.required_skill) + ",")
    if record.specialization is not None:
        lines.append(indent + "    specialization = " + str(record.specialization) + ",")
    # Obtain-side fields. Absent faction means both, which is the common case,
    # so emitting it on every record would be pure bloat.
    if record.faction is not None:
        lines.append(indent + "    faction = " + _lua_string(record.faction) + ",")
    if record.source_kind is not None:
        lines.append(indent + "    sourceKind = " + _lua_string(record.source_kind) + ",")
    # The four thresholds the game colours the recipe by. Emitted as a flat
    # array because they are always four and always in this order.
    if record.skill_levels:
        lines.append(indent + "    skillLevels = { "
                     + ", ".join(str(value) for value in record.skill_levels) + " },")
    if record.world_drop:
        lines.append(indent + "    worldDrop = true,")
    if record.boss_drop:
        lines.append(indent + "    bossDrop = true,")
    if record.removed:
        lines.append(indent + "    removed = true,")
    if record.source_places:
        # Name and zone travel together: two parallel lists could not say
        # which vendor stands in which city.
        parts = []
        for place in record.source_places:
            fields = []
            if place.name:
                fields.append("name = " + _lua_string(place.name))
            if place.zone:
                fields.append("zone = " + str(zone_ids[place.zone]))
            # A position is only a position with both halves, and only worth
            # the bytes when there is a zone for it to be a position in.
            if place.zone and place.x is not None and place.y is not None:
                fields.append("x = " + _lua_number(place.x))
                fields.append("y = " + _lua_number(place.y))
            # Per-NPC faction. Absent means no restriction, exactly as it does
            # on the record itself.
            if place.faction:
                fields.append("faction = " + _lua_string(place.faction))
            parts.append("{ " + ", ".join(fields) + " }")
        lines.append(indent + "    sourcePlaces = { " + ", ".join(parts) + " },")
    if record.is_outputless_self_only:
        lines.append(indent + "    selfOnlyOutputless = true,")
    if record.bop_output is not None:
        lines.append(indent + "    bopOutput = " + _lua_bool(record.bop_output) + ",")
    if record.reagents:
        lines.append(indent + "    reagents = {")
        for reagent in record.reagents:
            lines.append(indent + "        { itemId = " + str(reagent.item_id) + ", count = " + str(reagent.quantity) + " },")
        lines.append(indent + "    },")
    lines.append(indent + "},")
    return lines


def _emit_array_table(entries, indent="        "):
    lines = [indent + "{"]
    for entry in sorted(entries, key=lambda item: (item["order"], item["key"])):
        lines.append(
            indent
            + "    { key = "
            + _lua_string(entry["key"])
            + ", label = "
            + _lua_string(entry["label"])
            + ", order = "
            + str(entry["order"])
            + " },"
        )
    lines.append(indent + "},")
    return lines


def _build_nav_tree(records):
    """Group recipes hierarchically expansion → profession → category → subcategory.

    Each node exposes an `_all` array that unions every recipe under it, so the
    runtime can answer "show all recipes for this expansion×profession" or
    "this category" with a direct table lookup instead of iterating records.
    Leaves at the subcategory level are plain arrays; recipes that have no
    subcategory live only under the category `_all` array.
    """
    tree = {}
    for record in records:
        exp = record.expansion
        prof = record.profession_key
        cat = record.category_key or "misc"
        sub = record.subcategory_key
        spell_id = record.spell_id

        exp_node = tree.setdefault(exp, {})
        prof_node = exp_node.setdefault(prof, {"_all": []})
        prof_node["_all"].append(spell_id)

        cat_node = prof_node.get(cat)
        if cat_node is None:
            cat_node = {"_all": []}
            prof_node[cat] = cat_node
        cat_node["_all"].append(spell_id)

        if sub is not None:
            sub_list = cat_node.get(sub)
            if sub_list is None:
                sub_list = []
                cat_node[sub] = sub_list
            sub_list.append(spell_id)
    return tree


def _emit_id_array(values, indent):
    sorted_values = sorted(values)
    return indent + "{ " + ", ".join(str(value) for value in sorted_values) + " },"


def _emit_nav_tree(tree, indent="    "):
    """Render the nav-tree as deterministic Lua source."""
    lines = [indent + "navTree = {"]
    inner1 = indent + "    "
    inner2 = inner1 + "    "
    inner3 = inner2 + "    "
    inner4 = inner3 + "    "
    for exp in sorted(tree):
        lines.append(inner1 + "[" + _lua_string(exp) + "] = {")
        exp_node = tree[exp]
        for prof in sorted(exp_node):
            prof_node = exp_node[prof]
            lines.append(inner2 + "[" + _lua_string(prof) + "] = {")
            lines.append(inner3 + "_all = " + _emit_id_array(prof_node["_all"], "").lstrip())
            for cat in sorted(key for key in prof_node if key != "_all"):
                cat_node = prof_node[cat]
                lines.append(inner3 + "[" + _lua_string(cat) + "] = {")
                lines.append(inner4 + "_all = " + _emit_id_array(cat_node["_all"], "").lstrip())
                for sub in sorted(key for key in cat_node if key != "_all"):
                    lines.append(
                        inner4
                        + "["
                        + _lua_string(sub)
                        + "] = "
                        + _emit_id_array(cat_node[sub], "").lstrip()
                    )
                lines.append(inner3 + "},")
            lines.append(inner2 + "},")
        lines.append(inner1 + "},")
    lines.append(indent + "},")
    return lines


def emit_lua(records, categories_by_profession, subcategories_by_profession, metadata_version, schema_version=1, flavor="tbc"):
    records = sorted(records, key=lambda record: record.spell_id)
    created_item_to_spell_ids = defaultdict(list)

    lines = [
        "-- Generated by tools/recipe-metadata/generate_recipe_metadata.py. Do not hand-edit.",
        "RecipeRegistryRecipeMetadata = {",
        "    schemaVersion = " + str(schema_version) + ",",
        "    metadataVersion = " + _lua_string(metadata_version) + ",",
        "    flavor = " + _lua_string(flavor) + ",",
        "",
        "    recipesBySpellId = {",
    ]

    # Zone names are interned into small integers: a popular vendor city is
    # cited by hundreds of records, and repeating the string on each of them
    # is the single biggest thing that would bloat the generated file.
    zone_ids = {}
    for record in sorted(records, key=lambda item: item.spell_id):
        for place in record.source_places:
            if place.zone:
                zone_ids.setdefault(place.zone, len(zone_ids) + 1)

    for record in records:
        lines.extend(_emit_record(record, zone_ids))
        if record.created_item_id is not None:
            created_item_to_spell_ids[record.created_item_id].append(record.spell_id)

    lines.extend(["    },", "", "    recipeItemToSpellId = {"])
    for record in records:
        if record.recipe_item_id is not None:
            lines.append("        [" + str(record.recipe_item_id) + "] = " + str(record.spell_id) + ",")
    lines.extend(["    },", "", "    createdItemToSpellIds = {"])
    for item_id in sorted(created_item_to_spell_ids):
        spell_ids = sorted(created_item_to_spell_ids[item_id])
        lines.append("        [" + str(item_id) + "] = { " + ", ".join(str(spell_id) for spell_id in spell_ids) + " },")
    lines.extend(["    },", "", "    categoriesByProfession = {"])
    for profession in sorted(categories_by_profession):
        lines.append("        " + profession + " = ")
        lines.extend(_emit_array_table(categories_by_profession[profession], "        "))
    lines.extend(["    },", "", "    subcategoriesByProfession = {"])
    for profession in sorted(subcategories_by_profession):
        lines.append("        " + profession + " = {")
        for category in sorted(subcategories_by_profession[profession]):
            lines.append("            " + category + " = ")
            lines.extend(_emit_array_table(subcategories_by_profession[profession][category], "            "))
        lines.append("        },")
    lines.append("    },")
    lines.append("")

    # Zone names live once at the top level rather than being repeated on
    # every record that points at them: a popular vendor zone is referenced by
    # hundreds of recipes. Only zones some record actually cites are emitted.
    lines.append("    zoneNamesById = {")
    for zone, zone_id in sorted(zone_ids.items(), key=lambda item: item[1]):
        lines.append("        [" + str(zone_id) + "] = " + _lua_string(zone) + ",")
    lines.append("    },")
    lines.append("")
    lines.extend(_emit_nav_tree(_build_nav_tree(records)))
    lines.extend(["}", ""])
    return "\n".join(lines)
