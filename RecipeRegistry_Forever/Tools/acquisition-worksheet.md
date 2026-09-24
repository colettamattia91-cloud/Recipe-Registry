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
  soli.

Quindi le 994 righe qui sono il residuo dopo aver spremuto tutto il
replicabile.

## Vocabolario

Lo stesso del dataset TBC, perche' `RecipeMetadata:GetSource` legge quei campi
e la UI (`sourceLabelFor` in `Data/DataCatalog.lua`) sa gia' renderli. Non
inventarne di nuovi.

`sourceKind` -- uno di: `trainer`, `vendor`, `drop`, `worldDrop`, `quest`,
`container`, `blueprint`, `discovery`, `worldEvent`.

`blueprint` e' l'unico che TBC non ha: sono le postazioni di Forever --
fermentatore, forno, forgia arcana, banco da lavoro, tavolo da conciatura --
che non le insegna nessuno e non stanno da nessuna parte, arrivano col sistema
di perk del mestiere. Percio' non hanno ne' NPC ne' zona, e la riga in UI e'
la sola parola "Blueprint".

- `npcName` / `zone` -- chi e dove. Una delle due puo' mancare: una quest
  nomina la zona e nessuno, una ricetta che insegnano tutti i trainer non
  nomina niente.
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

## Ordine

Le righe sono ordinate per banda (prima `forever`, che e' l'unica di cui
nessuno ha i dati), poi mestiere, poi `learnSkill` crescente. La fascia bassa
sta quindi in testa a ogni mestiere, che e' anche la piu' facile da verificare
di persona.
