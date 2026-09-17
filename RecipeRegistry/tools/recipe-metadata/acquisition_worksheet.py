"""Worksheet for the recipes no bulk source places.

Two commands, either side of a person and a browser:

    emit   -- list what is still unplaced, with the page to open for each
    apply  -- read the filled sheet back into a snapshot the pipeline uses

The sheet is regenerated in place and never overwrites a row that has been
filled in, so it can be re-emitted after an ARL refetch: rows the refetch
answered drop off the bottom, rows already answered by hand stay.

Rows are banded by how much the answer is worth. The Missing recipes tab asks
what a character can still go and learn, so a TBC recipe with a real skill
requirement is the one a player will actually stand in front of; a vanilla
recipe with no skill requirement is usually a discovery or a quest reward,
where the obtain side is often not a place at all.

    1  TBC, has a skill requirement
    2  TBC, no skill requirement
    3  vanilla, has a skill requirement
    4  vanilla, no skill requirement

Filling a row means writing `kind`, and optionally `faction`, `names` and
`zones`. Names and zones hold several values separated by a pipe. Everything
else in the row is context, regenerated on every emit.
"""

import argparse
import csv
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from recipe_sources.arl_source_provider import load_acquisition
from recipe_sources.removed_recipes import load_removed
from recipe_sources.manual_acquisition import (
    KINDS,
    FACTIONS,
    build_entry,
    build_snapshot,
    load_manual_acquisition,
    validate_entry,
    write_snapshot,
)

REPO_ROOT = SCRIPT_DIR.parents[1]
SNAPSHOT_DIR = SCRIPT_DIR / "snapshots" / "tbc-2.5.5"
WORKSHEET_PATH = SCRIPT_DIR / "remediation" / "acquisition_worksheet.csv"
LINKS_PATH = REPO_ROOT / "artifacts" / "recipe-metadata" / "acquisition_links.txt"

# Wowhead is fine to read; it is automated fetching their terms refuse, and a
# 403 has stood since the crawl was cut off. These links are for a person to
# open.
ITEM_URL = "https://www.wowhead.com/tbc/item={0}"
SPELL_URL = "https://www.wowhead.com/tbc/spell={0}"

COLUMNS = (
    "priority",
    "spellId",
    "profession",
    "expansion",
    "requiredSkill",
    "recipeItemId",
    "name",
    "kind",
    "faction",
    "names",
    "zones",
    "notes",
    "url",
)

FILLABLE = ("kind", "faction", "names", "zones", "notes")

BAND_TITLES = {
    1: "TBC, with a skill requirement -- what the Missing tab is for",
    2: "TBC, no skill requirement -- often discovery or quest",
    3: "vanilla, with a skill requirement",
    4: "vanilla, no skill requirement",
}


def _load_json(path, default=None):
    path = Path(path)
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _item_names(snapshot_dir):
    rows = _load_json(Path(snapshot_dir) / "item_sparse.json", []) or []
    return {int(row["itemId"]): row.get("name") for row in rows if row.get("itemId")}


def _dataset(snapshot_dir):
    data = _load_json(Path(snapshot_dir) / "recipes.json", {}) or {}
    if isinstance(data, list):
        return data
    return data.get("recipes", [])


def _removed_with_overrides(snapshot_dir):
    """What the generator will treat as removed, not just what the list says.

    The sheet is a completeness tracker, so it has to agree with the data that
    actually ships: a recipe put back by hand belongs on the sheet again, and
    one flagged by hand does not.
    """
    removed = dict(load_removed(snapshot_dir))
    try:
        import generate_recipe_metadata
        overrides = generate_recipe_metadata._load_overrides()
    except Exception:
        return removed
    for spell_id, flagged in (overrides.get("removedBySpellId") or {}).items():
        if flagged is True:
            removed[int(spell_id)] = True
        else:
            removed.pop(int(spell_id), None)
    return removed


def _band(recipe):
    tbc = recipe.get("firstSeenExpansion") == "tbc"
    skilled = bool(recipe.get("requiredSkill"))
    if tbc:
        return 1 if skilled else 2
    return 3 if skilled else 4


