"""Wowhead importer for where a recipe is obtained: faction and zones.

Why a second Wowhead source: neither DB2 nor the profession spell listview
knows this. The Wago snapshot models what a recipe *is*, not where it comes
from -- the snapshot manifest says alternate teaching sources are
deliberately not modelled -- and the profession page listview carries only a
coarse `source` type array (a key census of the blacksmithing page shows no
`reqrace` and no `sourcemore` on any row).

The data lives on the individual item page of the recipe item, in its
`new Listview({...})` blobs:

    id=sold-by      template=npc
      {"id":1286,"name":"Edna Mullby","location":[1519],"react":[1,null],
       "tag":"Trade Supplies","cost":[[1425]]}

    id=dropped-by   template=npc
      {"id":36,"name":"Harvest Golem","location":[40,0],"react":[-1,-1],
       "count":6,"outof":29282}

    id=contained-in-object  template=object
      {"id":2847,"name":"Tattered Chest","location":[3433]}

Three fields carry the answer:

* `react` is the NPC's reaction to [Alliance, Horde]. A vendor with
  `[1, null]` is friendly to Alliance and does not exist for Horde, which is
  what "Alliance-only recipe" actually means in TBC: the item itself carries
  no race restriction, it is simply sold by one faction's quartermaster.
* `location` is an array of zone IDs; names come from the zone index, which
  is a handful of extra requests rather than one per zone. The same index
  says which of those zones are instances.
* `classification` is 3 for a boss. Inside an instance that is the whole
  difference between "drops from Nightbane", which is worth printing, and
  "drops off trash in Karazhan", where naming twenty creatures answers
  nothing.

Cost: one request per recipe item, and 1436 of the 2150 catalogued recipes
have one. That is why the snapshot is the cache -- a rerun fetches only the
items it does not already hold, so an interrupted fetch resumes instead of
starting over.
"""

import json
import re
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


WOWHEAD_BASE_URL = "https://www.wowhead.com"
DEFAULT_FLAVOR = "tbc"
# Per-worker spacing, not per-run: with a few workers the delay still
# keeps the request rate civil while turning an hour-long serial crawl
# into minutes.
DEFAULT_REQUEST_DELAY = 1.5
DEFAULT_WORKERS = 4
DEFAULT_USER_AGENT = "RecipeRegistry metadata importer"
SNAPSHOT_FILENAME = "sources.json"
# Bumped whenever the parser starts extracting a field the stored rows lack,
# so a resume refetches instead of serving a half-populated payload.
PARSER_VERSION = 2

# Zone index pages. The root listing carries the cities and instances, the
# continent pages carry the open world, and between them every zone a TBC
# recipe source can sit in is covered. A zone ID that still fails to resolve
# is kept as a number in the payload, so a gap is visible rather than
# silently dropped.
ZONE_INDEX_SLUGS = (
    "",
    "eastern-kingdoms",
    "kalimdor",
    "outland",
)

FACTION_ALLIANCE = "alliance"
FACTION_HORDE = "horde"
FACTION_BOTH = "both"

_LISTVIEW_RE = re.compile(r"new Listview\(\{")
_TEMPLATE_RE = re.compile(r"template:\s*'([^']*)'")
_ID_RE = re.compile(r"id:\s*'([^']*)'")


def _listview_blocks(html):
    """Yield (listview id, raw data text) for every Listview on the page.

    The blobs are not valid JSON -- some keys are unquoted -- so the data
    array is located by brace matching and the rows are scanned field by
    field, the same way the specialization importer does it.
    """
    for match in _LISTVIEW_RE.finditer(html or ""):
        head = html[match.end():match.end() + 600]
        template = _TEMPLATE_RE.search(head)
        listview_id = _ID_RE.search(head)
        data_start = html.find("data:", match.end())
        if data_start == -1:
            continue
        depth = 0
        start = None
        end = None
        for index in range(data_start, len(html)):
            char = html[index]
            if char == "[":
                if depth == 0:
                    start = index
                depth += 1
            elif char == "]":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
            elif char == ";" and depth == 0:
                break
        if start is None or end is None:
            continue
        yield (
            listview_id.group(1) if listview_id else "",
            template.group(1) if template else "",
            html[start:end],
        )


_JSON_LISTVIEWS_RE = re.compile(
    r'<script type="application/json" id="data\.page\.listPage\.listviews">(.*?)</script>',
    re.DOTALL,
)


