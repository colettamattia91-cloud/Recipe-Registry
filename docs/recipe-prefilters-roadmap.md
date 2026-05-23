# Recipe UI Prefilters: analisi tecnica e roadmap

## Contesto e obiettivi

Recipe Registry oggi costruisce una directory di ricette condivisa a livello gilda: la UI mostra ricette note localmente o ricevute via sync, i crafter disponibili, materiali e stime di costo. Questo modello e utile per ricette craftabili per altri giocatori, ma produce rumore in due casi:

- ricette che producono item `binds when picked up` (BoP), dove in pratica solo il personaggio che possiede e usa la ricetta puo beneficiare del craft;
- ricette Vanilla/pre-TBC, che sono spesso meno rilevanti nel contesto TBC Classic Anniversary e rendono piu pesante lista, ricerca e dettaglio.

L'obiettivo e introdurre prefiltri UI, applicati prima possibile nel flusso di caricamento/rendering, per escludere queste ricette dal comportamento predefinito senza cambiare il database sync sottostante. L'utente deve poter disabilitare i filtri e ripristinare il comportamento attuale.

## Comportamento attuale ipotizzato

Il flusso principale in `UI/MainFrame.lua` e:

1. La selezione della vista/professione aggiorna `UI.selectedProfession`, `UI.selectedCategory` e resetta `UI.selectedRecipeKey`.
2. `UI:RefreshRecipeList()` calcola:
   - `effectiveProfession`;
   - `categoryFilter`;
   - ricerca globale e modalita sort.
3. La lista viene costruita tramite `Addon.Data:BuildRecipeListAsync(effectiveProfession, searchText, sortMode, searchMode, categoryFilter, callback)`.
4. Se il risultato non e inline, `_ShowRecipeListLoadingState()` mostra un header `loading...`.
5. `_FinalizeRecipeList(rows, context, generation)`:
   - applica oggi solo il filtro Favorites lato UI;
   - aggiorna `self.currentRecipeRows`;
   - verifica se `self.selectedRecipeKey` esiste ancora;
   - auto-seleziona la prima ricetta visibile quando necessario;
   - chiama `RenderVisibleRecipeRows()`, `RefreshSummaryCards()` e `RefreshDetailPanel()`.
6. `RenderVisibleRecipeRows()` usa righe virtualizzate e `BindRecipeRow()`.
7. `BindRecipeRow()` chiama lazy `RefreshRecipeRowAssets()`, che usa `Data:GetRecipeDisplayInfo(recipeKey)` per label, icone, created item, recipe item e metadati visuali.
8. `RefreshDetailPanel()` usa `Addon.Data:GetRecipeDetail(self.selectedRecipeKey)` e renderizza:
   - titolo e sottotitolo;
   - crafter online/offline;
   - materiali;
   - cost estimate.

Nel data layer, `DataCatalog.lua` contiene i punti piu rilevanti:

- `Data:GetRecipeDisplayInfo(recipeKey)`: costruisce/cacha metadati display, spesso arricchiti da AtlasLoot.
- `Data:GetRecipeList(...)` e `Data:BuildRecipeListAsync(...)`: costruiscono righe lista e ordinamento.
- `Data:GetRecipeDetail(recipeKey)`: estende i metadati display con crafter, reagenti, costi.

Assunzione importante: i filtri richiesti devono essere filtri UI/catalogo, non filtri sync. I dati ricevuti dai peer devono restare salvati e indicizzati, cosi l'utente puo riattivare la visualizzazione completa senza dover risincronizzare.

## Requisiti funzionali

### RF1 - Prefiltro item BoP

Escludere dalla UI le ricette il cui output e un item `binds when picked up`, tranne quando la ricetta appartiene al personaggio locale/profilo corrente.

Regola proposta:

- se il created item non e BoP: mostra normalmente;
- se il created item e BoP:
  - mostra solo se il player locale e tra i crafter/owner della ricetta;
  - nascondi se la ricetta e nota solo tramite altri membri gilda.

Motivazione: se un craft produce un BoP, un altro crafter non puo produrre un item commerciabile per il player. Il proprietario locale puo comunque voler vedere la propria ricetta per materiali, costo o consultazione personale.

### RF2 - Prefiltro Vanilla/pre-TBC

Escludere per default le ricette classificate come Vanilla/pre-TBC. Le ricette TBC restano visibili.

La classificazione non dovrebbe basarsi solo su skill rank o nome:

- alcune ricette TBC possono avere rank bassi;
- alcuni oggetti/ricette possono essere presenti in AtlasLoot con categorie non sufficienti;
- enchanting e professioni secondarie hanno casi particolari.