def _unplaced(snapshot_dir):
    """Recipes the pipeline still cannot place.

    Two ways to be unplaced: no ARL record at all, or a record that states a
    faction but never says where the recipe comes from. Both read the same to
    a player, so both belong on the sheet.

    Recipes that are not in the game are not on it. Their having no source is
    the expected outcome and not a gap -- it is, in fact, how the removed list
    identifies them in the first place.
    """
    arl = load_acquisition(snapshot_dir)
    manual = load_manual_acquisition(snapshot_dir)
    removed = _removed_with_overrides(snapshot_dir)
    rows = []
    for recipe in _dataset(snapshot_dir):
        spell_id = int(recipe["spellId"])
        if spell_id in removed:
            continue
        record = manual.get(spell_id) or arl.get(spell_id)
        if _is_answered(record):
            continue
        rows.append(recipe)
    return rows


# Kinds where the kind alone is a whole answer. You go to your own trainer; a
# world drop has nowhere to go; a discovery happens at your own workbench and
# a world event recipe is only there while the event runs. For a vendor or a
# creature, though, "sold by somebody somewhere" is not an answer.
KINDS_ANSWERED_BY_KIND_ALONE = ("trainer", "worldDrop", "discovery", "worldEvent", "quest")


def _is_answered(record):
    if not record or not record.get("kind"):
        return False
    if record["kind"] in KINDS_ANSWERED_BY_KIND_ALONE:
        return True
    return bool(record.get("names") or record.get("zones"))


def _existing_rows(path):
    path = Path(path)
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return {
            int(row["spellId"]): row
            for row in csv.DictReader(handle)
            if (row.get("spellId") or "").strip().isdigit()
        }


def _is_filled(row):
    return bool((row.get("kind") or "").strip())


def emit(snapshot_dir=SNAPSHOT_DIR, worksheet_path=WORKSHEET_PATH,
         links_path=LINKS_PATH):
    names = _item_names(snapshot_dir)
    previous = _existing_rows(worksheet_path)

    rows = []
    for recipe in _unplaced(snapshot_dir):
        spell_id = int(recipe["spellId"])
        recipe_item_id = recipe.get("recipeItemId")
        created_item_id = recipe.get("createdItemId")

        # The dataset carries no recipe names -- the addon reads those from
        # the client at runtime -- so the label is the pattern's name where
        # there is a pattern, and what the recipe makes where there is not.
        if recipe_item_id and names.get(int(recipe_item_id)):
            label = names[int(recipe_item_id)]
        elif created_item_id and names.get(int(created_item_id)):
            label = "makes: " + names[int(created_item_id)]
        else:
            label = ""

        url = (ITEM_URL.format(recipe_item_id) if recipe_item_id
               else SPELL_URL.format(spell_id))

        row = {
            "priority": _band(recipe),
            "spellId": spell_id,
            "profession": recipe.get("profession") or "",
            "expansion": recipe.get("firstSeenExpansion") or "",
            "requiredSkill": recipe.get("requiredSkill") or "",
            "recipeItemId": recipe_item_id or "",
            "name": label,
            "kind": "",
            "faction": "",
            "names": "",
            "zones": "",
            "notes": "",
            "url": url,
        }
        # A filled row is the whole point of the file; regenerating the
        # context around it must never cost the answer.
        kept = previous.get(spell_id)
        if kept:
            for column in FILLABLE:
                row[column] = (kept.get(column) or "").strip()
        rows.append(row)

    rows.sort(key=lambda row: (row["priority"], row["profession"],
                               row["requiredSkill"] or 0, row["spellId"]))

    worksheet_path = Path(worksheet_path)
    worksheet_path.parent.mkdir(parents=True, exist_ok=True)
    with worksheet_path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(rows)

    links_path = Path(links_path)
    links_path.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for band in sorted(BAND_TITLES):
        band_rows = [row for row in rows
                     if row["priority"] == band and not _is_filled(row)]
        if not band_rows:
            continue
        lines.append("# band {0} -- {1} ({2} left)".format(
            band, BAND_TITLES[band], len(band_rows)))
        for row in band_rows:
            lines.append("{0}\t{1}\t{2}".format(
                row["spellId"], row["name"] or "?", row["url"]))
        lines.append("")
    links_path.write_text("\n".join(lines), encoding="utf-8")

    filled = sum(1 for row in rows if _is_filled(row))
    print("worksheet: {0}".format(worksheet_path))
    print("links:     {0}".format(links_path))
    print("{0} rows, {1} filled, {2} to go".format(
        len(rows), filled, len(rows) - filled))
    for band in sorted(BAND_TITLES):
        band_rows = [row for row in rows if row["priority"] == band]
        if band_rows:
            done = sum(1 for row in band_rows if _is_filled(row))
            print("  band {0}: {1:>3} rows, {2} filled  -- {3}".format(
                band, len(band_rows), done, BAND_TITLES[band]))
    return rows


