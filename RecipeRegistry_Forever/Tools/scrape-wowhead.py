"""La provenienza delle ricette di Forever, dalle pagine-oggetto di Wowhead.

Wowhead e' la sola fonte che ha visto il contenuto nuovo di Forever: lo sa
perche' migliaia di client glielo caricano. foreverchanges ne legge una parte;
qui si va alla fonte, una pagina per oggetto-ricetta, perche' nessun elenco di
Wowhead porta chi vende e chi droppa (lo stesso misurato su TBC il 01/09).

Ogni pagina-oggetto porta il dato in blocchi `new Listview({...})`:

    id: 'sold-by'      template: 'npc'    {"id":..,"name":..,"location":[zona],"react":[A,H]}
    id: 'dropped-by'   template: 'npc'    {..,"classification":3,"count":..,"outof":..}
    id: 'contained-in-object' / 'contained-in-item'
    id: 'reward-from-q' template: 'quest' {"id":..,"name":..,"side":..,"category":zona}

Si raccoglie tutto in una cache (Tools/dumps/wowhead-cache.json, fuori dal
repo), una voce per oggetto, e si filtra dopo: un filtro in raccolta fa
rispondere "niente" a una fonte che i dati li aveva. Il TSV per il worksheet
(Tools/captures/wowhead-recipes.tsv) si riscrive dalla cache a ogni giro.

Le pagine si leggono da un Chrome vero (wowhead_browser.py), una alla volta,
con una pausa fra l'una e l'altra. Tre rifiuti di fila e il giro si ferma: se
la verifica di Wowhead non passa, insistere non la fa passare e rischia di far
marcare l'indirizzo.

    python RecipeRegistry_Forever/Tools/scrape-wowhead.py --limit 5 --save-html <cartella>
    python RecipeRegistry_Forever/Tools/scrape-wowhead.py --all
    python RecipeRegistry_Forever/Tools/scrape-wowhead.py --report

Con --spells legge invece gli elenchi degli spell di mestiere, uno per
mestiere, e ne fa Tools/captures/wowhead-trainer-skill.tsv: il livello a cui un
trainer insegna ogni ricetta, che il client di Forever non porta (dice 1).
--from-html rilegge le pagine salvate con --save-html, senza rete.

    python RecipeRegistry_Forever/Tools/scrape-wowhead.py --spells all
"""
import argparse, csv, json, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

WORKSHEET = os.path.join(HERE, "acquisition-worksheet.tsv")
CACHE = os.path.join(HERE, "dumps", "wowhead-cache.json")
OUT = os.path.join(HERE, "captures", "wowhead-recipes.tsv")
TRAINER_OUT = os.path.join(HERE, "captures", "wowhead-trainer-skill.tsv")
TRAINER = 6       # `source` di Wowhead per uno spell: 6 = insegnato da un trainer
BASE = "https://www.wowhead.com/forever"
# Si alza quando il parser comincia a estrarre un campo che le voci in cache
# non hanno: la cache vecchia si butta invece di servire righe a meta'.
PARSER_VERSION = 2

COLS = ["spellId", "recipeItemId", "name", "sourceKind", "npcName", "zone",
        "faction", "bossDrop", "worldDrop", "notes"]

LIST_SLUGS = ("alchemy", "blacksmithing", "cooking", "enchanting", "engineering",
              "first-aid", "fishing", "leatherworking", "tailoring")

# Gli elenchi degli spell di mestiere: per ogni ricetta il livello a cui si
# impara e le soglie di difficolta', un mestiere intero in una richiesta. Il
# livello dei trainer e' dato del server -- il client di Forever dice 1 -- e il
# vanilla non regge dove Forever ha abbassato le soglie.
SPELL_LISTS = {
    "alchemy": "professions/alchemy", "blacksmithing": "professions/blacksmithing",
    "enchanting": "professions/enchanting", "engineering": "professions/engineering",
    "leatherworking": "professions/leatherworking", "mining": "professions/mining",
    "tailoring": "professions/tailoring", "herbalism": "professions/herbalism",
    "skinning": "professions/skinning",
    "cooking": "secondary-skills/cooking", "first-aid": "secondary-skills/first-aid",
    "fishing": "secondary-skills/fishing",
}

