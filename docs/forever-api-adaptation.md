# Forever: adeguamento API

Fase 0 per il supporto a World of Warcraft: Forever, che dalle dichiarazioni
espone API in stile retail, senza toccare il comportamento su TBC.

A decidere cosa finisce in un pacchetto è il TOC: un TOC per flavor, uno zip
per TOC, e `main` porta i flavor tutti insieme. Il ramo decide un'altra cosa,
cioè dove sta il lavoro finché non è verificato: per la durata della beta
(17/09 - 21/10) l'adeguamento Forever vive su `feat/forever`, forkato da
`develop`, perché il client cambia di settimana in settimana e metà di quello
che segue è ancora deduzione. Rientra in `develop` quando le incognite qui
sotto sono chiuse su dati reali, e da lì la linea TBC resta rilasciabile senza
portarsi dietro lavoro in corso. Quindi la domanda di questo documento non è
"quale ramo", è **quali file** cambiano e quali no.

Data: 2026-09-17. Client di riferimento: `wow_classic_beta` 1.60.1.69893.

## Stato

Stabilito su dati reali:

- Inventario completo delle API classic usate in produzione, TradeSkill e Craft.
- Mappa di corrispondenza verso le API retail.
- Evidenza indiretta, dai file del client, che il sistema di crafting sia quello
  retail.

Non ancora verificato, e va verificato prima di scrivere codice:

- **Che Forever esponga davvero `C_TradeSkillUI`.** Oggi è una deduzione dalle
  dichiarazioni pubbliche più l'indizio sui dati qui sotto. Nessuno di noi ha
  ancora aperto il client.
- Interface number reale, con `/dump select(4, GetBuildInfo())`. Per la regola
  `major*10000 + minor*100 + patch` la 1.60.1 darebbe `16001`, ma è derivato.
- Se `ProfessionsFrame` esista, o se il frame si chiami ancora `TradeSkillFrame`.
- Comportamento di AtlasLoot, TSM e Auctionator su questo client.

## Inventario: cosa usiamo oggi

74 righe di produzione, 111 occorrenze, 20 API distinte, nessuna delle quali
esiste su un client retail. Zero occorrenze di `C_TradeSkillUI` in tutto il
codice.

| file | righe |
|---|---:|
| `Data/Data.lua` | 38 |
| `Data/DataScan.lua` | 35 |
| `Core/Core.lua` | 1 |

Due file di produzione portano il 99% della superficie. Il resto dell'addon non
sa su quale client sta girando, ed è la ragione per cui questo si fa per file e
non per ramo.

## Mappa classic -> retail

| classic (oggi) | usi | retail |
|---|---:|---|
| `SetTradeSkillItem` | 14 | `GameTooltip:SetRecipeResultItem` / `SetRecipeReagentItem` |
| `TradeSkillFrame` | 12 | `ProfessionsFrame` |
| `GetNumTradeSkills` | 9 | `C_TradeSkillUI.GetFilteredRecipeIDs` |
| `GetTradeSkillInfo` | 8 | `C_TradeSkillUI.GetRecipeInfo(recipeID)` |
| `TradeSkillOnlyShowMakeable` | 6 | `C_TradeSkillUI.SetOnlyShowMakeableRecipes` |
| `GetTradeSkillLine` | 6 | `C_TradeSkillUI.GetBaseProfessionInfo` |
| `GetTradeSkillRecipeLink` | 5 | `C_TradeSkillUI.GetRecipeLink(recipeID)` |
| `GetTradeSkillItemLink` | 5 | `C_TradeSkillUI.GetRecipeItemLink(recipeID)` |
| `ExpandTradeSkillSubClass` | 5 | nessuna corrispondenza diretta |
| `CollapseTradeSkillSubClass` | 4 | nessuna corrispondenza diretta |

E la famiglia Craft, che in TBC esiste **solo** per Enchanting:

| classic (oggi) | usi | retail |
|---|---:|---|
| `GetNumCrafts` | 7 | `C_TradeSkillUI.GetFilteredRecipeIDs` |
| `CraftFrame` | 7 | `ProfessionsFrame` |
| `GetCraftSkillLine` | 6 | `C_TradeSkillUI.GetBaseProfessionInfo` |
| `GetCraftInfo` | 6 | `C_TradeSkillUI.GetRecipeInfo` |
| `GetCraftDisplaySkillLine` | 6 | `C_TradeSkillUI.GetBaseProfessionInfo` |
| `GetCraftItemLink` | 5 | `C_TradeSkillUI.GetRecipeItemLink` |

