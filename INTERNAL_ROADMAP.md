# Internal Roadmap

Questo file e' locale al repository e non deve entrare nelle release
dell'addon. La fonte tecnica di partenza e' `CODEBASE_ANALYSIS.local.md`.

## Sintesi Decisionale

La prossima evoluzione piu' conveniente non e' aggiungere nuovi payload sync,
ma chiudere le ultime condizioni che rendono la convergenza imprevedibile in
gilde grandi. P0/P1 sono gia' in prima implementazione, P2/P4/P5 hanno ricevuto
hardening sostanziale e il test harness locale copre il backend principale.
L'analisi aggiornata del codice mostra che:

- la UX della main window e i tooltip crafter-aware non sono piu' blocchi
  architetturali, ma richiedono ancora smoke test manuali in-game;
- la verita' owner locale e' molto piu' protetta: pending scan per professione,
  subset protection, snapshot block-aware, specializzazioni e cleanup dati
  corrotti sono presenti;
- il rischio dati piu' serio residuo non e' piu' la correttezza base del sync,
  ma il comportamento sotto carico: traffico manifest in gilde grandi, costi di
  confronto manifest e refresh UI/tooltip su dataset grandi;
- la riduzione memoria piu' innocua e gia' rilasciabile senza toccare il wire:
  cache catalogo bounded e indice tooltip piu' leggero; l'alleggerimento del
  serve path snapshot e' invece rinviato finche' non ci sono test con peer
  reali;
- restano pero' alcuni rischi runtime che non cambiano il wire ma possono
  degradare convergenza e costo in gilde grandi: batching delle invalidazioni
  cache/UI durante inbound sync massivo, lista recipe su dataset reali molto
  grandi, e alcuni costi lineari residui nelle code calde ancora da rifinire;
- il manifest ora e' cacheato, aggiornato per delta e inviato con pacing; il
  cap catch-up e' verificato anche in simulazione comm-bus multi-peer, con
  churn coordinator, chunk persi/riordinati e race stale/replica;
- il path diretto `REQ` ora ha retry limitati, peer backoff temporaneo e
  selezione piu' source-aware, oltre a una piccola concorrenza bounded per
  owner diversi, cosi' un peer online ma silenzioso non resta il collo di
  bottiglia unico del catch-up;
- raid instance e altre instance sono tornati contesti pausa-first: traffico
  sync, build manifest, maintenance e job UI non essenziali ora si fermano
  molto piu' aggressivamente per evitare stutter e crolli FPS, senza bloccare
  il sync solo perche' il gruppo e' convertito in raid nel mondo aperto;
- login, reload e uscita da combat/instance hanno ora una warmup window breve
  che lascia passare `HELLO` ma rinvia fanout manifest, catch-up drain e
  rebuild tooltip non richiesti finche' il client non e' di nuovo stabile;
- lo scan locale e' meno dipendente dalla visibilita' dei frame Blizzard, ma va
  ancora validato nei casi reali piu' strani: Enchanting, API non pronta,
  specializzazione appresa/trovata senza recipe scan;
- il filtro su recipe impossibili e il safe auto-clean al login riducono la
  propagazione di saved data corrotti senza introdurre lavoro pesante in login;
- bootstrap resta scaffolding: va considerato una feature grande separata, non
  un piccolo completamento.

Ordine consigliato:

1. Hardening runtime sync su bounded-state, osservabilita', prune e identita'
  dei transfer.
2. Throughput/performance su `REQ`, strutture dati delle code, fallback
  manifest e invalidazioni UI/tooltip nei dataset grandi.
3. Smoke test in-game mirati su UX, tooltip, scan reale, specializzazioni,
  roster churn e cleanup automatico prima della release.
4. Rifinitura residua P6 su diagnostica replica/stale solo dove migliora
  davvero il troubleshooting.
5. Eventuale bootstrap reale solo se diventa prioritario l'onboarding di
  database vuoti.

## Principi Guida

- La verita' del personaggio locale deve restare owner-authoritative.
- Il manifest deve restare solo metadato: niente recipe payload dentro `MANI`.
- Prima si misura, poi si introduce cache o stato persistente.
- Ogni nuovo lavoro pesante deve passare da `Performance.lua`.
- Ogni cambio wire-visible deve valutare `WIRE_VERSION`.
- Mock, stale e bootstrap non devono sporcare viste normali o manifest normali.
- Meglio una diagnostica utile via slash command che una UI rumorosa.

## Nota Locale: Split Data/Sync

Stato: completato localmente senza cambi wire/runtime intenzionali.

- `Data` e' stato diviso in `Data.lua`, `DataAtlasLoot.lua`,
  `DataManifest.lua`, `DataScan.lua`, `DataSnapshot.lua`,
  `DataCatalog.lua`, `DataCleanup.lua`.
- `Sync` e' stato diviso in `Sync.lua`, `SyncRuntime.lua`,
  `SyncProtocol.lua`, `SyncRequests.lua`, `SyncTransfer.lua`,
  `SyncManifest.lua`, `SyncDiagnostics.lua`.
- Le shard condividono helper/costanti tramite `Data._private` e
  `Sync._private`; i metodi pubblici `Addon.Data:*` e `Addon.Sync:*` restano
  invariati.
- `RecipeRegistry.toc` e `local-tests/harness/load-addon.lua` devono restare
  allineati all'ordine di load sopra, altrimenti il backend harness non esercita
  la stessa superficie del gioco.
- Vincoli da non rompere nei refactor successivi: payload wire, schema DB,
  timing constants, semantica slash output e comportamento mock/spec.

## Roadmap Prioritaria

### P0 - Hotfix UX Main Window

Stato: implementato in prima passata. Restano test manuali in-game su chat,
combat, Escape, drag/reload e SavedVariables esistenti.

Questi punti vanno trattati prima del lavoro sync perche' bloccano l'uso
quotidiano: se la ricerca cattura Invio o la finestra non si chiude/sposta in
modo prevedibile, l'utente non arriva nemmeno al valore del database ricette.

Pre-analisi:

- `UI/MainFrame.lua` ha gia' `releaseSearchFocus()` e hook su molti frame
  interni, ma la search box non ha `OnEnterPressed` e un click fuori dall'addon
  non passa dai frame interni; il focus puo' quindi restare nell'editbox e
  intercettare la chat.
- `UI:ClearSearch()` oggi cancella anche il testo quando la finestra viene
  nascosta. Per il bug chat serve soprattutto `ClearFocus()`, non
  necessariamente svuotare la ricerca in ogni path.
- il frame principale usa gia' `SetMovable(true)`, `RegisterForDrag()` e
  `StartMoving`, ma la title bar e' un child frame che cattura mouse/focus e
  non avvia il drag; manca inoltre persistenza posizione in profilo.
- il close button chiama `HideUIPanel(f)`. Il frame e' un custom frame creato
  con `CreateFrame("Frame", ...)`, non un pannello Blizzard gestito con
  `ShowUIPanel`; in combat o in stati UI strani conviene centralizzare una
  `UI:Close()` che faccia `ClearFocus()`, cancelli timer UI pendenti e poi
  chiami direttamente `f:Hide()`.

Risultato atteso:

- premere Invio nella search box applica la ricerca/debounce corrente e rilascia
  il focus, permettendo subito di aprire la chat con Invio;
- Escape e click su UI addon rilasciano il focus senza effetti collaterali;
- chiudere con X, `/rr`, minimap button o Escape (`UISpecialFrames`) usa lo
  stesso path affidabile;