LISTVIEWS = ("sold-by", "dropped-by", "contained-in-object", "contained-in-item", "reward-from-q")
BOSS = 3          # classification di Wowhead: 0 normale, 1 elite, 2 rare elite, 3 boss, 4 rare
# Oltre queste soglie un drop non e' un posto dove andare, e' un world drop:
# mandare il giocatore dal primo di trenta mob sarebbe una bugia comoda.
WORLD_DROP_CREATURES = 8
WORLD_DROP_ZONES = 4


# -- lettura delle pagine ----------------------------------------------------

def listview_blocks(html):
    """(id, testo dell'array data) per ogni Listview della pagina.

    I blob non sono JSON valido -- alcune chiavi sono senza virgolette --
    quindi l'array si ritaglia contando le parentesi e le righe si leggono
    campo per campo."""
    for match in re.finditer(r"new Listview\(\{", html):
        head = html[match.end():match.end() + 600]
        lv_id = re.search(r"id:\s*'([^']*)'", head)
        start = html.find("data:", match.end())
        if start == -1 or not lv_id:
            continue
        depth, begin = 0, None
        for index in range(start, len(html)):
            char = html[index]
            if char == "[":
                if depth == 0:
                    begin = index
                depth += 1
            elif char == "]":
                depth -= 1
                if depth == 0:
                    yield lv_id.group(1), html[begin:index + 1]
                    break


def rows(data):
    depth, begin = 0, None
    for index, char in enumerate(data):
        if char == "{":
            if depth == 0:
                begin = index
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0 and begin is not None:
                yield data[begin:index + 1]


def field(row, name, pattern=r"(-?\d+)"):
    got = re.search(r'"%s":%s' % (name, pattern), row)
    return got.group(1) if got else None


def ints(text):
    return [int(p) for p in (text or "").split(",") if p.strip().lstrip("-").isdigit()]


def react(text):
    """[Alliance, Horde]: positivo = amichevole, null = non esiste per quella
    fazione. Solo un venditore amichevole vende."""
    parts = [p.strip() for p in (text or "").split(",")] + ["null", "null"]
    def usable(value):
        return value.lstrip("-").isdigit() and int(value) > 0
    return usable(parts[0]), usable(parts[1])


def item_blob(html, item_id):
    """Il blob dell'oggetto della pagina, `$.extend(g_items[ID], {...})`.

    Porta i codici `source` di Wowhead (2 drop, 4 quest, 5 venditore...),
    `sourcemore` e `commondrop`, il segno del world drop. Per un oggetto
    senza listview di provenienza e' l'unica cosa che Wowhead dice; qui e'
    JSON vero."""
    got = re.search(r"\$\.extend\(g_items\[%s\],\s*\{" % item_id, html)
    if not got:
        return {}
    start = got.end() - 1
    depth, inside, escape = 0, False, False
    for index in range(start, len(html)):
        char = html[index]
        if inside:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                inside = False
        elif char == '"':
            inside = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(html[start:index + 1])
                except ValueError:
                    return {}
    return {}


def parse_item(html, item_id):
    blob = item_blob(html, item_id)
    found = {"listviews": [], "vendors": [], "drops": [], "containers": [], "quests": [],
             "teaches": [], "source": blob.get("source") or [],
             "sourcemore": blob.get("sourcemore") or [],
             "commondrop": bool(blob.get("commondrop"))}
    for lv_id, data in listview_blocks(html):
        found["listviews"].append(lv_id)
        if lv_id == "teaches-recipe":
            found["teaches"] = [int(field(row, "id")) for row in rows(data) if field(row, "id")]
            continue
        if lv_id not in LISTVIEWS:
            continue
        for row in rows(data):
            ident = field(row, "id")
            if ident is None:
                continue
            name = (field(row, "name", r'"((?:[^"\\]|\\.)*)"') or "").replace('\\"', '"').replace("\\'", "'")
            if lv_id == "reward-from-q":
                found["quests"].append({"id": int(ident), "name": name,
                                        "side": int(field(row, "side") or 0),
                                        "zone": int(field(row, "category") or 0)})
                continue
            alliance, horde = react(field(row, "react", r"\[([^\]]*)\]"))
            entry = {"id": int(ident), "name": name,
                     "zones": [z for z in ints(field(row, "location", r"\[([^\]]*)\]")) if z > 0],
                     "alliance": alliance, "horde": horde}
            if lv_id == "sold-by":
                found["vendors"].append(entry)
            elif lv_id == "dropped-by":
                entry["boss"] = (field(row, "classification") or "") == str(BOSS)
                entry["count"] = int(field(row, "count") or 0)
                entry["outof"] = int(field(row, "outof") or 0)
                found["drops"].append(entry)
            else:
                found["containers"].append(entry)
    return found


