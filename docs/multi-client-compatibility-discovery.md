# Multi-Client Compatibility Discovery

Fase 0 discovery per supportare Mists of Pandaria Classic e Classic Era mantenendo TBC Classic Anniversary come baseline senza regressioni.

Data: 2026-05-21.

## Stato

Completabile offline:

- Mappa preliminare delle API e dei file impattati.
- Matrice di compatibilita' iniziale.
- Scope professioni consigliato.
- Gate no-regression.
- Cross-check locale con `C:\Users\valer\Documents\ProfessionMaster`.

Richiede verifica in-game:

- Interface number effettivi con `/dump (select(4, GetBuildInfo()))`.
- Comportamento reale delle API professione su MoP Classic ed Era.
- Namespace/versioni reali di AtlasLoot, TSM e Auctionator installati sui tre client.
- Eventuali errori Lua legati ai frame Blizzard profession/options/tooltip.

## Fonti esterne consultate

- Warcraft Wiki TOC format: `https://warcraft.wiki.gg/wiki/TOC_format`
- Warcraft Wiki GetTradeSkillInfo: `https://warcraft.wiki.gg/wiki/API_GetTradeSkillInfo`
- Warcraft Wiki Classic API matrix: `https://warcraft.wiki.gg/wiki/World_of_Warcraft_API/Classic`
- Warcraft Wiki GetFirstTradeSkill: `https://warcraft.wiki.gg/wiki/API_GetFirstTradeSkill`
- Addon locale ProfessionMaster: `C:\Users\valer\Documents\ProfessionMaster`

Nota: Warcraft Wiki indica che i valori Interface sono aggiornati da contributor e possono essere non aggiornati. La fonte finale resta il client reale via `GetBuildInfo()`.

## Interface e packaging

Valori preliminari:

| Client | Interface preliminare | Stato |
|---|---:|---|
| TBC Classic Anniversary | `20505` | Attuale baseline repo; confermato da `ProfessionMaster_TBC.toc` |
| Mists of Pandaria Classic | `50503` | Confermato da `ProfessionMaster_Mists.toc`; resta verifica in-game |
| Classic Era / Vanilla | `11508` | Confermato da `ProfessionMaster_Vanilla.toc`; resta verifica in-game |

Direzione consigliata:

- Partire da singolo `RecipeRegistry.toc` con `## Interface: 50503, 20505, 11508`.
- Evitare TOC specifici finche' il load order resta identico.
- Usare TOC specifici solo se una fase successiva richiede file caricati diversamente per client.

Osservazione da ProfessionMaster:

- Usa TOC separati per espansione: Vanilla `11508`, TBC `20505`, Wrath `30405`, Cata `40402`, Mists `50503`.
- Ogni TOC carica dataset cumulativi per espansione: Vanilla solo vanilla; TBC vanilla+bcc; Mists vanilla+bcc+wrath+cata+mop.
- Questo conferma i numeri Interface preliminari, ma non sostituisce la verifica finale con `GetBuildInfo()` nel client reale.

## File e API impattati

### Profession scan

File principali:

- `Data.lua`
- `DataScan.lua`

API/oggetti da normalizzare:

- `GetNumSkillLines`
- `GetSkillLineInfo`
- `GetTradeSkillLine`
- `GetNumTradeSkills`
- `GetTradeSkillInfo`
- `GetTradeSkillItemLink`
- `GetTradeSkillRecipeLink`
- `ExpandTradeSkillSubClass`
- `CollapseTradeSkillSubClass`
- `GetTradeSkillSubClasses`
- `GetTradeSkillSubClassFilter`
- `SetTradeSkillSubClassFilter`
- `GetTradeSkillInvSlots`
- `GetTradeSkillInvSlotFilter`
- `SetTradeSkillInvSlotFilter`
- `GetTradeSkillItemNameFilter`
- `SetTradeSkillItemNameFilter`
- `GetTradeSkillItemLevelFilter`
- `SetTradeSkillItemLevelFilter`
- `TradeSkillOnlyShowMakeable`
- `TradeSkillOnlyShowSkillUps`
- `GetNumCrafts`
- `GetCraftInfo`
- `GetCraftItemLink`
- `GetCraftRecipeLink`
- `GetCraftSkillLine`
- `GetCraftDisplaySkillLine`
- `GetCraftItemNameFilter`
- `SetCraftItemNameFilter`

Rischi:

- Era e TBC dipendono dal vecchio split TradeSkill/Craft, soprattutto per Enchanting.
- ProfessionMaster usa anche su MoP il vecchio path `GetTradeSkill*`/`GetCraft*`, non `C_TradeSkillUI`; il rischio MoP resta sui return reali e sui filtri, non necessariamente su una migrazione obbligatoria a `C_TradeSkillUI`.
- I filtri devono essere sempre snapshot/restore con guardie `type(...) == "function"` e `pcall`.
- Le scansioni parziali devono continuare a non cancellare dati owner validi.

