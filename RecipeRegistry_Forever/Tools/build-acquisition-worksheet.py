"""Ricostruisce acquisition-worksheet.tsv da zero e vi riversa il raccolto.

Scrittura atomica: si costruisce tutto in memoria, si scrive un temporaneo e
solo alla fine si sostituisce il file. La versione precedente apriva il file in
scrittura prima di finire il lavoro, e un'eccezione a meta' lo ha troncato.
"""
import csv, json, os, re, sqlite3, sys
from collections import Counter

REPO = r"C:\Progetti\Public\RecipeRegistry"
MINING = r"C:\Progetti\Public\WowForeverMining"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "acquisition-worksheet.tsv")
HARVEST = os.path.join(HERE, "captures", "foreverchanges-2026-09-24.tsv")
# Il dataset del datamining da cui si prendono le ricette e gli oggetti del
# client. Va tenuto uguale al bundle con cui si genera il database.
MINING_REF = "forever-local-1.60.1.71139"

# Le discordanze fra foreverchanges e Wowhead si decidono caso per caso, e
# questi sono i casi decisi a favore di Wowhead. 18/11: tre pattern SoD di
# Tailoring (Phoenix Bindings, Invoker's Cord, Invoker's Mantle) che Wowhead
# vede vendere dai mercanti di stoffa di sei citta' e foreverchanges da' drop
# da un mob qualsiasi, letto da un addon.
PREFER_WOWHEAD = {428424, 435841, 435848}

COLS = ["profession", "learnSkill", "name", "spellId", "recipeItemId", "band",
        "sourceKind", "npcName", "zone", "x", "y", "faction",
        "bossDrop", "worldDrop", "trainerTitle", "mobLevel", "notes"]
# Le colonne della ricetta e quelle di UNA provenienza. Una ricetta puo' averne
# piu' d'una -- su Forever Pattern: Blue Suede Armor cade da Shadowsworn Thug
# ed e' premio di Leather Technique, entrambe vere -- e il foglio le scrive una
# per riga, la principale per prima. Fino al 26/11 una riga sola per ricetta,
# e la prima fonte che la riempiva cancellava le altre.
RECIPE_COLS = COLS[:6]
SOURCE_COLS = COLS[6:]


def family(kind):
    """Drop e world drop sono la stessa risposta detta piu' o meno bene: una
    ricetta che ne ha gia' uno non ne prende un secondo da un'altra fonte."""
    return "drop" if kind in ("drop", "worldDrop") else kind


def source(**fields):
    out = {c: "" for c in SOURCE_COLS}
    for key, value in fields.items():
        if key in out:
            out[key] = value or ""
    return out


def add_source(row, src):
    """Aggiunge una provenienza alla ricetta, se e' di un tipo che non ha.

    Per ogni tipo vince la prima fonte che lo porta, nell'ordine dei livelli in
    main(): e' lo stesso ordine di fiducia di quando la ricetta ne teneva una
    sola, quindi la principale resta quella di prima e le altre si aggiungono
    dopo. Due fonti che danno lo stesso tipo non fanno due righe: dove dicono
    cose diverse sullo stesso tipo, una sbaglia, e non si sa quale.

    Tranne i venditori, che si sommano (merge_vendors).
    """
    if not src["sourceKind"]:
        return False
    for have in row["sources"]:
        if family(have["sourceKind"]) == family(src["sourceKind"]):
            if have["sourceKind"] == "vendor" and src["sourceKind"] == "vendor":
                merge_vendors(row, have, src)
            return False
    row["sources"].append(src)
    return True


def positions(value, count, broadcast):
    """Una colonna " | " come lista lunga quanto i nomi. Le liste sono
    posizionali; un valore solo vale per tutti solo dove la colonna lo
    prevede (zona, fazione), mai per le coordinate."""
    parts = [p.strip() for p in value.split("|")] if value else []
    if broadcast and len(parts) == 1:
        parts = parts * count
    return (parts + [""] * count)[:count]


def unpack(src):
    """Una provenienza come lista di luoghi [nome, zona, x, y, fazione]."""
    names = [p.strip() for p in src["npcName"].split("|")] if src["npcName"] else []
    n = max(len(names), len(src["zone"].split("|")) if src["zone"] else 0)
    names = (names + [""] * n)[:n]
    zone, faction = positions(src["zone"], n, True), positions(src["faction"], n, True)
    x, y = positions(src["x"], n, False), positions(src["y"], n, False)
    return [[names[i], zone[i], x[i], y[i], faction[i]] for i in range(n)]


