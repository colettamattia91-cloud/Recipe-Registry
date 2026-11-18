"""Trainer, venditori e NPC visti su Forever, dai dati pubblici di foreverdb.net.

Il sito serve JSON statici: `data/professions.json` elenca i mestieri,
`data/profguides/learn-<mestiere>.json` porta per ogni ricetta (chiave: lo
spellId) chi la insegna, chi la vende, chi la droppa, e una tabella degli NPC
con mappa e coordinate. `data/maps/zones.json` da' il nome di ogni mappa.

Il sito dichiara che trainer e venditori sono dati Classic (CMaNGOS) salvo
quelli "visti su Forever" dal suo addon companion, e lo segna campo per campo:

    fv   i nomi dei trainer visti insegnare la ricetta su Forever
    vo   i venditori visti venderla su Forever, per id NPC
    npcs[id][6]   1 se l'NPC e' stato visto su Forever

**Si prende solo quella parte.** La parte Classic l'abbiamo gia' da
foreverchanges e dal dataset TBC, e i drop dalle stesse fonti e da Wowhead
(contro il quale quelli di foreverdb concordano su due terzi, 18/11). Scelta
dell'utente del 18/11: foreverdb entra per ultimo, a riempire le righe vuote e
le coordinate mancanti.

Scrive due file in captures/:
    foreverdb-recipes.tsv   una riga per ricetta con un trainer o un venditore visti
    foreverdb-npcs.tsv      gli NPC visti su Forever con mappa e coordinate

    python Tools/scrape-foreverdb.py
    python Tools/scrape-foreverdb.py --from <cartella con gli snapshot salvati>
"""
import argparse, json, os, subprocess, sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_RECIPES = os.path.join(HERE, "captures", "foreverdb-recipes.tsv")
OUT_NPCS = os.path.join(HERE, "captures", "foreverdb-npcs.tsv")
BASE = "https://foreverdb.net/data/"

RECIPE_COLS = ["spellId", "recipeItemId", "profession", "sourceKind", "npcName", "zone",
               "x", "y", "faction", "notes"]
NPC_COLS = ["npcId", "name", "title", "zone", "x", "y", "faction"]

SIDE = {"Alliance": "alliance", "Horde": "horde"}


def loader(source_dir, save_dir):
    """Una funzione che da' il JSON di un percorso relativo a data/.

    Con --from legge i file salvati, con il nome piatto che il download da'
    (profguides/learn-x.json -> learn-x.json, maps/zones.json -> maps-zones.json).
    """
    def flat(path):
        return path.replace("profguides/", "").replace("/", "-")

    def load(path):
        if source_dir:
            with open(os.path.join(source_dir, flat(path)), encoding="utf-8") as f:
                return json.load(f)
        got = subprocess.run(["curl", "-sSL", "--max-time", "60", BASE + path],
                             capture_output=True, text=True, encoding="utf-8", errors="replace")
        if got.returncode != 0 or not got.stdout:
            raise SystemExit("download fallito: %s (%s)" % (path, got.stderr.strip()))
        if save_dir:
            with open(os.path.join(save_dir, flat(path)), "w", encoding="utf-8") as f:
                f.write(got.stdout)
        return json.loads(got.stdout)
    return load


def write_tsv(path, cols, rows):
    tmp = path + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        f.write("\t".join(cols) + "\n")
        for row in rows:
            f.write("\t".join(str(row.get(c, "")) for c in cols) + "\n")
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--from", dest="source", help="cartella con gli snapshot gia' scaricati")
    parser.add_argument("--save", help="cartella dove salvare gli snapshot scaricati")
    args = parser.parse_args()
    load = loader(args.source, args.save)

    zones = {z["m"]: z["n"] for z in load("maps/zones.json")["zones"] if "m" in z}
    index = load("professions.json")

    recipes, npcs = [], {}
    for prof in index["professions"]:
        data = load("profguides/learn-%s.json" % prof["slug"])
        if len(data["r"]) != prof["count"]:
            raise SystemExit("snapshot incompleto: %s" % prof["slug"])

        def place(npc_id):
            """Nome, zona, coordinate e fazione di un NPC, se la mappa ha un nome.

            Le mappe senza nome sono il continente (1414) e lo 0: coordinate su
            una mappa che non sappiamo nominare non dicono niente al giocatore.
            """
            npc = data["npcs"].get(str(npc_id))
            if not npc:
                return None
            name, title, side, map_id, x, y, seen = npc[:7]
            zone = zones.get(map_id, "")
            spot = {"npcId": npc_id, "name": name, "title": title or "",
                    "faction": SIDE.get(side, ""), "zone": zone, "x": "", "y": ""}
            if zone and (x or y):
                spot["x"], spot["y"] = "%.1f" % x, "%.1f" % y
            if seen and spot["x"]:
                npcs[npc_id] = spot
            return spot

        # Ogni NPC visto su Forever, anche quelli che nessuno ha ancora visto
        # vendere una ricetta precisa: la posizione e' comunque un'osservazione,
        # ed e' quella che serve a chi va a cercarlo.
        for npc_id in data["npcs"]:
            place(int(npc_id))

        for spell, r in data["r"].items():
            kind, spots = "", []
            if r.get("fv"):
                # fv da' i nomi; la posizione sta negli NPC trainer della
                # ricetta (tr, e trI dove il sito li ha dedotti), per nome.
                ids = [i for lst in (r.get("tr") or {}).values() for i in lst]
                ids += [i for lst in (r.get("trI") or {}).values() for i in lst]
                by_name = {}
                for i in ids:
                    spot = place(i)
                    if spot:
                        by_name.setdefault(spot["name"].lower(), spot)
                # Un nome che non e' fra i trainer della ricetta non si
                # tiene: e' il nome che ha letto un giocatore col client in
                # un'altra lingua ("Bengus Forjahonda" e' Bengus Deepforge in
                # spagnolo, 18/11), e non si saprebbe ne' scriverlo ne'
                # posizionarlo. Nessuna ricetta resta senza trainer per questo.
                kind = "trainer"
                spots = [by_name[n.lower()] for n in r["fv"] if n.lower() in by_name]
            elif r.get("vo"):
                kind = "vendor"
                for npc_id in r["vo"]:
                    spots.append(place(int(npc_id)) or {"name": ""})
                spots = [s for s in spots if s.get("name")]
            if not kind or not spots:
                continue

            def column(field):
                values = [str(s.get(field, "")) for s in spots]
                return " | ".join(values) if any(values) else ""

            recipes.append({
                "spellId": spell, "recipeItemId": r.get("book") or "",
                "profession": prof["slug"], "sourceKind": kind,
                "npcName": column("name"), "zone": column("zone"),
                "x": column("x"), "y": column("y"), "faction": column("faction"),
                "notes": "foreverdb, %s visto su Forever" % ("trainer" if kind == "trainer" else "venditore"),
            })

    recipes.sort(key=lambda r: int(r["spellId"]))
    write_tsv(OUT_RECIPES, RECIPE_COLS, recipes)
    write_tsv(OUT_NPCS, NPC_COLS, sorted(npcs.values(), key=lambda n: (n["name"], n["npcId"])))

    print("ricette con trainer o venditore visti: %d -> %s" % (len(recipes), OUT_RECIPES))
    for kind, n in Counter(r["sourceKind"] for r in recipes).most_common():
        print("   %-8s %d" % (kind, n))
    print("NPC visti con coordinate: %d -> %s" % (len(npcs), OUT_NPCS))


if __name__ == "__main__":
    main()