Evidenza da ProfessionMaster:

- `services/own-professions-service.lua` legge professioni crafting con `GetTradeSkillLine`, `GetNumTradeSkills`, `GetTradeSkillInfo`, `GetTradeSkillItemLink`, `GetTradeSkillRecipeLink`.
- Enchanting/CraftFrame usa `GetCraftDisplaySkillLine`, `GetNumCrafts`, `GetCraftInfo`, `GetCraftItemLink`.
- La rilevazione gathering combina `GetNumSkillLines`/`GetSkillLineInfo`, fallback `GetProfessions`/`GetProfessionInfo`, fallback spellbook e fallback persisted level.
- Per Recipe Registry la discovery suggerisce un adapter che mantenga il path attuale ma aggiunga fallback `GetProfessions`/`GetProfessionInfo` almeno per detection/rank su MoP.

### Guild roster

File principali:

- `Data.lua`
- `GuildLifecycleMaintenance.lua`
- `Core.lua`
- `SyncRuntime.lua`

API/oggetti da normalizzare:

- `GetNumGuildMembers`
- `GetGuildRosterInfo`
- `GetGuildRosterLastOnline`
- `C_GuildInfo.GuildRoster`
- `GuildRoster`
- `GUILD_ROSTER_UPDATE`

Rischi:

- Timing del roster diverso tra client.
- Snapshot incompleto non deve far marcare membri stale in modo aggressivo.
- La readiness sync deve restare conservativa.

Evidenza da ProfessionMaster:

- `services/player-service.lua` chiama `C_GuildInfo.GuildRoster()` e legge con `GetNumGuildMembers()`/`GetGuildRosterInfo()`.
- Recipe Registry ha gia' fallback `C_GuildInfo.GuildRoster`/`GuildRoster`; mantenerlo e' piu' conservativo di ProfessionMaster.

### Options/UI/tooltip

File principali:

- `Options.lua`
- `UI/MainFrame.lua`
- `Tooltip.lua`
- `MinimapButton.lua`

API/oggetti da normalizzare:

- `Settings.RegisterCanvasLayoutCategory`
- `Settings.RegisterAddOnCategory`
- `Settings.OpenToCategory`
- `InterfaceOptions_AddCategory`
- `InterfaceOptionsFrame_OpenToCategory`
- `InterfaceOptionsFramePanelContainer`
- `GameTooltip`
- `ItemRefTooltip`
- `OnTooltipSetItem`
- `OnTooltipSetSpell`
- `C_Item.GetItemQualityColor`

Rischi:

- Frame options diversi o mancanti nei client Classic.
- Tooltip hooks disponibili ma con timing diverso.
- `C_Item` puo' essere assente o parziale.

Evidenza da ProfessionMaster:

- `views/settings-view.lua` usa lo stesso pattern fallback: `Settings.RegisterCanvasLayoutCategory` + `Settings.RegisterAddOnCategory`, altrimenti `InterfaceOptions_AddCategory`; apertura via `Settings.OpenToCategory` o `InterfaceOptionsFrame_OpenToCategory`.
- `services/tooltip-service.lua` hooka `OnTooltipSetItem`, `OnTooltipSetSpell`, `OnTooltipCleared`, `OnTooltipSetUnit` e `GameTooltip:Show`.
- Questo supporta l'approccio attuale di Recipe Registry, ma resta necessario smoke test in-game per tooltip/frame specifici.

### Optional integrations

File principali:

- `DataAtlasLoot.lua`
- `Market.lua`

Namespace/API da verificare:

- `AtlasLootClassic`
- `AtlasLoot`
- `AtlasLoot.Data.Recipe`
- `AtlasLoot.Data.Profession`
- `TSM_API`
- `TSM_API_FOUR`
- `Auctionator.API.v1`

Rischi:

- Dataset AtlasLoot diversi per espansione.
- TSM/Auctionator possono non supportare tutti i client o avere API differenti.
- Il fallback deve restare graceful: niente errori Lua e UI funzionante anche senza prezzi/categorie.

Evidenza da ProfessionMaster:

- Non risultano riferimenti diretti a AtlasLoot, TSM o Auctionator.
- ProfessionMaster non puo' quindi verificare questi optional deps; restano punti da testare direttamente.

## Scope professioni consigliato

### TBC Classic Anniversary

Mantenere invariato:

- Alchemy
- Blacksmithing
- Cooking
- Enchanting
- Engineering
- Herbalism
- Jewelcrafting
- Leatherworking
- Mining
- Skinning
- Tailoring

Specializzazioni: mantenere la tabella attuale come baseline.

### Classic Era

Supportare:

- Alchemy
- Blacksmithing
- Cooking
- Enchanting
- Engineering
- Herbalism
- Leatherworking
- Mining
- Skinning
- Tailoring

Escludere o nascondere:

- Jewelcrafting
- Inscription

Da valutare solo se richiesto:

- First Aid
- Fishing

Nota da ProfessionMaster:

- ProfessionMaster include Fishing nel mapping spell ma non la tratta come professione principale mostrata.
- ProfessionMaster non mostra Skinning nella lista principale, mentre Recipe Registry attualmente lo traccia. Mantenerlo e' possibile, ma va trattato come professione senza ricette craftabili oppure escluso dalla UI se produce solo blocchi vuoti.

Specializzazioni da verificare:

- Blacksmithing
- Engineering
- Leatherworking

### Mists of Pandaria Classic

Supportare almeno:

- Alchemy
- Blacksmithing
- Cooking
- Enchanting
- Engineering
- Herbalism
- Inscription
- Jewelcrafting
- Leatherworking
- Mining
- Skinning
- Tailoring

Da valutare solo se richiesto:

- First Aid
- Fishing
- Archaeology

Specializzazioni da verificare:

- Spell ID professioni.
- Eventuali profession specializations ancora rilevanti.
- Skill rank/max rank return per professione.

Nota da ProfessionMaster:

- ProfessionMaster aggiunge Jewelcrafting da BCC in poi e Inscription da Wrath in poi.
- Il modello `profession-spells.lua` usa SkillLine ID `755` per Jewelcrafting e `773` per Inscription.
- Il dataset `models/skills/mop.lua` contiene skill con `["p"] = 755` e `["p"] = 773`, confermando lo scope MoP con Jewelcrafting + Inscription.

## Matrice supporto iniziale

| Area | TBC baseline | Era target | MoP target | Azione |
|---|---|---|---|---|
| TOC load | Attivo `20505` | Da aggiungere `11508` | Da aggiungere `50503` | Fase 2 |
| Profession detection | Vecchie API skill line | Probabilmente compatibile con pruning professioni | Da verificare con Inscription | Fasi 1, 3, 4 |
| TradeSkill scan | Baseline attuale | Probabilmente compatibile | Da adattare/testare | Fase 3 |
| Enchanting Craft scan | Baseline attuale | Necessario | Da verificare se ancora serve | Fase 3 |
| Guild roster | Baseline con fallback C_GuildInfo/GuildRoster | Da verificare timing | Da verificare timing | Fase 1 |
| Options panel | Gia' fallback Settings/InterfaceOptions | Da smoke test | Da smoke test | Fase 6 |
| Tooltip | Hook standard | Da smoke test | Da smoke test | Fase 6 |
| AtlasLoot | Optional/fallback | Dataset diverso | Dataset diverso | Fase 7 |
| TSM/Auctionator | Optional/fallback | Da verificare | Da verificare | Fase 7 |
| Sync Wire v3 | Baseline | Deve restare invariato | Deve restare invariato | Fase 5 |

## Criteri no-regression

Automated:

- `.\local-tests\run-backend-tests.ps1`
- `.\local-tests\run-backend-tests.ps1 -Suite sync`
- `.\local-tests\run-syntax.ps1`
- Nuovi profili harness: `tbc`, `era`, `mists`.
- Test dedicati per profession scope per client.
- Test dedicati per API mancanti/parziali.
- Test dedicati per scansione parziale senza perdita dati.
- Test sync legacy grep invariants ancora verdi.

Manual in-game:

- Login/reload senza errori Lua.
- `/rr` apre UI.
- `/rr options` apre opzioni.
- Apertura professione e scan manuale.
- Enchanting scan dove applicabile.
- Guild roster refresh e readiness sync.
- HELLO/SUMMARY visibili in diagnostica sync con un peer compatibile.
- Tooltip crafter su item/spell/recipe.
- Prezzi materiali: provider presente e provider assente.
- AtlasLoot presente e assente.

## Decisioni iniziali

- TBC resta la baseline: ogni refactor deve preservare il comportamento TBC esistente.
- La prima implementazione deve introdurre detection e adapter, non cambiare direttamente i flussi TBC esistenti.
- Professioni non presenti nel client vanno escluse dallo scope di scan/UI, non rimosse dai dati storici via merge.
- Il sync Wire v3 non deve usare client flavor come merge gate; al massimo come diagnostica/capability non-authoritative.
- La validazione finale richiede test in-game reali su tutti e tre i client.
