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


def load_fixture_snapshot():
    recipes = [
        {"spellId": 2329, "profession": "alchemy", "firstSeenExpansion": "vanilla", "recipeItemId": None, "createdItemId": 2454, "requiredSkill": 1, "categoryHint": "alchemy.potions.combat"},
        {"spellId": 2330, "profession": "alchemy", "firstSeenExpansion": "vanilla", "recipeItemId": None, "createdItemId": 118, "requiredSkill": 1, "categoryHint": "alchemy.potions.healing"},
        {"spellId": 28543, "profession": "alchemy", "firstSeenExpansion": "tbc", "recipeItemId": 22907, "createdItemId": 22823, "requiredSkill": 305, "categoryHint": "alchemy.potions.mana"},
        {"spellId": 28596, "profession": "alchemy", "firstSeenExpansion": "tbc", "recipeItemId": 22900, "createdItemId": 22845, "requiredSkill": 300, "categoryHint": "alchemy.flasks.guardian_elixirs"},
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
        self.assertEqual(by_spell[28596].expansion, "tbc")
        self.assertEqual(by_spell[28596].category_key, "flasks")

    def test_recipe_and_created_item_shapes(self):
        _primary, records, _diagnostics = load_default_records()
        by_spell = {record.spell_id: record for record in records}

        self.assertIsNone(by_spell[2329].recipe_item_id)
        self.assertEqual(by_spell[2329].created_item_id, 2454)
        self.assertEqual(by_spell[28596].recipe_item_id, 22900)
        self.assertEqual(by_spell[28596].created_item_id, 22845)
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
        primary["recipes"] = [dict(primary["recipes"][0], categoryHint="missing.category")]
        primary["reagentsBySpellId"] = {2329: primary["reagentsBySpellId"][2329]}
        taxonomies = load_taxonomies(ROOT / "remediation" / "taxonomy")

        records, diagnostics = normalize_records(primary, secondary, taxonomies, {})

        self.assertEqual(records[0].category_key, "misc")
        self.assertEqual(diagnostics["categoryFallbacks"][0]["spellId"], 2329)

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


if __name__ == "__main__":
    unittest.main()
