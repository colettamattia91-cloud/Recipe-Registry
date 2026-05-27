"""Wago Tools DB2 importer for Classic Anniversary profession recipes."""

import csv
import io
import json
from collections import Counter
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen


DEFAULT_PRODUCT = "wow_anniversary"
DEFAULT_BRANCH = "wow_anniversary"
DEFAULT_VANILLA_BUILD = "1.15.7.61582"
DEFAULT_LOCALE = "enUS"
DEFAULT_METADATA_VERSION = "wago-wow-anniversary-tbc-2.5.5"
WAGO_DB2_BASE_URL = "https://wago.tools/db2"

CREATE_ITEM_EFFECT = 24
ENCHANT_ITEM_EFFECT = 53
LEARN_RECIPE_TRIGGER = 6

PROFESSION_BY_SKILL_LINE = {
    164: "blacksmithing",
    165: "leatherworking",
    171: "alchemy",
    185: "cooking",
    197: "tailoring",
    202: "engineering",
    333: "enchanting",
    755: "jewelcrafting",
}

SOURCE_TABLES = (
    "SkillLineAbility",
    "SpellEffect",
    "SpellReagents",
    "ItemEffect",
    "ItemSparse",
    "Item",
    "SpellName",
)
VANILLA_SKILL_LINE_ABILITY_TABLE = "VanillaSkillLineAbility"

# DB2 Item.ClassID values relevant to crafted output classification.
ITEM_CLASS_WEAPON = 2
ITEM_CLASS_ARMOR = 4
# DB2 Item.SubclassID values for armor.
ARMOR_SUBCLASS_BY_ID = {
    1: "cloth",
    2: "leather",
    3: "mail",
    4: "plate",
}
# DB2 Item.SubclassID values for weapons, collapsed to filter-friendly classes
# (1h+2h combined). Bows/guns/crossbows/wands/fishing poles aren't blacksmithed
# but the map covers them for completeness.
WEAPON_SUBCLASS_BY_ID = {
    0: "axe", 1: "axe",
    2: "bow",
    3: "gun",
    4: "mace", 5: "mace",
    6: "polearm",
    7: "sword", 8: "sword",
    9: "warglaive",
    10: "staff",
    13: "fist",
    15: "dagger",
    16: "thrown",
    17: "spear",
    18: "crossbow",
    19: "wand",
    20: "fishing_pole",
}


def _as_int(value, default=0):
    try:
        if value is None or value == "":
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def _csv_rows(text):
    return list(csv.DictReader(io.StringIO(text)))


def _fetch_wago_csv(table, query, timeout):
    url = "{0}/{1}/csv?{2}".format(WAGO_DB2_BASE_URL, table, query)
    request = Request(url, headers={
        "User-Agent": "RecipeRegistry metadata importer",
    })
    with urlopen(request, timeout=timeout) as response:
        content = response.read().decode("utf-8-sig")
    return _csv_rows(content)


def fetch_wago_table(table, product=DEFAULT_PRODUCT, branch=DEFAULT_BRANCH, timeout=90):
    query = urlencode({
        "branch": branch,
        "product": product,
    })
    return _fetch_wago_csv(table, query, timeout)


def fetch_wago_build_table(table, build, locale=DEFAULT_LOCALE, timeout=90):
    query = urlencode({
        "build": build,
        "locale": locale,
    })
    return _fetch_wago_csv(table, query, timeout)


def fetch_wago_tables(
    product=DEFAULT_PRODUCT,
    branch=DEFAULT_BRANCH,
    vanilla_build=DEFAULT_VANILLA_BUILD,
    locale=DEFAULT_LOCALE,
    timeout=90,
):
    tables = {
        table: fetch_wago_table(table, product=product, branch=branch, timeout=timeout)
        for table in SOURCE_TABLES
    }
    tables[VANILLA_SKILL_LINE_ABILITY_TABLE] = fetch_wago_build_table(
        "SkillLineAbility",
        vanilla_build,
        locale=locale,
        timeout=timeout,
    )
    return tables


def _created_items_by_spell(spell_effects):
    created = {}
    for row in spell_effects:
        spell_id = _as_int(row.get("SpellID"))
        effect = _as_int(row.get("Effect"))
        item_id = _as_int(row.get("EffectItemType"))
        if spell_id and effect == CREATE_ITEM_EFFECT and item_id > 0 and spell_id not in created:
            created[spell_id] = item_id
    return created


