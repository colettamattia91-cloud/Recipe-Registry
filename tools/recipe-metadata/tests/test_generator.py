import tempfile
import unittest
import json
from pathlib import Path
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO

import sys

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]
sys.path.insert(0, str(ROOT))

import generate_recipe_metadata as generator
from recipe_pipeline.derive_categories import load_taxonomies
from recipe_pipeline.normalize import normalize_records
from recipe_pipeline.records import ReagentRecord, RecipeRecord
from recipe_pipeline.validate import validate_records
from recipe_sources.wago_anniversary_provider import build_normalized_snapshot
from recipe_pipeline.emit_lua import emit_lua
from recipe_pipeline.normalize import summarize_source
from recipe_sources.arl_source_provider import (
    is_post_tbc,
    parse_custom_places,
    parse_lookup,
    parse_profession,
    parse_source_flags,
    summarize_recipe,
)
from recipe_sources.manual_acquisition import (
    build_entry,
    build_snapshot as build_manual_snapshot,
    load_manual_acquisition,
    merge_acquisition,
    validate_entry,
    write_snapshot as write_manual_snapshot,
)
import acquisition_worksheet
from recipe_sources.removed_recipes import (
    build_snapshot as build_removed_snapshot,
    load_removed,
    parse_removed,
    write_snapshot as write_removed_snapshot,
)
from recipe_sources.wowhead_source_provider import (
    FetchOutcome,
    derive_faction,
    parse_item_sources,
    summarize_item,
)
from recipe_sources.wowhead_specialization_provider import (
    build_specialization_snapshot,
    fetch_specializations,
    parse_listview_specializations,
)


def load_fixture_snapshot():
    recipes = [
        {"spellId": 2329, "profession": "alchemy", "firstSeenExpansion": "vanilla", "recipeItemId": None, "createdItemId": 2454, "requiredSkill": 1, "categoryHint": "alchemy.potions.combat"},
        {"spellId": 2330, "profession": "alchemy", "firstSeenExpansion": "vanilla", "recipeItemId": None, "createdItemId": 118, "requiredSkill": 1, "categoryHint": "alchemy.potions.healing"},
        {"spellId": 28543, "profession": "alchemy", "firstSeenExpansion": "tbc", "recipeItemId": 22907, "createdItemId": 22823, "requiredSkill": 305, "categoryHint": "alchemy.potions.mana"},
        {"spellId": 28587, "profession": "alchemy", "firstSeenExpansion": "tbc", "recipeItemId": 22900, "createdItemId": 22845, "requiredSkill": 300, "categoryHint": "alchemy.flasks.guardian_elixirs"},
        {"spellId": 2660, "profession": "blacksmithing", "firstSeenExpansion": "vanilla", "recipeItemId": None, "createdItemId": 2862, "requiredSkill": 1, "categoryHint": "blacksmithing.stones.sharpening"},
        {"spellId": 29669, "profession": "blacksmithing", "firstSeenExpansion": "tbc", "recipeItemId": 23590, "createdItemId": 23537, "requiredSkill": 365, "categoryHint": "blacksmithing.armor.plate"},
        {"spellId": 2538, "profession": "cooking", "firstSeenExpansion": "vanilla", "recipeItemId": None, "createdItemId": 2679, "requiredSkill": 1, "categoryHint": "cooking.food.meat"},
        {"spellId": 45545, "profession": "cooking", "firstSeenExpansion": "wotlk", "recipeItemId": None, "createdItemId": 34721, "requiredSkill": 350, "categoryHint": "cooking.food.future"},
        {"spellId": 27924, "profession": "enchanting", "firstSeenExpansion": "tbc", "recipeItemId": None, "createdItemId": None, "requiredSkill": 360, "categoryHint": "enchanting.ring.self_only"},
        {"spellId": 3918, "profession": "engineering", "firstSeenExpansion": "vanilla", "recipeItemId": None, "createdItemId": 4357, "requiredSkill": 1, "categoryHint": "engineering.explosives.powders"},
        {"spellId": 30303, "profession": "engineering", "firstSeenExpansion": "tbc", "recipeItemId": 23799, "createdItemId": 23761, "requiredSkill": 350, "categoryHint": "engineering.devices.weapons"},
        {"spellId": 25255, "profession": "jewelcrafting", "firstSeenExpansion": "tbc", "recipeItemId": None, "createdItemId": 20816, "requiredSkill": 1, "categoryHint": "jewelcrafting.components.wire"},
        {"spellId": 35530, "profession": "leatherworking", "firstSeenExpansion": "tbc", "recipeItemId": 29664, "createdItemId": 29540, "requiredSkill": 375, "categoryHint": "leatherworking.armor.bop"},
        {"spellId": 26745, "profession": "tailoring", "firstSeenExpansion": "tbc", "recipeItemId": None, "createdItemId": 21840, "requiredSkill": 325, "categoryHint": "tailoring.cloth.bolts"},
        {"spellId": 26746, "profession": "tailoring", "firstSeenExpansion": "tbc", "recipeItemId": None, "createdItemId": 21840, "requiredSkill": 325, "categoryHint": "tailoring.cloth.bolts"},
    ]
    reagent_rows = {
        int(row["spellId"]): [{"itemId": 1, "count": 1}]
        for row in recipes
        if row["createdItemId"] is not None
    }
    primary = {
        "manifest": {
            "provider": "test-fixture",
            "snapshot": "tbc-2.5.5",
            "metadataVersion": "test",
            "flavor": "tbc",
            "datasetKind": "fixture",
        },
        "recipes": recipes,
        "reagentsBySpellId": reagent_rows,
        "bindTypeByItemId": {
            118: 0,
            2454: 0,
            2679: 0,
            2862: 0,
            4357: 0,
            20816: 0,
            21840: 0,
            22823: 0,
            22845: 0,
            22851: 0,
            23537: 0,
            23761: 0,
            29540: 1,
            34721: 0,
        },
    }
    secondary = {
        "selfOnlyOutputlessBySpellId": {27924: True},
        "bopOutputBySpellId": {},
        "recipeItemBySpellId": {},
        "createdItemBySpellId": {},
        "expansionBySpellId": {},
    }
    return primary, secondary


def load_default_records():
    primary, secondary = load_fixture_snapshot()
    taxonomies = load_taxonomies(ROOT / "remediation" / "taxonomy")
    records, diagnostics = normalize_records(primary, secondary, taxonomies, {})
    return primary, records, diagnostics


def build_expected_counts(records):
    expected = {
        "total": len(records),
        "byProfession": {},
        "byExpansion": {},
        "byProfessionExpansion": {},
    }
    for record in records:
        expected["byProfession"][record.profession_key] = (
            expected["byProfession"].get(record.profession_key, 0) + 1
        )
        expected["byExpansion"][record.expansion] = (
            expected["byExpansion"].get(record.expansion, 0) + 1
        )
        expected["byProfessionExpansion"].setdefault(record.profession_key, {})
        expected["byProfessionExpansion"][record.profession_key][record.expansion] = (
            expected["byProfessionExpansion"][record.profession_key].get(record.expansion, 0) + 1
        )
    return expected


def write_fetch_snapshot(root, snapshot="import-test", recipes=None):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    (root / "manifest.json").write_text(json.dumps({
        "provider": "test-normalized",
        "snapshot": snapshot,
        "metadataVersion": "test",
        "flavor": "tbc",
        "datasetKind": "fixture",
    }), encoding="utf-8")
    (root / "recipes.json").write_text(json.dumps(recipes or [{
        "spellId": 2329,
        "profession": "alchemy",
        "firstSeenExpansion": "vanilla",
        "recipeItemId": None,
        "createdItemId": 2454,
        "requiredSkill": 1,
        "categoryHint": "alchemy.potions.combat",
    }]), encoding="utf-8")
    (root / "spell_effects.json").write_text(json.dumps([
        {"spellId": 2329, "effectType": "reagent", "itemId": 2449, "count": 1},
    ]), encoding="utf-8")
    (root / "item_sparse.json").write_text(json.dumps([
        {"itemId": 2454, "bindType": 0},
    ]), encoding="utf-8")
    (root / "secondary_static.json").write_text(json.dumps({
        "selfOnlyOutputlessSpellIds": [],
        "bopOutputBySpellId": {},
        "recipeItemBySpellId": {},
        "createdItemBySpellId": {},
        "expansionBySpellId": {},
    }), encoding="utf-8")


