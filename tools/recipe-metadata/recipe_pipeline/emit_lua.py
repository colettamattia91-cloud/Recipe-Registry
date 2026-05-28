from collections import defaultdict


def _lua_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _lua_bool(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    return "nil"


def _emit_record(record, indent="        "):
    lines = [indent + "[" + str(record.spell_id) + "] = {"]
    lines.append(indent + "    profession = " + _lua_string(record.profession_key) + ",")
    lines.append(indent + "    expansion = " + _lua_string(record.expansion) + ",")
    if record.recipe_item_id is not None:
        lines.append(indent + "    recipeItemId = " + str(record.recipe_item_id) + ",")
    if record.created_item_id is not None:
        lines.append(indent + "    createdItemId = " + str(record.created_item_id) + ",")
    lines.append(indent + "    category = " + _lua_string(record.category_key or "misc") + ",")
    if record.subcategory_key is not None:
        lines.append(indent + "    subcategory = " + _lua_string(record.subcategory_key) + ",")
    lines.append(indent + "    sortOrder = " + str(record.sort_order) + ",")
    if record.required_skill is not None:
        lines.append(indent + "    requiredSkill = " + str(record.required_skill) + ",")
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

    for record in records:
        lines.extend(_emit_record(record))
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
    lines.extend(_emit_nav_tree(_build_nav_tree(records)))
    lines.extend(["}", ""])
    return "\n".join(lines)
