"""Ricostruisce acquisition-worksheet.tsv da zero e vi riversa il raccolto.

Scrittura atomica: si costruisce tutto in memoria, si scrive un temporaneo e
solo alla fine si sostituisce il file. La versione precedente apriva il file in
scrittura prima di finire il lavoro, e un'eccezione a meta' lo ha troncato.
"""
import csv, json, os, re, sqlite3, sys

REPO = r"C:\Progetti\Public\RecipeRegistry"
MINING = r"C:\Progetti\Public\WowForeverMining"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "acquisition-worksheet.tsv")
HARVEST = os.path.join(HERE, "captures", "foreverchanges-2026-09-24.tsv")

COLS = ["profession", "learnSkill", "name", "spellId", "recipeItemId", "band",
        "sourceKind", "npcName", "zone", "x", "y", "faction",
        "bossDrop", "worldDrop", "trainerTitle", "mobLevel", "notes"]


def norm(s):
    s = (s or "").lower().strip()
    s = re.sub(r"^enchant\s+[a-z0-9\- ]*?\s*-\s*", "", s)
    return re.sub(r"[^a-z0-9]+", "", s)


def load_client():
    recipes = json.load(open(os.path.join(
        MINING, "out", "bundle", "forever-local-1.60.1.69913", "recipes.json"), encoding="utf-8"))
    rank, sparse = {}, set()
    path = os.path.join(MINING, "cache", "datasets", "forever-local-1.60.1.69913", "ItemSparse.csv")
    with open(path, encoding="utf-8") as f:
        reader = csv.reader(f)
        header = next(reader)
        col = header.index("RequiredSkillRank")
        for row in reader:
            try:
                item = int(row[0])
                sparse.add(item)
                rank[item] = int(row[col])
            except (ValueError, IndexError):
                pass
    return recipes, rank, sparse


def load_cmangos():
    db = sqlite3.connect(os.path.join(
        REPO, "RecipeRegistry", "tools", "recipe-metadata", "snapshots", "tbc-2.5.5",
        ".cmangos", "tbcmangos.sqlite"))
    db.text_factory = lambda b: b.decode("utf-8", "replace")
    cur = db.cursor()
    covered = set()
    for table in ("npc_vendor", "creature_loot_template", "reference_loot_template",
                  "gameobject_loot_template"):
        cur.execute("select distinct item from " + table)
        covered |= {r[0] for r in cur.fetchall()}
    cur.execute("select RewItemId1,RewItemId2,RewItemId3,RewItemId4,RewChoiceItemId1,"
                "RewChoiceItemId2,RewChoiceItemId3,RewChoiceItemId4,RewChoiceItemId5,"
                "RewChoiceItemId6 from quest_template")
    for row in cur.fetchall():
        covered |= {x for x in row if x}
    return cur, covered


def band(spell_id):
    if spell_id < 100000:
        return "vanilla"
    return "sod" if spell_id < 1240000 else "forever"


def parse_source(text):
    """Il testo del sito -> i campi del nostro vocabolario."""
    s = text.strip()
    low = s.lower()
    if "blueprint" in low:
        # Le postazioni del sistema di perk di Forever: non le insegna nessuno
        # e non stanno da nessuna parte, arrivano progredendo nel mestiere.
        return {"sourceKind": "blueprint"}
    if "nobody has found" in low:
        return {"notes": "ignota anche alla community"}
    m = re.search(r"reward of the quest ([^(]+)", s, re.I)
    if m:
        return {"sourceKind": "quest", "notes": "quest: " + m.group(1).strip()}
    # Una coppia di venditori, uno per fazione: e' la forma di tutti i
    # quartermaster a Merchant's Favor, non un caso raro. I due nomi stanno
    # nella stessa cella separati da " | ", e il generatore li rilegge come
    # due sourcePlaces distinte -- che e' la verita': sono due NPC.
    m = re.search(r"sold by ([^(,]+)\((Alliance|Horde)\)\s*or\s+([^(,]+)\((Alliance|Horde)\)", s, re.I)
    if m:
        return {"sourceKind": "vendor",
                "npcName": "%s | %s" % (m.group(1).strip(), m.group(3).strip()),
                "faction": "%s | %s" % (m.group(2).lower(), m.group(4).lower())}
    # "Merchant's Favor" senza nomi: il sito a volte dice solo la fascia di
    # prezzo. E' comunque un venditore, e sapere QUALE lo dara' la cattura in
    # gioco dei quartermaster, che sovrascrive questa riga con gli NPC veri.
    if "merchant's favor" in low:
        return {"sourceKind": "vendor", "notes": "quartermaster a Merchant's Favor -- " + s}
    m = re.search(r"sold by ([^,]+), ([A-Z][A-Za-z' ]+)", s)
    if m:
        return {"sourceKind": "vendor", "npcName": m.group(1).strip(), "zone": m.group(2).strip()}
    m = re.search(r"drops from ([^,]+), ([A-Za-z' ]+)", s, re.I)
    if m:
        return {"sourceKind": "drop", "npcName": m.group(1).strip(),
                "zone": m.group(2).strip(), "notes": s}
    if re.search(r"drops in .* and \d+ more", s, re.I):
        return {"sourceKind": "worldDrop", "worldDrop": "true", "notes": s}
    if "drops in" in low:
        return {"sourceKind": "drop", "notes": s}
    return {"notes": s}