def _enchant_spells(spell_effects):
    spells = set()
    for row in spell_effects:
        spell_id = _as_int(row.get("SpellID"))
        if spell_id and _as_int(row.get("Effect")) == ENCHANT_ITEM_EFFECT:
            spells.add(spell_id)
    return spells


def _reagent_rows_by_spell(spell_reagents):
    by_spell = {}
    for row in spell_reagents:
        spell_id = _as_int(row.get("SpellID"))
        if not spell_id:
            continue
        for index in range(8):
            item_id = _as_int(row.get("Reagent_{0}".format(index)))
            count = _as_int(row.get("ReagentCount_{0}".format(index)))
            if item_id > 0 and count > 0:
                by_spell.setdefault(spell_id, []).append({
                    "spellId": spell_id,
                    "effectType": "reagent",
                    "itemId": item_id,
                    "count": count,
                })
    return by_spell


def _recipe_items_by_spell(item_effects):
    by_spell = {}
    for row in item_effects:
        spell_id = _as_int(row.get("SpellID"))
        parent_item_id = _as_int(row.get("ParentItemID"))
        trigger = _as_int(row.get("TriggerType"))
        if spell_id and parent_item_id > 0 and trigger == LEARN_RECIPE_TRIGGER and spell_id not in by_spell:
            by_spell[spell_id] = parent_item_id
    return by_spell


def _items_by_id(item_sparse):
    return {
        _as_int(row.get("ID")): row
        for row in item_sparse
        if _as_int(row.get("ID"))
    }


def _item_class_by_id(item_table):
    """Map itemId -> (classID, subclassID) from the DB2 Item table."""
    out = {}
    for row in item_table:
        item_id = _as_int(row.get("ID"))
        if not item_id:
            continue
        out[item_id] = (
            _as_int(row.get("ClassID"), None),
            _as_int(row.get("SubclassID"), None),
        )
    return out


def _armor_type(item_id, item_class_by_id):
    class_subclass = item_class_by_id.get(item_id)
    if not class_subclass:
        return None
    class_id, subclass_id = class_subclass
    if class_id != ITEM_CLASS_ARMOR:
        return None
    return ARMOR_SUBCLASS_BY_ID.get(subclass_id)


def _weapon_class(item_id, item_class_by_id):
    class_subclass = item_class_by_id.get(item_id)
    if not class_subclass:
        return None
    class_id, subclass_id = class_subclass
    if class_id != ITEM_CLASS_WEAPON:
        return None
    return WEAPON_SUBCLASS_BY_ID.get(subclass_id)


# DB2 ItemSparse.InventoryType -> filter-friendly slot label. Covers the
# inventory types relevant to crafted output classification.
INVENTORY_SLOT_BY_TYPE = {
    1:  "head",
    2:  "neck",
    3:  "shoulder",
    4:  "shirt",
    5:  "chest",
    6:  "waist",
    7:  "legs",
    8:  "feet",
    9:  "wrist",
    10: "hands",
    11: "ring",
    12: "trinket",
    13: "one_hand",
    14: "shield",
    15: "ranged",
    16: "back",
    17: "two_hand",
    18: "bag",
    19: "tabard",
    20: "robe",
    21: "main_hand",
    22: "off_hand",
    23: "holdable",
    25: "thrown",
    26: "ranged_right",
    27: "quiver",
    28: "relic",
}


def _inventory_slot(inv_type):
    if inv_type is None:
        return None
    return INVENTORY_SLOT_BY_TYPE.get(inv_type)


def _names_by_spell(spell_names):
    return {
        _as_int(row.get("ID")): row.get("Name_lang", "")
        for row in spell_names
        if _as_int(row.get("ID"))
    }


def _supported_skill_line_spells(skill_line_ability):
    spells = set()
    for row in skill_line_ability:
        if _as_int(row.get("SkillLine")) in PROFESSION_BY_SKILL_LINE:
            spell_id = _as_int(row.get("Spell"))
            if spell_id:
                spells.add(spell_id)
    return spells


def _first_seen_expansion(spell_id, vanilla_recipe_spell_ids):
    if spell_id in vanilla_recipe_spell_ids:
        return "vanilla"
    return "tbc"


def _required_skill(recipe_item_id, skill_line_row, items_by_id):
    if recipe_item_id:
        recipe_item = items_by_id.get(recipe_item_id, {})
        required = _as_int(recipe_item.get("RequiredSkillRank"))
        if required > 0:
            return required
    minimum = _as_int(skill_line_row.get("MinSkillLineRank"))
    return minimum if minimum > 1 else None


