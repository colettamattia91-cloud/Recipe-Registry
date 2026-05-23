from collections import Counter


SUPPORTED_PROFESSIONS = (
    "alchemy",
    "blacksmithing",
    "cooking",
    "enchanting",
    "engineering",
    "jewelcrafting",
    "leatherworking",
    "tailoring",
)


def collect_unresolved(records, diagnostics=None):
    unresolved = []
    recipe_item_ids = {}

    for record in records:
        def add(field, severity, message):
            unresolved.append({
                "spellId": record.spell_id,
                "field": field,
                "severity": severity,
                "message": message,
            })

        if record.profession_key not in SUPPORTED_PROFESSIONS:
            add("profession", "release-blocking", "missing or unsupported profession")
        if record.expansion not in ("vanilla", "tbc"):
            add("expansion", "release-blocking", "missing or unsupported expansion")
        if not record.category_key:
            add("category", "release-blocking", "missing category")
        if record.sort_order is None:
            add("sortOrder", "release-blocking", "missing sort order")
        if not record.is_outputless_self_only and record.created_item_id is None:
            add("createdItemId", "release-blocking", "missing created item for normal craft")
        if not record.is_outputless_self_only and not record.reagents:
            add("reagents", "release-blocking", "missing reagents")
        if record.recipe_item_id is not None:
            previous = recipe_item_ids.get(record.recipe_item_id)
            if previous is not None:
                add("recipeItemId", "release-blocking", "recipe item maps to multiple spells")
            recipe_item_ids[record.recipe_item_id] = record.spell_id

    counts = Counter(record.profession_key for record in records)
    for profession in SUPPORTED_PROFESSIONS:
        if counts[profession] == 0:
            unresolved.append({
                "spellId": None,
                "field": "professionCoverage",
                "severity": "release-blocking",
                "message": "no records for supported profession " + profession,
            })

    return unresolved


def validate_records(records, diagnostics=None, strict=False):
    unresolved = collect_unresolved(records, diagnostics)
    if strict:
        failures = [item for item in unresolved if item["severity"] == "release-blocking"]
    else:
        failures = unresolved
    return failures, unresolved