Serve una fonte metadata esplicita: `recipeExpansion = "vanilla" | "tbc" | "unknown"`.

### RF3 - Opzioni utente

Entrambi i prefiltri devono essere disabilitabili. Disabilitarli deve ripristinare il comportamento attuale della UI, cioe mostrare tutte le ricette note/sincronizzate.

### RF4 - Configurazione per professione

Per ogni professione l'utente deve poter scegliere se:

- usare il comportamento globale;
- mostrare solo TBC;
- includere anche Vanilla/pre-TBC.

### RF5 - Globale con override

Serve una impostazione globale, ad esempio `solo TBC`, con override per singola professione. Esempio:

- globale: solo TBC;
- Enchanting: includi anche Vanilla;
- Alchemy/Blacksmithing/etc: ereditano solo TBC.

## Proposta di configurazione utente

Nuove opzioni in `RecipeRegistryDB.profile`, con nomi indicativi:

```lua
recipePrefilters = {
    hideBopOutputs = true,
    expansionMode = "tbc_only", -- "tbc_only" | "all"
    professionExpansionOverrides = {
        -- ["Enchanting"] = "all",
        -- ["Alchemy"] = "tbc_only",
        -- nil/assente = inherit globale
    },
    unknownExpansionMode = "show", -- "show" | "hide"; consigliato show in V1
}
```

Default proposto:

- `hideBopOutputs = true`;
- `expansionMode = "tbc_only"`;
- `professionExpansionOverrides = {}`;
- `unknownExpansionMode = "show"` per evitare falsi negativi su ricette non ancora classificate.

UI opzioni:

- sezione `Recipe filters` nel pannello opzioni;
- checkbox: `Hide BoP output recipes unless known by this character`;
- dropdown globale: `Expansion filter: TBC only / All recipes`;
- tabella per-professione:
  - `Inherit global`;
  - `TBC only`;
  - `All recipes`.

Nota UX: quando i filtri sono attivi, la UI dovrebbe evitare messaggi invasivi. Un indicatore leggero nel summary/header puo essere utile, ad esempio `TBC filter active`, ma non e necessario per V1.

## Impatto sui dati e sui filtri

### Metadata necessari

Per ogni `recipeKey` servono almeno:

```lua
{
    recipeKey = ...,
    professionName = "Enchanting",
    createdItemID = 12345,
    recipeItemID = 23456,
    spellID = 34567,
    outputBindType = 1, -- 1 = BoP / bind on acquire, se disponibile
    recipeExpansion = "tbc",
}
```

Possibili fonti:

- `GetItemInfo(createdItemID)`: in WoW Classic/TBC puo esporre `bindType` tra i valori ritornati. Da verificare nel client target e nel mock test.
- AtlasLoot: utile per `createdItemID`, `recipeItemID`, professione, reagenti e possibilmente classificazione, ma non va dato per completo.
- Tabella curated locale: consigliata per `recipeExpansion` e per fallback BoP quando l'API item cache non e pronta.

### Dove applicare il prefiltro

Il punto ideale e nel data layer, prima che le righe lista vengano consegnate alla UI:

- `Data:GetRecipeList(...)`;
- `Data:BuildRecipeListAsync(...)`;
- eventuale helper condiviso tipo `Data:RecipePassesUiPrefilters(recipeKey, detail, opts)`.

Vantaggi:

- riduce il numero di righe costruite/ordinate;
- riduce chiamate lazy a `GetRecipeDisplayInfo`;
- evita che Favorites/global search/category applichino regole divergenti;
- centralizza cache key e invalidazione.

La UI deve comunque difendersi:

- `_FinalizeRecipeList()` deve continuare a verificare che `selectedRecipeKey` sia ancora visibile;
- `RefreshDetailPanel()` dovrebbe non renderizzare un dettaglio se la ricetta selezionata non passa piu i filtri correnti;
- quando un filtro cambia, va incrementata la generazione lista e invalidata la cache visibile.

### Cache key

Le cache lista devono includere i nuovi parametri:

- `hideBopOutputs`;
- expansion mode effettivo per professione;
- `unknownExpansionMode`;
- eventuale versione/generazione metadata.

Se si usa `Data:GetRecipeList` e `BuildRecipeListAsync`, la cache key deve distinguere:

```text
profession|search|sort|searchMode|category|hideBop|expansionMode|unknownMode|metadataGeneration
```

### Favorites

`UI:BuildFavoriteRecipeRows()` oggi costruisce righe dai favorite key e cammina l'indice ricette. Anche Favorites deve rispettare i prefiltri per coerenza, salvo opzione futura `Favorites ignore filters`. Per V1: Favorites rispetta i filtri attivi.

