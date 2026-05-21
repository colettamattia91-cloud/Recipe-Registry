# Multi-Client Compatibility Discovery

Fase 0 discovery per supportare Mists of Pandaria Classic e Classic Era mantenendo TBC Classic Anniversary come baseline senza regressioni.

Data: 2026-05-21.

## Stato

Completabile offline:

- Mappa preliminare delle API e dei file impattati.
- Matrice di compatibilita' iniziale.
- Scope professioni consigliato.
- Gate no-regression.

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

Nota: Warcraft Wiki indica che i valori Interface sono aggiornati da contributor e possono essere non aggiornati. La fonte finale resta il client reale via `GetBuildInfo()`.

## Interface e packaging

Valori preliminari:

| Client | Interface preliminare | Stato |
|---|---:|---|
| TBC Classic Anniversary | `20505` | Attuale baseline repo |
| Mists of Pandaria Classic | `50503` | Da confermare in-game |
| Classic Era / Vanilla | `11508` | Da confermare in-game |

Direzione consigliata:

- Partire da singolo `RecipeRegistry.toc` con `## Interface: 50503, 20505, 11508`.
- Evitare TOC specifici finche' il load order resta identico.
- Usare TOC specifici solo se una fase successiva richiede file caricati diversamente per client.

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
- MoP Classic potrebbe avere API Classic moderne/backportate ma non identiche nei return e nei filtri.
- I filtri devono essere sempre snapshot/restore con guardie `type(...) == "function"` e `pcall`.
- Le scansioni parziali devono continuare a non cancellare dati owner validi.

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