- trascinare la title bar sposta la finestra;
- posizione e dimensione, se si decide di includere anche resize, vengono
  salvate in `Addon.db.profile`.

Come farlo:

1. In `UI/MainFrame.lua`, introdurre helper piccoli:
   - `UI:ClearSearchFocus()`;
   - `UI:Close(reason)`;
   - `UI:SaveFramePlacement()` e `UI:RestoreFramePlacement()`.
2. Aggiungere alla search box:
   - `OnEnterPressed` -> `ClearFocus()` e refresh immediato se serve;
   - `OnEscapePressed` -> `ClearFocus()` senza bloccare la chat dopo;
   - eventuale gestione di `OnEditFocusLost` solo se serve a ripulire stato
     visuale.
3. Sostituire il close button con `UI:Close("button")`, evitando
   `HideUIPanel(f)` per il frame custom.
4. Agganciare drag alla title bar:
   - `titleBar:EnableMouse(true)`;
   - `titleBar:RegisterForDrag("LeftButton")`;
   - `OnDragStart`/`OnDragStop` verso il parent frame;
   - al termine salvare posizione.
5. Ripristinare posizione al create/show, con fallback al centro e
   `SetClampedToScreen(true)`.

File coinvolti:

- `UI/MainFrame.lua`
- `Data.lua` solo se si decide di spostare default profilo DB li' invece che
  usare lazy-init in UI
- `Core.lua`, `MinimapButton.lua`, `Options.lua` solo se si vuole far chiamare
  esplicitamente `UI:Close()`/`UI:Toggle()` da tutti i path

Librerie:

- nessuna nuova libreria richiesta;
- usare AceDB gia' presente (`Addon.db.profile`) per salvare posizione;
- nessuna dipendenza da AceGUI necessaria, perche' la UI e' custom frame.

Rischio:

- basso/medio. Tocca solo UX main frame, ma va testato in combat e con chat
  aperta per evitare regressioni fastidiose.

Criteri di successo:

- dopo una ricerca, Invio apre la chat normalmente;
- cliccare fuori dall'addon non lascia la chat bloccata al prossimo Invio;
- X chiude la finestra anche in combat o con sync paused;
- `/rr` apre/chiude in modo coerente;
- la title bar trascina la finestra e la posizione resta dopo reload;
- Escape chiude la finestra o libera focus senza errori Lua.

Test consigliati:

- `/rr`, cercare una ricetta, premere Invio, aprire chat;
- search + click su mondo/chat frame + Invio;
- close con X in combat e fuori combat;
- minimap toggle e slash toggle;
- drag title bar, reload UI, verifica posizione.

### P1 - Tooltip Crafter-Aware Per Item Ed Enchant

Stato: implementato in prima passata per `GameTooltip` e `ItemRefTooltip`.
Restano test manuali in-game su item link, recipe item link, enchant/spell link
e fallback senza AtlasLoot.

Questo lavoro e' subito dopo gli hotfix finestra perche' rende l'addon utile
nel punto in cui il giocatore prende decisioni: tooltip di oggetti/enchant in
chat, inventario, professioni e link condivisi. Esiste gia' una base legacy in
`Tooltip.lua`, ma e' limitata.

Pre-analisi:

- `Tooltip.lua` fa hook solo su `GameTooltip:OnTooltipSetItem`.
- l'indice attuale usa solo recipeKey numerici positivi come itemID; le ricette
  spell/direct enchant, spesso salvate come recipeKey negativo, non compaiono.
- l'indice legge direttamente `GetMembersDB()` e dovrebbe invece rispettare la
  visibilita' utente: niente mock e niente stale nelle viste normali.
- `Data.lua` ha gia' `BuildRecipeIndex()`, `GetRecipeDisplayInfo()`,
  `GetRecipeCrafters()` e resolver AtlasLoot per created item, recipe item e
  spell; conviene riusare questi dati invece di duplicare logica nel tooltip.
- l'ordinamento online/offline esiste nella UI dettaglio, ma la regola richiesta
  e' piu' specifica: se almeno un crafter e' online, mostrare solo online; se
  nessuno e' online, mostrare anche offline.

Risultato atteso:

- aprendo il tooltip di un item craftabile si vede chi puo' craftarlo;
- aprendo il tooltip di una ricetta/enchant/spell link in chat si vede chi puo'
  craftarlo quando il mapping e' disponibile;
- se ci sono crafter online, il tooltip mostra solo loro;
- se nessun crafter e' online, il tooltip mostra gli offline visibili;
- stale/mock restano esclusi dai tooltip normali;
- il tooltip non fa rebuild pesanti nel render path.

Come farlo:

1. Spostare la costruzione indice tooltip su un helper che parte da
   `Data:GetRecipeIndex()`:
   - chiave `item:<createdItemID>` per output item;
   - chiave `item:<recipeItemID>` per recipe item;
   - chiave `spell:<spellID>` per enchant/direct spell;
   - eventuale alias da item enchant a spell quando AtlasLoot lo consente.
2. In `Tooltip.lua`, aggiungere supporto a:
   - `OnTooltipSetItem` per item link;
   - `OnTooltipSetSpell` o fallback equivalente disponibile sul client per
     spell/enchant link;
   - parsing link solo come fallback, non come fonte primaria.
3. Riutilizzare righe crafter da `Data:GetRecipeCrafters(recipeKey)` o da
   `BuildRecipeIndex()` per mantenere online, professione, skill rank e
   updatedAt coerenti con la UI.
4. Rendering:
   - calcolare `onlineRows`;
   - se `#onlineRows > 0`, mostrare solo online;
   - altrimenti mostrare offline visibili;
   - cap configurabile o costante breve, con riga `+N more`;
   - colore verde online, grigio offline.
5. Invalidare indice su:
   - `GET_ITEM_INFO_RECEIVED`;
   - `GUILD_ROSTER_UPDATE`/presence;
   - `Data:InvalidateRecipeCaches("presence"|"all")`;
   - merge/snapshot applicati.

File coinvolti:

- `Tooltip.lua`
- `Data.lua` se servono helper tipo `GetTooltipCraftKeysForRecipe()` o
  `GetVisibleCraftersForRecipe()`
- `Core.lua` solo se serve propagare invalidazione tooltip su eventi gia'
  gestiti

Librerie:

- nessuna nuova libreria obbligatoria;
- AtlasLootClassic/AtlasLoot e' gia' `OptionalDeps` ed e' utile per mappare
  enchant/spell/recipeItem/createdItem, ma il feature deve degradare bene senza
  AtlasLoot;
- non serve LibTooltip o una libreria tooltip esterna: `GameTooltip:HookScript`
  basta per questo scope.

Rischio:

- medio. Il rischio e' performance e accuratezza mapping enchant, non protocollo
  o DB.

Criteri di successo:

- tooltip di item craftabile mostra crafter online se presenti;
- tooltip dello stesso item con tutti offline mostra offline visibili;
- tooltip di enchant/spell link in chat mostra crafter quando AtlasLoot conosce
  il mapping;
- tooltip di ricetta item mostra crafter della ricetta o output collegato;
- nessun mock/stale appare;
- nessun errore Lua se AtlasLoot manca o item cache non e' pronta.

Test consigliati:

- link item craftabile in chat;
- link formula/ricetta in chat;
- link enchant/spell diretto;
- roster con un crafter online e uno offline;
- roster con tutti offline;
- AtlasLoot presente e assente.