BROWSER_NOTE = "read from the item page"

# What a Wowhead source kind means in this project's vocabulary. A container
# is not a kind we model: the recipe is inside something that itself drops, so
# it reads as a drop.
BROWSER_KINDS = {"vendor": "vendor", "drop": "drop", "container": "drop"}


def fill_from_browser(count=None, band=None, batch=20, headless=False, port=9222,
                      snapshot_dir=SNAPSHOT_DIR, worksheet_path=WORKSHEET_PATH,
                      links_path=LINKS_PATH):
    """Open the unanswered item pages in a browser and read the answers back.

    The parser is the one already written for the item pages; only the way the
    page arrives is different, which is the whole reason this exists. Answers
    land in the sheet rather than straight in the snapshot, so they can be
    looked over before they become data -- and rows the page has nothing to say
    about stay empty, because Wowhead not knowing is a real outcome and not a
    failure to record.
    """
    from recipe_sources.browser_bridge import Browser
    from recipe_sources.wowhead_source_provider import (
        BrowserPageFetcher, parse_item_sources, summarize_item)

    zones_by_id = (_load_json(Path(snapshot_dir) / "sources.json", {}) or {}).get("zonesById", {})

    rows = [row for row in _existing_rows(worksheet_path).values()
            if not _is_filled(row) and row.get("recipeItemId")]
    if band:
        rows = [row for row in rows if row.get("priority") == str(band)]
    rows.sort(key=lambda row: (row.get("priority") or "9", int(row["spellId"])))
    if count:
        rows = rows[:count]
    if not rows:
        print("nothing left to read")
        return 0

    by_item = {int(row["recipeItemId"]): row for row in rows}
    answered, silent = 0, []
    with Browser(headless=headless, port=port) as browser:
        fetch = BrowserPageFetcher(browser, list(by_item), batch=batch,
                                   progress=lambda text: print("  " + text))
        for item_id, row in by_item.items():
            try:
                summary = summarize_item(parse_item_sources(fetch(item_id)))
            except Exception as error:
                print("  {0}: {1}".format(item_id, error))
                continue

            kind = next((BROWSER_KINDS[k] for k in summary["kinds"]
                         if k in BROWSER_KINDS), None)
            if not kind:
                # The page carries no obtain-side listview at all. Recorded as
                # nothing rather than guessed at.
                silent.append(row)
                continue

            # Name and zone must line up: apply pairs them by position, and
            # each entry on the page carries its own zone.
            names, zones = [], []
            for entry in (summary["vendors"] if kind == "vendor" else summary["drops"]):
                if not entry.get("name"):
                    continue
                zone_ids = entry.get("zones") or []
                zone = None
                for zone_id in zone_ids:
                    zone = zones_by_id.get(str(zone_id)) or zones_by_id.get(zone_id)
                    if zone:
                        break
                names.append(entry["name"])
                zones.append(zone or "")
            row["kind"] = kind
            row["faction"] = summary["faction"]
            row["names"] = "|".join(names[:3])
            row["zones"] = "|".join(zones[:3])
            row["notes"] = BROWSER_NOTE
            answered += 1

    _write_worksheet(list(_existing_rows(worksheet_path).values()),
                     {int(r["spellId"]): r for r in rows}, worksheet_path)
    print("\n{0} of {1} answered; {2} pages list no source at all".format(
        answered, len(rows), len(silent)))
    for row in silent:
        print("  {0:>6}  {1}".format(row["spellId"], row["name"] or "?"))
    print("\nlook the sheet over, then: python acquisition_worksheet.py apply")
    return 0


def _write_worksheet(all_rows, updated, worksheet_path):
    """Rewrite the sheet, taking the answered columns from `updated`."""
    for row in all_rows:
        fresh = updated.get(int(row["spellId"]))
        if fresh:
            for column in FILLABLE:
                row[column] = fresh.get(column) or ""
    all_rows.sort(key=lambda row: (row["priority"], row["profession"],
                                   row["requiredSkill"] or "0", int(row["spellId"])))
    with Path(worksheet_path).open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows({column: row.get(column, "") for column in COLUMNS}
                         for row in all_rows)


