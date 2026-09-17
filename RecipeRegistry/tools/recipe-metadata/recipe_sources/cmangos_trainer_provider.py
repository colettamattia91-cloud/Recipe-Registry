"""Which trainer teaches a recipe, from the cmangos Burning Crusade world DB.

AckisRecipeList records that *a* trainer teaches a recipe and never which one:
all 770 trainer-taught recipes in this dataset carry an empty NPC list, and its
Trainer.lua is 376 lines of mostly Wrath-era entries. So the label read "any
trainer", which is a promise the source never made -- a recipe requiring 350
engineering is not taught by the trainer in Ironforge, whatever your skill.

An emulator cannot run without knowing exactly which NPC teaches what, so
cmangos models it properly: `npc_trainer_template` maps a template to its
spells, and `creature_template.TrainerTemplateId` maps the NPCs to the template.
714 of our 770 resolve.

What is emitted is the trainer's TITLE, not the names. Where every trainer of a
recipe shares one -- "Master Engineering Trainer" -- that title is the whole
answer, and it is better than five names: it is what the player reads under the
NPC in the world, and there are five Master Engineering Trainers scattered
across Outland. Where several titles teach the same recipe, no title is
emitted: those are the recipes any trainer of the profession really does teach,
and "from a trainer" is the honest answer rather than a surrender.

The continent comes from `creature.map`, a three-entry mapping and not a guess.
Zones do not: cmangos has no zone column, only a map id and world coordinates,
which is exactly why it was rejected as a source for vendors. A trainer title
does not need one.

Caveats worth keeping in view: cmangos reconstructs 2.4.3 while this addon
targets 2.5.x, and it is a community reconstruction rather than Blizzard data.
"""

import json
import sqlite3
import zipfile
from collections import defaultdict
from pathlib import Path
from urllib.request import Request, urlopen

RELEASE_API = "https://api.github.com/repos/cmangos/tbc-db/releases/latest"
SQLITE_ASSET = "tbc-sqlite-db.zip"
WORLD_DB = "tbcmangos.sqlite"
DEFAULT_USER_AGENT = "RecipeRegistry metadata importer"

# creature.map -> where a player would say they are going. Outland is one
# continent in the client's own terms, and a trainer title plus a continent is
# a destination; a list of five zones is a research task.
CONTINENT_BY_MAP = {
    0: "Eastern Kingdoms",
    1: "Kalimdor",
    530: "Outland",
}


def _download(url, destination, timeout=300, user_agent=DEFAULT_USER_AGENT):
    request = Request(url, headers={"User-Agent": user_agent})
    with urlopen(request, timeout=timeout) as response:
        destination.write_bytes(response.read())
    return destination