def parse_list(html):
    """Le righe di una pagina-elenco: per ogni oggetto i codici `source`,
    `sourcemore` e `commondrop` -- gli stessi campi del blob della
    pagina-oggetto, per un mestiere intero in una richiesta sola.

    Stanno in `var listviewitems = [...]`, che non e' JSON (popularity e
    firstseenpatch hanno le chiavi senza virgolette): righe ritagliate con le
    parentesi e campi letti uno per uno. `sourcemore` invece e' JSON vero.
    Le sue forme: {"n","t":1,"ti","z"} un NPC, {"n","t":5,"ti"} una quest,
    {"z"} solo una zona, cioe' tante creature in quel posto."""
    found = {}
    start = html.find("var listviewitems = [")
    if start == -1:
        return found
    start = html.find("[", start)
    for row in rows(html[start:html.find("];", start) + 1]):
        ident = field(row, "id")
        if ident is None or field(row, "classs") != "9":
            continue
        more = re.search(r'"sourcemore":(\[[^\]]*\])', row)
        try:
            sourcemore = json.loads(more.group(1)) if more else []
        except ValueError:
            sourcemore = []
        found[ident] = {"name": (field(row, "name", r'"((?:[^"\\]|\\.)*)"') or ""),
                        "source": ints(field(row, "source", r"\[([^\]]*)\]")),
                        "sourcemore": sourcemore,
                        "commondrop": '"commondrop":true' in row}
    return found


def parse_spell_list(html):
    """Le righe di un elenco di spell: id, nome, `learnedat`, `colors` (le
    quattro soglie), `skill` (le skill line), `source` (6 = trainer) e
    `trainingcost`.

    Stanno in `var listviewspells = [...]`, come quelle degli oggetti in
    `listviewitems` (vedi parse_list), e non e' JSON: quality e popularity hanno
    le chiavi senza virgolette. Righe ritagliate con le parentesi, campi letti
    uno per uno."""
    found = {}
    start = html.find("var listviewspells = [")
    if start == -1:
        return found
    start = html.find("[", start)
    for row in rows(html[start:html.find("];", start) + 1]):
        ident = field(row, "id")
        if ident is None:
            continue
        learnedat = field(row, "learnedat")
        cost = field(row, "trainingcost")
        found[ident] = {"name": (field(row, "name", r'"((?:[^"\\]|\\.)*)"') or "").replace('\\"', '"'),
                        "learnedat": int(learnedat) if learnedat is not None else None,
                        "colors": ints(field(row, "colors", r"\[([^\]]*)\]")),
                        "skill": ints(field(row, "skill", r"\[([^\]]*)\]")),
                        "source": ints(field(row, "source", r"\[([^\]]*)\]")),
                        "trainingcost": int(cost) if cost is not None else None}
    return found


def trainer_level(entry):
    """Il livello a cui un trainer insegna lo spell, quando Wowhead lo sa.

    Wowhead scrive `learnedat` anche quando non lo sa: allora l'arancione,
    colors[0], e' 0 e learnedat ripete la soglia gialla. Bolt of Linen Cloth,
    che il gioco da' da solo a 1, esce "a 25" senza nessuna fonte; Shadoweave
    Pants ha il trainer ma l'arancione a 0. Vale solo con un trainer fra le
    fonti e l'arancione uguale al livello -- e cosi' restano fuori anche gli
    spell dei ranghi di mestiere, che di soglie non ne hanno."""
    level, colors = entry.get("learnedat"), entry.get("colors") or []
    if TRAINER in (entry.get("source") or []) and level and colors and colors[0] == level:
        return level
    return None