def main():
    recipes, rank, sparse = load_client()
    cur, covered = load_cmangos()

    # Il raccolto dal sito, per nome normalizzato.
    harvest = {}
    if os.path.exists(HARVEST):
        for h in csv.DictReader(open(HARVEST, encoding="utf-8"), delimiter="\t"):
            harvest[(h["profession"], norm(h["name"]))] = h

    # La provenienza gia' risolta dall'albero TBC, per spellId. Le ricette che
    # Forever eredita da vanilla sono le stesse ricette: se lo spell coincide,
    # chi la vende e chi la droppa lo sappiamo gia', e non c'e' niente da
    # dedurre. Prodotto da Tools/extract-tbc-acquisition.lua.
    tbc = {}
    tbc_path = os.path.join(HERE, "captures", "tbc-vanilla.tsv")
    if os.path.exists(tbc_path):
        for t in csv.DictReader(open(tbc_path, encoding="utf-8"), delimiter="\t"):
            tbc[int(t["spellId"])] = t

    # Ogni ricetta che esiste nel gioco, non solo quelle che ci mancano: il
    # foglio E' il censimento della provenienza, e una riga vuota e' la
    # risposta onesta per cio' che nessuno sa ancora.
    rows = []
    for r in recipes:
        if r["createdItemId"] and r["createdItemId"] not in sparse:
            continue          # fuori col filtro removed
        item = r["recipeItemId"]
        row = {c: "" for c in COLS}
        row.update(profession=r["profession"], learnSkill=rank.get(item, "") if item else "",
                   name=r["name"], spellId=r["spellId"], recipeItemId=item or "",
                   band=band(r["spellId"]))
        rows.append(row)

    # PRIMA DI TUTTO le catture in gioco: sono l'unica fonte che ha visto la
    # cosa invece di ricordarsela. Il sito dava Archmage Alvareaux in "Alterac
    # Mountains", che e' dov'era Dalaran in vanilla; in gioco sta in The Silver
    # Enclave, City of Dalaran. Un file per sessione di cattura, letti tutti,
    # perche' il DB del Collector si azzera a ogni reload.
    ingame = {}
    captures = os.path.join(HERE, "captures")
    for fname in sorted(os.listdir(captures)) if os.path.isdir(captures) else []:
        if not (fname.startswith("ingame-vendors-") and fname.endswith(".tsv")):
            continue
        for c in csv.DictReader(open(os.path.join(captures, fname), encoding="utf-8"), delimiter="\t"):
            item = int(c["recipeItemId"])
            got = ingame.setdefault(item, {"npcName": [], "zone": [], "x": [], "y": [], "faction": []})
            # Lo stesso NPC catturato due volte non diventa due venditori.
            if c["npcName"] in got["npcName"]:
                continue
            for field in ("npcName", "zone", "x", "y", "faction"):
                got[field].append(c[field])

    # Prima il dataset TBC, che e' il dato curato e verificato da anni.
    from_tbc = 0
    for row in rows:
        if row["sourceKind"]:
            continue
        t = tbc.get(int(row["spellId"]))
        if not t:
            continue
        row.update(sourceKind=t["sourceKind"], npcName=t["npcName"], zone=t["zone"],
                   faction=t["faction"], bossDrop=t["bossDrop"],
                   worldDrop=t["worldDrop"], trainerTitle=t["trainerTitle"])
        row["notes"] = "da vanilla, dataset TBC"
        from_tbc += 1

    # Lo scraping strutturato di foreverchanges: il dato incorporato nelle sue
    # pagine, non il testo riassunto. Indicizzato per spellId e, dove lo spell
    # non c'e' (enchanting), per oggetto-ricetta.
    web_by_spell, web_by_item = {}, {}
    web_path = os.path.join(HERE, "captures", "foreverchanges-recipes.tsv")
    if os.path.exists(web_path):
        for w in csv.DictReader(open(web_path, encoding="utf-8"), delimiter="\t"):
            if w["spellId"]:
                web_by_spell[int(w["spellId"])] = w
            if w["recipeItemId"]:
                web_by_item[int(w["recipeItemId"])] = w

    from_web = 0
    for row in rows:
        if row["sourceKind"]:
            continue
        w = web_by_spell.get(int(row["spellId"]))
        if not w and row["recipeItemId"]:
            w = web_by_item.get(int(row["recipeItemId"]))
        if not w:
            continue
        row.update(sourceKind=w["sourceKind"], npcName=w["npcName"], zone=w["zone"],
                   faction=w["faction"], worldDrop=w["worldDrop"], notes=w["notes"])
        from_web += 1

    # Infine il raccolto a mano dalle pagine, per cio' che lo scraping non ha:
    # i Blueprint, che sul sito non stanno nel dato strutturato.
    filled = 0
    for row in rows:
        if row["sourceKind"]:
            continue
        h = harvest.get((row["profession"], norm(row["name"])))
        if not h:
            continue
        row.update(parse_source(h["source"]))
        row["notes"] = (row.get("notes") or h["source"]) + " [foreverchanges 2026-09-24]"
        filled += 1

    # ULTIMA la cattura in gioco, e FONDE invece di sostituire.
    #
    # Un venditore visto non e' l'unico venditore: Brilliant Smallfish la
    # vendono Harn Longcast, Gretta Ganter e altri, e aver visto Sewa
    # Mistrunner a Thunder Bluff aggiunge lei, non cancella loro. Quindi si
    # fonde per nome: l'NPC che c'era resta, e se e' lo stesso che abbiamo
    # visto vince la versione in gioco -- quella porta zona e coordinate
    # verificate, ed e' cosi' che Archmage Alvareaux e' passato da "Alterac
    # Mountains", dov'era Dalaran in vanilla, a The Silver Enclave.
    from_ingame = 0
    for row in rows:
        if not row["recipeItemId"]:
            continue
        got = ingame.get(int(row["recipeItemId"]))
        if not got:
            continue

        def split(value):
            return [p.strip() for p in (value or "").split("|")] if value else []

        places, order = {}, []
        old = (split(row["npcName"]), split(row["zone"]), split(row["x"]),
               split(row["y"]), split(row["faction"]))
        for i, name in enumerate(old[0]):
            if not name:
                continue
            order.append(name)
            places[name] = [name] + [old[j][i] if i < len(old[j]) else "" for j in (1, 2, 3, 4)]
        for i, name in enumerate(got["npcName"]):
            if name not in places:
                order.append(name)
            places[name] = [name, got["zone"][i], got["x"][i], got["y"][i], got["faction"][i]]

        row.update(sourceKind=row["sourceKind"] or "vendor",
                   npcName=" | ".join(places[n][0] for n in order),
                   zone=" | ".join(places[n][1] for n in order),
                   x=" | ".join(places[n][2] for n in order),
                   y=" | ".join(places[n][3] for n in order),
                   faction=" | ".join(places[n][4] for n in order),
                   notes=(row["notes"] + " + " if row["notes"] else "") + "catturato in gioco")
        from_ingame += 1

    # La fazione quando il sito la mette fra parentesi nella zona.
    for row in rows:
        m = re.match(r"^(.*?)\s*\((Horde|Alliance)\)\s*$", row["zone"] or "")
        if m:
            row["zone"], row["faction"] = m.group(1).strip(), m.group(2).lower()

    # Il livello del mob, dal DB cmangos: sono creature vanilla e i loro livelli
    # non sono provenienza, sono anagrafica -- per questo si possono usare.
    for row in rows:
        if row["sourceKind"] == "drop" and row["npcName"]:
            cur.execute("select MinLevel,MaxLevel from creature_template where name=?",
                        (row["npcName"],))
            got = cur.fetchone()
            if got:
                row["mobLevel"] = "%d-%d" % got

    rows.sort(key=lambda r: (r["band"] != "forever", r["profession"],
                             r["learnSkill"] if r["learnSkill"] != "" else 999, r["name"]))

    tmp = OUT + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=COLS, delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    os.replace(tmp, OUT)

    print("righe: %d | in gioco: %d | TBC: %d | scraping: %d | a mano: %d | vuote: %d"
          % (len(rows), from_ingame, from_tbc, from_web, filled,
             sum(1 for r in rows if not r["sourceKind"])))
    low = [r for r in rows if r["sourceKind"] == "drop" and r["mobLevel"]
           and int(r["mobLevel"].split("-")[1]) <= 20]
    print("\n=== DROP DA MOB <= LIVELLO 20 CHE CI MANCANO ===")
    for r in sorted(low, key=lambda r: int(r["mobLevel"].split("-")[0])):
        print("  %-9s %-30s skill %-4s %-21s lv %-6s %s"
              % (r["profession"], r["name"], r["learnSkill"], r["npcName"],
                 r["mobLevel"], r["zone"]))
    print("totale:", len(low))


if __name__ == "__main__":
    main()