class GeneratorPipelineTests(unittest.TestCase):
    def test_normal_vanilla_and_tbc_crafts(self):
        _primary, records, _diagnostics = load_default_records()
        by_spell = {record.spell_id: record for record in records}

        self.assertEqual(by_spell[2329].expansion, "vanilla")
        self.assertEqual(by_spell[2329].profession_key, "alchemy")
        self.assertEqual(by_spell[28587].expansion, "tbc")
        self.assertEqual(by_spell[28587].category_key, "flasks")

    def test_recipe_and_created_item_shapes(self):
        _primary, records, _diagnostics = load_default_records()
        by_spell = {record.spell_id: record for record in records}

        self.assertIsNone(by_spell[2329].recipe_item_id)
        self.assertEqual(by_spell[2329].created_item_id, 2454)
        self.assertEqual(by_spell[28587].recipe_item_id, 22900)
        self.assertEqual(by_spell[28587].created_item_id, 22845)
        self.assertIsNone(by_spell[27924].recipe_item_id)
        self.assertIsNone(by_spell[27924].created_item_id)

    def test_outputless_self_only_and_bop_output(self):
        _primary, records, _diagnostics = load_default_records()
        by_spell = {record.spell_id: record for record in records}

        self.assertTrue(by_spell[27924].is_outputless_self_only)
        self.assertIsNone(by_spell[27924].bop_output)
        self.assertTrue(by_spell[35530].bop_output)

    def test_ambiguous_created_item_mapping_is_preserved(self):
        _primary, records, _diagnostics = load_default_records()
        by_created = {}
        for record in records:
            if record.created_item_id is not None:
                by_created.setdefault(record.created_item_id, []).append(record.spell_id)

        self.assertEqual(sorted(by_created[21840]), [26745, 26746])

    def test_missing_category_falls_back_to_misc_with_diagnostic(self):
        primary, secondary = load_fixture_snapshot()
        primary = dict(primary)
        # Use a spellId that is NOT in any profession whitelist so the hint-based
        # fallback path is exercised. Real whitelisted spellIds bypass categoryHint.
        primary["recipes"] = [dict(primary["recipes"][0], spellId=99999, categoryHint="missing.category")]
        primary["reagentsBySpellId"] = {99999: primary["reagentsBySpellId"][2329]}
        taxonomies = load_taxonomies(ROOT / "remediation" / "taxonomy")

        records, diagnostics = normalize_records(primary, secondary, taxonomies, {})

        self.assertEqual(records[0].category_key, "misc")
        self.assertEqual(diagnostics["categoryFallbacks"][0]["spellId"], 99999)

    def test_whitelist_classification_beats_category_hint(self):
        primary, secondary = load_fixture_snapshot()
        primary = dict(primary)
        # spellId 2329 is whitelisted as elixirs/battle regardless of any hint.
        primary["recipes"] = [dict(primary["recipes"][0], categoryHint="alchemy.misc")]
        primary["reagentsBySpellId"] = {2329: primary["reagentsBySpellId"][2329]}
        taxonomies = load_taxonomies(ROOT / "remediation" / "taxonomy")

        records, diagnostics = normalize_records(primary, secondary, taxonomies, {})

        self.assertEqual(records[0].category_key, "elixirs")
        self.assertEqual(records[0].subcategory_key, "battle")
        self.assertEqual(diagnostics["categoryFallbacks"], [])

    def test_missing_reagent_data_is_release_blocking_in_strict_validation(self):
        record = RecipeRecord(
            spell_id=90001,
            profession_key="alchemy",
            expansion="vanilla",
            recipe_item_id=None,
            created_item_id=2454,
            reagents=(),
            category_key="potions",
            subcategory_key=None,
            sort_order=1,
            required_skill=1,
        )

        failures, unresolved = validate_records((record,), strict=True)

        self.assertTrue(any(item["field"] == "reagents" for item in failures))
        self.assertTrue(any(item["field"] == "reagents" for item in unresolved))

    def test_outputless_enchanting_with_reagents_is_not_missing_created_item(self):
        record = RecipeRecord(
            spell_id=90003,
            profession_key="enchanting",
            expansion="tbc",
            recipe_item_id=22536,
            created_item_id=None,
            reagents=(ReagentRecord(22449, 2),),
            category_key="ring_enchants",
            subcategory_key="self_only",
            sort_order=1,
            required_skill=360,
        )

        failures, unresolved = validate_records((record,), strict=True)

        self.assertFalse(any(item["field"] == "createdItemId" for item in failures))
        self.assertFalse(any(item["field"] == "createdItemId" for item in unresolved))

    def test_out_of_scope_future_expansion_record_is_excluded(self):
        _primary, records, diagnostics = load_default_records()

        self.assertNotIn(45545, {record.spell_id for record in records})
        self.assertTrue(any(item["spellId"] == 45545 for item in diagnostics["excluded"]))

    def test_generation_is_deterministic(self):
        first = generator._build_pipeline()
        second = generator._build_pipeline()

        self.assertEqual(first[3], second[3])
        self.assertEqual(first[4], second[4])

    def test_strict_validation_fails_unresolved_expansion(self):
        record = RecipeRecord(
            spell_id=90002,
            profession_key="alchemy",
            expansion="unknown",
            recipe_item_id=None,
            created_item_id=2454,
            reagents=(),
            category_key="potions",
            subcategory_key=None,
            sort_order=1,
            required_skill=1,
        )

        failures, _unresolved = validate_records((record,), strict=True)

        self.assertTrue(any(item["field"] == "expansion" for item in failures))

    def test_generate_check_fails_when_committed_output_is_stale(self):
        original_output = generator.OUTPUT_PATH
        original_report_dir = generator.REPORT_DIR
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            generator.OUTPUT_PATH = tmp_path / "RecipeMetadata_Generated.lua"
            generator.REPORT_DIR = tmp_path / "reports"
            generator.OUTPUT_PATH.write_text("-- stale\n", encoding="utf-8")

            try:
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    exit_code = generator.main(["generate", "--flavor", "tbc", "--offline", "--check"])
            finally:
                generator.OUTPUT_PATH = original_output
                generator.REPORT_DIR = original_report_dir

        self.assertEqual(exit_code, 1)

    def test_strict_validation_fails_fixture_dataset_kind(self):
        primary, records, diagnostics = load_default_records()

        failures, _unresolved = validate_records(
            records,
            diagnostics,
            strict=True,
            source_manifest=primary["manifest"],
        )

        self.assertTrue(any(item["field"] == "datasetKind" for item in failures))

    def test_strict_validation_fails_truncated_release_candidate_snapshot(self):
        primary, records, diagnostics = load_default_records()
        expected = build_expected_counts(records)
        manifest = dict(primary["manifest"], datasetKind="release-candidate", expectedRecipeCounts=expected)

        failures, _unresolved = validate_records(
            records[:-1],
            diagnostics,
            strict=True,
            source_manifest=manifest,
        )

        self.assertTrue(any(item["field"] == "recipeCoverage" for item in failures))

    def test_release_candidate_requires_vanilla_and_tbc_expected_coverage(self):
        primary, records, diagnostics = load_default_records()
        expected = build_expected_counts(records)
        manifest = dict(
            primary["manifest"],
            datasetKind="release-candidate",
            expectedRecipeCounts={"byProfession": expected["byProfession"]},
        )

        failures, _unresolved = validate_records(
            records,
            diagnostics,
            strict=True,
            source_manifest=manifest,
        )

        self.assertTrue(any(item["field"] == "expectedCoverage" for item in failures))

    def test_strict_validation_fails_missing_vanilla_or_tbc_records(self):
        primary, records, diagnostics = load_default_records()
        expected = build_expected_counts(records)
        manifest = dict(primary["manifest"], datasetKind="release-candidate", expectedRecipeCounts=expected)
        truncated = tuple(record for record in records if record.spell_id != 2329)

        failures, _unresolved = validate_records(
            truncated,
            diagnostics,
            strict=True,
            source_manifest=manifest,
        )

        self.assertTrue(any(item["field"] == "expansionCoverage" for item in failures))
        self.assertTrue(any(item["field"] == "professionExpansionCoverage" for item in failures))

    def test_coverage_report_shows_expected_actual_and_missing(self):
        primary, records, diagnostics = load_default_records()
        primary = dict(primary)
        expected = {"alchemy": 5}
        primary["manifest"] = dict(primary["manifest"], datasetKind="release-candidate", expectedRecipeCounts=expected)

        reports = generator.build_reports(records, diagnostics, primary)

        self.assertIn("| alchemy | 4 | 5 | 1 |", reports["coverage.md"])

    def test_coverage_report_shows_vanilla_and_tbc_denominators(self):
        primary, records, diagnostics = load_default_records()
        primary = dict(primary)
        expected = build_expected_counts(records)
        expected["byExpansion"]["vanilla"] += 1
        expected["byProfessionExpansion"]["alchemy"]["vanilla"] += 1
        primary["manifest"] = dict(primary["manifest"], datasetKind="release-candidate", expectedRecipeCounts=expected)

        reports = generator.build_reports(records, diagnostics, primary)

        self.assertIn("| vanilla | 5 | 6 | 1 |", reports["coverage.md"])
        self.assertIn("| alchemy | 2 | 3 | 1 | 2 | 2 | 0 |", reports["coverage.md"])

    def test_fetch_imports_valid_normalized_snapshot(self):
        original_snapshot_root = generator.SNAPSHOT_ROOT
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "source"
            target = tmp_path / "snapshots"
            write_fetch_snapshot(source)
            generator.SNAPSHOT_ROOT = target
            try:
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    exit_code = generator.main([
                        "fetch",
                        "--snapshot",
                        "import-test",
                        "--source-dir",
                        str(source),
                    ])
            finally:
                generator.SNAPSHOT_ROOT = original_snapshot_root

            self.assertEqual(exit_code, 0)
            self.assertTrue((target / "import-test" / "manifest.json").exists())
            self.assertTrue((target / "import-test" / "secondary_static.json").exists())

    def test_fetch_rejects_manifest_snapshot_mismatch(self):
        original_snapshot_root = generator.SNAPSHOT_ROOT
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "source"
            target = tmp_path / "snapshots"
            write_fetch_snapshot(source, snapshot="different-snapshot")
            generator.SNAPSHOT_ROOT = target
            stderr = StringIO()
            try:
                with redirect_stdout(StringIO()), redirect_stderr(stderr):
                    exit_code = generator.main([
                        "fetch",
                        "--snapshot",
                        "import-test",
                        "--source-dir",
                        str(source),
                    ])
            finally:
                generator.SNAPSHOT_ROOT = original_snapshot_root

            self.assertEqual(exit_code, 2)
            self.assertIn("does not match requested snapshot", stderr.getvalue())
            self.assertFalse((target / "import-test").exists())

    def test_fetch_rejects_invalid_normalized_snapshot_shape(self):
        original_snapshot_root = generator.SNAPSHOT_ROOT
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "source"
            target = tmp_path / "snapshots"
            write_fetch_snapshot(source)
            (source / "recipes.json").write_text(json.dumps({"not": "a list"}), encoding="utf-8")
            generator.SNAPSHOT_ROOT = target
            stderr = StringIO()
            try:
                with redirect_stdout(StringIO()), redirect_stderr(stderr):
                    exit_code = generator.main([
                        "fetch",
                        "--snapshot",
                        "import-test",
                        "--source-dir",
                        str(source),
                    ])
            finally:
                generator.SNAPSHOT_ROOT = original_snapshot_root

            self.assertEqual(exit_code, 2)
            self.assertIn("recipes.json: expected list", stderr.getvalue())
            self.assertFalse((target / "import-test").exists())

    def test_wago_anniversary_builder_maps_recipe_fields(self):
        snapshot = build_normalized_snapshot({
            "SkillLineAbility": [{
                "SkillLine": "171",
                "Spell": "2329",
                "MinSkillLineRank": "1",
            }, {
                "SkillLine": "202",
                "Spell": "26011",
                "MinSkillLineRank": "250",
            }, {
                "SkillLine": "333",
                "Spell": "27924",
                "MinSkillLineRank": "1",
            }],
            "VanillaSkillLineAbility": [{
                "SkillLine": "171",
                "Spell": "2329",
            }, {
                "SkillLine": "202",
                "Spell": "26011",
            }],
            "SpellEffect": [{
                "SpellID": "2329",
                "Effect": "24",
                "EffectItemType": "2454",
            }, {
                "SpellID": "26011",
                "Effect": "24",
                "EffectItemType": "21277",
            }, {
                "SpellID": "27924",
                "Effect": "53",
                "EffectItemType": "0",
            }],
            "SpellReagents": [{
                "SpellID": "2329",
                "Reagent_0": "2449",
                "Reagent_1": "765",
                "Reagent_2": "3371",
                "ReagentCount_0": "1",
                "ReagentCount_1": "1",
                "ReagentCount_2": "1",
            }, {
                "SpellID": "26011",
                "Reagent_0": "15407",
                "ReagentCount_0": "1",
            }, {
                "SpellID": "27924",
                "Reagent_0": "22449",
                "Reagent_1": "22446",
                "ReagentCount_0": "2",
                "ReagentCount_1": "2",
            }],
            "ItemEffect": [{
                "TriggerType": "6",
                "SpellID": "27924",
                "ParentItemID": "22536",
            }],
            "ItemSparse": [{
                "ID": "2454",
                "Display_lang": "Elixir of Lion's Strength",
                "Bonding": "0",
            }, {
                "ID": "21277",
                "Display_lang": "Tranquil Mechanical Yeti",
                "Bonding": "0",
            }, {
                "ID": "22536",
                "Display_lang": "Formula: Enchant Ring - Spellpower",
                "Bonding": "1",
                "RequiredSkillRank": "360",
            }],
            "SpellName": [{
                "ID": "2329",
                "Name_lang": "Elixir of Lion's Strength",
            }, {
                "ID": "26011",
                "Name_lang": "Tranquil Mechanical Yeti",
            }, {
                "ID": "27924",
                "Name_lang": "Enchant Ring - Spellpower",
            }],
        }, "unit-snapshot")

        recipes = {row["spellId"]: row for row in snapshot["recipes.json"]}

        self.assertEqual(recipes[2329]["createdItemId"], 2454)
        self.assertEqual(recipes[2329]["firstSeenExpansion"], "vanilla")
        self.assertEqual(recipes[26011]["firstSeenExpansion"], "vanilla")
        self.assertEqual(recipes[27924]["recipeItemId"], 22536)
        self.assertIsNone(recipes[27924]["createdItemId"])
        self.assertEqual(recipes[27924]["requiredSkill"], 360)
        self.assertEqual(snapshot["secondary_static.json"]["selfOnlyOutputlessSpellIds"], [27924])
        self.assertEqual(snapshot["manifest.json"]["sourceStats"]["lateVanillaRecipesFromBaseline"], 1)
        self.assertEqual(snapshot["manifest.json"]["expectedRecipeCounts"]["total"], 3)

    def test_wago_anniversary_builder_reads_created_quantity(self):
        # EffectBasePoints stores quantity - 1, and EffectDieSides > 1 turns
        # the yield into a range. Ammunition is the case that matters: a
        # single Crafted Light Shot craft yields 200 units, so a recipe
        # priced as one item would be off by that factor.
        def build(effect_rows):
            return build_normalized_snapshot({
                "SkillLineAbility": [{"SkillLine": "202", "Spell": "3919", "MinSkillLineRank": "1"}],
                "VanillaSkillLineAbility": [],
                "SpellEffect": effect_rows,
                "SpellReagents": [{"SpellID": "3919", "Reagent_0": "2835", "ReagentCount_0": "1"}],
                "ItemEffect": [],
                "ItemSparse": [{"ID": "2516", "Display_lang": "Crafted Light Shot", "Bonding": "0"}],
                "SpellName": [{"ID": "3919", "Name_lang": "Crafted Light Shot"}],
            }, "unit-snapshot")["recipes.json"][0]

        stacked = build([{
            "SpellID": "3919", "Effect": "24", "EffectItemType": "2516",
            "EffectBasePoints": "199", "EffectDieSides": "1",
        }])
        self.assertEqual(stacked["createdCount"], 200)
        self.assertIsNone(stacked["createdCountMax"])

        # DB2 renders some numeric columns as floats, and dieSides 0 carries
        # the same meaning as 1: a fixed amount.
        single = build([{
            "SpellID": "3919", "Effect": "24", "EffectItemType": "2516",
            "EffectBasePoints": "0.0", "EffectDieSides": "0",
        }])
        self.assertEqual(single["createdCount"], 1)
        self.assertIsNone(single["createdCountMax"])

        ranged = build([{
            "SpellID": "3919", "Effect": "24", "EffectItemType": "2516",
            "EffectBasePoints": "1", "EffectDieSides": "3",
        }])
        self.assertEqual(ranged["createdCount"], 2)
        self.assertEqual(ranged["createdCountMax"], 4)