def write_trainer_tsv(cache):
    """spellId -> livello del trainer, per generate-from-dump.lua
    (--trainer-skill=). Dalla cache, che tiene tutto: il filtro e' qui."""
    out = sorted((int(spell_id), trainer_level(entry), entry["name"])
                 for spell_id, entry in cache.get("spells", {}).items() if trainer_level(entry))
    tmp = TRAINER_OUT + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        f.write("spellId\trequiredSkill\tname\n")
        for spell_id, level, name in out:
            f.write("%d\t%d\t%s\n" % (spell_id, level, name.replace("\t", " ")))
    os.replace(tmp, TRAINER_OUT)
    return out


def vendor_reactions(cache):
    """NPC -> (Alliance, Horde), da ogni venditore visto su una pagina-oggetto.
    La fazione di un venditore e' sua, non dell'oggetto: letta una volta vale
    per tutto cio' che vende."""
    out = {}
    for entry in cache["items"].values():
        for vendor in entry.get("vendors") or []:
            out[vendor["id"]] = (vendor["alliance"], vendor["horde"])
    return out


def summarize_list(entry, reactions):
    """Una riga di elenco -> la stessa forma di summarize, ma solo nei casi
    che l'elenco risolve da solo: world drop, o una fonte sola e di un tipo
    solo. Il resto chiede la pagina-oggetto."""
    if entry["commondrop"]:
        return "worldDrop", [], [], "", "true"
    if len(entry["sourcemore"]) != 1:
        return "", [], [], "", ""
    more, source = entry["sourcemore"][0], entry["source"]
    if more.get("t") == 5 and source == [4]:
        zone = more.get("c") or 0
        return "quest", [{"name": "", "zones": [zone] if zone > 0 else []}], [""], "", ""
    place = {"name": more.get("n", ""), "zones": [more["z"]] if more.get("z") else []}
    if source == [5] and more.get("t") == 1:
        if more.get("ti") not in reactions:
            return "", [], [], "", ""
        alliance, horde = reactions[more["ti"]]
        faction = "alliance" if alliance and not horde else "horde" if horde and not alliance else ""
        return "vendor", [dict(place, alliance=alliance, horde=horde)], [faction], "", ""
    # 2 e' il drop; 16 pescato e 21 borseggiato sono modi di farlo cadere.
    # Ma Wowhead chiama drop anche cio' che sta in un oggetto del mondo (t 2,
    # i "Blacksmithing Plans" di BRD) o dentro un altro oggetto (t 3): per noi
    # e' un container, ed e' quello che il dataset TBC dice di quelle righe.
    if 2 in source and not set(source) - {2, 16, 21}:
        if more.get("t") in (2, 3):
            return "container", [place], [""], "", ""
        if more.get("t") in (1, None):
            return "drop", [place], [""], "", ""
    return "", [], [], "", ""


def triage(cache, items):
    """Le righe vuote del worksheet, divise per quanto lavoro chiede Wowhead.
    Restituisce gli oggetti di cui serve davvero la pagina."""
    from collections import Counter
    reactions = vendor_reactions(cache)
    groups, need, vendor_item = Counter(), [], {}
    for row in items:
        if row["sourceKind"]:
            continue
        item_id = row["recipeItemId"]
        got = cache["lists"].get(item_id)
        if item_id in cache["items"] and not cache["items"][item_id].get("refused"):
            groups["pagina gia' letta"] += 1
        elif not got:
            groups["fuori dagli elenchi: pagina"] += 1
            need.append(item_id)
        elif not got["source"]:
            groups["Wowhead non sa niente"] += 1
        elif summarize_list(got, reactions)[0]:
            groups["risolta dall'elenco"] += 1
        elif got["source"] == [5] and len(got["sourcemore"]) == 1:
            groups["un venditore, manca la fazione"] += 1
            vendor_item.setdefault(got["sourcemore"][0].get("ti"), item_id)
        else:
            groups["piu' fonti: pagina"] += 1
            need.append(item_id)
    # Un oggetto per venditore basta a leggerne la fazione.
    need += [item for item in vendor_item.values() if item not in need]
    print("\nrighe vuote del worksheet:")
    for name, n in groups.most_common():
        print("   %-36s %d" % (name, n))
    print("   venditori senza fazione: %d, un oggetto ciascuno" % len(vendor_item))
    return need