def _category_hint(profession, spell_name, created_item_id, items_by_id):
    name = (spell_name or "").lower()
    created = items_by_id.get(created_item_id or 0, {})
    created_name = (created.get("Display_lang") or "").lower()

    if profession == "alchemy":
        if "flask" in name:
            return "alchemy.flasks.guardian_elixirs"
        if "mana potion" in name:
            return "alchemy.potions.mana"
        if "healing potion" in name or "rejuvenation potion" in name:
            return "alchemy.potions.healing"
        if "potion" in name or "elixir" in name:
            return "alchemy.potions.combat"
    elif profession == "blacksmithing":
        if "sharpening" in name or "weightstone" in name:
            return "blacksmithing.stones.sharpening"
        if created_name and _as_int(created.get("InventoryType")) > 0:
            return "blacksmithing.armor.plate"
    elif profession == "cooking":
        if name:
            return "cooking.food.meat"
    elif profession == "enchanting":
        if name.startswith("enchant ring -"):
            return "enchanting.ring.self_only"
    elif profession == "engineering":
        if "powder" in name or "explosive" in name:
            return "engineering.explosives.powders"
        if "gun" in name or "rifle" in name or "scope" in name:
            return "engineering.devices.weapons"
    elif profession == "jewelcrafting":
        if "wire" in name:
            return "jewelcrafting.components.wire"
    elif profession == "leatherworking":
        if _as_int(created.get("Bonding")) == 1:
            return "leatherworking.armor.bop"
    elif profession == "tailoring":
        if name.startswith("bolt of "):
            return "tailoring.cloth.bolts"

    return profession + ".misc"


def _is_recipe_candidate(profession, spell_id, created_items_by_spell, enchant_spells, reagents_by_spell):
    if spell_id in created_items_by_spell:
        return True
    return profession == "enchanting" and spell_id in enchant_spells and spell_id in reagents_by_spell


def _expected_counts(recipes):
    by_profession = Counter(row["profession"] for row in recipes)
    by_expansion = Counter(row["firstSeenExpansion"] for row in recipes)
    by_profession_expansion = {}
    for row in recipes:
        profession = row["profession"]
        expansion = row["firstSeenExpansion"]
        by_profession_expansion.setdefault(profession, Counter())
        by_profession_expansion[profession][expansion] += 1

    return {
        "total": len(recipes),
        "byProfession": dict(sorted(by_profession.items())),
        "byExpansion": dict(sorted(by_expansion.items())),
        "byProfessionExpansion": {
            profession: dict(sorted(counts.items()))
            for profession, counts in sorted(by_profession_expansion.items())
        },
    }