class WowheadSpecializationTests(unittest.TestCase):
    # One row per case, in the shape Wowhead emits: keys are only partly
    # quoted, so the parser must not depend on the blob being valid JSON.
    GNOMISH = ('{"cat":11,"id":12906,"learnedat":230,"name":"Gnomish Battle Chicken",'
               '"skill":[202],"specialization":20219,quality:1,popularity:12}')
    TEACHES_SPEC = ('{"cat":11,"id":20219,"learnedat":9999,"name":"Gnomish Engineer",'
                    '"skill":[202],"specialization":20219,quality:-1}')
    PLAIN = '{"cat":11,"id":29545,"learnedat":330,"name":"Felsteel Longblade","skill":[164],quality:1}'
    FOREIGN = ('{"cat":11,"id":34542,"learnedat":375,"name":"Black Planar Edge",'
               '"skill":[164],"specialization":17041,quality:4}')
    NOISE = '{"id":99999,"name":"Something","specialization":12345}'

    def test_parses_specialization_and_skips_the_spell_that_teaches_it(self):
        html = "junk " + self.GNOMISH + " more " + self.TEACHES_SPEC + " " + self.PLAIN
        self.assertEqual(parse_listview_specializations(html), {12906: 20219})

    def test_rejects_unknown_specialization_ids(self):
        self.assertEqual(parse_listview_specializations(self.NOISE), {})

    def test_profession_guard_drops_rows_from_embedded_foreign_listviews(self):
        html = self.GNOMISH + self.FOREIGN
        self.assertEqual(
            parse_listview_specializations(html, profession="engineering"),
            {12906: 20219},
        )
        self.assertEqual(
            parse_listview_specializations(html, profession="blacksmithing"),
            {34542: 17041},
        )
        # Without the guard both rows are accepted, which is what makes the
        # union across pages correct even though per-page counts are not.
        self.assertEqual(parse_listview_specializations(html), {12906: 20219, 34542: 17041})

    def test_fetch_visits_every_profession_and_merges(self):
        pages = {"engineering": self.GNOMISH, "blacksmithing": self.FOREIGN}
        seen = []

        def fake_fetch(profession, flavor=None, timeout=None):
            seen.append(profession)
            return pages.get(profession, "")

        by_spell, per_profession = fetch_specializations(
            professions=("engineering", "blacksmithing", "cooking"),
            delay=0,
            fetch_page=fake_fetch,
        )
        self.assertEqual(seen, ["engineering", "blacksmithing", "cooking"])
        self.assertEqual(by_spell, {12906: 20219, 34542: 17041})
        self.assertEqual(per_profession, {"engineering": 1, "blacksmithing": 1, "cooking": 0})

    def test_snapshot_payload_is_deterministic_and_named(self):
        payload = build_specialization_snapshot({12906: 20219, 34542: 17041}, {"engineering": 1})
        self.assertEqual(payload["specializationBySpellId"], {"12906": 20219, "34542": 17041})
        self.assertEqual(
            payload["sourceStats"]["bySpecialization"],
            {"Gnomish Engineering": 1, "Master Axesmith": 1},
        )
        self.assertNotIn("fetchedAt", payload)

    def test_normalize_carries_specialization_from_secondary_and_overrides(self):
        primary = {"recipes": [
            {"spellId": 12906, "profession": "engineering", "firstSeenExpansion": "vanilla",
             "categoryHint": "engineering.misc", "createdItemId": 10725},
            {"spellId": 29545, "profession": "blacksmithing", "firstSeenExpansion": "tbc",
             "categoryHint": "blacksmithing.misc", "createdItemId": 23507},
        ]}
        secondary = {"specializationBySpellId": {12906: 20219, 29545: 9788}}
        records, _diag = normalize_records(
            primary, secondary, {},
            overrides={"specializationBySpellId": {29545: 17039}},
        )
        by_spell = {record.spell_id: record for record in records}
        self.assertEqual(by_spell[12906].specialization, 20219)
        # An explicit override beats the fetched snapshot.
        self.assertEqual(by_spell[29545].specialization, 17039)