def json_listviews(html):
    """Listviews from the JSON script tag the list pages use.

    Item pages inline `new Listview({...})` with unquoted keys; the list
    pages (zones, item categories) instead ship a proper JSON blob in a
    script tag. Same rows, two embeddings, so both have to be read.
    """
    match = _JSON_LISTVIEWS_RE.search(html or "")
    if not match:
        return []
    try:
        return json.loads(match.group(1))
    except ValueError:
        return []


def _rows(data_text):
    """Split a listview data array into its top-level row objects."""
    out = []
    depth = 0
    start = None
    for index, char in enumerate(data_text):
        if char == "{":
            if depth == 0:
                start = index
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0 and start is not None:
                out.append(data_text[start:index + 1])
                start = None
    return out


_ROW_ID_RE = re.compile(r'"id":(\d+)')
_ROW_NAME_RE = re.compile(r'"name":"((?:[^"\\]|\\.)*)"')
_ROW_TAG_RE = re.compile(r'"tag":"((?:[^"\\]|\\.)*)"')
_ROW_LOCATION_RE = re.compile(r'"location":\[([^\]]*)\]')
_ROW_REACT_RE = re.compile(r'"react":\[([^\]]*)\]')
_ROW_CLASSIFICATION_RE = re.compile(r'"classification":(-?\d+)')
# Wowhead NPC classification: 0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare.
BOSS_CLASSIFICATION = 3


def _ints(text):
    out = []
    for part in (text or "").split(","):
        part = part.strip()
        if part and part.lstrip("-").isdigit():
            out.append(int(part))
    return out


def _react(text):
    """Parse a react pair into (alliance, horde) booleans.

    `null` means the NPC does not exist for that faction; a negative value
    means hostile. Either way the faction cannot buy from them.
    """
    parts = [p.strip() for p in (text or "").split(",")]
    while len(parts) < 2:
        parts.append("null")

    def usable(value):
        if value in ("null", "", "undefined"):
            return False
        try:
            return int(value) > 0
        except ValueError:
            return False

    return usable(parts[0]), usable(parts[1])


def _parse_npc_row(row):
    id_match = _ROW_ID_RE.search(row)
    if not id_match:
        return None
    name_match = _ROW_NAME_RE.search(row)
    tag_match = _ROW_TAG_RE.search(row)
    location_match = _ROW_LOCATION_RE.search(row)
    react_match = _ROW_REACT_RE.search(row)
    classification_match = _ROW_CLASSIFICATION_RE.search(row)
    alliance, horde = _react(react_match.group(1) if react_match else None)
    # Zone 0 is Wowhead's "no zone" filler and carries no information.
    zones = [zone for zone in _ints(location_match.group(1) if location_match else "") if zone > 0]
    return {
        "id": int(id_match.group(1)),
        "name": (name_match.group(1) if name_match else "").replace('\\"', '"'),
        "tag": tag_match.group(1) if tag_match else None,
        "zones": zones,
        "alliance": alliance,
        "horde": horde,
        "boss": bool(classification_match) and int(classification_match.group(1)) == BOSS_CLASSIFICATION,
    }


def parse_item_sources(html):
    """Pull the obtain-side listviews off one recipe item page."""
    vendors, drops, containers = [], [], []
    for listview_id, _template, data_text in _listview_blocks(html or ""):
        if listview_id not in ("sold-by", "dropped-by", "contained-in-object", "contained-in-item"):
            continue
        for row in _rows(data_text):
            parsed = _parse_npc_row(row)
            if not parsed:
                continue
            if listview_id == "sold-by":
                vendors.append(parsed)
            elif listview_id == "dropped-by":
                drops.append(parsed)
            else:
                containers.append(parsed)
    return {"vendors": vendors, "drops": drops, "containers": containers}


def derive_faction(parsed):
    """Which faction can actually obtain the recipe.

    Only vendors carry a usable signal: a drop is hostile to everyone, so its
    react pair says nothing about who may loot it. A recipe that drops or sits
    in a container is therefore available to both sides regardless of which
    vendors also sell it.
    """
    if parsed["drops"] or parsed["containers"]:
        return FACTION_BOTH
    vendors = parsed["vendors"]
    if not vendors:
        return FACTION_BOTH
    alliance = any(vendor["alliance"] for vendor in vendors)
    horde = any(vendor["horde"] for vendor in vendors)
    if alliance and horde:
        return FACTION_BOTH
    if alliance:
        return FACTION_ALLIANCE
    if horde:
        return FACTION_HORDE
    # No vendor is usable by either side: nothing learned, so claim nothing.
    return FACTION_BOTH