def open_tabs(count=25, band=None, snapshot_dir=SNAPSHOT_DIR,
              worksheet_path=WORKSHEET_PATH):
    """Open the next unanswered pages in the browser, for reading by hand.

    The companion to `fill_from_browser`, for the rows it leaves empty: the
    page had no obtain-side listview, so whatever answer exists is in prose
    somewhere on it, and a person has to look.
    """
    import webbrowser

    rows = [row for row in _existing_rows(worksheet_path).values()
            if not _is_filled(row)]
    if band:
        rows = [row for row in rows if row.get("priority") == str(band)]
    rows.sort(key=lambda row: (row.get("priority") or "9", int(row["spellId"])))
    batch = rows[:count]
    if not batch:
        print("nothing left to open" + (" in band {0}".format(band) if band else ""))
        return 0

    for row in batch:
        webbrowser.open_new_tab(row["url"])
    print("opened {0} tabs; {1} unanswered rows left".format(len(batch), len(rows)))
    for row in batch:
        print("  {0:>6}  {1}".format(row["spellId"], row["name"] or "?"))
    return 0


def _split_list(value):
    return [part.strip() for part in (value or "").split("|") if part.strip()]


def apply(snapshot_dir=SNAPSHOT_DIR, worksheet_path=WORKSHEET_PATH):
    rows = _existing_rows(worksheet_path)
    if not rows:
        print("no worksheet at {0}; run emit first".format(worksheet_path),
              file=sys.stderr)
        return 1

    by_spell_id = dict(load_manual_acquisition(snapshot_dir))
    problems = []
    added = 0
    for spell_id, row in sorted(rows.items()):
        if not _is_filled(row):
            continue
        entry = build_entry(
            kind=(row.get("kind") or "").strip(),
            faction=(row.get("faction") or "both").strip() or "both",
            names=_split_list(row.get("names")),
            zones=_split_list(row.get("zones")),
        )
        complaints = validate_entry(spell_id, entry)
        problems.extend(complaints)
        if any("is not one of" in complaint for complaint in complaints):
            continue
        by_spell_id[spell_id] = entry
        added += 1

    for complaint in problems:
        print("  " + complaint, file=sys.stderr)
    if any("is not one of" in complaint for complaint in problems):
        print("refusing to write: fix the rows above "
              "(kind is one of {0}; faction is one of {1})".format(
                  ", ".join(KINDS), ", ".join(FACTIONS)), file=sys.stderr)
        return 1

    path = write_snapshot(build_snapshot(by_spell_id), snapshot_dir)
    print("wrote {0}".format(path))
    print("{0} hand-verified records ({1} from this sheet)".format(
        len(by_spell_id), added))
    print("then run: python generate_recipe_metadata.py generate")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Acquisition worksheet.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("emit", help="regenerate the worksheet and the link list")
    opener = sub.add_parser("open", help="open the next unanswered pages in the browser")
    opener.add_argument("--count", type=int, default=25,
                        help="how many tabs to open at once (default 25)")
    opener.add_argument("--band", type=int, choices=(1, 2, 3, 4),
                        help="restrict to one priority band")

    reader = sub.add_parser(
        "fill", help="open the pages in a browser and read the answers into the sheet")
    reader.add_argument("--count", type=int, help="stop after this many rows")
    reader.add_argument("--band", type=int, choices=(1, 2, 3, 4),
                        help="restrict to one priority band")
    reader.add_argument("--batch", type=int, default=20,
                        help="tabs open at once (default 20)")
    reader.add_argument("--headless", action="store_true",
                        help="do not show the browser window")
    reader.add_argument("--port", type=int, default=9222,
                        help="devtools port (default 9222)")

    sub.add_parser("apply", help="read the filled worksheet into the snapshot")
    args = parser.parse_args(argv)

    if args.command == "emit":
        emit()
        return 0
    if args.command == "open":
        return open_tabs(count=args.count, band=args.band)
    if args.command == "fill":
        return fill_from_browser(count=args.count, band=args.band, batch=args.batch,
                                 headless=args.headless, port=args.port)
    return apply()


if __name__ == "__main__":
    raise SystemExit(main())