def _record(spell_id, **overrides):
    """A minimal valid record, so source tests only state the fields at issue."""
    fields = dict(
        spell_id=spell_id,
        profession_key="blacksmithing",
        expansion="tbc",
        recipe_item_id=None,
        created_item_id=1000 + spell_id,
        reagents=(),
        category_key="misc",
        subcategory_key=None,
        sort_order=1,
        required_skill=1,
    )
    fields.update(overrides)
    return RecipeRecord(**fields)


class WowheadSourceTests(unittest.TestCase):
    # Shapes taken verbatim from live TBC pages: a single-faction vendor, a
    # neutral one, a creature drop and a container. Wowhead inlines these with
    # partly unquoted keys, so the parser must not assume valid JSON.
    ALLIANCE_VENDOR = (
        "new Listview({template: 'npc', id: 'sold-by', data: ["
        '{"classification":0,"id":1286,"location":[1519],"maxlevel":30,"minlevel":30,'
        '"name":"Edna Mullby","react":[1,null],"tag":"Trade Supplies","type":7}]});'
    )
    HORDE_VENDOR = (
        "new Listview({template: 'npc', id: 'sold-by', data: ["
        '{"id":3960,"location":[1637],"name":"Kaplak","react":[null,1],"tag":"Trade Supplies"}]});'
    )
    NEUTRAL_VENDOR = (
        "new Listview({template: 'npc', id: 'sold-by', data: ["
        '{"id":19239,"location":[3703],"name":"Haastrum","react":[1,1],"tag":"Trade Supplies"}]});'
    )
    DROP = (
        "new Listview({template: 'npc', id: 'dropped-by', data: ["
        '{"id":36,"location":[40,0],"name":"Harvest Golem","react":[-1,-1],"count":6,"outof":29282}]});'
    )
    CONTAINER = (
        "new Listview({template: 'object', id: 'contained-in-object', data: ["
        '{"id":2847,"location":[3433],"name":"Tattered Chest","type":3}]});'
    )

    def test_reads_vendor_zone_and_faction(self):
        parsed = parse_item_sources(self.ALLIANCE_VENDOR)
        self.assertEqual(len(parsed["vendors"]), 1)
        vendor = parsed["vendors"][0]
        self.assertEqual(vendor["name"], "Edna Mullby")
        self.assertEqual(vendor["zones"], [1519])
        self.assertTrue(vendor["alliance"])
        self.assertFalse(vendor["horde"])
        self.assertEqual(derive_faction(parsed), "alliance")

    def test_null_and_hostile_react_both_mean_unavailable(self):
        # `null` is "this NPC does not exist for you", a negative value is
        # "it will not trade with you". Neither lets that faction buy.
        self.assertEqual(derive_faction(parse_item_sources(self.HORDE_VENDOR)), "horde")
        self.assertEqual(derive_faction(parse_item_sources(self.NEUTRAL_VENDOR)), "both")

    def test_a_drop_is_available_to_everyone(self):
        # A creature is hostile to both sides, so its react pair says nothing
        # about who may loot the recipe.
        parsed = parse_item_sources(self.DROP)
        self.assertEqual(derive_faction(parsed), "both")
        self.assertEqual(parsed["drops"][0]["name"], "Harvest Golem")
        # Zone 0 is Wowhead filler and must not reach the payload.
        self.assertEqual(parsed["drops"][0]["zones"], [40])

    def test_a_drop_overrides_a_single_faction_vendor(self):
        parsed = parse_item_sources(self.ALLIANCE_VENDOR + self.DROP)
        self.assertEqual(derive_faction(parsed), "both")

    def test_summary_names_the_kinds_and_unions_the_zones(self):
        summary = summarize_item(parse_item_sources(self.ALLIANCE_VENDOR + self.CONTAINER))
        self.assertEqual(summary["kinds"], ["vendor", "container"])
        self.assertEqual(summary["zones"], [1519, 3433])
        self.assertEqual(summary["vendors"], [{"name": "Edna Mullby", "zones": [1519]}])

    def test_unrelated_listviews_are_ignored(self):
        related = (
            "new Listview({template: 'item', id: 'can-be-placed-in', data: ["
            '{"id":34482,"name":"Leatherworker\'s Satchel","source":[1]}]});'
        )
        parsed = parse_item_sources(related + self.ALLIANCE_VENDOR)
        self.assertEqual(len(parsed["vendors"]), 1)
        self.assertEqual(parsed["drops"], [])
        self.assertEqual(parsed["containers"], [])


