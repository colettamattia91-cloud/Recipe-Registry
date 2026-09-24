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
    """I campi del sito -> il nostro vocabolario. Un solo tipo per ricetta:
    l'ordine sotto e' quello di quanto e' azionabile la risposta."""
    drops = source.get("drops") or []
    vendors = source.get("vendors") or []
    quests = source.get("quests") or []
    names, zones, factions = [], [], []
    if vendors:
        for v in vendors:
            names.append(v.get("npc") or "")
            zones.append(v.get("zone") or "")
            factions.append(SIDE.get(v.get("side"), ""))
        return "vendor", names, zones, factions, ""
    if drops:
        for d in drops:
            names.append(d.get("npc") or "")
            zones.append(d.get("zone") or "")
            factions.append("")
        # Tanti NPC in tante zone non e' un drop da cercare, e' un world drop:
        # mandare il giocatore dal primo della lista sarebbe una bugia comoda.
        if len({z for z in zones if z}) > 4:
            return "worldDrop", [], [], [], "true"
        return "drop", names, zones, factions, ""
    if quests:
        q = quests[0]
        return "quest", [], [q.get("zone") or ""], [SIDE.get(q.get("side"), "")], ""
    return "", [], [], [], ""


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
            kind, names, zones, factions, world = classify(source)
            if not kind:
                continue
            seen.add(key)
            def join(values):
                return " | ".join(values) if any(values) else ""
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
    print("totale %d -> %s" % (len(rows), OUT))
    for kind, n in Counter(r["sourceKind"] for r in rows).most_common():
        print("   %-12s %d" % (kind, n))


if __name__ == "__main__":
    main()