def parse_zones(html):
    """Zona -> nome, e quali sono istanze. Le pagine-elenco portano i
    listview come JSON vero in un tag script, non come `new Listview`."""
    zones, instances = {}, set()
    got = re.search(r'<script type="application/json" id="data\.page\.listPage\.listviews">(.*?)</script>',
                    html, re.S)
    if not got:
        return zones, instances
    try:
        listviews = json.loads(got.group(1))
    except ValueError:
        return zones, instances
    for lv in listviews:
        for row in lv.get("data") or []:
            if isinstance(row.get("id"), int) and row["id"] > 0 and row.get("name"):
                zones[str(row["id"])] = row["name"]
                if row.get("instance"):
                    instances.add(row["id"])
    return zones, instances


# -- cache ---------------------------------------------------------------------

def load_cache():
    try:
        cache = json.load(open(CACHE, encoding="utf-8"))
    except (OSError, ValueError):
        cache = {}
    if cache.get("parser") != PARSER_VERSION:
        cache = {"parser": PARSER_VERSION, "zones": {}, "instances": [], "items": {}}
    cache.setdefault("lists", {})
    return cache


def save_cache(cache):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=1, sort_keys=True)
    os.replace(tmp, CACHE)


def worksheet_items():
    """Gli oggetti-ricetta del worksheet, prima quelli ancora senza
    provenienza: se il giro si interrompe, ha gia' preso quelli che contano.
    Si chiedono comunque tutti -- e' un ordine, non un filtro."""
    out, seen = [], set()
    for row in csv.DictReader(open(WORKSHEET, encoding="utf-8"), delimiter="\t"):
        if row["recipeItemId"] and row["recipeItemId"] not in seen:
            seen.add(row["recipeItemId"])
            out.append(row)
    out.sort(key=lambda r: (bool(r["sourceKind"]), r["band"] != "forever"))
    return out


# -- dalla cache al TSV ------------------------------------------------------------

def summarize(entry):
    def faction(place):
        if place["alliance"] and not place["horde"]:
            return "alliance"
        if place["horde"] and not place["alliance"]:
            return "horde"
        return ""

    if entry["vendors"]:
        places = entry["vendors"]
        return "vendor", places, [faction(p) for p in places], "", ""
    if entry["drops"]:
        # Lo stesso nome con piu' ID (Fel Interloper, quattro volte) e' una
        # creatura sola per chi la cerca.
        places, by_name = [], {}
        for place in entry["drops"]:
            if place["name"] not in by_name:
                by_name[place["name"]] = dict(place, zones=[])
                places.append(by_name[place["name"]])
            merged = by_name[place["name"]]
            merged["zones"] += [z for z in place["zones"] if z not in merged["zones"]]
            merged["boss"] = merged["boss"] or place["boss"]
        zones = []
        for place in places:
            for zone in place["zones"]:
                if zone not in zones:
                    zones.append(zone)
        boss = "true" if any(p["boss"] for p in places) else ""
        # Un drop e' di tutti: la creatura e' ostile a entrambe le fazioni,
        # quindi la sua reazione non dice chi puo' raccoglierlo.
        if len(places) <= WORLD_DROP_CREATURES and len(zones) <= WORLD_DROP_ZONES:
            return "drop", places, [""] * len(places), boss, ""
        # Si tiene quello che dice qualcosa. Tante creature in poche zone --
        # i boss di Deadmines, i mob di Redridge -- e' un posto: la zona senza
        # i nomi. Una creatura in tante zone e' un nome da cercare. World drop
        # solo quando non resta ne' l'uno ne' l'altro.
        if len(zones) <= WORLD_DROP_ZONES:
            return "drop", [{"name": "", "zones": [z]} for z in zones], [""] * len(zones), "", ""
        if len(places) == 1:
            return "drop", [dict(places[0], zones=[])], [""], boss, ""
        return "worldDrop", [], [], "", "true"
    if entry["containers"]:
        places = entry["containers"]
        return "container", places, [""] * len(places), "", ""
    if entry["quests"]:
        quest = entry["quests"][0]
        side = {1: "alliance", 2: "horde"}.get(quest["side"], "")
        return "quest", [dict(quest, name="")], [side], "", ""
    return "", [], [], "", ""