class FetchOutcomeTests(unittest.TestCase):
    """A crawl that gets refused must not look like one that worked."""

    def test_a_clean_run_reports_no_failures(self):
        outcome = FetchOutcome(attempted=10, succeeded=10, failures={})
        self.assertEqual(outcome.describe(), "10/10 fetched")
        self.assertFalse(outcome.mostly_failed())

    def test_a_blocked_run_is_flagged_and_names_the_reason(self):
        outcome = FetchOutcome(attempted=1396, succeeded=114, failures={"http": 1282})
        self.assertIn("1282 failed", outcome.describe())
        self.assertIn("http", outcome.describe())
        self.assertTrue(outcome.mostly_failed())

    def test_a_few_stragglers_do_not_condemn_the_run(self):
        outcome = FetchOutcome(attempted=100, succeeded=95, failures={"http": 5})
        self.assertFalse(outcome.mostly_failed())


class AcquisitionSummaryTests(unittest.TestCase):
    """What summarize_source keeps, now that the provider states the rest."""

    def test_keeps_names_and_zones_and_drops_a_neutral_faction(self):
        faction, kind, zones, names, world_drop, trash = summarize_source({
            "faction": "both",
            "kind": "vendor",
            "worldDrop": False,
            "names": ["Kendor Kabonka"],
            "zones": ["Stormwind City"],
        })
        # "both" is the default reading of an absent field, so it is not stored.
        self.assertIsNone(faction)
        self.assertEqual(kind, "vendor")
        self.assertEqual(names, ("Kendor Kabonka",))
        self.assertEqual(zones, ("Stormwind City",))
        self.assertFalse(world_drop)

    def test_a_world_drop_points_nowhere(self):
        faction, kind, zones, names, world_drop, trash = summarize_source({
            "faction": "both", "kind": "worldDrop", "worldDrop": True,
            "names": ["Some Mob"], "zones": ["Everywhere"],
        })
        self.assertEqual(kind, "worldDrop")
        self.assertTrue(world_drop)
        self.assertEqual(names, ())
        self.assertEqual(zones, ())

    def test_a_faction_restriction_survives(self):
        faction, _kind, _zones, _names, _wd, _t = summarize_source({
            "faction": "horde", "kind": "vendor", "names": [], "zones": [],
        })
        self.assertEqual(faction, "horde")

    def test_nothing_known_stays_empty(self):
        self.assertEqual(summarize_source({}), (None, None, (), (), False, False))


class ArlProviderTests(unittest.TestCase):
    PROFESSION = """
        AddRecipe(2661, 35, 2851, Q.COMMON, V.ORIG, 35, 75, 95, 115)
        self:AddRecipeFlags(2661, F.ALLIANCE, F.HORDE, F.TRAINER)
        self:AddRecipeTrainer(2661, 3355, 3174, 29924, 1241)

        AddRecipe(9811, 200, 7961, Q.COMMON, V.ORIG, 200, 220, 230, 240)
        self:AddRecipeFlags(9811, F.HORDE, F.VENDOR)
        self:AddRecipeVendor(9811, 340)

        AddRecipe(12906, 230, 10725, Q.COMMON, V.ORIG, 230, 250, 260, 270)
        self:AddRecipeFlags(12906, F.ALLIANCE, F.HORDE, F.WORLD_DROP)
        self:AddRecipeWorldDrop(12906, 1)
    """
    LOOKUP = """
        AddVendor(340, L["Kendor Kabonka"], BZ["Stormwind City"], 77.5, 53.5, ALLIANCE)
        AddMob(2242, L["Syndicate Spy"], BZ["Alterac Mountains"], 63.0, 40.6)
    """

    def test_reads_the_faction_off_the_flags(self):
        recipes = parse_profession(self.PROFESSION)
        self.assertEqual(recipes[2661]["faction"], "both")
        self.assertEqual(recipes[9811]["faction"], "horde")

    def test_reads_the_acquire_kind_and_its_npcs(self):
        recipes = parse_profession(self.PROFESSION)
        self.assertEqual(recipes[9811]["acquires"], {"vendor": [340]})
        self.assertEqual(recipes[2661]["acquires"]["trainer"], [3355, 3174, 29924, 1241])

    def test_resolves_an_npc_to_a_name_and_zone(self):
        lookups = parse_lookup(self.LOOKUP)
        summary = summarize_recipe(parse_profession(self.PROFESSION)[9811], lookups)
        self.assertEqual(summary["kind"], "vendor")
        self.assertEqual(summary["names"], ["Kendor Kabonka"])
        self.assertEqual(summary["zones"], ["Stormwind City"])
        self.assertEqual(summary["faction"], "horde")

    def test_a_recipe_every_trainer_teaches_names_none_of_them(self):
        # Four trainers listed against a cap of three: naming the one whose
        # id happens to resolve is worse than naming none.
        summary = summarize_recipe(parse_profession(self.PROFESSION)[2661],
                                   parse_lookup(self.LOOKUP), max_names=3)
        self.assertEqual(summary["kind"], "trainer")
        self.assertEqual(summary["names"], [])
        self.assertEqual(summary["zones"], [])

    def test_a_world_drop_is_marked_and_named_nowhere(self):
        summary = summarize_recipe(parse_profession(self.PROFESSION)[12906],
                                   parse_lookup(self.LOOKUP))
        self.assertTrue(summary["worldDrop"])
        self.assertEqual(summary["names"], [])