### P2 - Integrita' Dati Owner E Sync

Stato: implementata e hardenata in piu' passate. Sono presenti pending scan per
professione/generico, risultati scan ricchi, protezione owner da subset
sospetti, diagnostica scan/recipe validation, preservazione di professioni
mancanti negli snapshot replica/parziali, guardrail roster snapshot incompleto,
sync stabile delle specializzazioni, filtro su manifest/request malformati,
protezione da recipe key impossibili e cleanup dati corrotti. Resta la
validazione manuale in-game sui casi reali piu' delicati: recipe event +
professione sbagliata, Enchanting/AtlasLoot, specializzazione remota senza
recipe scan e wipe/catch-up di peer appena ripuliti.

Questa feature nasceva come prossima priorita' dopo gli hotfix UX/tooltip. Il
rischio reale non e' solo "un pacchetto sync perso": il sync tende a propagare
fedelmente cio' che considera autorevole. Se il dato owner locale e'
incompleto, o se un merge accetta uno snapshot parziale, il risultato visibile
e' che una recipe o una professione di un player sparisce dal database di
gilda.

Pre-analisi iniziale, indirizzata in questa feature:

- `Core.lua` usava un solo `Data._scanNeeded = true` per tutti gli eventi
  recipe. Ora esiste pending per professione/generico e il pending non viene
  consumato da scansioni invalide, invarianti o sospette.
- `Data:ApplyScanResult()` rimpiazzava interamente `prof.recipes` con quanto
  esposto dalla UI professione in quel momento. Ora una riduzione sospetta del
  count owner viene bloccata e diagnosticata.
- `Data:FinalizeIncomingSnapshot()` e `MergeEngine` ragionavano molto a livello
  di member/rev. Ora la finalizzazione preserva blocchi professione mancanti e
  protegge subset/zero subset in ingresso.
- `isValidRecipeKey()` poteva scartare recipe spell/enchant negative se
  AtlasLoot era presente ma incompleto. Ora il mapping AtlasLoot resta preferito
  ma non e' l'unica prova di validita'.
- `GuildLifecycleMaintenance` poteva marcare stale se lo snapshot roster era
  incompleto o non ancora pronto. Ora abortisce prima di schedulare cleanup se
  lo snapshot non e' plausibile.
- manifest owner key e request dirette potevano accettare chiavi corrotte o
  concatenate, generando timeout inutili. Ora vengono validate prima di entrare
  nelle code sync.
- recipe key impossibili potevano arrivare da saved data vecchi o parsing link
  non valido. Ora scan, snapshot, inbound e cleanup usano filtri coerenti e un
  safe auto-clean al login per riparazioni deterministiche leggere.

Risultato atteso:

- una recipe imparata non puo' essere "persa" aprendo la professione sbagliata;
- una scansione subset non puo' ridurre una professione owner gia' piu' completa
  senza una condizione forte e diagnosticabile;
- snapshot e merge applicano blocchi per professione, con protezione chiara da
  professioni mancanti o parziali;
- recipe spell/enchant valide non vengono scartate solo per un buco AtlasLoot;
- stale roster non nasconde dati buoni se il roster snapshot e' palesemente
  incompleto;
- specializzazioni professione vengono pubblicate quando apprese/trovate o
  cambiate, ma non ribumpano la revision a ogni relog;
- dati corrotti locali non vengono propagati e possono essere riparati senza
  wipe manuale del database.

Come farlo:

1. Sostituire `_scanNeeded` globale con stato per professione: fatto in prima
   passata.
   - `Data._scanNeededByProfession[profName] = true`;
   - se l'evento non identifica la professione, mantenere un pending generico
     ma non consumarlo su una scan invariata o su professione non correlabile;
   - consumare il pending solo dopo una scansione valida della professione.
2. Cambiare `ScanTradeSkill()`/`ScanCraft()` per restituire uno stato ricco:
   fatto in prima passata.
   - `changed`;
   - `valid`;
   - `profession`;
   - `skipReason`;
   - `count`;
   - `suspectedPartial`.
3. Proteggere `ApplyScanResult()`: fatto in prima passata per riduzioni
   sospette.
   - se `count` scende rispetto al count owner precedente e non c'e' un segnale
     forte di rescan completo, non sovrascrivere subito;
   - mantenere `_scanNeededByProfession[profession] = true` e stampare/debuggare
     il motivo;
   - permettere riduzioni solo con criterio esplicito, ad esempio professione
     valida, UI pronta, filtro pulito e seconda scansione coerente.
4. Rendere il merge piu' block-aware: prima passata fatta per professioni
   mancanti e subset/zero subset.
   - non far sparire professioni locali quando uno snapshot replica non le
     include;
   - applicare protezioni subset per singolo blocco professione, non solo come
     euristica dentro finalizzazione member;
   - owner locale resta sempre non degradabile da replica/bootstrap.
5. Ammorbidire o diagnosticare `isValidRecipeKey()`: fatto in prima passata.
   - loggare conteggio recipe scartate per professione/source;
   - per spell/enchant negative, evitare scarti distruttivi quando AtlasLoot e'
     presente ma non risolve il mapping;
   - valutare quarantena/debug invece di drop definitivo.
6. Proteggere roster cleanup: fatto in prima passata.
   - prima di marcare stale, verificare che lo snapshot roster abbia una size
     plausibile e sia arrivato dopo un `GuildRoster()` recente;
   - se lo snapshot e' troppo piccolo rispetto al DB/ultima vista, abortire con
     diagnostica.

File coinvolti:

- `Core.lua`
- `Data.lua`
- `MergeEngine.lua`
- `Sync.lua`
- `TrickleSync.lua`
- `GuildLifecycleMaintenance.lua`
- `MockSync.lua`

Rischio:

- residuo medio/basso: il backend locale e' coperto dal harness, ma resta
  rischio client reale su eventi professione, item cache, AtlasLoot opzionale e
  peer con saved data storici. Prima di aumentare aggressivita' replica serve
  ancora verifica in-game mirata.

Criteri di successo:

- imparare recipe Alchemy e aprire prima Tailoring non consuma il pending
  Alchemy;
- una scan temporaneamente vuota/subset non riduce il count owner pubblicato;
- snapshot replica senza una professione non cancella quella professione locale;
- owner locale non viene mai ridotto da replica/bootstrap;
- recipe enchant negative valide non vengono droppate silenziosamente;
- roster cleanup non marca mezza gilda stale se il roster non e' pronto;
- malformed owner keys non entrano in request/in-flight sync;
- il safe auto-clean al login ripara solo errori deterministici e non introduce
  picchi visibili in `/rr perf dump`.

Test consigliati:

- recipe event con professione chiusa;
- recipe event seguito da apertura professione diversa;
- scan con filtri/categorie chiuse e item cache fredda;
- `/rr mock start integrity` per snapshot parziale con professione mancante e
  replica piu' nuova ma subset;
- `/rr mock start rosterbad` per roster snapshot incompleto;
- test manuale AtlasLoot missing mapping per enchant quando disponibile.

### P3 - Osservabilita' Scan E Manifest

Stato: molto avanzato per scan, manifest e cleanup. `/rr dump`, `/rr sync`,
`/rr manifest`, `/rr offline`, `/rr self` e `/rr perf dump` coprono scan
signals, skip/failure/partial, recipe validation, manifest cache, dirty block,
chunk cache, deferred send, paced MANI e stato owner pubblicato dal client.
Restano assert/mock dedicati per verificare in modo piu' stretto il catch-up da
manifest grandi e alcune policy stale/replica.