### Global search

La ricerca globale deve rispettare gli stessi prefiltri. Se l'utente cerca una ricetta Vanilla con `TBC only` attivo, non deve apparire. Disabilitando il filtro deve tornare visibile.

## Punti del codice da investigare/modificare

### `UI/MainFrame.lua`

Punti principali:

- `UI:RefreshRecipeList()`
  - costruisce il contesto della lista;
  - deve passare le opzioni filtro effettive al data layer;
  - deve includere il filtro nel `context` per header/sommario.

- `UI:_FinalizeRecipeList(rows, context, generation)`
  - oggi filtra solo Favorites;
  - deve mantenere selezione coerente se la ricetta selezionata viene filtrata;
  - puo aggiornare header/summary con eventuale indicatore filtro.

- `UI:BuildFavoriteRecipeRows()`
  - deve usare lo stesso predicato `RecipePassesUiPrefilters`.

- `UI:RefreshDetailPanel()`
  - deve gestire il caso in cui `selectedRecipeKey` non passi piu i filtri;
  - deve evitare render stale quando un'opzione cambia.

- `UI:RefreshProfessionButtons()`
  - possibile punto per indicare override professione o conteggi filtrati;
  - da valutare in V2, non obbligatorio per V1.

### `Data/DataCatalog.lua`

Punti principali:

- `Data:GetRecipeDisplayInfo(recipeKey)`
  - arricchire `info` con `outputBindType`, `isOutputBop`, `recipeExpansion`;
  - fare refresh quando item cache diventa disponibile.

- `Data:GetRecipeList(...)`
  - aggiungere parametro opzioni filtro o oggetto `uiFilterOptions`;
  - applicare predicato prima di inserire riga.

- `Data:BuildRecipeListAsync(...)`
  - stesso filtro del path sync;
  - cache key estesa.

- `Data:GetRecipeDetail(recipeKey)`
  - dettaglio puo includere metadati filtro per debug/tooltip.

### `Options.lua`

- aggiungere controlli profilo;
- al cambio opzione:
  - invalidare recipe list cache;
  - invalidare detail/list visible cache;
  - richiedere refresh UI.

### `Core.lua` / defaults DB

- aggiungere defaults profilo;
- bump schema solo se il progetto richiede migrazione esplicita per nuovi defaults;
- comando diagnostico opzionale, ad esempio `/rr filters`.

### Test harness

- estendere mock `GetItemInfo` se serve restituire `bindType`;
- aggiungere helper per metadata expansion;
- coprire path sync e async lista.

## Rischi e casi limite

### Item cache incompleta

`GetItemInfo(createdItemID)` puo non essere pronto. Se il bind type non e disponibile:

- non filtrare come BoP solo per assenza dati;
- marcare metadata come `unknown`;
- aggiornare quando arriva item cache event;
- evitare flicker aggressivo.

### Ricette senza created item

Enchanting diretto e alcune ricette spell-based possono non avere `createdItemID`.

Regola proposta:

- BoP filter non si applica se manca `createdItemID`;
- expansion filter usa recipe/spell metadata, non solo output item.

### BoP ma owner locale multiplo

Se il player ha piu personaggi/profili, "solo chi effettivamente ha quella recipe" va definito come:

- V1: il personaggio corrente (`Data:GetPlayerKey()`) deve risultare owner/crafter della ricetta;
- V2 opzionale: profili/alt locali sullo stesso account possono essere trattati come visibili se esiste una nozione affidabile di "mio alt".

### Ricette ricevute via sync

Non filtrare in sync, merge o fingerprint. Filtrare solo in UI. Altrimenti cambiare opzione richiederebbe risync o invaliderebbe fingerprint contenuto.

### Classificazione Vanilla/TBC incompleta

I falsi positivi sono peggiori dei falsi negativi: nascondere una ricetta TBC per errore danneggia la feature. Per V1:

- `unknownExpansionMode = "show"`;
- logging/debug per ricette unknown;
- tabella metadata incrementale.

### Categoria AtlasLoot

Il filtro expansion deve essere applicato dopo categoria/professione o prima in modo coerente. Se categoria AtlasLoot include ricette Vanilla e TBC, con `TBC only` devono restare solo le TBC.

### Selezione dettaglio stale

Quando un filtro nasconde la ricetta selezionata:

- `_FinalizeRecipeList()` deve selezionare la prima riga visibile;
- se non ci sono righe, `selectedRecipeKey = nil`;
- `RefreshDetailPanel()` deve mostrare `No recipe selected` o messaggio filtrato.