def write_tsv(cache, items):
    """Prima la pagina-oggetto, che vede tutte le fonti e chi e' boss; dove
    la pagina non c'e', l'elenco nei casi che risolve da solo."""
    names = {r["recipeItemId"]: r for r in items}
    reactions = vendor_reactions(cache)
    out = []
    for item_id in sorted(set(cache["items"]) | set(cache["lists"]), key=int):
        entry = cache["items"].get(item_id)
        if entry and not entry.get("refused"):
            kind, places, factions, boss, world = summarize(entry)
            notes = "wowhead"
        elif item_id in cache["lists"]:
            entry = cache["lists"][item_id]
            kind, places, factions, boss, world = summarize_list(entry, reactions)
            notes = "wowhead, elenco"
        else:
            continue
        if not kind:
            continue
        row = names.get(item_id, {})
        def join(values):
            return " | ".join(values) if any(values) else ""
        def zone_of(place):
            ids = place.get("zones") or ([place["zone"]] if place.get("zone") else [])
            return cache["zones"].get(str(ids[0]), str(ids[0])) if ids else ""
        if kind == "quest":
            quest = entry["quests"][0]["name"] if "quests" in entry else entry["sourcemore"][0].get("n", "")
            notes += ", quest: " + quest
        out.append({"spellId": row.get("spellId", ""), "recipeItemId": item_id,
                    "name": row.get("name", ""), "sourceKind": kind,
                    "npcName": join([p["name"] for p in places]),
                    "zone": join([zone_of(p) for p in places]),
                    "faction": join(factions), "bossDrop": boss, "worldDrop": world,
                    "notes": notes})
    tmp = OUT + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        f.write("\t".join(COLS) + "\n")
        for row in out:
            f.write("\t".join(str(row[c]) for c in COLS) + "\n")
    os.replace(tmp, OUT)
    return out