Conviene farlo insieme o subito dopo P2 perche' costa poco e riduce il rischio
delle fasi sync/scan successive. Oggi alcune scelte importanti sono implicite:
non sappiamo quanto costa costruire manifest grandi, quante volte vengono
scartati per cooldown, quante scansioni vengono saltate per frame/API non
pronte, o se i pending scan restano aperti troppo a lungo.

Risultato atteso:

- `/rr perf dump`, `/rr sync`, `/rr manifest` e/o un nuovo dump interno rendono
  chiaro cosa sta succedendo senza dover leggere live il codice.
- I dati raccolti dicono se serve davvero un pacing piu' aggressivo lato
  request, non piu' se serve una cache manifest: la cache e' gia' presente.

Come farlo:

- In `Data.lua`, aggiungere piccoli contatori locali:
  - scan trigger ricevuti;
  - scan eseguite;
  - scan cambiate;
  - scan saltate per dati non disponibili;
  - scan saltate per dati gia' presenti e `_scanNeeded == false`;
  - ultimo motivo di skip.
- In `Sync.lua`, estendere `telemetry` con:
  - manifest build richiesti;
  - manifest chunk inviati/ricevuti;
  - manifest send saltati per cooldown;
  - manifest force replies;
  - durata stimata build manifest, se misurabile con `debugprofilestop`.
- In `Data:DumpManifestSummary()` aggiungere, senza spam, i contatori manifest
  piu' utili.
- In `Sync:DumpStatus()` includere i contatori manifest solo in una riga breve.
- In `MockSync.lua`, verificare che `traffic` e `offline` facciano crescere i
  contatori attesi.

File coinvolti:

- `Data.lua`
- `Sync.lua`
- `MockSync.lua`
- eventualmente `Performance.lua` solo per leggere metriche gia' presenti

Rischio:

- basso. Non cambia protocollo ne' comportamento utente.

Criteri di successo:

- dopo `/rr mock start traffic`, si vedono manifest inviati/ricevuti;
- dopo `/rr mock start offline`, si vedono blocchi replica osservati e richieste
  replica queued/applied;
- una scansione invariata non risulta come aggiornamento owner.

### P4 - Scansione Locale Robustezza Owner

Stato: implementata lato backend locale e coperta dal harness. `Data.lua` ora
espone helper per professione attiva/readiness, `Core.lua` tenta scan
opportunistiche senza dipendere direttamente da
`TradeSkillFrame:IsShown()`/`CraftFrame:IsShown()` e il harness copre frame
nascosti, dati non pronti, pending generico e CraftFrame non-Enchanting. La
stessa area copre anche la sincronizzazione stabile della specializzazione
professione: prima discovery o cambio reale fanno bump di `rev` e
pubblicazione, mentre relog e re-detect identici non devono generare sync
infinito. Resta validazione manuale in-game con UI Blizzard, Enchanting reale,
specializzazione remota ricevuta senza recipe scan e, se disponibile, Skillet.

Questo e' il lavoro piu' utile lato prodotto. Il database di gilda converge solo
se i dati owner locali sono corretti. Oggi gli eventi recipe impostano
`Data._scanNeeded`, ma il consumo reale dipende ancora da `TradeSkillFrame` o
`CraftFrame` visibili nei path di `Core.lua`.

Risultato atteso:

- una recipe nuova resta marcata come "da scansionare" finche' non avviene una
  scansione valida;
- l'addon prova a scansionare quando i dati professione sono disponibili, non
  solo quando il frame Blizzard e' esplicitamente visibile;
- la UI Blizzard standard resta compatibile e non perde filtri/stato.

Come farlo:

1. Introdurre helper in `Data.lua`:
   - `Data:CanScanTradeSkillData()` - fatto in prima passata;
   - `Data:CanScanCraftData()` - fatto in prima passata;
   - `Data:GetActiveTradeSkillProfession()` - fatto in prima passata;
   - `Data:GetActiveCraftProfession()` - fatto in prima passata.
2. Spostare la decisione "posso scansionare?" dentro `Data.lua`, lasciando a
   `Core.lua` solo il trigger evento/timer: fatto in prima passata.
3. Cambiare `Core.lua`:
   - `OnTradeSkillShow()` non deve dipendere direttamente da
     `TradeSkillFrame:IsShown()` - fatto in prima passata;
   - `OnCraftShow()` non deve dipendere direttamente da `CraftFrame:IsShown()`
     - fatto in prima passata;
   - `ProcessRecipeSignal()` deve tentare una scansione opportunistica e, se
     fallisce per dati non pronti, lasciare `_scanNeeded = true` - fatto in
     prima passata.
4. Cambiare `Data:ScanTradeSkill()` e `Data:ScanCraft()` per distinguere:
   - skip per "non serve" - gia' presente via `cached`;
   - skip per "dati non pronti" - fatto in prima passata;
   - scansione valida invariata - gia' presente;
   - scansione valida cambiata - gia' presente.
5. Non introdurre subito integrazioni Skillet profonde. Prima usare segnali API
   del client e fallback Blizzard.

File coinvolti:

- `Core.lua`
- `Data.lua`
- `UI/MainFrame.lua` solo se si vuole mostrare un piccolo stato debug

Rischio:

- medio. Tocca la fonte owner della sincronizzazione.

Criteri di successo:

- con UI Blizzard standard, comportamento invariato;
- recipe learnata con professione chiusa non viene persa: `_scanNeeded` resta
  true fino a scansione valida;
- scansione invariata non incrementa `rev`;
- scansione cambiata incrementa `rev` una sola volta e chiama
  `Sync:AdvertiseLocalRevision()`;
- discovery/cambio specializzazione incrementa `rev` una sola volta e resta
  stabile ai relog successivi se la specializzazione non cambia;
- Enchanting continua a non importare Beast Training o altre CraftFrame non
  professione.

Test consigliati:

- login/reload in guild;
- relog con specializzazione gia' nota: nessun bump ulteriore di `rev`;
- apertura TradeSkill standard;
- apertura CraftFrame Enchanting;
- recipe learnata senza professione aperta;
- apprendimento o rilevazione iniziale della specializzazione: un solo
  advertise/sync;
- `/rr dump`, `/rr sync`, `/rr perf dump`;
- setup con Skillet se disponibile.

### P5 - Pacing Manifest E Replica Catch-Up

Stato: implementato lato manifest outbound e inbound catch-up. La cache
manifest, gli aggiornamenti delta, il riuso chunk, l'invio paced e il cap
progressivo delle request generate da manifest grandi sono presenti e
misurabili.

Il manifest e' piccolo rispetto agli snapshot recipe e ora viene mantenuto in
cache: `Data` costruisce/aggiorna il manifest in background e `TrickleSync`
riusa i chunk finche' il manifest non cambia. I dirty update sono a livello di
blocco `owner::profession`, con fallback full quando la mutazione e' troppo
ampia o ambigua. Anche l'invio `MANI` e' ora accodato e paced dal worker
outbound.

Gia' fatto:

- cache manifest in memoria;
- build background `manifest-cache-build`;
- delta update per blocchi sporchi;
- chunk cache per riusare i `MANI` su piu' peer;
- defer dei send finche' la cache fresca e' pronta;
- coda paced per inviare `MANI` dal worker `sync-outbound-loop`;
- jitter leggero sugli invii automatici non-force;
- metriche in `/rr perf dump`.