## Strategia di migrazione

Migrazione dati:

- aggiungere defaults non distruttivi a `RecipeRegistryDB.profile.recipePrefilters`;
- non modificare `members`, profession blocks, sync state o recipe ownership;
- non cambiare wire protocol.

Compatibilita comportamento:

- il comportamento attuale resta recuperabile disabilitando entrambi i prefiltri;
- per evitare sorprese su profili esistenti si puo scegliere una delle due strategie:
  - `product default`: nuovi e vecchi profili ricevono filtri ON, con opt-out;
  - `compat default`: nuovi profili ON, profili esistenti OFF fino a scelta esplicita.

Dato il requisito "pre-TBC escluso dal comportamento predefinito", la roadmap consiglia `product default` ON, ma con release note e opzioni ben visibili.

## Piano di implementazione incrementale

### Fase 1 - Metadata e predicato

- Aggiungere helper metadata:
  - `Data:GetRecipeUiMetadata(recipeKey)`;
  - `Data:IsRecipeOutputBop(recipeKey, detail)`;
  - `Data:GetRecipeExpansion(recipeKey, detail)`.
- Aggiungere predicato:

```lua
Data:RecipePassesUiPrefilters(recipeKey, detail, opts)
```

- Nessun cambio UI ancora; solo test unitari su metadata/predicato.

### Fase 2 - Opzioni e defaults

- Aggiungere defaults `recipePrefilters`.
- Aggiungere controlli in `Options.lua`.
- Al cambio opzione:
  - invalidare recipe list cache;
  - richiedere `Addon:RequestRefresh("recipe-prefilter-options")`.

### Fase 3 - Integrazione lista Data

- Estendere `GetRecipeList` e `BuildRecipeListAsync` con `uiFilterOptions`.
- Aggiornare cache key.
- Applicare filtro prima di costruire/inserire righe.
- Coprire profession list, global search, category filter e sorting.

### Fase 4 - Integrazione UI selection/detail

- `UI:RefreshRecipeList()` calcola opzioni effettive per professione.
- `_FinalizeRecipeList()` mantiene selezione coerente.
- `RefreshDetailPanel()` rifiuta dettagli non piu visibili.
- `BuildFavoriteRecipeRows()` usa lo stesso predicato.

### Fase 5 - Metadata expansion completa

- Aggiungere tabella curated per expansion.
- Inserire coverage per professioni principali.
- Aggiungere diagnostica per unknown:
  - conteggio ricette unknown;
  - comando/debug opzionale.

### Fase 6 - UX polish

- Indicatore leggero negli header quando filtri attivi.
- Per-profession override nel pannello opzioni.
- Eventuale tooltip: "Some recipes hidden by filters".

## Suggerimenti test manuali/regressione

### Test manuali

- Con filtri default ON:
  - aprire Alchemy: verificare che Vanilla/pre-TBC note non appaiano;
  - disabilitare `TBC only`: verificare che riappaiano;
  - impostare globale `TBC only`, override Enchanting `All`: verificare Enchanting include Vanilla mentre altre professioni no.

- BoP:
  - ricetta BoP nota solo a un guildmate: non deve apparire;
  - stessa ricetta BoP nota al player corrente: deve apparire;
  - ricetta non-BoP nota a guildmate: deve apparire.

- Favorites:
  - mettere tra i preferiti una ricetta Vanilla;
  - con `TBC only` attivo non deve comparire in Favorites;
  - disattivando il filtro deve tornare.

- Global search:
  - cercare una ricetta Vanilla con filtro ON: non visibile;
  - filtro OFF: visibile.

- Detail:
  - selezionare una ricetta che poi viene nascosta cambiando opzione;
  - il dettaglio deve cambiare selezione o mostrare stato vuoto senza errori.

### Test automatizzati

- `Data:RecipePassesUiPrefilters`:
  - BoP remoto nascosto;
  - BoP locale visibile;
  - non-BoP visibile;
  - Vanilla nascosto con TBC only;
  - Vanilla visibile con override professione.

- `BuildRecipeListAsync`:
  - cache key diversa per opzioni diverse;
  - callback stale non aggiorna UI;
  - sorting stabile dopo filtro.

- `UI:_FinalizeRecipeList`:
  - selectedRecipeKey rimossa se filtrata;
  - prima riga visibile auto-selezionata;
  - zero rows produce dettaglio vuoto.

- Regression:
  - sync fingerprints invariati;
  - merge/additive sync invariato;
  - AtlasLoot category filter invariato salvo esclusioni richieste.