def pack(src, places):
    for field, i in (("npcName", 0), ("zone", 1), ("x", 2), ("y", 3), ("faction", 4)):
        values = [p[i] for p in places]
        src[field] = " | ".join(values) if any(values) else ""


def origin(src):
    """La fonte di una provenienza, dalla testa delle sue note."""
    return src["notes"].split(",")[0].split(" + ")[0].split(" [")[0] or "?"


# Ricetta -> NPC aggiunti da merge_vendors, per il rapporto in fondo.
VENDOR_MERGES = {}


def merge_vendors(row, have, src):
    """I venditori di una fonte che la ricetta non ha ancora, in coda ai suoi.

    Un venditore nominato non esclude gli altri: Gingerbread Cookie lo vendono
    un NPC per capitale, e il dataset TBC ne conosceva due (piu' i due di
    Shattrath e The Exodar) mentre foreverchanges ne ha cinque. Fino al 26/11
    la seconda fonte si scartava intera, come per gli altri tipi. Si somma per
    nome, come fa gia' la cattura in gioco: chi c'era tiene zona, coordinate e
    fazione che aveva, e i nuovi entrano coi loro.
    """
    mine = unpack(have)
    seen = {p[0] for p in mine if p[0]}
    added = []
    for place in unpack(src):
        if place[0] and place[0] not in seen:
            seen.add(place[0])
            added.append(place)
    if not added:
        return
    pack(have, mine + added)
    have["notes"] = have["notes"] + " + venditori da " + origin(src)
    VENDOR_MERGES.setdefault(row["spellId"], []).extend((p[0], p[1], origin(src)) for p in added)


def norm(s):
    s = (s or "").lower().strip()
    s = re.sub(r"^enchant\s+[a-z0-9\- ]*?\s*-\s*", "", s)
    return re.sub(r"[^a-z0-9]+", "", s)


def load_client():
    recipes = json.load(open(os.path.join(
        MINING, "out", "bundle", MINING_REF, "recipes.json"), encoding="utf-8"))
    rank, sparse = {}, set()
    path = os.path.join(MINING, "cache", "datasets", MINING_REF, "ItemSparse.csv")
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


def camp_spells(recipes):
    """Le ricette da campo di Forever: per noi, i Blueprint.

    Il client le mette in una categoria "Camping" per ogni mestiere, 39 in
    tutto: il tier 1 insegnato dal trainer a 20 (Mana Well, Camp Tent, il
    Basic Campfire...) e i tier 2-4 che si imparano da un oggetto "Blueprint:".
    L'utente le vuole tutte sotto Blueprint, perche' sono tutte oggetti da
    campo (18/11). Il criterio sta nel client e non nel testo di una fonte: la
    raccolta a mano del 24/09 diceva "Blueprint" anche per undici Formula di
    Enchanting (idol, libram, totem), e ne mancava piu' della meta'.
    """
    path = os.path.join(MINING, "cache", "datasets", MINING_REF, "TradeSkillCategory.csv")
    with open(path, encoding="utf-8") as f:
        camping = {int(r["ID"]) for r in csv.DictReader(f) if r["Name_lang"] == "Camping"}
    if not camping:
        raise SystemExit("nessuna categoria Camping in %s: il client l'ha rinominata?" % path)
    return {r["spellId"] for r in recipes if r["tradeSkillCategoryId"] in camping}


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
        # Non e' una provenienza: il sito metteva questa parola a una famiglia
        # di ricette, e la metteva anche dove non andava. Quali siano i
        # Blueprint lo dice il client (camp_spells); qui non si scrive
        # niente, cosi' la riga resta vuota invece di dire il falso.
        return None
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


def quest_name(w):
    """Il nome della quest di una riga Wowhead, che lo scraper scrive nelle
    note ("wowhead, elenco, quest: Leather Technique") e non in npcName."""
    if w["sourceKind"] != "quest":
        return ""
    m = re.search(r"quest: (.+)$", w["notes"] or "")
    return m.group(1).strip() if m else ""