class PostTbcNpcTests(unittest.TestCase):
    """ARL covers later expansions than this project targets."""

    def test_an_npc_numbered_past_the_end_of_tbc_is_rejected(self):
        # Didi the Wrench, 29513, against a last TBC creature of 29095.
        self.assertTrue(is_post_tbc(29513, "Dalaran"))
        self.assertFalse(is_post_tbc(8126, "Tanaris"))

    def test_a_northrend_zone_is_rejected_whatever_the_id(self):
        # 87 of the offenders have ids inside TBC's range but stand in
        # Northrend, so the id test alone would keep them.
        self.assertTrue(is_post_tbc(26569, "Dragonblight"))
        self.assertTrue(is_post_tbc(1, "Borean Tundra"))

    def test_a_wotlk_npc_standing_in_a_tbc_zone_is_still_rejected(self):
        # The Inscription trainers WotLK put in old cities: a zone test alone
        # would keep every one of them.
        self.assertTrue(is_post_tbc(33637, "Shattrath City"))
        self.assertTrue(is_post_tbc(30717, "Ironforge"))
        self.assertFalse(is_post_tbc(340, "Stormwind City"))

    def test_tbc_dalaran_is_treated_as_the_northrend_one(self):
        # TBC has a Dalaran, the ruined bubble over Alterac, but nobody in it
        # teaches or sells a recipe -- every ARL entry there is the later city.
        self.assertTrue(is_post_tbc(100, "Dalaran"))


class ArlDroppedNpcTests(unittest.TestCase):
    """A later-expansion trainer must not count towards the naming cap."""

    PROFESSION = """
        AddRecipe(8895, 1, 1, Q.COMMON, V.ORIG, 1, 1, 1, 1)
        self:AddRecipeFlags(8895, F.ALLIANCE, F.HORDE, F.TRAINER)
        self:AddRecipeTrainer(8895, 8126, 29513)
    """
    LOOKUP = """
        self:addLookupList(DB, 8126, L["Nixx Sprocketspring"], BZ["Tanaris"], 52.5, 27.3, 0)
        self:addLookupList(DB, 29513, L["Didi the Wrench"], BZ["Dalaran"], 39.5, 25.5, 0)
    """

    def test_the_later_trainer_is_dropped_and_the_tbc_one_named(self):
        lookups = {"Trainer": parse_lookup(self.LOOKUP)}
        summary = summarize_recipe(parse_profession(self.PROFESSION)[8895], lookups)
        self.assertEqual(summary["names"], ["Nixx Sprocketspring"])
        self.assertEqual(summary["zones"], ["Tanaris"])

    def test_dropping_it_also_takes_it_out_of_the_naming_cap(self):
        # Two trainers listed, one of them not in this expansion: with a cap of
        # one, counting the dropped one would blank the name of the one that
        # does exist.
        lookups = {"Trainer": parse_lookup(self.LOOKUP)}
        summary = summarize_recipe(parse_profession(self.PROFESSION)[8895],
                                   lookups, max_names=1)
        self.assertEqual(summary["names"], ["Nixx Sprocketspring"])


class ArlGenericAcquireTests(unittest.TestCase):
    """Recipes ARL places with a flag and a place rather than an NPC.

    Several hundred recipes carry no acquire call naming anybody: the raid
    drops, the discoveries, the recipes every trainer sells. Reading only the
    NPC-naming calls left every one of them looking like a recipe nothing in
    the world knows about.
    """

    PROFESSION = """
        AddRecipe(46140, 365, 35556, Q.EPIC, V.TBC, 365, 365, 375, 385)
        self:AddRecipeFlags(46140, F.ALLIANCE, F.HORDE, F.RAID, F.IBOE)
        self:AddRecipeAcquire(46140, A.CUSTOM, 24)

        AddRecipe(36389, 375, 30321, Q.EPIC, V.TBC, 375, 375, 385, 395)
        self:AddRecipeFlags(36389, F.ALLIANCE, F.HORDE, F.RAID)
        self:AddRecipeAcquire(36389, A.CUSTOM, 37, A.CUSTOM, 43)

        AddRecipe(28580, 350, 22452, Q.COMMON, V.TBC, 350, 350, 360, 370)
        self:AddRecipeFlags(28580, F.ALLIANCE, F.HORDE, F.DISC)
        self:AddRecipeAcquire(28580, A.CUSTOM, 3)

        AddRecipe(21923, 1, 17722, Q.COMMON, V.ORIG, 1, 1, 1, 1)
        self:AddRecipeFlags(21923, F.ALLIANCE, F.HORDE, F.SEASONAL)
        self:AddRecipeAcquire(21923, A.SEASONAL, 1)

        AddRecipe(13501, 1, 1, Q.COMMON, V.ORIG, 1, 1, 1, 1)
        self:AddRecipeFlags(13501, F.ALLIANCE, F.HORDE, F.TRAINER, F.INSTANCE)
        self:AddRecipeAcquire(13501, A.CUSTOM, 13)
    """
    CUSTOM = """
        self:addLookupList(DB, 3, L["DISCOVERY_ALCH_XMUTE"])
        self:addLookupList(DB, 13, L["HENRY_STERN_RFD"], BZ["Razorfen Downs"], 0, 0)
        self:addLookupList(DB, 24, L["SUNWELL_RANDOM"], BZ["Sunwell Plateau"], 0, 0)
        self:addLookupList(DB, 37, L["SSC_RANDOM"], BZ["Serpentshrine Cavern"], 0, 0)
        self:addLookupList(DB, 43, L["TK_RANDOM"], BZ["The Eye"], 0, 0)
    """

    def _summary(self, spell_id):
        return summarize_recipe(parse_profession(self.PROFESSION)[spell_id],
                                {}, parse_custom_places(self.CUSTOM))

    def test_a_place_without_a_zone_is_not_a_place(self):
        places = parse_custom_places(self.CUSTOM)
        # A discovery happens at the cauldron; there is nowhere to send anyone.
        self.assertNotIn(3, places)
        self.assertEqual(places[24], "Sunwell Plateau")

    def test_the_flag_states_the_kind_when_no_call_names_anybody(self):
        self.assertEqual(parse_source_flags("F.ALLIANCE, F.HORDE, F.RAID"), "drop")
        self.assertEqual(parse_source_flags("F.HORDE, F.DISC"), "discovery")
        self.assertEqual(parse_source_flags("F.SEASONAL"), "worldEvent")
        self.assertEqual(parse_source_flags("F.ALLIANCE, F.IBOE"), None)

    def test_a_trainer_inside_an_instance_is_still_a_trainer(self):
        summary = self._summary(13501)
        self.assertEqual(summary["kind"], "trainer")
        self.assertEqual(summary["zones"], ["Razorfen Downs"])

    def test_a_raid_drop_lands_in_its_raid(self):
        summary = self._summary(46140)
        self.assertEqual(summary["kind"], "drop")
        self.assertEqual(summary["zones"], ["Sunwell Plateau"])
        # Nobody is named: the recipe drops off the instance, not off a name.
        self.assertEqual(summary["names"], [])

    def test_a_recipe_that_drops_in_two_raids_names_both(self):
        self.assertEqual(self._summary(36389)["zones"],
                         ["Serpentshrine Cavern", "The Eye"])

    def test_a_discovery_is_its_own_kind_and_points_nowhere(self):
        summary = self._summary(28580)
        self.assertEqual(summary["kind"], "discovery")
        self.assertEqual(summary["zones"], [])
        self.assertFalse(summary["worldDrop"])

    def test_a_world_event_is_its_own_kind(self):
        self.assertEqual(self._summary(21923)["kind"], "worldEvent")

    def test_the_custom_ids_never_reach_the_npc_lookup(self):
        # Custom id 24 must not be read as NPC 24.
        recipes = parse_profession(self.PROFESSION)
        self.assertEqual(recipes[46140]["acquires"], {})
        self.assertEqual(recipes[46140]["places"], [24])

    def test_an_acquire_call_that_names_npcs_still_wins(self):
        text = self.PROFESSION + """
        AddRecipe(9811, 200, 7961, Q.COMMON, V.ORIG, 200, 220, 230, 240)
        self:AddRecipeFlags(9811, F.HORDE, F.RAID)
        self:AddRecipeVendor(9811, 340)
        """
        lookups = parse_lookup(
            'AddVendor(340, L["Kendor Kabonka"], BZ["Stormwind City"], 77.5, 53.5, ALLIANCE)')
        summary = summarize_recipe(parse_profession(text)[9811], lookups,
                                   parse_custom_places(self.CUSTOM))
        self.assertEqual(summary["kind"], "vendor")
        self.assertEqual(summary["names"], ["Kendor Kabonka"])