def summarize_item(parsed, instance_zones=()):
    instance_zones = set(instance_zones or ())
    zones = set()
    kinds = []
    for bucket, kind in (("vendors", "vendor"), ("drops", "drop"), ("containers", "container")):
        rows = parsed[bucket]
        if rows:
            kinds.append(kind)
        for row in rows:
            zones.update(row["zones"])

    def brief(rows, mark_boss=False):
        out = []
        for row in sorted(rows, key=lambda item: (item["name"], item["id"])):
            entry = {"name": row["name"], "zones": sorted(row["zones"])}
            if mark_boss and row.get("boss"):
                entry["boss"] = True
            if any(zone in instance_zones for zone in row["zones"]):
                entry["instance"] = True
            out.append(entry)
        return out

    return {
        "faction": derive_faction(parsed),
        "kinds": kinds,
        "zones": sorted(zones),
        "vendors": brief(parsed["vendors"]),
        "drops": brief(parsed["drops"], mark_boss=True),
        "containers": brief(parsed["containers"]),
    }


def fetch_item_page(item_id, flavor=DEFAULT_FLAVOR, timeout=90, user_agent=DEFAULT_USER_AGENT):
    url = "{0}/{1}/item={2}".format(WOWHEAD_BASE_URL, flavor, item_id)
    request = Request(url, headers={"User-Agent": user_agent})
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def fetch_zone_index(flavor=DEFAULT_FLAVOR, slugs=ZONE_INDEX_SLUGS, timeout=90,
                     delay=DEFAULT_REQUEST_DELAY, fetch_page=None):
    """Zone ID to name, plus the set of zone IDs that are instances.

    The listing rows carry `instance` (0 for the open world) which is what
    separates a dungeon or raid drop from a world drop.
    """
    def default_fetch(slug):
        url = "{0}/{1}/zones".format(WOWHEAD_BASE_URL, flavor)
        if slug:
            url = "{0}/{1}".format(url, slug)
        request = Request(url, headers={"User-Agent": DEFAULT_USER_AGENT})
        with urlopen(request, timeout=timeout) as response:
            return response.read().decode("utf-8", "replace")

    fetch_page = fetch_page or default_fetch
    zones = {}
    instances = set()
    for index, slug in enumerate(slugs):
        if index and delay:
            time.sleep(delay)
        try:
            html = fetch_page(slug)
        except HTTPError:
            continue
        for listview in json_listviews(html):
            if listview.get("template") != "zone" and listview.get("id") != "zones":
                continue
            for row in listview.get("data") or []:
                zone_id = row.get("id")
                name = row.get("name")
                if isinstance(zone_id, int) and zone_id > 0 and name:
                    zones.setdefault(zone_id, name)
                    if row.get("instance"):
                        instances.add(zone_id)
    return zones, sorted(instances)


class FetchOutcome(object):
    """What a run actually managed, so a blocked crawl cannot look like a
    successful one.

    The first version of this swallowed every failed page and returned the
    handful that worked, so a run that Wowhead answered with 403 on 1396 of
    1436 items still exited zero and printed a cheerful count.
    """

    def __init__(self, attempted, succeeded, failures):
        self.attempted = attempted
        self.succeeded = succeeded
        self.failures = failures

    @property
    def failed(self):
        return sum(self.failures.values())

    def describe(self):
        if not self.failures:
            return "{0}/{1} fetched".format(self.succeeded, self.attempted)
        breakdown = ", ".join(
            "{0}x{1}".format(count, reason)
            for reason, count in sorted(self.failures.items(), key=lambda kv: -kv[1])
        )
        return "{0}/{1} fetched, {2} failed ({3})".format(
            self.succeeded, self.attempted, self.failed, breakdown
        )

    def mostly_failed(self, threshold=0.2):
        """True when so little got through that the run is not worth
        reporting as a success."""
        if not self.attempted:
            return False
        return self.succeeded < self.attempted * threshold