Quello che e' stato completato in questa fase:

- cap progressivo alle request generate da un manifest grande;
- telemetria breve su request candidate, accodate, differite e drenate;
- test limite, test di carico comm-boundary con centinaia di peer simulati e
  test comm-bus con 200 addon isolati che convergono tramite coordinator,
  piu' scenari di churn, conflitto replica, resume e stale race.

Quello che non conviene fare subito:

- cache manifest persistente;
- delta recipe-level dentro al manifest;
- aumento frequenza sync.

Risultato atteso:

- i manifest restano automatici, ma il traffico e' piu' distribuito;
- le gilde grandi non causano micro-burst quando molti client fanno hello/tick;
- si puo' decidere con dati reali se serve pacing piu' aggressivo.

Come farlo:

1. [x] Cache build: `Data` mantiene manifest cache e aggiorna dirty block in
   background; `TrickleSync` riusa i chunk cacheati.
2. [x] In `Sync.lua`, aggiungere una coda manifest outbound separata o riusare una
   coda low-priority dedicata:
   - entry: `peerKey`, `payload`, `why`, `queuedAt`;
   - invio massimo per tick o per peer;
   - rispetto di `SyncPausePolicy:ShouldPauseOutbound()`.
3. [x] Cambiare `Sync:SendManifestToPeer()`:
   - continua a fare cooldown per peer;
   - usa chunk gia' pronti da `TrickleSync:BuildManifestChunks()`;
   - invece di inviarli tutti subito, li accoda;
   - `why == "force"` resta bypass cooldown, ma non bypass pacing salvo casi
     esplicitamente scelti.
4. [x] Aggiungere jitter leggero nei broadcast automatici:
   - evitare che tutti i client inviino manifest nello stesso secondo dopo
     `HELLO_INTERVAL` o `AUTO_SYNC_INTERVAL`;
   - non cambiare il protocollo wire.
5. [x] Limitare replica catch-up:
   - in `HandleManifestChunk()`, cap massimo di owner/block request accodate per
     manifest, con il resto lasciato al tick successivo o al prossimo manifest;
   - mantenere priorita' a owner online e blocchi piu' nuovi.
6. [x] Aggiungere metriche:
   - request candidate;
   - request accodate;
   - request differite dal cap;
   - request drenate nei tick successivi.
7. Continuare a misurare prima di aggiungere cache persistente o delta piu'
   fini.

File coinvolti:

- `Sync.lua`
- `TrickleSync.lua` solo se servono helper di ordinamento/priorita'
- `Performance.lua` se si sceglie una categoria job dedicata
- `MockSync.lua` per scenari burst

Rischio:

- medio. Cambia tempistica del sync, non il contenuto.

Criteri di successo:

- `/rr mock start trafficburst` non produce code incontrollate;
- `MANI` force risponde ancora in tempi ragionevoli;
- `/rr pull` continua a recuperare dati;
- replica offline converge anche se in modo leggermente piu' progressivo.
- la simulazione comm-bus da 200 peer converge senza lasciare request obsolete
  in-flight.
- chunk snapshot persi o fuori ordine vengono recuperati via `RESUME`;
- un owner stale locale non viene riattivato da una replica gia' in volo.

### P6 - Hardening Replica, Stale E Diagnostica Di Correttezza

Stato: quasi chiuso lato backend. Le invarianti principali sono gia' presenti,
il test harness locale copre anche scenari multi-peer pesanti, e il lavoro che
resta qui non e' piu' correttezza sync di base ma soprattutto osservabilita' e
una decisione finale su quanto presto bloccare repliche stale nel path
manifest.

Il sync offline/replica e' una feature importante. L'analisi conferma che gli
invarianti principali sono gia' presenti: stale esclusi dai manifest normali,
mock esclusi, owner protetto da replica, merge con authority. Ora conviene
tenere solo i guardrail che migliorano la comprensione dei problemi reali senza
introdurre altra complessita' gratuita.

Gia' verificato:

- convergenza multi-peer con coordinator reale simulato, `REQ`/`SNAP`/`DONE`,
  chunk persi/riordinati e `RESUME`;
- conflitto fra repliche per owner offline con scelta della variante piu'
  ricca/nuova;
- request obsolete che non restano piu' in-flight dopo convergenza concorrente;
- owner stale locale che non viene riattivato da una replica gia' in volo;
- sorgenti offline non piu' considerate viabili solo per presenza di manifest,
  ma anche in base al roster meta quando disponibile.

Risultato atteso:

- meno rischio di regressioni quando si toccano manifest, roster o merge;
- diagnosi piu' rapida quando un crafter offline non compare.

Come farlo, se serve ancora toccarlo:

1. In `Data:DumpManifestSummary()`, rendere evidente:
   - owner blocks locali;
   - replica blocks;
   - stale esclusi;
   - top replica owners.
2. In `Sync:DumpOfflineSyncStatus()`, tenere una riga sintetica su:
   - manifest owners/blocks osservati;
   - requests queued/served;
   - owners applied/new owners applied.
3. Valutare una piccola protezione in `HandleManifestChunk()`:
   - ignorare blocchi replica per owner marcati stale localmente, a meno che
     una policy esplicita dica il contrario.
4. Aggiungere scenari `MockSync` solo se migliorano davvero il troubleshooting
   umano rispetto al comm-bus gia' esistente.

Quello che resta davvero utile:

- rendere `Data:DumpManifestSummary()` piu' leggibile quando bisogna capire
  perche' un owner offline non compare;
- decidere se anticipare il filtro stale gia' in `HandleManifestChunk()` oppure
  considerare sufficiente il blocco nel merge/finalize;
- evitare altro hardening sync generico finche' non emerge un caso reale che il
  comm-bus o i test limite non stanno gia' coprendo.

File coinvolti:

- `MockSync.lua`
- `Data.lua`
- `Sync.lua`
- `MergeEngine.lua` solo se emerge un caso non coperto

Rischio:

- basso/medio. Le diagnostiche sono basse; le policy stale vanno trattate con
  cautela.

Criteri di successo:

- mock offline converge;
- mock roster non fa riapparire ex-guild nei risultati normali;
- owner locale non viene mai degradato da replica;
- `/rr offline` spiega abbastanza bene cosa e' successo.

### P7 - Bootstrap Reale

Stato: non implementato come trasferimento dati reale. Rimane una feature
separata ad alto rischio e non va confusa con il catch-up replica attuale.

Bootstrap oggi e' uno scheletro utile per UI/state, ma il trasferimento reale
non c'e'. Conviene farlo solo quando il problema principale diventa l'onboarding
di un client nuovo o con DB vuoto. Non e' un refactor piccolo.

Risultato atteso:

- un client con DB vuoto sceglie un seed affidabile e riceve un dataset iniziale
  in modo controllato;
- il bootstrap non rompe owner/replica authority;
- il protocollo e' compatibile con versioni future.

Come farlo:

1. Definire wire message espliciti:
   - seed advertise/discovery;
   - bootstrap request;
   - bootstrap snapshot chunk;
   - done/resume/error.
2. Decidere se riusare `SNAP` o creare chunk bootstrap separati.
3. Incrementare `WIRE_VERSION` se cambia il contratto wire.
4. Usare `Performance.lua` categoria `bootstrap`.
5. Applicare i dati come `sourceType = "bootstrap"` con authority piu' bassa di
   replica e owner.
6. Non includere stale/mock nel seed normale.
7. Aggiungere mock scenario dedicato.