class RemovedRecipeTests(unittest.TestCase):
    """Recipes in the client data but not in the game.

    Flagged, never deleted: the point of keeping the record is that putting
    one back costs an override line, not an investigation.
    """

    PAYLOAD = {
        "_reason": "No Wowhead difficulty data available",
        "recipes": {
            "Alchemy": [{"spellId": 2336, "name": "Elixir of Tongues",
                         "notes": "No Wowhead data"}],
            "Tailoring": [{"spellId": 31461, "name": "Heavy Netherweave Net"}],
        },
    }

    def test_parses_every_profession_into_one_map(self):
        parsed = parse_removed(self.PAYLOAD)
        self.assertEqual(sorted(parsed), [2336, 31461])
        self.assertEqual(parsed[2336]["profession"], "Alchemy")

    def test_snapshot_round_trips_to_a_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            write_removed_snapshot(
                build_removed_snapshot(parse_removed(self.PAYLOAD)), directory)
            loaded = load_removed(directory)
            self.assertEqual(loaded, {2336: True, 31461: True})
            # Nothing flagged is the honest reading of no file at all.
            self.assertEqual(load_removed(Path(directory) / "nope"), {})

    def _normalize(self, secondary=None, overrides=None):
        primary = {"recipes": [{
            "spellId": 2336, "profession": "alchemy", "requiredSkill": 1,
            "createdItemId": 1, "firstSeenExpansion": "vanilla",
        }]}
        return normalize_records(primary, secondary or {}, {},
                                 overrides=overrides or {})[0]

    def test_the_flag_reaches_the_record(self):
        records = self._normalize({"removedBySpellId": {2336: True}})
        self.assertTrue(records[0].removed)

    def test_a_recipe_nothing_flags_is_not_removed(self):
        self.assertFalse(self._normalize()[0].removed)

    def test_an_override_puts_a_recipe_back(self):
        records = self._normalize({"removedBySpellId": {2336: True}},
                                  {"removedBySpellId": {2336: False}})
        self.assertFalse(records[0].removed)

    def test_an_override_can_also_flag_one_the_list_missed(self):
        records = self._normalize({}, {"removedBySpellId": {2336: True}})
        self.assertTrue(records[0].removed)

    def test_the_flag_is_emitted_only_when_set(self):
        removed = _record(spell_id=1, removed=True)
        kept = _record(spell_id=2)
        lua = emit_lua([removed, kept], {}, {}, "1", 1, "tbc")
        self.assertEqual(lua.count("removed = true"), 1)


class OverrideParsingTests(unittest.TestCase):
    """The override file is hand-edited, so it has to survive being annotated."""

    def _load(self, body):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manual_overrides.yaml"
            path.write_text(body, encoding="utf-8")
            return generator._load_overrides(path)

    def test_a_trailing_comment_is_not_part_of_the_value(self):
        # Without this, the value parsed as the string "true  # never
        # released", the caller's `is True` check failed, and the override was
        # read, accepted, and quietly did nothing.
        loaded = self._load(
            "removedBySpellId:\n  26918: true  # Design: Arcanite Sword Pendant\n")
        self.assertEqual(loaded["removedBySpellId"], {26918: True})

    def test_false_survives_a_comment_too(self):
        loaded = self._load("removedBySpellId:\n  1: false  # actually in the game\n")
        self.assertIs(loaded["removedBySpellId"][1], False)

    def test_a_number_survives_a_comment(self):
        loaded = self._load("createdItemBySpellId:\n  1: 4321  # the real item\n")
        self.assertEqual(loaded["createdItemBySpellId"][1], 4321)

    def test_a_hash_inside_a_quoted_value_is_kept(self):
        loaded = self._load('categoryBySpellId:\n  1: "weapons#swords"\n')
        self.assertEqual(loaded["categoryBySpellId"][1], "weapons#swords")

    def test_a_whole_line_comment_is_still_ignored(self):
        loaded = self._load("# nothing to see\nremovedBySpellId:\n  7: true\n")
        self.assertEqual(loaded["removedBySpellId"], {7: True})


class SourceEmitTests(unittest.TestCase):
    def test_emits_faction_zones_and_names_but_omits_both(self):
        alliance = _record(spell_id=1, faction="alliance", source_kind="vendor",
                           source_zones=("Stormwind City",), source_names=("Edna Mullby",))
        neutral = _record(spell_id=2)
        lua = emit_lua([alliance, neutral], {}, {}, "1", 1, "tbc")
        self.assertIn('faction = "alliance"', lua)
        self.assertIn('sourceKind = "vendor"', lua)
        self.assertIn("sourceZones = { 1 }", lua)
        self.assertIn('sourceNames = { "Edna Mullby" }', lua)
        self.assertIn('[1] = "Stormwind City"', lua)
        # The neutral record carries no faction line at all.
        self.assertEqual(lua.count("faction ="), 1)

    def test_zone_names_are_interned_once_however_many_records_cite_them(self):
        records = [_record(spell_id=index, source_zones=("Stormwind City",))
                   for index in range(1, 4)]
        lua = emit_lua(records, {}, {}, "1", 1, "tbc")
        # One entry in the table, three records pointing at it.
        self.assertEqual(lua.count('= "Stormwind City"'), 1)
        self.assertEqual(lua.count("sourceZones = { 1 }"), 3)


class ManualAcquisitionTests(unittest.TestCase):
    """Hand-read records outrank the bulk sources, whole record at a time."""

    def test_a_world_drop_keeps_neither_names_nor_zones(self):
        entry = build_entry("worldDrop", names=("Somebody",), zones=("Somewhere",))
        self.assertTrue(entry["worldDrop"])
        self.assertEqual(entry["names"], [])
        self.assertEqual(entry["zones"], [])

    def test_an_absent_faction_reads_as_both(self):
        self.assertEqual(build_entry("vendor", faction="")["faction"], "both")

    def test_an_unknown_kind_is_rejected(self):
        problems = validate_entry(123, build_entry("sold-by-a-guy"))
        self.assertTrue(any("is not one of" in problem for problem in problems))

    def test_a_hand_record_replaces_the_automated_one_outright(self):
        arl = {1: {"kind": None, "faction": "both", "names": [], "zones": [],
                   "worldDrop": False}}
        manual = {1: build_entry("vendor", faction="horde",
                                 names=("Ongrom Black Tooth",),
                                 zones=("Hellfire Peninsula",))}
        merged = merge_acquisition(arl, manual)
        self.assertEqual(merged[1]["kind"], "vendor")
        self.assertEqual(merged[1]["faction"], "horde")
        # Nothing of the automated record survives inside the hand one.
        self.assertEqual(merged[1]["names"], ["Ongrom Black Tooth"])

    def test_recipes_the_bulk_source_placed_are_left_alone(self):
        arl = {1: {"kind": "trainer", "faction": "both", "names": [],
                   "zones": [], "worldDrop": False}}
        merged = merge_acquisition(arl, {2: build_entry("quest")})
        self.assertEqual(merged[1]["kind"], "trainer")
        self.assertEqual(merged[2]["kind"], "quest")

    def test_snapshot_round_trips(self):
        with tempfile.TemporaryDirectory() as directory:
            write_manual_snapshot(
                build_manual_snapshot({7: build_entry("quest")}), directory)
            loaded = load_manual_acquisition(directory)
        self.assertEqual(loaded[7]["kind"], "quest")