# -- il giro -------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, help="al massimo N pagine in questo giro")
    parser.add_argument("--all", action="store_true", help="tutti gli oggetti non ancora in cache")
    parser.add_argument("--items", help="solo questi oggetti, separati da virgola")
    parser.add_argument("--report", action="store_true", help="niente rete: riscrive il TSV dalla cache")
    parser.add_argument("--lists", help="pagine-elenco dei mestieri (separati da virgola, o 'all') e triage")
    parser.add_argument("--triage", action="store_true",
                        help="solo le pagine-oggetto che gli elenchi non bastano a risolvere")
    parser.add_argument("--spells", help="elenchi degli spell dei mestieri (separati da virgola, o 'all'):"
                        " livello a cui si imparano e soglie")
    parser.add_argument("--from-html", help="con --spells: rilegge le pagine salvate qui invece della rete")
    parser.add_argument("--retry-refused", action="store_true", help="richiede anche gli oggetti rifiutati")
    parser.add_argument("--save-html", help="salva qui l'HTML di ogni pagina letta")
    parser.add_argument("--delay", type=float, default=3.0, help="secondi fra una pagina e l'altra")
    parser.add_argument("--max-refusals", type=int, default=3, help="rifiuti di fila prima di fermarsi")
    args = parser.parse_args()
    if not (args.limit or args.all or args.items or args.report or args.lists or args.triage or args.spells):
        parser.error("indica --limit N, --all, --items, --lists, --spells, --triage o --report")

    items = worksheet_items()
    cache = load_cache()

    if args.spells:
        slugs = list(SPELL_LISTS) if args.spells == "all" else args.spells.split(",")
        cache.setdefault("spells", {})

        def pages():
            if args.from_html:
                for slug in slugs:
                    path = os.path.join(args.from_html, "spells-%s.html" % slug)
                    if os.path.exists(path):
                        yield slug, open(path, encoding="utf-8").read()
                return
            from wowhead_browser import Browser, Refused
            with Browser() as browser:
                for slug in slugs:
                    try:
                        html = browser.read("%s/spells/%s" % (BASE, SPELL_LISTS.get(slug, "professions/" + slug)))
                    except Refused as error:
                        print("  %-15s %s" % (slug, error))
                        continue
                    if args.save_html:
                        os.makedirs(args.save_html, exist_ok=True)
                        open(os.path.join(args.save_html, "spells-%s.html" % slug), "w",
                             encoding="utf-8").write(html)
                    yield slug, html
                    time.sleep(args.delay)

        for slug, html in pages():
            got = parse_spell_list(html)
            for spell_id, entry in got.items():
                cache["spells"][spell_id] = dict(entry, slug=slug)
            save_cache(cache)
            print("  %-15s %d spell, %d con il livello del trainer" % (slug, len(got),
                  sum(1 for e in got.values() if trainer_level(e))))
        out = write_trainer_tsv(cache)
        print("in cache %d spell | con il livello del trainer %d -> %s"
              % (len(cache["spells"]), len(out), TRAINER_OUT))
        return

    if args.lists:
        from wowhead_browser import Browser, Refused
        slugs = LIST_SLUGS if args.lists == "all" else args.lists.split(",")
        with Browser() as browser:
            for slug in slugs:
                try:
                    html = browser.read("%s/items/recipes/%s" % (BASE, slug))
                except Refused as error:
                    print("  %-15s %s" % (slug, error))
                    continue
                if args.save_html:
                    os.makedirs(args.save_html, exist_ok=True)
                    open(os.path.join(args.save_html, "list-%s.html" % slug), "w", encoding="utf-8").write(html)
                got = parse_list(html)
                for item_id, entry in got.items():
                    cache["lists"][item_id] = dict(entry, slug=slug)
                save_cache(cache)
                print("  %-15s %d oggetti" % (slug, len(got)))
                time.sleep(args.delay)
        triage(cache, items)
        return

    if not args.report:
        if args.items:
            pending = [i.strip() for i in args.items.split(",") if i.strip()]
        elif args.triage:
            pending = triage(cache, items)
        else:
            pending = [r["recipeItemId"] for r in items
                       if r["recipeItemId"] not in cache["items"]
                       or (args.retry_refused and cache["items"][r["recipeItemId"]].get("refused"))]
        if args.limit:
            pending = pending[:args.limit]
        print("da leggere: %d pagine (in cache: %d)" % (len(pending), len(cache["items"])))

        from wowhead_browser import Browser, Refused
        fetched, refused, streak = 0, 0, 0
        with Browser() as browser:
            def read(url, label):
                html = browser.read(url)
                if args.save_html:
                    os.makedirs(args.save_html, exist_ok=True)
                    open(os.path.join(args.save_html, label + ".html"), "w", encoding="utf-8").write(html)
                return html

            if not cache["zones"]:
                for slug in ("", "/eastern-kingdoms", "/kalimdor"):
                    try:
                        zones, instances = parse_zones(read(BASE + "/zones" + slug, "zones" + slug.replace("/", "-")))
                    except Refused as error:
                        print("  zone%s: %s" % (slug, error))
                        continue
                    cache["zones"].update(zones)
                    cache["instances"] = sorted(set(cache["instances"]) | instances)
                    time.sleep(args.delay)
                print("zone note: %d" % len(cache["zones"]))
                save_cache(cache)

            for index, item_id in enumerate(pending, 1):
                try:
                    entry = parse_item(read("%s/item=%s" % (BASE, item_id), "item-" + item_id), item_id)
                    streak = 0
                    fetched += 1
                except Refused as error:
                    entry = {"refused": str(error)}
                    streak += 1
                    refused += 1
                cache["items"][item_id] = entry
                save_cache(cache)
                print("  %4d/%d  item %-7s %s" % (index, len(pending), item_id,
                      entry.get("refused") or ", ".join(entry["listviews"]) or "nessun listview"))
                if streak >= args.max_refusals:
                    print("\n%d rifiuti di fila: mi fermo. Rilanciare con --retry-refused." % streak)
                    break
                time.sleep(args.delay)
        print("\nlette %d, rifiutate %d" % (fetched, refused))

    out = write_tsv(cache, items)
    from collections import Counter
    done = [e for e in cache["items"].values() if not e.get("refused")]
    print("in cache %d oggetti, %d rifiutati | con provenienza %d -> %s"
          % (len(done), len(cache["items"]) - len(done), len(out), OUT))
    for kind, n in Counter(r["sourceKind"] for r in out).most_common():
        print("   %-10s %d" % (kind, n))


if __name__ == "__main__":
    main()