File coinvolti:

- `BootstrapSync.lua`
- `Sync.lua`
- `Data.lua`
- `MergeEngine.lua`
- `MockSync.lua`
- `UI/MainFrame.lua` per stato e debug minimo

Rischio:

- alto. Cambia onboarding, protocollo e merge.

Criteri di successo:

- DB vuoto riceve dataset utile senza bloccare UI;
- bootstrap interrotto puo' riprendere o fallire pulito;
- owner locale successivo sovrascrive bootstrap;
- non aumenta traffico normale quando bootstrap non serve.

## Cose Da Non Fare Ora

- Non introdurre librerie nuove per focus, drag, close o tooltip: il codice
  esistente e le API Blizzard bastano.
- Non introdurre una cache manifest persistente prima di avere metriche sul
  costo reale della build.
- Non aumentare la frequenza di `HELLO` o `AUTO_SYNC_INTERVAL`.
- Non aumentare ulteriormente aggressivita' sync o replica finche' non abbiamo
  misure migliori sul costo reale in gilda grande e sul fanout manifest.
- Non integrare Skillet con API private profonde finche' non basta un rilevamento
  piu' generico dei dati professione attivi.
- Non completare bootstrap insieme al pacing manifest: sono due rischi diversi.
- Non aggiungere UI permanente per diagnostica interna; slash/debug bastano.

## Piano Concreto Della Prossima Iterazione

La prossima iterazione consigliata non e' piu' correttezza sync di base, ma
performance hardening mirato: traffico manifest, costo di confronto manifest e
pressione UI/tooltip con dataset grandi, seguiti da smoke test in-game mirati
prima della release. Il test harness Lua 5.1 esiste gia' e copre il backend
principale; i test locali sono arrivati a 68 spec e vanno mantenuti
workspace-local finche' restano strumento personale.

Stato attuale:

- P0/P1: prima implementazione fatta, restano smoke test manuali.
- P2/P4: implementate e hardenate con test locali; resta validazione in-game su
  client reale, specializzazioni remote e Enchanting.
- P3: diagnostica scan/manifest/cleanup utilizzabile.
- P5: manifest outbound paced e catch-up inbound cappato sono implementati.
- P6: correttezza backend ampiamente coperta; restano solo rifiniture su
  diagnostica e policy stale.
- P7: fuori scope per la prossima iterazione.
- Performance/runtime sync: nuovo focus reale prima della release, soprattutto
  su bounded-state, fanout manifest residuo, confronto manifest, costi delle
  code e costi UI/tooltip.

Step 0 - test harness locale:

- [x] creare `local-tests/harness/wow.lua` con mock minimi di API Blizzard,
  `LibStub`, AceAddon/AceDB e scheduler timer;
- [x] creare `local-tests/harness/load-addon.lua` per caricare i moduli backend
  in ordine TOC;
- [x] creare `local-tests/run-backend-tests.ps1` come comando unico accanto a
  `local-tests/run-syntax.ps1`;
- [x] aggiungere prime spec backend per pending scan, snapshot parziale e roster
  snapshot incompleto;
- [x] aggiungere spec esaustiva per tutti gli scenari `MockSync`:
  snapshot diretti, bootstrap mock, manifest/replica traffic, offline,
  offlinewipe, trafficburst, roster, rosterheavy, rosterbad, integrity,
  comandi `/rr mock` e cleanup;
- [x] aggiungere spec sugli output dei comandi slash principali:
  help, perf dump/reset, rescan manuale, manifest compatto/verbose, offline,
  sync e usage mock;
- [x] aggiungere spec manifest cache:
  build/cache, chunk cache, delta dirty block, rimozione stale e send MANI
  differito finche' la cache fresca e' pronta, pacing stesso peer;
- [x] mantenere `local-tests/` escluso dal repo remoto finche' resta harness
  personale/workspace-local.

Step 1:

- [x] introdurre `_scanNeededByProfession` e non consumare piu' il pending scan su
  una professione sbagliata;
- [x] far ritornare a `ScanTradeSkill()`/`ScanCraft()` uno stato ricco invece del
  solo booleano;
- [x] mantenere il pending quando la scan e' non pronta, invalida o sospetta.

Step 2:

- [x] proteggere `ApplyScanResult()` dalle riduzioni sospette del count owner;
- [x] aggiungere contatori/debug per scan skipped, scan partial sospette, recipe
  scartate da `isValidRecipeKey()`;
- [x] aggiungere mock/test per recipe event seguito da API professione attiva,
  frame nascosto, API non pronta e CraftFrame non-Enchanting; resta la verifica
  manuale in-game del trigger client reale.

Step 3:

- [x] rendere il merge/snapshot piu' block-aware sulle professioni mancanti;
- [x] aggiungere guardrail roster snapshot incompleto;
- [x] verificare con mock subset/replica/stale prima di toccare pacing manifest:
  aggiunti `integrity`, `rosterbad`, piu' scenari esistenti `offline`/`roster`.

Step 4 - completato nella fase manifest/cache:

- [x] cache manifest in background;
- [x] delta update per blocco `owner::profession`;
- [x] riuso chunk `MANI`;
- [x] invio manifest paced dal worker outbound;
- [x] diagnostica manifest cache in `/rr perf dump`.

Step 5 - completato nella fase hardening saved data:

- [x] validazione member/sync block key prima di accodare request dirette;
- [x] filtro su recipe key impossibili in scan, snapshot e inbound;
- [x] cleanup manuale con preview;
- [x] safe auto-clean al login in batch leggeri;
- [x] diagnostica recipe validation e last cleaned recipe.

Step 6 - completato nella fase catch-up manifest:

- [x] introdurre cap progressivo alle request generate da un manifest grande;
- [x] ordinare o prioritizzare le request per owner online, revision piu' nuova
  e blocchi mancanti;
- [x] drenare le request differite in tick successivi senza perdere convergenza;
- [x] aggiungere metriche su candidate/queued/deferred/drained;
- [x] aggiungere spec dedicate per cap, edge case e carico comm-boundary.
- [x] aggiungere comm-bus multi-nodo con 200 addon isolati, routing
  GUILD/WHISPER, coordinator unico e flusso reale `REQ`/`SNAP`/`DONE`;
- [x] scartare request gia' soddisfatte prima che restino in-flight dopo una
  convergenza concorrente.
- [x] coprire churn del coordinator, conflitti replica offline, snapshot grandi
  con chunk persi/riordinati e race stale durante replica in-flight.

Step 7 - prossimo focus performance:

- [x] ridurre lavoro inutile in `TrickleSync:ComparePeerManifest()` nel path che
  serve solo il catch-up locale, evitando confronto speculare non usato;
- [x] limitare meglio il fanout manifest quando il manifest locale non cambia o
  quando il peer ha gia' ricevuto serial/fingerprint equivalente;
- [x] fermare in modo molto piu' aggressivo il lavoro non essenziale in
  raid/instance, inclusi protocol traffic, build manifest, maintenance e job
  UI background;
- [x] introdurre retry cap, peer backoff e selezione source-aware per evitare
  che un peer non responsivo blocchi a lungo il catch-up diretto;
- [x] aggiungere una warmup window post login/reload/combat-exit/instance-exit
  che rinvia il lavoro sync piu' pesante e i rebuild tooltip non urgenti;
- [x] aggiungere `/rr syncreset` per resettare solo lo stato runtime del sync
  senza toccare il DB ricette;
