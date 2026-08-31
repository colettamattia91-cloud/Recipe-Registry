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


class SourceSummaryTests(unittest.TestCase):
    def test_vendor_wins_over_drop_as_the_actionable_answer(self):
        source = {
            "faction": "both",
            "kinds": ["vendor", "drop"],
            "zones": [1519, 40],
            "vendors": [{"name": "Edna Mullby", "zones": [1519]}],
            "drops": [{"name": "Harvest Golem", "zones": [40]}],
        }
        faction, kind, zones, names, world_drop, trash = summarize_source(source)
        self.assertIsNone(faction)  # "both" is the default reading of absent
        self.assertEqual(kind, "vendor")
        self.assertEqual(names, ("Edna Mullby",))
        self.assertFalse(world_drop)

    def test_many_droppers_collapse_to_a_world_drop(self):
        drops = [{"name": "Mob %d" % index, "zones": [index]} for index in range(12)]
        faction, kind, zones, names, world_drop, trash = summarize_source({
            "faction": "both",
            "kinds": ["drop"],
            "zones": list(range(12)),
            "drops": drops,
        })
        self.assertEqual(kind, "drop")
        self.assertTrue(world_drop)
        # Naming a dozen creatures across a dozen zones answers nothing, so
        # the payload carries neither.
        self.assertEqual(zones, ())
        self.assertEqual(names, ())

    def test_no_source_data_stays_empty(self):
        self.assertEqual(summarize_source({}), (None, None, (), (), False, False))


class InstanceDropTests(unittest.TestCase):
    """A drop is not one answer: a boss, instance trash and a world drop are
    three different things to tell the player."""

    def test_a_boss_is_named(self):
        faction, kind, zones, names, world_drop, trash = summarize_source({
            "faction": "both",
            "kinds": ["drop"],
            "zones": [3457],
            "drops": [
                {"name": "Nightbane", "zones": [3457], "boss": True, "instance": True},
                {"name": "Phase Hunter", "zones": [3457], "instance": True},
            ],
        })
        self.assertEqual(kind, "boss")
        self.assertEqual(names, ("Nightbane",))
        self.assertFalse(trash)
        self.assertEqual(zones, (3457,))

    def test_instance_non_bosses_collapse_to_trash_without_a_list(self):
        drops = [
            {"name": "Servant %d" % index, "zones": [3457], "instance": True}
            for index in range(4)
        ]
        faction, kind, zones, names, world_drop, trash = summarize_source({
            "faction": "both", "kinds": ["drop"], "zones": [3457], "drops": drops,
        })
        self.assertEqual(kind, "trash")
        self.assertTrue(trash)
        # The instance name is the answer; the creature list is not.
        self.assertEqual(names, ())
        self.assertEqual(zones, (3457,))
        self.assertFalse(world_drop)

    def test_two_creatures_out_in_the_world_are_still_named(self):
        faction, kind, zones, names, world_drop, trash = summarize_source({
            "faction": "both",
            "kinds": ["drop"],
            "zones": [40],
            "drops": [
                {"name": "Harvest Golem", "zones": [40]},
                {"name": "Harvest Watcher", "zones": [40]},
            ],
        })
        self.assertEqual(kind, "drop")
        self.assertEqual(names, ("Harvest Golem", "Harvest Watcher"))
        self.assertFalse(trash)
        self.assertFalse(world_drop)


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


class SourceEmitTests(unittest.TestCase):
    def test_emits_faction_zones_and_names_but_omits_both(self):
        alliance = _record(spell_id=1, faction="alliance", source_kind="vendor",
                           source_zones=(1519,), source_names=("Edna Mullby",))
        neutral = _record(spell_id=2)
        lua = emit_lua([alliance, neutral], {}, {}, "1", 1, "tbc", {1519: "Stormwind City"})
        self.assertIn('faction = "alliance"', lua)
        self.assertIn('sourceKind = "vendor"', lua)
        self.assertIn("sourceZones = { 1519 }", lua)
        self.assertIn('sourceNames = { "Edna Mullby" }', lua)
        self.assertIn('[1519] = "Stormwind City"', lua)
        # The neutral record carries no faction line at all.
        self.assertEqual(lua.count("faction ="), 1)

    def test_only_cited_zones_reach_the_name_table(self):
        record = _record(spell_id=1, source_zones=(1519,))
        lua = emit_lua([record], {}, {}, "1", 1, "tbc",
                       {1519: "Stormwind City", 1637: "Orgrimmar"})
        self.assertIn('[1519] = "Stormwind City"', lua)
        self.assertNotIn("Orgrimmar", lua)


if __name__ == "__main__":
    unittest.main()
