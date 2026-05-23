import tempfile
import unittest
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
from recipe_pipeline.records import RecipeRecord
from recipe_pipeline.validate import validate_records
from recipe_sources.local_snapshot_provider import load_local_snapshot


def load_default_records():
    primary, secondary = load_local_snapshot(ROOT / "snapshots")
    taxonomies = load_taxonomies(ROOT / "remediation" / "taxonomy")
    records, diagnostics = normalize_records(primary, secondary, taxonomies, {})
    return primary, records, diagnostics


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
        primary, secondary = load_local_snapshot(ROOT / "snapshots")
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


if __name__ == "__main__":
    unittest.main()