Si noti la colonna di destra: **le due famiglie collassano nella stessa**. Su
retail Enchanting non ha API proprie, è un mestiere come gli altri. Quindi il
doppio percorso TradeSkill/Craft, che oggi è duplicazione obbligata, sul lato
Forever sparisce. È la parte di pulizia che si guadagna gratis.

## Il punto che non è una rinomina

`ExpandTradeSkillSubClass` e `CollapseTradeSkillSubClass` sono la vera
differenza, e il motivo per cui questo è riscrittura e non find-and-replace.

Il client classic espone la lista mestiere come **un array indicizzato piatto che
contiene anche le righe di intestazione**. Per questo esistono Expand e Collapse:
il codice deve espandere i sottogruppi per far comparire le ricette, e la nostra
scansione ci gira intorno. È una fonte nota di fragilità.

Il client retail non ha nulla di tutto questo. Espone **ID di ricetta** più un
**albero di categorie** separato, e non c'è niente da espandere perché niente è
nascosto dentro la lista.

Quindi `DataScan.lua` non va tradotto: il suo modello di iterazione sparisce.

Ed è il motivo per cui la separazione va fatta **per file** e non con le keyword
del packager sparse nel codice. Un `if` per flavor dentro una funzione che deve
iterare in due modi incompatibili diventa illeggibile in fretta; due file che
espongono la stessa interfaccia, caricati da TOC diversi, restano leggibili
entrambi:

```
RecipeRegistry_TBC.toc      -> Data/DataScan_Classic.lua
RecipeRegistry_Forever.toc  -> Data/DataScan_Forever.lua
```

Tutto il resto — Core, UI, Sync, Integrations, cioè il 89% del Lua — resta un
file solo, caricato da entrambi.

## L'indizio dai file del client

Non è una prova sulle API, ma non è nemmeno niente.

Il client Forever contiene `TradeSkillCategory` popolata: 216 categorie, con
nome, genitore, ordinamento e skill line. 34 sotto Blacksmithing, 28 sotto
Leatherworking, con figli veri (`Weapon Stones`, `Plate Helmets`, `Camping`).
1556 ricette ci sono agganciate.

Quella tabella è esattamente ciò che `C_TradeSkillUI.GetCategoryInfo` consuma su
retail. Un client TBC non ne ha bisogno, perché le sue categorie sono le righe di
intestazione dentro la lista piatta. Un client che la spedisce popolata, molto
probabilmente, ha la UI mestiere moderna dietro.

Dettaglio a margine, dallo stesso dato: l'albero pende in gran parte da skill
line **nuove** (2937-2948) mentre le ricette pendono ancora da quelle vanilla.
Il rework è cablato a metà, quindi il comportamento in beta può cambiare.

Fonte: `WowForeverMining`, bundle `forever-local-1.60.1.69893`, file
`trade_skill_categories.json`.

## Ordine di lavoro proposto

1. Avviare il client e confermare le tre incognite qui sopra. Finché non è fatto,
   qualunque codice scritto è scritto contro un'ipotesi.
2. Portare le 74 righe dietro una singola cucitura. `Core/Compat.lua` esiste
   già e fa questo mestiere per `C_AddOns`; è il posto giusto.
3. Riscrivere la scansione sul modello a ID di ricetta, eliminando Expand e
   Collapse invece di emularli.
4. Sbloccare il generatore per il flavor `forever` e importare il bundle. Da
   quel momento `forever` entra nella matrice di `recipe-metadata.yml`, che
   oggi contiene solo `tbc` proprio perché il generatore rifiuta il resto.
5. Aggiungere `RecipeRegistry_Forever.toc` con l'Interface confermata al punto
   1, e portare il tutto su `develop`. È l'esistenza di quel file, non il ramo
   su cui è stato scritto, a far uscire un secondo zip: finché il TOC non c'è,
   un tag su `main` non pubblica niente per Forever.

## Fonti

- Datamining: `../WowForeverMining`, dataset `forever-local-1.60.1.69893`.
- Analisi della scansione, secondo passo: `docs/forever-scan-rewrite.md`.
- La fonte finale per gli Interface number resta il client via `GetBuildInfo()`.