class AcquisitionWorksheetTests(unittest.TestCase):
    """The sheet is a person's working file: regenerating it must be safe."""

    RECIPES = {
        "recipes": [
            {"spellId": 1, "profession": "tailoring", "firstSeenExpansion": "tbc",
             "requiredSkill": 350, "recipeItemId": 100},
            {"spellId": 2, "profession": "cooking", "firstSeenExpansion": "vanilla",
             "requiredSkill": None, "createdItemId": 200},
            {"spellId": 3, "profession": "alchemy", "firstSeenExpansion": "tbc",
             "requiredSkill": 300},
        ],
    }
    ITEMS = [{"itemId": 100, "name": "Pattern: Something"},
             {"itemId": 200, "name": "Some Food"}]

    def _snapshot(self, directory, acquisition=None):
        directory = Path(directory)
        (directory / "recipes.json").write_text(json.dumps(self.RECIPES), encoding="utf-8")
        (directory / "item_sparse.json").write_text(json.dumps(self.ITEMS), encoding="utf-8")
        (directory / "acquisition.json").write_text(
            json.dumps({"acquisitionBySpellId": acquisition or {}}), encoding="utf-8")
        return directory

    def _emit(self, directory):
        sheet = Path(directory) / "worksheet.csv"
        links = Path(directory) / "links.txt"
        out = StringIO()
        with redirect_stdout(out):
            rows = acquisition_worksheet.emit(directory, sheet, links)
        return rows, sheet, links

    def _fill(self, sheet, spell_id, **values):
        """Answer one row, the way a person would in a spreadsheet.

        Through the csv module rather than by splicing a literal line: a test
        that counts commas by hand breaks whenever a column is added or
        removed, which says nothing about the behaviour under test.
        """
        import csv as csv_module
        with open(sheet, "r", encoding="utf-8-sig", newline="") as handle:
            reader = csv_module.DictReader(handle)
            fieldnames = reader.fieldnames
            rows = list(reader)
        for row in rows:
            if int(row["spellId"]) == spell_id:
                row.update(values)
        with open(sheet, "w", encoding="utf-8-sig", newline="") as handle:
            writer = csv_module.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)

    def test_only_unplaced_recipes_reach_the_sheet(self):
        with tempfile.TemporaryDirectory() as directory:
            self._snapshot(directory, {
                # Placed: it says where it comes from, and who.
                "1": {"kind": "vendor", "faction": "both", "names": ["Somebody"],
                      "zones": ["Somewhere"], "worldDrop": False},
                # Unplaced: a record, but it never says where.
                "2": {"kind": None, "faction": "alliance", "names": [], "zones": [],
                      "worldDrop": False},
            })
            rows, _, _ = self._emit(directory)
        # Spell 3 has no record at all, spell 2 has one that places nothing.
        self.assertEqual(sorted(row["spellId"] for row in rows), [2, 3])

    def test_a_kind_that_needs_a_place_and_has_none_is_still_a_gap(self):
        # "Sold by somebody somewhere" is not an answer a player can act on,
        # so it belongs on the sheet even though the kind is known.
        with tempfile.TemporaryDirectory() as directory:
            self._snapshot(directory, {
                "1": {"kind": "vendor", "faction": "both", "names": [], "zones": [],
                      "worldDrop": False},
            })
            rows, _, _ = self._emit(directory)
        self.assertIn(1, [row["spellId"] for row in rows])

    def test_a_kind_that_is_a_whole_answer_on_its_own_is_not_a_gap(self):
        # You go to your own trainer; a world drop has nowhere to go; a
        # discovery happens at your own workbench. None of them wants a place.
        for kind in ("trainer", "worldDrop", "discovery", "worldEvent", "quest"):
            with tempfile.TemporaryDirectory() as directory:
                self._snapshot(directory, {
                    "1": {"kind": kind, "faction": "both", "names": [], "zones": [],
                          "worldDrop": kind == "worldDrop"},
                })
                rows, _, _ = self._emit(directory)
            self.assertNotIn(1, [row["spellId"] for row in rows],
                             "{0} should not need a place".format(kind))

    def test_rows_are_banded_and_the_tbc_skilled_ones_come_first(self):
        with tempfile.TemporaryDirectory() as directory:
            self._snapshot(directory)
            rows, _, _ = self._emit(directory)
        self.assertEqual([row["priority"] for row in rows], [1, 1, 4])

    def test_a_recipe_without_a_pattern_is_labelled_by_what_it_makes(self):
        with tempfile.TemporaryDirectory() as directory:
            self._snapshot(directory)
            rows, _, _ = self._emit(directory)
        by_spell = {row["spellId"]: row for row in rows}
        self.assertEqual(by_spell[1]["name"], "Pattern: Something")
        self.assertEqual(by_spell[2]["name"], "makes: Some Food")
        # No pattern means the spell page is the one to open.
        self.assertIn("spell=3", by_spell[3]["url"])
        self.assertIn("item=100", by_spell[1]["url"])

    def test_re_emitting_keeps_answers_already_filled_in(self):
        with tempfile.TemporaryDirectory() as directory:
            self._snapshot(directory)
            _, sheet, links = self._emit(directory)
            self._fill(sheet, 1, kind="vendor", faction="horde",
                       names="Ongrom|Hurnak", zones="Orgrimmar")

            out = StringIO()
            with redirect_stdout(out):
                rows = acquisition_worksheet.emit(directory, sheet, links)
            kept = next(row for row in rows if row["spellId"] == 1)
        self.assertEqual(kept["kind"], "vendor")
        self.assertEqual(kept["names"], "Ongrom|Hurnak")

    def test_a_filled_row_becomes_a_snapshot_record(self):
        with tempfile.TemporaryDirectory() as directory:
            self._snapshot(directory)
            _, sheet, links = self._emit(directory)
            self._fill(sheet, 1, kind="vendor", faction="horde",
                       names="Ongrom|Hurnak", zones="Orgrimmar")

            out, err = StringIO(), StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = acquisition_worksheet.apply(directory, sheet)
            self.assertEqual(code, 0)
            records = load_manual_acquisition(directory)
        self.assertEqual(records[1]["kind"], "vendor")
        self.assertEqual(records[1]["faction"], "horde")
        self.assertEqual(records[1]["names"], ["Ongrom", "Hurnak"])
        self.assertEqual(records[1]["zones"], ["Orgrimmar"])
        # An empty row is not an answer.
        self.assertNotIn(3, records)

    def test_a_bad_kind_refuses_to_write_anything(self):
        with tempfile.TemporaryDirectory() as directory:
            self._snapshot(directory)
            _, sheet, links = self._emit(directory)
            self._fill(sheet, 1, kind="dunno")

            out, err = StringIO(), StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = acquisition_worksheet.apply(directory, sheet)
            self.assertEqual(code, 1)
            self.assertFalse((Path(directory) / "acquisition_manual.json").exists())

    def test_a_recipe_flagged_removed_by_hand_leaves_the_sheet(self):
        # The sheet tracks what still needs an answer, and a recipe that is
        # not in the game never will -- however it came to be flagged.
        with tempfile.TemporaryDirectory() as directory:
            self._snapshot(directory)
            (Path(directory) / "removed.json").write_text(
                json.dumps({"removedBySpellId": {"3": {"name": "Gone"}}}), encoding="utf-8")
            rows, _, _ = self._emit(directory)
        self.assertNotIn(3, [row["spellId"] for row in rows])

    def test_the_link_list_drops_rows_already_answered(self):
        with tempfile.TemporaryDirectory() as directory:
            self._snapshot(directory)
            _, sheet, links = self._emit(directory)
            self.assertIn("item=100", links.read_text(encoding="utf-8"))
            self._fill(sheet, 1, kind="vendor")
            out = StringIO()
            with redirect_stdout(out):
                acquisition_worksheet.emit(directory, sheet, links)
            self.assertNotIn("item=100", links.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
