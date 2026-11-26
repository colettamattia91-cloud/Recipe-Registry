"""Offline regression tests for Wowhead refusals, recovery and saved pages."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


TOOLS = Path(__file__).resolve().parents[1] / "Tools"
sys.path.insert(0, str(TOOLS))
import wowhead_browser as bridge

spec = importlib.util.spec_from_file_location("scrape_wowhead", TOOLS / "scrape-wowhead.py")
scraper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scraper)

ITEM_URL = scraper.BASE + "/item=2555"
ITEM_HTML = """<html><script>
$.extend(g_items[2555], {"source":[5]});
new Listview({id: 'sold-by', data: [{"id":123,"name":"Test Vendor","location":[12],"react":[1,-1]}]});
</script></html>"""
LIST_HTML = 'var listviewitems = [{"id":2555,"classs":9,"name":"Recipe","source":[5]}];'
SPELL_HTML = ('var listviewspells = [{"id":2335,"name":"Swiftness Potion",'
              '"learnedat":60,"colors":[60,90,110,130],"source":[6]}];')
BLOCK_HTML = '<html><div id="challenge-container">Max challenge attempts exceeded</div></html>'


class PageValidationTests(unittest.TestCase):
    def test_large_error_page_is_not_recipe_data(self):
        html = '<html><title>Access Denied</title>' + 'x' * 20000 + '</html>'
        self.assertFalse(bridge.page_has_data(html, ITEM_URL))
        self.assertIsNotNone(bridge.challenge_reason(html))

    def test_item_requires_its_own_id_and_accepts_small_valid_page(self):
        self.assertTrue(bridge.page_has_data(ITEM_HTML, ITEM_URL))
        self.assertFalse(bridge.page_has_data(ITEM_HTML, scraper.BASE + "/item=2697"))


class BrowserRecoveryTests(unittest.TestCase):
    def browser(self, interactive):
        browser = bridge.Browser.__new__(bridge.Browser)
        browser.interactive = interactive
        browser.verification_timeout = 300.0
        browser._root = object()
        browser._command = mock.Mock(return_value={"targetId": "target"})
        browser._get = mock.Mock(return_value=[{"id": "target", "webSocketDebuggerUrl": "ws://local"}])
        return browser

    def test_manual_verification_resumes_same_tab_without_terminal_input(self):
        browser = self.browser(True)
        browser._evaluate = mock.Mock(side_effect=["complete", BLOCK_HTML, "complete", ITEM_HTML])
        with mock.patch.object(bridge, "WebSocket"), mock.patch.object(bridge.time, "sleep"), \
                mock.patch("builtins.input", side_effect=EOFError) as prompt, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(browser.read(ITEM_URL), ITEM_HTML)
        prompt.assert_not_called()
        methods = [call.args[1] for call in browser._command.call_args_list]
        self.assertEqual(methods, ["Target.createTarget", "Target.closeTarget"])

    def test_unsolved_verification_times_out_and_closes_tab(self):
        browser = self.browser(True)
        browser._evaluate = mock.Mock(side_effect=["complete", BLOCK_HTML] * 2)
        with mock.patch.object(bridge, "WebSocket") as ws, mock.patch.object(bridge.time, "sleep"), \
                mock.patch.object(bridge.time, "monotonic", side_effect=[0, 1, 2, 303]), \
                mock.patch("builtins.input") as prompt, \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(bridge.Refused):
            browser.read(ITEM_URL)
        prompt.assert_not_called()
        ws.return_value.close.assert_called_once()

    def test_noninteractive_run_never_prompts(self):
        browser = self.browser(False)
        browser._evaluate = mock.Mock(side_effect=["complete", BLOCK_HTML])
        with mock.patch.object(bridge, "WebSocket"), mock.patch.object(bridge.time, "sleep"), \
                mock.patch("builtins.input") as prompt, self.assertRaises(bridge.Refused) as error:
            browser.read(ITEM_URL)
        prompt.assert_not_called()
        self.assertEqual(error.exception.html, BLOCK_HTML)

    def test_reloading_page_still_times_out(self):
        browser = self.browser(False)
        browser._evaluate = mock.Mock(side_effect=RuntimeError("execution context destroyed"))
        with mock.patch.object(bridge, "WebSocket"), mock.patch.object(bridge.time, "sleep"), \
                mock.patch.object(bridge.time, "monotonic", side_effect=[0, 61]), \
                self.assertRaises(bridge.Refused):
            browser.read(ITEM_URL)


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.cache = self.folder / "cache.json"
        self.out = self.folder / "recipes.tsv"
        self.trainer = self.folder / "trainer.tsv"
        worksheet = self.folder / "worksheet.tsv"
        worksheet.write_text("spellId\trecipeItemId\tname\tsourceKind\tband\n"
                             "2335\t2555\tSwiftness Potion\t\tforever\n", encoding="utf-8")
        patches = mock.patch.multiple(scraper, CACHE=str(self.cache), OUT=str(self.out),
                                      TRAINER_OUT=str(self.trainer), WORKSHEET=str(worksheet))
        patches.start()
        self.addCleanup(patches.stop)
        self.seed()

    def seed(self, items=None):
        self.cache.write_text(json.dumps({"parser": scraper.PARSER_VERSION,
            "zones": {"12": "Elwynn Forest"}, "instances": [], "lists": {}, "items": items or {}}),
            encoding="utf-8")

    def run_main(self, *args):
        with mock.patch.object(sys, "argv", ["scrape-wowhead.py", *args]), \
                contextlib.redirect_stdout(io.StringIO()):
            scraper.main()

    def test_saved_item_imports_vendor_without_starting_browser(self):
        (self.folder / "item-2555.html").write_text(ITEM_HTML, encoding="utf-8-sig")
        with mock.patch.object(bridge, "Browser") as browser:
            self.run_main("--items", "2555", "--from-html", self.temp.name)
        browser.assert_not_called()
        saved = json.loads(self.cache.read_text(encoding="utf-8"))
        self.assertEqual(saved["items"]["2555"]["vendors"][0]["name"], "Test Vendor")
        self.assertIn("vendor\tTest Vendor\tElwynn Forest\talliance", self.out.read_text(encoding="utf-8"))

    def test_refused_refresh_preserves_existing_recipe_and_export(self):
        old = scraper.parse_item(ITEM_HTML, "2555")
        self.seed({"2555": old})
        (self.folder / "item-2555.html").write_text(BLOCK_HTML, encoding="utf-8")
        self.run_main("--items", "2555", "--from-html", self.temp.name)
        self.assertEqual(json.loads(self.cache.read_text(encoding="utf-8"))["items"]["2555"], old)
        self.assertIn("Test Vendor", self.out.read_text(encoding="utf-8"))

    def test_saved_challenge_is_retryable_refusal_instead_of_empty_item(self):
        (self.folder / "item-2555.html").write_text(BLOCK_HTML, encoding="utf-8")
        self.run_main("--items", "2555", "--from-html", self.temp.name)
        item = json.loads(self.cache.read_text(encoding="utf-8"))["items"]["2555"]
        self.assertIn("refused", item)
        (self.folder / "item-2555.html").write_text(ITEM_HTML, encoding="utf-8")
        self.run_main("--all", "--retry-refused", "--from-html", self.temp.name)
        item = json.loads(self.cache.read_text(encoding="utf-8"))["items"]["2555"]
        self.assertNotIn("refused", item)
        self.assertTrue(item["vendors"])

    def test_missing_saved_page_does_not_poison_cache(self):
        self.run_main("--items", "2555", "--from-html", self.temp.name)
        self.assertEqual(json.loads(self.cache.read_text(encoding="utf-8"))["items"], {})

    def test_refusal_diagnostic_does_not_replace_saved_valid_html(self):
        output = self.folder / "html"
        output.mkdir()
        saved = output / "item-2555.html"
        saved.write_text(ITEM_HTML, encoding="utf-8")
        with mock.patch.object(bridge, "Browser") as factory:
            browser = factory.return_value.__enter__.return_value
            browser.read.side_effect = bridge.Refused("verifica fallita", BLOCK_HTML)
            self.run_main("--items", "2555", "--max-refusals", "1", "--save-html", str(output))
        self.assertEqual(saved.read_text(encoding="utf-8"), ITEM_HTML)
        self.assertEqual((output / "refused-item-2555.html").read_text(encoding="utf-8"), BLOCK_HTML)

    def test_saved_lists_and_spells_import_without_browser(self):
        (self.folder / "list-alchemy.html").write_text(LIST_HTML, encoding="utf-8")
        (self.folder / "spells-alchemy.html").write_text(SPELL_HTML, encoding="utf-8")
        with mock.patch.object(bridge, "Browser") as browser:
            self.run_main("--lists", "alchemy", "--from-html", self.temp.name)
            self.run_main("--spells", "alchemy", "--from-html", self.temp.name)
        browser.assert_not_called()
        saved = json.loads(self.cache.read_text(encoding="utf-8"))
        self.assertIn("2555", saved["lists"])
        self.assertIn("2335", saved["spells"])
        self.assertIn("2335\t60\tSwiftness Potion", self.trainer.read_text(encoding="utf-8"))

    def test_all_network_modes_stop_at_refusal_limit(self):
        for mode in ("--lists", "--spells", "--items"):
            with self.subTest(mode=mode), mock.patch.object(bridge, "Browser") as factory:
                browser = factory.return_value.__enter__.return_value
                browser.read.side_effect = bridge.Refused("verifica fallita")
                values = "2555,2697,2698" if mode == "--items" else "alchemy,cooking,tailoring"
                self.run_main(mode, values, "--max-refusals", "2", "--delay", "0")
                self.assertEqual(browser.read.call_count, 2)

    def test_success_resets_consecutive_refusals(self):
        with mock.patch.object(bridge, "Browser") as factory:
            browser = factory.return_value.__enter__.return_value
            browser.read.side_effect = [bridge.Refused("blocked"), ITEM_HTML, bridge.Refused("blocked")]
            self.run_main("--items", "2697,2555,2698", "--max-refusals", "2", "--delay", "0")
        self.assertEqual(browser.read.call_count, 3)

    def test_missing_input_directory_fails_before_browser_launch(self):
        with mock.patch.object(bridge, "Browser") as browser, \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            self.run_main("--all", "--from-html", os.path.join(self.temp.name, "missing"))
        self.assertEqual(error.exception.code, 2)
        browser.assert_not_called()


class SeveralSourcesTests(unittest.TestCase):
    """Una riga d'elenco con piu' tipi di provenienza: ogni tipo esce (26/11)."""

    def entry(self, source, more, commondrop=False):
        return {"source": source, "sourcemore": more, "commondrop": commondrop}

    def kinds(self, got):
        return [g[0] for g in got]

    def test_parallel_lists_give_every_kind(self):
        # Flask of Distilled Wisdom: un drop a Stratholme e Pix Xizzix.
        got = scraper.summarize_list_all(self.entry([2, 5], [
            {"dd": -1, "z": 2017}, {"n": "Pix Xizzix", "t": 1, "ti": 227853, "z": 33}]),
            {227853: (True, True)})
        self.assertEqual(self.kinds(got), ["vendor", "drop"])
        self.assertEqual(got[0][1][0]["name"], "Pix Xizzix")
        self.assertEqual(got[1][1][0]["zones"], [2017])

    def test_parallel_lists_place_a_plain_mob(self):
        # Raptor Hide Harness: Dragonmaw Centurion non ha dd e non e' un
        # venditore; solo la posizione nella lista dice che e' il drop.
        got = scraper.summarize_list_all(self.entry([2, 5], [
            {"n": "Dragonmaw Centurion", "t": 1, "ti": 1036, "z": 11},
            {"n": "Tunkk", "t": 1, "ti": 2819, "z": 45}]), {2819: (False, True)})
        self.assertEqual(self.kinds(got), ["vendor", "drop"])
        self.assertEqual(got[1][1][0]["name"], "Dragonmaw Centurion")

    def test_shorter_sourcemore_goes_where_it_says(self):
        # Una voce sola per due codici: dd vuol dire istanza, quindi il drop;
        # il venditore resta senza nome e non entra.
        got = scraper.summarize_list_all(self.entry([2, 5], [
            {"dd": -1, "n": "Haunting Phantasm", "t": 1, "ti": 6427, "z": 796}]), {})
        self.assertEqual(self.kinds(got), ["drop"])
        self.assertEqual(got[0][1][0]["name"], "Haunting Phantasm")

    def test_known_vendor_is_a_vendor(self):
        got = scraper.summarize_list_all(self.entry([2, 5], [
            {"n": "Pix Xizzix", "t": 1, "ti": 227853, "z": 33}]), {227853: (False, True)})
        self.assertEqual(self.kinds(got), ["vendor", "drop"])
        self.assertEqual(got[0][2], ["horde"])
        self.assertEqual(got[1][1], [], "the drop names nobody: nobody said who")

    def test_entry_that_cannot_be_placed_is_not_guessed(self):
        # Skeletal Fiend: mob o venditore? Nessun indizio, quindi nessuno dei due.
        got = scraper.summarize_list_all(self.entry([2, 5], [
            {"n": "Skeletal Fiend", "t": 1, "ti": 531, "z": 10}]), {})
        self.assertEqual(self.kinds(got), ["drop"])
        self.assertEqual(got[0][1], [])

    def test_quest_and_vendor(self):
        got = scraper.summarize_list_all(self.entry([4, 5], [
            {"c": 16591, "n": "Step Two: More Rock", "t": 5, "ti": 96026},
            {"n": "Martha Wellsworth", "t": 1, "ti": 259860, "z": 16591}]),
            {259860: (True, True)})
        self.assertEqual(self.kinds(got), ["vendor", "quest"])
        self.assertEqual(got[1][1][0]["zones"], [16591])

    def test_world_drop_stays_alone(self):
        got = scraper.summarize_list_all(self.entry([2], [], commondrop=True), {})
        self.assertEqual(got, [("worldDrop", [], [], "", "true")])

    def test_page_keeps_its_first_source_first(self):
        entry = {"vendors": [{"name": "V", "zones": [1], "alliance": True, "horde": True}],
                 "drops": [], "containers": [],
                 "quests": [{"name": "Q", "zones": [2], "side": 1}]}
        self.assertEqual(scraper.summarize(entry)[0], "vendor")
        self.assertEqual(self.kinds(scraper.summarize_all(entry)), ["vendor", "quest"])


if __name__ == "__main__":
    unittest.main()