def fetch_world_db(work_dir, timeout=300, user_agent=DEFAULT_USER_AGENT):
    """Download and unpack the world DB, returning the path to the sqlite file.

    An already-unpacked copy is reused: the archive is 100MB and nothing in it
    changes between two runs of this importer.
    """
    work_dir = Path(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    unpacked = work_dir / WORLD_DB
    if unpacked.exists():
        return unpacked

    archive = work_dir / SQLITE_ASSET
    if not archive.exists():
        request = Request(RELEASE_API, headers={"User-Agent": user_agent})
        with urlopen(request, timeout=timeout) as response:
            release = json.loads(response.read().decode("utf-8"))
        url = None
        for asset in release.get("assets", ()):
            if asset.get("name") == SQLITE_ASSET:
                url = asset.get("browser_download_url")
                break
        if not url:
            raise RuntimeError("no {0} in the cmangos tbc-db release".format(SQLITE_ASSET))
        _download(url, archive, timeout=timeout, user_agent=user_agent)

    with zipfile.ZipFile(archive) as bundle:
        bundle.extract(WORLD_DB, work_dir)
    return unpacked


def _trainer_entries_by_spell(connection):
    """Every NPC that teaches each spell, through templates and directly."""
    by_spell = defaultdict(set)

    template_members = defaultdict(list)
    for entry, template in connection.execute(
        "SELECT entry, TrainerTemplateId FROM creature_template WHERE TrainerTemplateId > 0"
    ):
        template_members[template].append(entry)

    for template, spell in connection.execute(
        "SELECT entry, spell FROM npc_trainer_template"
    ):
        for entry in template_members.get(template, ()):
            by_spell[spell].add(entry)

    for entry, spell in connection.execute("SELECT entry, spell FROM npc_trainer"):
        by_spell[spell].add(entry)

    return by_spell


# Two continents read as "the old world"; four read as noise, and the label
# they would produce is longer than the answer it carries.
MAX_CONTINENTS = 2


def _says_more_than_the_kind(title, profession):
    """Whether the title is worth writing instead of "from a trainer".

    "Master Engineering Trainer" and "Goblin Engineering Trainer" are answers.
    A plain "Engineering Trainer" is the same sentence with the profession
    repeated -- and the profession is already the section the row sits under.
    """
    if not title:
        return False
    stem = title[: -len(" Trainer")] if title.endswith(" Trainer") else title
    return stem.strip().lower() != (profession or "").strip().lower()


def build_trainers(world_db_path, professions_by_spell):
    """spell id -> { title, continents }, for the recipes with one title.

    Only recipes whose trainers all carry the same title are answered. A recipe
    several ranks of trainer teach has no single answer to give, and inventing
    one -- naming the highest rank, say -- would say the low-rank trainer will
    not teach it, which is false.
    """
    connection = sqlite3.connect(str(world_db_path))
    try:
        by_spell = _trainer_entries_by_spell(connection)

        titles, names = {}, {}
        for entry, name, subname in connection.execute(
            "SELECT entry, name, subname FROM creature_template"
        ):
            titles[entry] = (subname or "").strip()
            names[entry] = (name or "").strip()

        maps_by_entry = defaultdict(set)
        for entry, map_id in connection.execute("SELECT id, map FROM creature"):
            maps_by_entry[entry].add(map_id)
    finally:
        connection.close()

    out, stats = {}, {"resolved": 0, "unresolved": 0, "manyTitles": 0, "kindOnly": 0}
    for spell_id in sorted(professions_by_spell):
        entries = by_spell.get(spell_id) or by_spell.get(int(spell_id)) or set()
        if not entries:
            stats["unresolved"] += 1
            continue
        stats["resolved"] += 1

        distinct = {titles.get(entry, "") for entry in entries}
        distinct.discard("")
        if len(distinct) != 1:
            stats["manyTitles"] += 1
            continue

        title = next(iter(distinct))
        if not _says_more_than_the_kind(title, professions_by_spell[spell_id]):
            stats["kindOnly"] += 1
            continue

        continents = set()
        for entry in entries:
            for map_id in maps_by_entry.get(entry, ()):
                continent = CONTINENT_BY_MAP.get(map_id)
                if continent:
                    continents.add(continent)
        if len(continents) > MAX_CONTINENTS:
            continents = set()

        out[int(spell_id)] = {
            "title": title,
            "continents": sorted(continents),
        }

    stats["titled"] = len(out)
    return out, stats


def build_snapshot(by_spell_id, stats):
    return {
        "source": {
            "provider": "cmangos-tbc-db",
            "table": "npc_trainer_template + creature_template",
        },
        "sourceStats": stats,
        "trainerBySpellId": {
            str(spell_id): value for spell_id, value in sorted(by_spell_id.items())
        },
    }


def write_snapshot(payload, snapshot_dir):
    path = Path(snapshot_dir) / "trainers.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def load_trainers(snapshot_dir):
    """Read the committed snapshot. An absent file means "not fetched", not an
    error: the pipeline runs without it and the labels fall back."""
    path = Path(snapshot_dir) / "trainers.json"
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    out = {}
    for spell_id, value in data.get("trainerBySpellId", {}).items():
        title = (value or {}).get("title")
        if not title:
            continue
        out[int(spell_id)] = {
            "title": title,
            "continents": tuple((value or {}).get("continents") or ()),
        }
    return out