def build_normalized_snapshot(
    tables,
    snapshot,
    product=DEFAULT_PRODUCT,
    branch=DEFAULT_BRANCH,
    vanilla_build=DEFAULT_VANILLA_BUILD,
    metadata_version=DEFAULT_METADATA_VERSION,
    dataset_kind="release-candidate",
):
    skill_line_ability = tables["SkillLineAbility"]
    spell_effects = tables["SpellEffect"]
    spell_reagents = tables["SpellReagents"]
    item_effects = tables["ItemEffect"]
    item_sparse = tables["ItemSparse"]
    item_table = tables.get("Item", ())
    spell_names = tables["SpellName"]
    vanilla_skill_line_ability = tables.get(VANILLA_SKILL_LINE_ABILITY_TABLE, ())

    created_items = _created_items_by_spell(spell_effects)
    enchant_spells = _enchant_spells(spell_effects)
    reagents_by_spell = _reagent_rows_by_spell(spell_reagents)
    recipe_items = _recipe_items_by_spell(item_effects)
    items_by_id = _items_by_id(item_sparse)
    item_class_by_id = _item_class_by_id(item_table)
    names_by_spell = _names_by_spell(spell_names)
    vanilla_recipe_spell_ids = _supported_skill_line_spells(vanilla_skill_line_ability)

    recipes = []
    used_item_ids = set()
    self_only_outputless_spell_ids = []
    seen_recipe_spell_ids = set()
    duplicates_skipped = 0
    late_vanilla_recipe_spell_ids = []

    for row in skill_line_ability:
        skill_line = _as_int(row.get("SkillLine"))
        profession = PROFESSION_BY_SKILL_LINE.get(skill_line)
        if not profession:
            continue

        spell_id = _as_int(row.get("Spell"))
        if not _is_recipe_candidate(profession, spell_id, created_items, enchant_spells, reagents_by_spell):
            continue
        if spell_id in seen_recipe_spell_ids:
            duplicates_skipped += 1
            continue
        seen_recipe_spell_ids.add(spell_id)

        created_item_id = created_items.get(spell_id)
        recipe_item_id = recipe_items.get(spell_id)
        spell_name = names_by_spell.get(spell_id, "")
        if profession == "enchanting" and spell_name.lower().startswith("enchant ring -"):
            self_only_outputless_spell_ids.append(spell_id)
        first_seen_expansion = _first_seen_expansion(spell_id, vanilla_recipe_spell_ids)
        if first_seen_expansion == "vanilla" and spell_id >= 25255:
            late_vanilla_recipe_spell_ids.append(spell_id)

        if created_item_id:
            used_item_ids.add(created_item_id)
        if recipe_item_id:
            used_item_ids.add(recipe_item_id)
        for reagent in reagents_by_spell.get(spell_id, ()):
            used_item_ids.add(reagent["itemId"])

        recipes.append({
            "spellId": spell_id,
            "profession": profession,
            "firstSeenExpansion": first_seen_expansion,
            "recipeItemId": recipe_item_id,
            "createdItemId": created_item_id,
            "requiredSkill": _required_skill(recipe_item_id, row, items_by_id),
            "categoryHint": _category_hint(profession, spell_name, created_item_id, items_by_id),
        })

    recipes.sort(key=lambda item: (item["profession"], item["spellId"]))
    spell_effect_rows = []
    for spell_id in sorted({row["spellId"] for row in recipes}):
        spell_effect_rows.extend(sorted(
            reagents_by_spell.get(spell_id, ()),
            key=lambda reagent: (reagent["itemId"], reagent["count"]),
        ))

    item_sparse_rows = []
    for item_id in sorted(used_item_ids):
        source = items_by_id.get(item_id, {})
        item_sparse_rows.append({
            "itemId": item_id,
            "name": source.get("Display_lang") or None,
            "bindType": _as_int(source.get("Bonding"), None),
            "armorType": _armor_type(item_id, item_class_by_id),
            "weaponClass": _weapon_class(item_id, item_class_by_id),
            "inventorySlot": _inventory_slot(_as_int(source.get("InventoryType"), None)),
        })

    manifest = {
        "provider": "wago.tools-db2",
        "snapshot": snapshot,
        "metadataVersion": metadata_version,
        "flavor": "tbc",
        "datasetKind": dataset_kind,
        "source": {
            "product": product,
            "branch": branch,
            "vanillaBuild": vanilla_build,
            "tables": list(SOURCE_TABLES),
            "expansionRule": "spell present in Vanilla SkillLineAbility build {0} => vanilla; otherwise tbc".format(
                vanilla_build,
            ),
            "recipeItemPolicy": "primary recipeItemId comes from DB2 ItemEffect ParentItemID; alternate teaching sources are intentionally not modeled",
            "createdItemPolicy": "createdItemId comes from DB2 SpellEffect Effect=24 EffectItemType",
        },
        "sourceStats": {
            "rawRows": {
                name: len(tables[name])
                for name in list(SOURCE_TABLES) + [VANILLA_SKILL_LINE_ABILITY_TABLE]
                if name in tables
            },
            "records": len(recipes),
            "duplicateSkillLineAbilityRecipesSkipped": duplicates_skipped,
            "lateVanillaRecipesFromBaseline": len(set(late_vanilla_recipe_spell_ids)),
            "lateVanillaRecipeSpellIds": sorted(set(late_vanilla_recipe_spell_ids)),
        },
        "expectedRecipeCounts": _expected_counts(recipes),
    }

    secondary = {
        "selfOnlyOutputlessSpellIds": sorted(set(self_only_outputless_spell_ids)),
        "bopOutputBySpellId": {},
        "recipeItemBySpellId": {},
        "createdItemBySpellId": {},
        "expansionBySpellId": {},
    }

    return {
        "manifest.json": manifest,
        "recipes.json": recipes,
        "spell_effects.json": spell_effect_rows,
        "item_sparse.json": item_sparse_rows,
        "secondary_static.json": secondary,
    }


def write_normalized_snapshot(snapshot_data, output_dir):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    for name, value in snapshot_data.items():
        path = output_dir / name
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
