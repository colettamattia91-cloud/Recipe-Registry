# La provenienza delle ricette di Forever, a mano

`acquisition-worksheet.tsv` accanto a questo file: 994 ricette che hanno un
oggetto-ricetta e per cui non sappiamo da dove venga. Le colonne da
`sourceKind` in poi sono vuote e si riempiono a mano; le sei prima
identificano la riga e non si toccano.

**Il file si rigenera, non si modifica a mano**:

```powershell
python .\Tools\build-acquisition-worksheet.py
```

Ricostruisce l'elenco dal bundle di datamining e dal DB cmangos, poi vi
riversa quello che sta in `Tools/captures/`. Scrive su un temporaneo e
sostituisce alla fine, perche' una versione precedente apriva il file in
scrittura prima di aver finito e un'eccezione a meta' lo ha troncato a due
righe. Quello che si raccoglie a mano va quindi messo in un file di
`captures/`, non digitato nel TSV.

## Perche' a mano

Non c'e' alternativa, ed e' stato verificato invece che dedotto. La
provenienza -- chi vende, chi droppa, chi insegna -- vive sul server: non e'
nei file del client, quindi nessun datamining la produce. Le tre fonti
pubbliche che sembrano averla sono tutte lo stesso dato di seconda mano:

- **ForeverChanges** dichiara cMaNGOS Classic per venditori e drop del
  contenuto vanilla, e Wowhead per quello nuovo.
- **LibItemDB** (MIT) porta 244 oggetti-ricetta con provenienza, tutti
  vanilla: **15** in piu' di quelli che il DB cmangos in
  `RecipeRegistry/tools/recipe-metadata/snapshots/` copre gia', e sono eventi
  stagionali e quartermaster reputazione. Zero righe sul contenuto Forever.
- **Wowhead** ce l'ha perche' migliaia di client dei giocatori glielo
  caricano. E' la sola fonte del contenuto nuovo, e non e' replicabile da
  soli. Dal 25/10 si legge direttamente, una pagina-oggetto per ricetta, con
  `Tools/scrape-wowhead.py` (in `captures/wowhead-recipes.tsv`): riempie le
  righe che foreverchanges lascia vuote, e conta dove i due non concordano.
- **foreverdb.net** (dal 18/11) e' CMaNGOS Classic piu' cio' che il suo addon
  companion ha visto su Forever. Si prende solo la seconda parte: trainer
  visti insegnare la ricetta, venditori visti venderla, posizione degli NPC
  visti. Entra per ultimo nel builder, a riempire righe vuote e coordinate
  mancanti, senza correggere niente. `python Tools/scrape-foreverdb.py`
  scrive `captures/foreverdb-recipes.tsv` e `captures/foreverdb-npcs.tsv`;
  `--save <cartella>` tiene gli snapshot scaricati, `--from <cartella>` li
  rilegge senza rete.

Quindi le righe vuote qui sono il residuo dopo aver spremuto tutto il
replicabile: 994 il 24/09, 424 il 25/10 dopo Wowhead. Di queste, 265
Wowhead le conosce senza sapere da dove vengano, e 62 su Forever non le ha:
resta la cattura in gioco.

## Vocabolario

Lo stesso del dataset TBC, perche' `RecipeMetadata:GetSource` legge quei campi
e la UI (`sourceLabelFor` in `Data/DataCatalog.lua`) sa gia' renderli. Non
inventarne di nuovi.

`sourceKind` -- uno di: `trainer`, `vendor`, `drop`, `worldDrop`, `quest`,
`container`, `blueprint`, `discovery`, `worldEvent`.

`blueprint` e' l'unico che TBC non ha: sono le ricette da campo di Forever
-- tenda, falo', fermentatore, forno, forgia arcana, banco da lavoro.
**Non si scrive a mano e non viene da una fonte:** il builder lo mette alle
ricette che il client mette nella categoria "Camping" del loro mestiere, 39 in
tutto. Il tier 1 lo insegna il trainer a 20 (Mana Well, Camp Tent, Basic
Campfire...); i tier 2-4 si imparano da un oggetto "Blueprint: ...". Sono
Blueprint tutti, perche' sono tutti oggetti da campo (decisione dell'utente,
18/11). Il testo "Blueprint" della raccolta del 24/09 lo dava anche a undici
Formula di Enchanting (idol, libram, totem), e ne mancava piu' della meta'.
NPC e zona restano quando si conoscono, e la riga in UI e'
"Blueprint: Gilnid (The Deadmines)"; dove non si sa, la sola parola
"Blueprint".

- `npcName` / `zone` -- chi e dove. Una delle due puo' mancare: una ricetta
  che insegnano tutti i trainer non nomina niente. Per una quest `npcName` e'
  il nome della quest, quando la fonte lo da'.
- `x` / `y` -- coordinate, se le hai. Opzionali.
- `faction` -- `alliance` o `horde`. **Vuoto quando vale per entrambe**, che e'
  il caso normale: non scrivere "both".
- `bossDrop` -- `true` solo se chi droppa e' un boss. Un mob comune e' una
  specie, non un nome: per quelli lascia `npcName` vuoto e tieni la zona.
