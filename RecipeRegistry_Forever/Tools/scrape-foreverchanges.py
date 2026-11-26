"""La provenienza delle ricette di Forever, dalle pagine di foreverchanges.pro.

NON si legge il testo della pagina. Ogni pagina-mestiere porta incorporato il
suo dato strutturato -- un oggetto per ricetta con lo spellId, l'oggetto che la
insegna e la provenienza in campi separati:

    {"spell":1249957, "formula":{"id":249879,"name":"Recipe: Peace Tea"},
     "source":{"drops":[{"npc":"Frostmane Seer","zone":"Dun Morogh"}]}}

Si estrae quello. Leggere il testo reso, come si era fatto prima, significa
passare da un riassuntore che tronca le pagine lunghe e risponde "non c'e'"
invece di "non ho guardato tutto": e' cosi' che Peace Tea e' risultata senza
fonte per mezza giornata, mentre il dato era li'.

Il sito dichiara da dove viene ogni riga nel campo `read` -- "wowhead" per il
contenuto nuovo di Forever, "classic" per quello che eredita da vanilla -- e
quel campo si conserva nelle note, perche' la fiducia nelle due meta' non e'
la stessa.

    python Tools/scrape-foreverchanges.py
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "captures", "foreverchanges-recipes.tsv")

PROFESSIONS = ["alchemy", "blacksmithing", "cooking", "enchanting", "engineering",
               "first-aid", "leatherworking", "tailoring", "mining", "herbalism",
               "skinning", "fishing"]

COLS = ["spellId", "recipeItemId", "name", "sourceKind", "npcName", "zone",
        "faction", "worldDrop", "notes"]

SIDE = {"a": "alliance", "h": "horde", "": "", None: ""}


def fetch(profession):
    url = "https://foreverchanges.pro/professions/" + profession
    got = subprocess.run(["curl", "-sL", "--max-time", "60", url],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    return got.stdout or ""


def recipe_objects(html):
    """Ogni oggetto-ricetta incorporato nella pagina.

    Il JSON e' dentro una stringa a sua volta dentro lo script, quindi arriva
    con le virgolette raddoppiate: si toglie un livello di escape e si cercano
    gli oggetti che cominciano con "spell". Si taglia con un conteggio di
    parentesi invece che con una regex, perche' gli oggetti sono annidati.
    """
    text = html.replace('\\\\"', "\x00").replace('\\"', '"').replace("\x00", '\\"')
    # Due forme, perche' le pagine non sono tutte uguali: quasi tutti i
    # mestieri aprono l'oggetto con "spell", enchanting con "name" e senza
    # spellId affatto -- li' la ricetta si riconosce dalla formula. Si ancora
    # su entrambe e si tiene solo cio' che ha davvero formula e provenienza.
    for match in re.finditer(r'\{"(?:spell":\d+|name":")', text):
        start = match.start()
        depth, index, inside, escape = 0, start, False, False
        while index < len(text):
            char = text[index]
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
                    break
            index += 1
        try:
            yield json.loads(text[start:index + 1])
        except ValueError:
            continue


def classify(source):
    """I campi del sito -> il nostro vocabolario, una voce per tipo.

    Ogni voce e' (tipo, nomi, zone, fazioni, worldDrop). L'ordine e' quello di
    quanto e' azionabile la risposta -- venditore, drop, quest -- e la prima
    voce e' la provenienza principale della ricetta.

    Fino al 26/11 usciva solo la prima, e le altre si perdevano: 49 ricette su
    1293 hanno sul sito piu' di un tipo (31 venditore e drop, 16 venditore e
    quest, 2 drop e quest), e su Forever sono vere insieme -- Plans: Copper
    Chain Vest e' premio di "Supplying the Front" e cade da Captain Perrine.
    """
    if not isinstance(source, dict):
        return []
    drops = source.get("drops") or []
    vendors = source.get("vendors") or []
    quests = source.get("quests") or []
    out = []
    if vendors:
        out.append(("vendor", [v.get("npc") or "" for v in vendors],
                    [v.get("zone") or "" for v in vendors],
                    [SIDE.get(v.get("side"), "") for v in vendors], ""))
    if drops:
        names = [d.get("npc") or "" for d in drops]
        zones = [d.get("zone") or "" for d in drops]
        # Tanti NPC in tante zone non e' un drop da cercare, e' un world drop:
        # mandare il giocatore dal primo della lista sarebbe una bugia comoda.
        if len({z for z in zones if z}) > 4:
            out.append(("worldDrop", [], [], [], "true"))
        else:
            out.append(("drop", names, zones, [""] * len(drops), ""))
    if quests:
        # Il nome della quest va dove il resto del foglio mette il "chi": la
        # riga diventa "Quest: Supplying the Front", che si cerca nel registro
        # delle missioni, invece di "Quest" e basta. La zona c'e' quando il
        # sito la sa.
        #
        # Molte quest vanilla esistono due volte, una per fazione, con lo
        # stesso nome (Wild Leather Shoulders): sono una quest sola per chi
        # legge, e la valgono entrambe le fazioni. Tenute separate davano due
        # righe identiche, e la UI ne mostrava una con la bandiera di una
        # fazione sola.
        merged, order = {}, []
        for q in quests:
            key = (q.get("name") or "", q.get("zone") or "")
            if key not in merged:
                merged[key] = set()
                order.append(key)
            merged[key].add(SIDE.get(q.get("side"), ""))
        def side(sides):
            return next(iter(sides)) if len(sides) == 1 else ""
        out.append(("quest", [k[0] for k in order], [k[1] for k in order],
                    [side(merged[k]) for k in order], ""))
    return out


def main():
    rows, seen = [], set()
    for profession in PROFESSIONS:
        html = fetch(profession)
        if not html:
            print("  %-16s nessuna risposta" % profession)
            continue
        found = 0
        for obj in recipe_objects(html):
            source = obj.get("source") or {}
            formula = obj.get("formula") or {}
            spell = obj.get("spell")
            # La chiave e' lo spell quando c'e', altrimenti l'oggetto-ricetta:
            # su enchanting lo spell non c'e' e la formula si', ed e' comunque
            # un identificatore che il nostro dataset porta.
            key = ("s", spell) if spell else ("f", formula.get("id"))
            if key[1] is None or key in seen:
                continue
            kinds = classify(source)
            if not kinds:
                continue
            seen.add(key)
            def join(values):
                return " | ".join(values) if any(values) else ""
            # Una riga per tipo, nell'ordine di classify: chi legge il file
            # prende la prima come principale e le altre come provenienze in
            # piu' della stessa ricetta.
            for kind, names, zones, factions, world in kinds:
                rows.append({
                    "spellId": spell or "",
                    "recipeItemId": formula.get("id") or "",
                    "name": formula.get("name") or obj.get("n") or "",
                    "sourceKind": kind,
                    "npcName": join(names),
                    "zone": join(zones),
                    "faction": join(factions),
                    "worldDrop": world,
                    "notes": "foreverchanges, letto da " + (source.get("read") or "?"),
                })
            found += 1
        print("  %-16s %d ricette con provenienza" % (profession, found))

    tmp = OUT + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        f.write("\t".join(COLS) + "\n")
        for row in sorted(rows, key=lambda r: (str(r["spellId"]), str(r["recipeItemId"]))):
            f.write("\t".join(str(row[c]) for c in COLS) + "\n")
    os.replace(tmp, OUT)

    from collections import Counter
    print()
    recipes = len({(r["spellId"], r["recipeItemId"]) for r in rows})
    print("totale %d ricette, %d righe -> %s" % (recipes, len(rows), OUT))
    for kind, n in Counter(r["sourceKind"] for r in rows).most_common():
        print("   %-12s %d" % (kind, n))


if __name__ == "__main__":
    main()