- [x] svuotare la direct request queue senza aspettare sempre il ticker da 1s
  dopo ogni completamento/fallimento, e non bloccare il catch-up differito solo
  perche' esiste un altro in-flight non correlato;
- [x] ridurre il fanout `MANI` ridondante: niente broadcast manifest proattivo
  su `HELLO` periodico o `auto-tick`, lasciando la propagazione ai reply
  mirati e ai path espliciti;
- [ ] misurare e poi batchare meglio le invalidazioni cache durante inbound sync
  massivo, soprattutto con UI aperta;
- [x] evitare rebuild pesanti dell'indice tooltip nel primo hover dopo sync o
  roster update;
- [ ] valutare lista recipe incrementale o virtualizzata se il dataset reale
  rende percepibili stutter in apertura o ricerca globale;
- [x] tenere i nuovi test di carico come guardrail di non-regressione mentre si
  tocca la pressione runtime.

Step 8 - hardening runtime sync e stato bounded:

Stato: implementato, validato localmente e impacchettato in release 1.8.0.

Obiettivo: chiudere le criticita' residue emerse dall'analisi del sistema sync
online/offline senza cambiare payload wire o schema DB. Questo step viene prima
di altri aumenti di aggressivita' o frequenza: prima rendiamo il runtime piu'
bounded e leggibile, poi allarghiamo il throughput.

Workstream 8A - osservabilita' minima del runtime:

- [x] estendere `SyncDiagnostics.lua`, `/rr sync`, `/rr manifest` e `/rr offline`
  con contatori compatti per: sessioni outgoing/incoming, partial manifest
  aperti, peer manifest residenti, queued blocks per peer, prune eseguiti,
  fallback manifest build e profondita' delle code `REQ`/outbound/inbound;
- [x] rendere evidente nei dump se il runtime sta drenando o accumulando stato,
  con timestamp/eta' massima dei bucket principali;
- [x] aggiungere spec che verifichino crescita e azzeramento dei contatori dopo
  prune/reset runtime.

Workstream 8B - transfer identity e timeout prune:

- [x] rendere `Sync:BuildSessionId()` univoco anche nello stesso secondo e verso
  peer diversi, includendo almeno target e un nonce/contatore monotono locale;
- [x] introdurre sweep periodici per sessioni ferme, partial receive vecchi e
  manifest parziali mai completati;
- [x] mantenere cleanup idempotente in reset runtime, cleanup mock e path di
  wipe locale.

Workstream 8C - peer state e code non bounded:

- [x] decidere il ruolo di `TrickleSync.outboundQueue`: o diventa una coda
  realmente drenata, o viene ridotta a puro supporto diagnostico con cap e
  prune espliciti;
- [x] potare `TrickleSync.peerState` quando il peer e' offline, stale o senza
  manifest recente, mantenendo solo il minimo stato utile al confronto;
- [x] aggiungere cap leggeri per peer e globali, con drop diagnostico invece di
  crescita silenziosa.

Workstream 8D - throughput richieste e costo code:

- [x] sostituire il single-flight `REQ` con una concorrenza piccola ma bounded,
  preservando fairness, retry cap, priorita' owner online e backoff peer;
- [~] ridurre gli shift lineari nei path caldi di `SyncRequests.lua`,
  `SyncTransfer.lua` e `SyncManifest.lua`; l'audit e' avviato ma restano ancora
  alcuni `table.remove(...)` nelle code snapshot/manifest da ottimizzare in una
  passata separata;
- [x] evitare di peggiorare il costo del reorder/prioritization sotto burst
  multi-owner o multi-peer.

Workstream 8E - manifest fallback e roster freshness:

- [x] misurare ogni fallback sincrono di
  `Data:GetPreparedSyncManifest()`/`BuildManifestCacheNow()` nel path sync e,
  quando il client e' in warmup/busy/pause, preferire defer/reply successivo a
  build inline pesanti;
- [x] rinfrescare in modo mirato il roster prima dei path che scelgono target o
  source peer quando i metadati locali sono vecchi o incoerenti;
- [x] aggiungere guardrail: se il roster non e' credibile, preferire una breve
  attesa o sorgenti multiple invece di routing deterministico su dati stantii.

Sequenza consigliata:

1. osservabilita';
2. session id + timeout prune;
3. peer state/outbound queue bounded;
4. concorrenza `REQ` + strutture dati delle code;
5. fallback manifest + roster freshness;
6. solo dopo, batching invalidazioni UI e lista recipe incrementale se resta
  un problema reale.

Nota release 1.8.1 / Unreleased:

- `1.8.1` contiene solo il lavoro considerato innocuo lato UI/memory:
  cache bounded in `DataCatalog.lua`, invalidazione cache allineata in
  `Data.lua`, e indice tooltip alleggerito in `Tooltip.lua`.
- il refactor locale per alleggerire la materializzazione delle sessioni
  `SNAP` non entra in `1.8.1` e resta esplicitamente lavoro `Unreleased`
  finche' non viene validato contro peer reali o almeno uno smoke multi-client
  affidabile.

File coinvolti:

- `SyncDiagnostics.lua`
- `SyncTransfer.lua`
- `SyncRuntime.lua`
- `SyncRequests.lua`
- `SyncManifest.lua`
- `TrickleSync.lua`
- `DataManifest.lua`
- `Core.lua` e `GuildLifecycleMaintenance.lua` solo se serve refresh roster
  mirato

Criteri di successo:

- nessuna collisione di session id sotto burst o retry ravvicinati;
- partial receive, peer manifest e code tornano a zero o a un plateau bounded
  dopo churn, timeout o reset runtime;
- catch-up multi-owner drena piu' rapidamente senza perdere fairness;
- nessun fallback sincrono pesante durante warmup, combat o instance pause;
- `/rr sync`, `/rr manifest` e `/rr offline` spiegano subito se il runtime sta
  accumulando stato.

Test locali da aggiungere:

- spec collisioni session id con burst nello stesso secondo;
- spec prune di partial manifest e peer state;
- spec bounded growth di `outboundQueue`/`peerState` dopo churn;
- spec multi-owner con piu' `REQ` in parallelo e fairness/backoff preservati;
- spec su fallback manifest evitato o almeno contabilizzato;
- smoke in-game su roster vecchio, guild join/leave e reload con peer online.

Deliverable:

- nessun cambio wire;
- nessuna migrazione DB obbligatoria, salvo stato transient/cache safe;
- nessuna nuova libreria;
- changelog sotto `Added` o `Changed` quando la modifica entra in release;
- mock/debug sufficienti per dimostrare che non spariscono recipe o professioni:
  `integrity`, `rosterbad`, `offline`, `roster`;
- test locali aggiornati: syntax OK e backend OK con 98 test.

Prossimi candidati ad alto impatto:

- rifinire la parte ancora aperta di Step 8D: ridurre gli shift lineari residui
  nelle code snapshot/manifest se i profili reali li confermano ancora caldi.
- batchare meglio invalidazioni cache/UI durante inbound sync massivo, in modo
  che la finestra aperta non rincorra continuamente dati appena cambiati.
- valutare lista recipe incrementale o virtualizzata solo se il dataset reale
  conferma stutter percepibili lato utente.
- tenere i test di carico e churn come guardrail di non-regressione mentre si
  tocca la pressione runtime.

## Template Impact Analysis

Feature:

Perche' conviene farla ora:

Quale problema utente risolve:

Alternative piu' semplici:

File da toccare:

Entry point/eventi/comandi:

Librerie:

Data model/migrazione:

Sync-visible:

Manifest:

Snapshot:

Merge/authority:

Roster/stale/mock:

UI/refresh reasons:

Cache invalidation:

Performance/pause policy:

Diagnostica:

Mock/manual test:

Rischio rollback:

## Smoke Test In-Game 1.7

Obiettivo: validare rapidamente la release 1.7 in un contesto reale senza
aprire una campagna di test enorme. Questa passata deve soprattutto confermare:

- sync vivo fuori instance anche in raid group;
- stop aggressivo dentro instance;
- wipe seguito da catch-up reale nella stessa sessione;
- specialization che convergono senza wipe;
- assenza di spam chat fuori debug.

### Setup minimo

- personaggio principale con professioni gia' scansionate;
- almeno 2-3 guildmate online con database non vuoto;
- idealmente uno con specialization visibile e uno con dati replica/offline;
- partire con `/rr debug` spento.

### Test 1 - Startup normale

1. `/reload`
2. aspettare 10-30 secondi
3. aprire `/rr`
4. verificare che non compaiano messaggi tecnici in chat
5. usare `/rr sync` solo se serve un dump debug mirato

Esito atteso:

- nessun errore Lua;
- chat pulita;
- roster e UI popolati gradualmente.

### Test 2 - Raid group fuori instance

1. entrare in un raid group nel mondo aperto;
2. attendere almeno un ciclo hello/sync;
3. se necessario fare `/rr debug` poi `/rr sync`.

Esito atteso:

- `paused=false`;
- `onlineNodes` e `registry` si muovono normalmente;
- arrivano `HELLO`, `MANI`, `REQ`, `SNAP` come in party/guild normale.

### Test 3 - Dentro instance

1. entrare in dungeon/raid instance;
2. attendere qualche secondo;
3. fare `/rr debug` poi `/rr sync`.

Esito atteso:

- `paused=true`;
- nessuna crescita anomala di queue/manifest traffic;
- niente stutter evidente attribuibile all'addon.

### Test 4 - Wipe e catch-up nella stessa sessione

1. fuori instance, con peer online;
2. `/rr wipe`;
3. attendere 5-15 secondi;
4. con debug acceso usare `/rr sync`.

Esito atteso:

- il messaggio wipe conferma che e' stata richiesta una nuova resync;
- `manifest received` sale sopra 0;
- il database ricomincia a popolarsi senza richiedere relog o secondo wipe;
- non restano stuck `unchangedSkips` alti con `received=0` per minuti.

### Test 5 - Specialization recovery

1. identificare un peer che ha una specialization nota;
2. fare `/reload` o partire da DB appena ripulito;
3. attendere il normale ciclo sync;
4. controllare UI/dettagli crafter o dump locale.

Esito atteso:

- la specialization remota compare senza wipe aggiuntivi;
- non serve che il peer cambi ricette per far passare il metadata update.

### Test 6 - Sanity scan locale

1. aprire una professione reale;
2. imparare o simulare una nuova recipe se possibile;
3. richiudere e riaprire `/rr`.

Esito atteso:

- nessun errore;
- eventuale specialization locale resta stabile;
- advertisement una tantum, non loop continui.

## Verifica Rapida Per Area

Locale:

- `.\local-tests\run-syntax.ps1`
- `.\local-tests\run-backend-tests.ps1`;
- spec attese: pending scan non consumato da professione sbagliata, snapshot
  parziale non degrada dati, roster incompleto abortisce cleanup.

Scan:

- `/rr dump`
- aprire professioni standard;
- recipe nuova;
- recipe nuova e poi apertura professione diversa;
- scan subset/temporaneamente vuota non deve ridurre count owner;
- Enchanting/CraftFrame;
- verifica rev invariata su scan invariata.

Integrita' dati:

- `/rr mock start integrity`
- `/rr mock status`
- `/rr mock cleanup`
- mock snapshot parziale con professione mancante;
- mock replica piu' nuova ma subset;
- recipe spell/enchant negativa con mapping AtlasLoot mancante;
- roster snapshot incompleto non deve marcare stale in massa;
- owner locale non viene mai degradato da replica/bootstrap.

Manifest/sync:

- `/rr sync`
- `/rr manifest`
- `/rr pull`
- `/rr mock start traffic`
- `/rr mock start offline`
- `/rr mock start trafficburst`
- `/rr offline`
- `/rr perf dump`

Roster:

- `/rr mock start roster`
- `/rr mock start rosterbad`
- `/rr mock status`
- bottone `Roster Cleanup`
- verificare stale esclusi da UI e manifest.

UI:

- `/rr`
- search: digitare, Invio, Escape, click fuori addon, poi aprire chat;
- close: X, Escape, slash toggle, minimap toggle, combat/non-combat;
- drag title bar e reload;
- profession tabs;
- global search con meno/piu' di 2 caratteri;
- favorites;
- dettaglio recipe;
- item cache cold login quando possibile.

Tooltip:

- item link craftabile in chat;
- recipe item link in chat;
- enchant/spell link in chat;
- crafter online presente: mostrare solo online;
- nessun crafter online: mostrare offline visibili;
- AtlasLoot presente e assente;
- stale/mock esclusi.

Pricing:

- `/rr prices <item link>`
- recipe con reagenti prezzati e non prezzati;
- TSM/Auctionator presenti e assenti.

## Stato Dei Grandi Temi

Main window UX:

- prima passata implementata;
- rischio basso/medio;
- resta da verificare in-game su chat, close e posizionamento.

Tooltip crafter-aware:

- prima passata implementata;
- rischio medio;
- resta da verificare in-game su item/enchant link e performance.

Integrita' dati owner/sync:

- implementata e hardenata su scan pending, protezione subset owner,
  specializzazioni, diagnostica scan/recipe validation, snapshot
  replica/parziali, guardrail roster, malformed sync keys e cleanup dati
  corrotti;
- rischio residuo medio/basso finche' mancano prove in-game su eventi recipe
  reali, Enchanting/AtlasLoot, specializzazioni remote senza recipe scan e
  roster Blizzard non completamente caricato;
- il prossimo lavoro non e' aumentare sync, ma limitare meglio il catch-up da
  manifest grandi.

Scansione professioni:

- priorita' alta;
- rischio medio;
- pending per professione/generico, protezione subset e scan opportunistica via
  dati professione attivi sono implementati lato backend;
- resta validazione manuale su UI Blizzard reale, Enchanting e Skillet se
  disponibile.

Manifest hardening:

- priorita' alta per la prossima iterazione;
- rischio medio;
- cache/delta/chunk reuse/outbound pacing e cap progressivo inbound sono
  implementati;
- resta da osservare in-game su gilde reali di grandi dimensioni.

Replica/offline:

- priorita' media-alta;
- rischio medio;
- diagnostica e mock base sono presenti;
- dopo P5 conviene consolidare con scenari stale/replica piu' stretti.

Corrupt data cleanup:

- safe auto-clean al login implementato in batch leggeri;
- cleanup manuale con preview implementato;
- rischio basso, ma va monitorato in-game su saved data molto grandi con
  `/rr perf dump`.

Bootstrap:

- priorita' bassa finche' l'onboarding DB vuoto non e' il problema principale;
- rischio alto;
- trattare come feature dedicata.

UI polish non bloccante:

- priorita' bassa dopo P0;
- fare solo modifiche collegate a problemi utente concreti, scan/sync/debug.