def load_snapshot(snapshot_dir):
    path = Path(snapshot_dir) / SNAPSHOT_FILENAME
    if not path.exists():
        return {"zonesById": {}, "sourcesByRecipeItemId": {}}
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_snapshot(payload, snapshot_dir):
    path = Path(snapshot_dir) / SNAPSHOT_FILENAME
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def build_snapshot(sources_by_item, zones_by_id, instance_zone_ids=(), flavor=DEFAULT_FLAVOR):
    """Deterministic payload: no timestamps, so a refetch that learns nothing
    produces a byte-identical file and an empty diff."""
    faction_counts = {}
    for entry in sources_by_item.values():
        faction = entry.get("faction", FACTION_BOTH)
        faction_counts[faction] = faction_counts.get(faction, 0) + 1
    return {
        "source": "wowhead-item-pages",
        "parserVersion": PARSER_VERSION,
        "flavor": flavor,
        "sourceStats": {
            "records": len(sources_by_item),
            "zones": len(zones_by_id),
            "byFaction": dict(sorted(faction_counts.items())),
        },
        "instanceZoneIds": sorted(instance_zone_ids),
        "zonesById": {str(zone_id): name for zone_id, name in sorted(zones_by_id.items())},
        "sourcesByRecipeItemId": {
            str(item_id): entry for item_id, entry in sorted(sources_by_item.items())
        },
    }


def fetch_sources(recipe_item_ids, snapshot_dir, flavor=DEFAULT_FLAVOR, timeout=90,
                  delay=DEFAULT_REQUEST_DELAY, fetch_page=fetch_item_page,
                  zone_fetcher=None, limit=None, progress=None, save_every=50,
                  workers=DEFAULT_WORKERS):
    """Fetch the item pages we do not already hold, and fold them in.

    One request per recipe item is unavoidable: no bulk listing carries the
    obtain-side detail (see the module docstring), so the two levers on a
    1436-item run are caching and concurrency. The snapshot is the cache --
    an item already in it is never refetched and the file is rewritten as the
    run goes, so an interrupt keeps everything learned so far. `workers`
    fetches a few pages at a time, with `delay` spacing the requests each
    worker makes rather than the run as a whole.
    """
    existing = load_snapshot(snapshot_dir)
    # A snapshot written by an older parser lacks fields the current one
    # extracts, and the resume logic would keep those rows forever because it
    # only ever fetches items it does not already hold. Discard the lot rather
    # than serve a silently mixed payload.
    if existing.get("parserVersion") != PARSER_VERSION:
        existing = {}
    sources = {int(k): v for k, v in existing.get("sourcesByRecipeItemId", {}).items()}
    zones = {int(k): v for k, v in existing.get("zonesById", {}).items()}
    instance_zones = set(existing.get("instanceZoneIds") or ())

    if not zones:
        if zone_fetcher is not None:
            zones, instance_zone_list = zone_fetcher()
        else:
            zones, instance_zone_list = fetch_zone_index(flavor=flavor, timeout=timeout, delay=delay)
        instance_zones = set(instance_zone_list)

    pending = [item_id for item_id in sorted(set(recipe_item_ids)) if item_id not in sources]
    if limit is not None:
        pending = pending[:limit]

    def work(item_id):
        if delay:
            time.sleep(delay)
        try:
            html = fetch_page(item_id, flavor=flavor, timeout=timeout)
        except HTTPError as error:
            # A missing page is a fact about the item, not a failure of the
            # run: record nothing and move on rather than retrying forever.
            return item_id, None, "http {0}".format(error.code)
        except (URLError, OSError) as error:
            return item_id, None, "network {0}".format(error)
        return item_id, summarize_item(parse_item_sources(html), instance_zones), None

    done = 0
    failures = {}

    def record_failure(note):
        key = (note or "unknown").split(" ")[0]
        failures[key] = failures.get(key, 0) + 1

    if workers and workers > 1:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for item_id, summary, error in pool.map(work, pending):
                done += 1
                if summary is not None:
                    sources[item_id] = summary
                else:
                    record_failure(error)
                if progress:
                    progress(item_id, done, len(pending), error or summary["faction"])
                if save_every and done % save_every == 0:
                    write_snapshot(build_snapshot(sources, zones, instance_zones, flavor=flavor), snapshot_dir)
    else:
        for item_id in pending:
            item_id, summary, error = work(item_id)
            done += 1
            if summary is not None:
                sources[item_id] = summary
            else:
                record_failure(error)
            if progress:
                progress(item_id, done, len(pending), error or summary["faction"])
            if save_every and done % save_every == 0:
                write_snapshot(build_snapshot(sources, zones, instance_zones, flavor=flavor), snapshot_dir)

    return sources, zones, instance_zones, FetchOutcome(len(pending), done - sum(failures.values()), failures)

def load_sources(snapshot_dir):
    """Read the committed snapshot; an absent file means "not fetched yet",
    not an error, so the pipeline keeps working without it."""
    data = load_snapshot(snapshot_dir)
    zones = {int(k): v for k, v in data.get("zonesById", {}).items()}
    sources = {int(k): v for k, v in data.get("sourcesByRecipeItemId", {}).items()}
    return sources, zones