- `worldDrop` -- `true` per il drop da mondo, e allora zona e nome non
  servono.
- `trainerTitle` -- per le ricette da trainer che nessun NPC singolo insegna:
  il titolo che il giocatore legge sotto l'NPC.

## Quello che sappiamo gia' e non va cercato

- **I quartermaster a Merchant's Favor**: 316 ricette su sette mestieri, tutti
  in due punti -- Azeroth Commerce Authority a Three Corners (Redridge) per
  l'Alliance, Durotar Supply and Logistics fuori dal Crossroads (Barrens) per
  l'Horde. Si catturano in gioco aprendo una finestra per mestiere, e allora
  sono `vendor` con nome e zona veri invece che copiati. L'elenco dei
  quattordici NPC e' nella conversazione del 2026-09-23.
- **Le 495 ricette senza oggetto-ricetta** non sono in questo file: non
  avendo un oggetto che le insegni sono quasi certamente da trainer. Misurato
  sul sottoinsieme vanilla dove il confronto e' possibile: 412 su 458, il 90%.
- Il campo `learnSkill` viene dal `RequiredSkillRank` dell'oggetto-ricetta,
  non da `requiredSkill` del datamining, che su Forever vale 1 su tutto.
  Dove e' vuoto o 0, l'oggetto non porta il campo: 38 righe, e non si sa a
  che livello si imparano.

## Piu' provenienze per ricetta

Dal 26/11 una ricetta puo' avere piu' righe, una per provenienza, con le
stesse sei colonne iniziali. Su Forever le combinazioni sono vere: Pattern:
Blue Suede Armor cade da Shadowsworn Thug ed e' premio di Leather Technique.
Prima la prima fonte che riempiva la riga cancellava le altre.

- **La prima riga e' la principale**, ed e' quella che il foglio avrebbe avuto
  con una riga sola: le fonti entrano nello stesso ordine di fiducia di prima
  (TBC, foreverchanges, Wowhead, raccolta di settembre, cattura in gioco,
  foreverdb). Il generatore la scrive nei campi di sempre; le altre vanno in
  `alsoSources`, nello stesso ordine.
- **Un tipo per ricetta**: ogni fonte aggiunge solo un tipo che la ricetta non
  ha, e drop e world drop contano come uno. Due fonti che danno lo stesso tipo
  con cose diverse non diventano due righe: una delle due sbaglia.
- **Tranne i venditori, che si sommano per nome**: un venditore nominato non
  esclude gli altri. Chi c'era tiene zona, coordinate e fazione, i nuovi
  entrano in coda coi loro. Gingerbread Cookie aveva dal dataset TBC i
  venditori di Stormwind e Thunder Bluff, e foreverchanges porta quelli di
  Ironforge, Orgrimmar e Undercity.
- **Restano sostituzioni** le due eccezioni decise: il trainer che il dataset
  TBC da' a ricette vanilla che su Forever droppano (vince Wowhead, il trainer
  sparisce) e `PREFER_WOWHEAD` (resta solo Wowhead).
  Quando il drop di Wowhead che sostituisce il trainer non dice ne' chi ne'
  dove, e un'altra fonte lo sa, sostituisce il drop di quella.
- **Wowhead da' piu' righe per oggetto** (`scrape-wowhead.py --report`): sulla
  pagina-oggetto venditori, drop, contenitori e quest; negli elenchi i codici
  di `source` con le voci di `sourcemore`, in parallelo quando sono lunghe
  uguali, altrimenti ogni voce al tipo che dice di se'. La prima riga e'
  quella che usciva quando ne usciva una sola.
- **La cattura in gioco** fonde i venditori visti nella riga `vendor` della
  ricetta, e se non c'e' ne aggiunge una.
- **Le quest portano il nome** in `npcName` quando la fonte lo da', e la UI
  scrive "Quest: Leather Technique (Desolace)".

## Correzioni a mano

`captures/manual-sources.tsv` e' l'unico posto dove una provenienza si toglie.
Ci va cio' che l'utente ha verificato in gioco, e il builder lo applica dopo
tutte le fonti:

- `set` -- le righe di quella ricetta diventano tutte le sue provenienze, in
  ordine (la prima e' la principale). Un NPC che le fonti avevano gia' tiene la
  zona, la fazione e, se la zona e' la stessa, le coordinate.
- `remove` -- gli NPC elencati in `npcName` escono da ogni provenienza della
  ricetta. Un nome che il foglio non ha ferma il builder: e' scritto male, e
  l'NPC che doveva uscire sarebbe ancora li'.

Nato il 26/11 per le diciotto ricette vanilla a cui il dataset TBC dava NPC di
Outland o delle zone di partenza TBC (Nakodu a Shattrath, Erilia a Eversong
Woods), che su Forever non ci sono.

## Ordine

Le righe sono ordinate per banda (prima `forever`, che e' l'unica di cui
nessuno ha i dati), poi mestiere, poi `learnSkill` crescente. La fascia bassa
sta quindi in testa a ogni mestiere, che e' anche la piu' facile da verificare
di persona. Le righe di una stessa ricetta stanno insieme, la principale per
prima.