def main():
    recipes, rank, sparse = load_client()
    camp = camp_spells(recipes)
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
    # risposta onesta per cio' che nessuno sa ancora. Le provenienze stanno in
    # row["sources"], la principale per prima; "pending" tiene la nota di una
    # ricetta che nessuna fonte ha riempito.
    rows = []
    for r in recipes:
        if r["createdItemId"] and r["createdItemId"] not in sparse:
            continue          # fuori col filtro removed
        item = r["recipeItemId"]
        row = {c: "" for c in RECIPE_COLS}
        row.update(profession=r["profession"], learnSkill=rank.get(item, "") if item else "",
                   name=r["name"], spellId=r["spellId"], recipeItemId=item or "",
                   band=band(r["spellId"]))
        row["sources"], row["pending"] = [], ""
        rows.append(row)
    rows_by_spell = {int(row["spellId"]): row for row in rows}

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
        t = tbc.get(int(row["spellId"]))
        if not t:
            continue
        if add_source(row, source(sourceKind=t["sourceKind"], npcName=t["npcName"], zone=t["zone"],
                                  faction=t["faction"], bossDrop=t["bossDrop"],
                                  worldDrop=t["worldDrop"], trainerTitle=t["trainerTitle"],
                                  notes="da vanilla, dataset TBC")):
            from_tbc += 1

    # Lo scraping strutturato di foreverchanges: il dato incorporato nelle sue
    # pagine, non il testo riassunto. Indicizzato per spellId e, dove lo spell
    # non c'e' (enchanting), per oggetto-ricetta. Una ricetta puo' avere piu'
    # righe, una per tipo, la principale per prima.
    web_by_spell, web_by_item = {}, {}
    web_path = os.path.join(HERE, "captures", "foreverchanges-recipes.tsv")
    if os.path.exists(web_path):
        for w in csv.DictReader(open(web_path, encoding="utf-8"), delimiter="\t"):
            if w["spellId"]:
                web_by_spell.setdefault(int(w["spellId"]), []).append(w)
            if w["recipeItemId"]:
                web_by_item.setdefault(int(w["recipeItemId"]), []).append(w)

    # Dove il dataset TBC ha gia' risposto, foreverchanges aggiunge solo i
    # tipi che quello non ha: e' cosi' che Cooked Crab Claw, venduta da Kendor
    # Kabonka, si scopre anche drop in Darkshore.
    from_web = 0
    for row in rows:
        ws = web_by_spell.get(int(row["spellId"]))
        if not ws and row["recipeItemId"]:
            ws = web_by_item.get(int(row["recipeItemId"]))
        for w in ws or []:
            was_empty = not row["sources"]
            if add_source(row, source(sourceKind=w["sourceKind"], npcName=w["npcName"],
                                      zone=w["zone"], faction=w["faction"],
                                      worldDrop=w["worldDrop"], notes=w["notes"])):
                if was_empty:
                    from_web += 1

    # Wowhead direttamente, dalle sue pagine-oggetto (Tools/scrape-wowhead.py).
    # Dopo foreverchanges, che in parte lo legge gia'. Dove la ricetta ha gia'
    # una provenienza aggiunge il suo tipo se e' nuovo, e conta in fondo dove
    # il suo tipo non e' quello principale: le due fonti possono essere vere
    # insieme, e il conteggio dice dove guardare se non lo sono.
    # Piu' righe per oggetto dal 26/11, una per tipo, la principale per prima.
    wowhead = {}
    wowhead_path = os.path.join(HERE, "captures", "wowhead-recipes.tsv")
    if os.path.exists(wowhead_path):
        for w in csv.DictReader(open(wowhead_path, encoding="utf-8"), delimiter="\t"):
            wowhead.setdefault(int(w["recipeItemId"]), []).append(w)

    # Due eccezioni, e restano sostituzioni anche con piu' provenienze.
    #
    # La prima, misurata il 25/10: il "trainer" che il dataset TBC da' a
    # ricette vanilla che su Forever droppano. TBC ha messo dal trainer molte
    # ricette che in vanilla si trovavano solo in giro -- 47 delle 54 hanno in
    # cmangos TBC sia il trainer sia la loot -- e il dataset ha scelto il
    # trainer. Forever e' vanilla, e Wowhead Forever le vede droppare: li'
    # vince Wowhead, e il trainer, che su Forever non c'e', se ne va.
    #
    # La seconda, PREFER_WOWHEAD: i casi in cui l'utente ha deciso che l'altra
    # fonte sbaglia. Resta solo Wowhead.
    from_wowhead, tbc_trainer_fixed, disagree = 0, 0, []
    for row in rows:
        found = wowhead.get(int(row["recipeItemId"])) if row["recipeItemId"] else None
        if not found:
            continue
        # Il nome della quest, che Wowhead da' e lo scraper mette nelle note:
        # "Quest: Leather Technique (Desolace)" invece di "Quest at Desolace".
        sources = [source(sourceKind=w["sourceKind"], npcName=w["npcName"] or quest_name(w),
                          zone=w["zone"], faction=w["faction"], bossDrop=w["bossDrop"],
                          worldDrop=w["worldDrop"], notes=w["notes"]) for w in found]
        # Le due eccezioni guardano la principale di Wowhead, come quando ne
        # dava una sola; le sue altre righe entrano dopo, come quelle di
        # chiunque altro.
        w, ws, rest = found[0], sources[0], sources[1:]
        primary = row["sources"][0] if row["sources"] else None
        if (primary and primary["sourceKind"] == "trainer"
                and primary["notes"] == "da vanilla, dataset TBC"
                and w["sourceKind"] in ("drop", "worldDrop")):
            # Il drop che prende il posto del trainer e' quello di Wowhead, a
            # meno che Wowhead dica solo "drop" senza ne' chi ne' dove (un
            # elenco senza sourcemore) e un'altra fonte lo sappia: allora il
            # drop di quella, che e' la stessa risposta detta meglio.
            # Greater Arcane Elixir, 26/11: foreverchanges ha i mob di Felwood.
            known = next((s for s in row["sources"][1:] if family(s["sourceKind"]) == "drop"
                          and (s["npcName"] or s["zone"])), None)
            if known and not (ws["npcName"] or ws["zone"] or ws["worldDrop"]):
                ws = dict(known, notes=known["notes"] + " (era trainer per il dataset TBC)")
            else:
                ws["notes"] = w["notes"] + " (era trainer per il dataset TBC)"
            row["sources"] = [ws] + [s for s in row["sources"][1:]
                                     if family(s["sourceKind"]) != "drop"]
            for extra in rest:
                add_source(row, extra)
            tbc_trainer_fixed += 1
            continue
        if int(row["spellId"]) in PREFER_WOWHEAD:
            ws["notes"] = w["notes"] + " (scelta dell'utente sul disaccordo)"
            row["sources"] = [ws]
            for extra in rest:
                add_source(row, extra)
            from_wowhead += 1
            continue
        if primary:
            if primary["sourceKind"] != w["sourceKind"]:
                disagree.append((primary["sourceKind"], w["sourceKind"], row["name"]))
        else:
            from_wowhead += 1
        for each in sources:
            add_source(row, each)

    # Infine il raccolto a mano dalle pagine, per cio' che lo scraping non ha.
    # Solo dove la ricetta e' ancora vuota: e' il testo di settembre, il piu'
    # vecchio e il meno preciso di tutti.
    filled = 0
    for row in rows:
        if row["sources"]:
            continue
        h = harvest.get((row["profession"], norm(row["name"])))
        if not h:
            continue
        parsed = parse_source(h["source"])
        if parsed is None:
            continue
        notes = (parsed.get("notes") or h["source"]) + " [foreverchanges 2026-09-24]"
        if add_source(row, source(**dict(parsed, notes=notes))):
            filled += 1
        else:
            row["pending"] = notes

    # ULTIMA la cattura in gioco, e FONDE invece di sostituire.
    #
    # Un venditore visto non e' l'unico venditore: Brilliant Smallfish la
    # vendono Harn Longcast, Gretta Ganter e altri, e aver visto Sewa
    # Mistrunner a Thunder Bluff aggiunge lei, non cancella loro. Quindi si
    # fonde per nome: l'NPC che c'era resta, e se e' lo stesso che abbiamo
    # visto vince la versione in gioco -- quella porta zona e coordinate
    # verificate, ed e' cosi' che Archmage Alvareaux e' passato da "Alterac
    # Mountains", dov'era Dalaran in vanilla, a The Silver Enclave.
    #
    # Si fonde nella provenienza "vendor" della ricetta, e se non ce l'ha ne
    # nasce una. Fino al 26/11 si fondeva nella riga qualunque fosse il suo
    # tipo, e Thorium Grenade, trainer per il dataset TBC, mostrava
    # "Trainer: <il venditore visto>".
    from_ingame = 0
    for row in rows:
        if not row["recipeItemId"]:
            continue
        got = ingame.get(int(row["recipeItemId"]))
        if not got:
            continue
        vendor = next((s for s in row["sources"] if s["sourceKind"] == "vendor"), None)
        if vendor is None:
            vendor = source(sourceKind="vendor")
            row["sources"].append(vendor)

        def split(value):
            return [p.strip() for p in (value or "").split("|")] if value else []

        places, order = {}, []
        old = (split(vendor["npcName"]), split(vendor["zone"]), split(vendor["x"]),
               split(vendor["y"]), split(vendor["faction"]))
        for i, name in enumerate(old[0]):
            if not name:
                continue
            order.append(name)
            places[name] = [name] + [old[j][i] if i < len(old[j]) else "" for j in (1, 2, 3, 4)]
        for i, name in enumerate(got["npcName"]):
            if name not in places:
                order.append(name)
            places[name] = [name, got["zone"][i], got["x"][i], got["y"][i], got["faction"][i]]

        vendor.update(npcName=" | ".join(places[n][0] for n in order),
                      zone=" | ".join(places[n][1] for n in order),
                      x=" | ".join(places[n][2] for n in order),
                      y=" | ".join(places[n][3] for n in order),
                      faction=" | ".join(places[n][4] for n in order),
                      notes=(vendor["notes"] + " + " if vendor["notes"] else "") + "catturato in gioco")
        from_ingame += 1

    # La fazione quando il sito la mette fra parentesi nella zona.
    for row in rows:
        for src in row["sources"]:
            m = re.match(r"^(.*?)\s*\((Horde|Alliance)\)\s*$", src["zone"] or "")
            if m:
                src["zone"], src["faction"] = m.group(1).strip(), m.group(2).lower()

    # In coda foreverdb (Tools/scrape-foreverdb.py), scelta dell'utente del
    # 18/11: solo cio' che il suo addon companion ha visto su Forever --
    # trainer visti insegnare la ricetta, venditori visti venderla, NPC visti
    # con la loro posizione. Riempie le ricette che nessuno ha riempito,
    # aggiunge un tipo che le altre fonti non hanno, e mette le coordinate
    # dove mancano; non corregge niente.
    from_fdb, fdb_coords, fdb_factions, fdb_zone_conflicts = 0, 0, 0, []
    fdb_path = os.path.join(HERE, "captures", "foreverdb-recipes.tsv")
    if os.path.exists(fdb_path):
        for f in csv.DictReader(open(fdb_path, encoding="utf-8"), delimiter="\t"):
            row = rows_by_spell.get(int(f["spellId"]))
            if row is None:
                continue
            was_empty = not row["sources"]
            if add_source(row, source(sourceKind=f["sourceKind"], npcName=f["npcName"],
                                      zone=f["zone"], x=f["x"], y=f["y"],
                                      faction=f["faction"], notes=f["notes"])):
                if was_empty:
                    from_fdb += 1

    fdb_npcs = {}
    npcs_path = os.path.join(HERE, "captures", "foreverdb-npcs.tsv")
    if os.path.exists(npcs_path):
        for n in csv.DictReader(open(npcs_path, encoding="utf-8"), delimiter="\t"):
            fdb_npcs.setdefault(n["name"].lower(), []).append(n)

    # Le correzioni dell'utente (captures/manual-sources.tsv), dopo tutte le
    # fonti: le ha viste in gioco, e sono le uniche che tolgono qualcosa.
    #
    #   set     le righe della ricetta diventano tutte le sue provenienze, in
    #           ordine. Un NPC che c'era gia' tiene zona, coordinate e fazione
    #           che le fonti gli davano, quando la riga non le dice.
    #   remove  gli NPC della riga escono da ogni provenienza della ricetta, e
    #           una provenienza rimasta senza nessuno se ne va.
    #
    # Nato il 26/11 per i diciotto NPC di TBC che il dataset TBC dava a ricette
    # vanilla: Nakodu a Shattrath, Erilia a Eversong Woods. Su Forever non ci
    # sono, e Alchemist's Stone la vende Dala Fairmaw a Mount Hyjal.
    manual_set, manual_remove, manual_missing = {}, {}, []
    manual_path = os.path.join(HERE, "captures", "manual-sources.tsv")
    if os.path.exists(manual_path):
        for m in csv.DictReader(open(manual_path, encoding="utf-8"), delimiter="\t"):
            spell = int(m["spellId"])
            if m["action"] == "set":
                manual_set.setdefault(spell, []).append(m)
            elif m["action"] == "remove":
                names = {p.strip() for p in m["npcName"].split("|") if p.strip()}
                manual_remove.setdefault(spell, set()).update(names)
            else:
                raise SystemExit("manual-sources.tsv: azione sconosciuta %r" % m["action"])

    manual_changed = 0
    for spell, ms in manual_set.items():
        row = rows_by_spell.get(spell)
        if row is None:
            manual_missing.append(str(spell))
            continue
        known = {}
        for src in row["sources"]:
            for place in unpack(src):
                if place[0]:
                    known.setdefault(place[0], place)
        row["sources"] = []
        for m in ms:
            src = source(sourceKind=m["sourceKind"], npcName=m["npcName"], zone=m["zone"],
                         faction=m["faction"], bossDrop=m["bossDrop"], notes=m["notes"])
            places = unpack(src)
            for place in places:
                had = known.get(place[0]) if place[0] else None
                if had:
                    place[1] = place[1] or had[1]
                    place[4] = place[4] or had[4]
                    # Le coordinate valgono solo nella zona per cui erano.
                    if place[1] == had[1]:
                        place[2], place[3] = had[2], had[3]
            pack(src, places)
            add_source(row, src)
        manual_changed += 1

    for spell, names in manual_remove.items():
        row = rows_by_spell.get(spell)
        if row is None:
            manual_missing.append(str(spell))
            continue
        kept, matched = [], set()
        for src in row["sources"]:
            places = unpack(src)
            left = [p for p in places if p[0] not in names]
            matched |= {p[0] for p in places if p[0] in names}
            if len(left) == len(places):
                kept.append(src)
                continue
            if any(p[0] or p[1] for p in left):
                pack(src, left)
                src["notes"] = src["notes"] + " + tolti a mano: " + ", ".join(sorted(names))
                kept.append(src)
        # Un nome che non c'e' e' scritto male, e l'NPC che doveva uscire e'
        # ancora li': meglio fermarsi che scrivere un foglio che sembra giusto.
        if names - matched:
            manual_missing.append("%d senza %s" % (spell, ", ".join(sorted(names - matched))))
        row["sources"] = kept
        manual_changed += 1
    if manual_missing:
        raise SystemExit("manual-sources.tsv: non trovati nel foglio: %s" % manual_missing)

    for row in rows:
        for src in row["sources"]:
            if src["sourceKind"] not in ("vendor", "trainer") or not src["npcName"]:
                continue
            names = [p.strip() for p in src["npcName"].split("|")]
            n = len(names)
            zone, faction = positions(src["zone"], n, True), positions(src["faction"], n, True)
            x, y = positions(src["x"], n, False), positions(src["y"], n, False)
            touched = False
            for i, name in enumerate(names):
                spots = fdb_npcs.get(name.lower()) if name else None
                if x[i] or not spots or len(spots) != 1:
                    continue
                spot = spots[0]
                # Le coordinate valgono sulla mappa di foreverdb. Se per noi l'NPC
                # sta in un'altra zona, una delle due fonti sbaglia e non si sa
                # quale: si lascia com'e' e si conta.
                if zone[i] and spot["zone"].lower() not in zone[i].lower():
                    fdb_zone_conflicts.append((row["name"], name, zone[i], spot["zone"]))
                    continue
                x[i], y[i] = spot["x"], spot["y"]
                zone[i] = zone[i] or spot["zone"]
                if not faction[i] and spot["faction"]:
                    faction[i] = spot["faction"]
                    fdb_factions += 1
                fdb_coords += 1
                touched = True
            if touched:
                src.update(zone=" | ".join(zone), x=" | ".join(x), y=" | ".join(y),
                           faction=" | ".join(faction) if any(faction) else "")
                if "foreverdb" not in src["notes"]:
                    src["notes"] = (src["notes"] + " + " if src["notes"] else "") + "coordinate da foreverdb"

    # Il livello del mob, dal DB cmangos: sono creature vanilla e i loro livelli
    # non sono provenienza, sono anagrafica -- per questo si possono usare.
    for row in rows:
        for src in row["sources"]:
            if src["sourceKind"] == "drop" and src["npcName"]:
                cur.execute("select MinLevel,MaxLevel from creature_template where name=?",
                            (src["npcName"],))
                got = cur.fetchone()
                if got:
                    src["mobLevel"] = "%d-%d" % got

    # I Blueprint, per ultimi perche' il tipo sovrascrive quello delle fonti.
    # Chi e dove restano: il tier 1 lo insegnano i trainer, del tier 2 molti
    # cadono dai boss delle istanze basse e tre li vende Happy Camper, e
    # "Blueprint: Gilnid (The Deadmines)" dice al giocatore sia che cosa e'
    # sia dove andare. Cambia solo la principale: le altre restano quello che
    # sono, e la riga sotto dice "Vendor: Happy Camper".
    blueprints = 0
    for row in rows:
        if int(row["spellId"]) not in camp:
            continue
        if row["sources"]:
            primary = row["sources"][0]
            primary["sourceKind"] = "blueprint"
            primary["notes"] = (primary["notes"] + " + " if primary["notes"] else "") + "Blueprint dal client"
        else:
            note = (row["pending"] + " + " if row["pending"] else "") + "Blueprint dal client"
            row["sources"].append(source(sourceKind="blueprint", notes=note))
        blueprints += 1

    rows.sort(key=lambda r: (r["band"] != "forever", r["profession"],
                             r["learnSkill"] if r["learnSkill"] != "" else 999, r["name"]))

    # Una riga per provenienza, la principale per prima; una sola, vuota, per
    # la ricetta che nessuno sa.
    lines = []
    for row in rows:
        base = {c: row[c] for c in RECIPE_COLS}
        for src in row["sources"] or [source(notes=row["pending"])]:
            line = dict(base)
            line.update(src)
            lines.append(line)

    tmp = OUT + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=COLS, delimiter="\t")
        writer.writeheader()
        writer.writerows(lines)
    os.replace(tmp, OUT)

    multi = [r for r in rows if len(r["sources"]) > 1]
    print("ricette: %d | in gioco: %d | TBC: %d | scraping: %d | wowhead: %d (+%d trainer TBC corretti)"
          " | a mano: %d | foreverdb: %d | blueprint: %d | vuote: %d"
          % (len(rows), from_ingame, from_tbc, from_web, from_wowhead, tbc_trainer_fixed, filled,
             from_fdb, blueprints, sum(1 for r in rows if not r["sources"])))
    # Contate alla fine, non quando entrano: la correzione dei trainer TBC ne
    # toglie qualcuna che foreverchanges aveva aggiunto.
    extra = Counter(origin(s) for r in multi for s in r["sources"][1:])
    print("provenienze in piu': %d su %d ricette (%s)"
          % (sum(extra.values()), len(multi), ", ".join("%s %d" % kv for kv in extra.most_common())))
    print("correzioni a mano (captures/manual-sources.tsv): %d ricette" % manual_changed)
    merged = [npc for added in VENDOR_MERGES.values() for npc in added]
    print("venditori sommati da un'altra fonte: %d NPC su %d ricette (%s)"
          % (len(merged), len(VENDOR_MERGES),
             ", ".join("%s %d" % kv for kv in Counter(m[2] for m in merged).most_common())))
    print("coordinate da foreverdb: %d NPC (%d con la fazione); zona diversa, lasciati: %d"
          % (fdb_coords, fdb_factions, len(fdb_zone_conflicts)))
    for recipe, npc, ours, theirs in fdb_zone_conflicts[:12]:
        print("  %-30s %-22s noi %-28s foreverdb %s" % (recipe[:30], npc[:22], ours[:28], theirs))
    if disagree:
        print("\n=== WOWHEAD HA UN ALTRO TIPO SU %d RICETTE GIA' PIENE (principale -> wowhead) ===" % len(disagree))
        for (before, after), n in Counter((d[0], d[1]) for d in disagree).most_common():
            print("  %-10s -> %-10s %4d   es. %s" % (before, after, n,
                  ", ".join(d[2] for d in disagree if (d[0], d[1]) == (before, after))[:90]))
    low = [(r, s) for r in rows for s in r["sources"]
           if s["sourceKind"] == "drop" and s["mobLevel"] and int(s["mobLevel"].split("-")[1]) <= 20]
    print("\n=== DROP DA MOB <= LIVELLO 20 CHE CI MANCANO ===")
    for r, s in sorted(low, key=lambda rs: int(rs[1]["mobLevel"].split("-")[0])):
        print("  %-9s %-30s skill %-4s %-21s lv %-6s %s"
              % (r["profession"], r["name"], r["learnSkill"], s["npcName"],
                 s["mobLevel"], s["zone"]))
    print("totale:", len(low))


if __name__ == "__main__":
    main()
