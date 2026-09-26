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

Data: 2026-09-17, aggiornato il 2026-09-18 con le prime risposte del client.
Client di riferimento: `wow_classic_beta` 1.60.1.69913 (il bundle di datamining
citato piu' sotto e' fermo alla 69893: il client e' avanzato di una build).

## Stato

Stabilito su dati reali:

- Inventario completo delle API classic usate in produzione, TradeSkill e Craft.
- Mappa di corrispondenza verso le API retail.
- Evidenza indiretta, dai file del client, che il sistema di crafting sia quello
  retail.
- **L'Interface number: `16001`.** Letto in gioco il 2026-09-18 con
  `/dump select(4, GetBuildInfo())`, che ha risposto
  `1.60.1 | 69913 | Sep 17 2026 | 16001`. La regola
  `major*10000 + minor*100 + patch` aveva previsto lo stesso valore, ma adesso
  non e' piu' una previsione. `RecipeRegistry_Forever.toc` lo porta, quindi
  l'albero Forever carica senza "Load out of date AddOns".
- **Come si chiama un personaggio, e cosa ne facciamo.** Letto in gioco il
  2026-09-18, vedi la sezione qui sotto. La chiave di proprietario e' stata
  riscritta di conseguenza nell'albero Forever, con uno spec che la sorveglia.
- **Che `C_TradeSkillUI` esista.** Confermato in gioco il 2026-09-18: la tabella
  c'e' e le sei funzioni che ci servono sono tutte `function` --
  `GetAllRecipeIDs`, `GetRecipeInfo`, `GetRecipeItemLink`, `GetRecipeLink`,
  `GetBaseProfessionInfo`, `GetCategoryInfo`. Era la deduzione su cui poggiava
  tutta la mappa qui sotto, e l'indizio di `TradeSkillCategory` popolata era
  buono: `GetCategoryInfo` esiste, quindi l'albero delle 216 categorie trovate
  nei file del client e' servibile alla UI.

Verifiche ancora aperte:

- ~~Scansione delle ricette conosciute al login.~~ Abbandonata il 2026-09-25.
  Riverificato in gioco a finestra chiusa, dopo un `/reload`: `IsTradeSkillReady`
  false, `GetBaseProfessionInfo` vuoto, `GetAllRecipeIDs` restituisce 471 ID di
  Tailoring, l'ultimo mestiere aperto. Su quelli `learned` e
  `C_SpellBook.IsSpellKnown` concordano 471 su 471; su una ricetta di un altro
  mestiere `learned` risponde false dove `IsSpellKnown` risponde true. Nessuna
  delle 74 funzioni di `C_TradeSkillUI` su ricette e mestieri elenca le ricette
  di un mestiere scelto. Quindi al login un mestiere solo e' leggibile, e gli
  altri richiederebbero una lista di ID presa altrove (un catalogo salvato o il
  dataset) e centinaia di chiamate per mestiere, per un risultato comunque
  parziale. Le ricette si registrano aprendo il mestiere e da
  `NEW_RECIPE_LEARNED`.
- ~~Se `ProfessionsFrame` esista, o se il frame si chiami ancora `TradeSkillFrame`.~~
  Chiuso il 2026-09-21: `ProfessionsFrame` esiste, `TradeSkillFrame` e' nil. Non
  serve niente, perche' la scansione riscritta non dipende da nessuno dei due
  frame e nell'albero Forever `TradeSkillFrame` non compare piu'.
- Comportamento di AtlasLoot, TSM e Auctionator su questo client.

## Oltre TradeSkill: la superficie che nessuno ha ancora guardato

Fatto il 2026-09-20, leggendo l'albero Forever invece del client. Le API di
mestiere sono la parte che abbiamo verificato in gioco; tutto il resto
dell'addon e' arrivato qui per copia dall'albero TBC, e almeno tre punti
poggiano su assunzioni che su un client retail-shaped sono false.

Il guaio comune e' che **falliscono in silenzio**: niente errore Lua, solo una
funzione che non fa niente. Vanno sondati apposta.

### 1. I tooltip non si agganciavano -- chiuso il 2026-09-21

La diagnosi era giusta, la causa che le avevo attribuito no, e vale la pena
lasciarlo scritto perche' e' l'errore naturale da fare.

Sondato in gioco:

    /dump RecipeRegistry.Tooltip._tooltipHooksRegistered   -> nil
    /dump type(TooltipDataProcessor), type(GameTooltip.GetItem), type(TooltipUtil)
                                                            -> table, function, table

Quindi `GameTooltip:GetItem()` **c'e'**. Questo documento sosteneva che su retail
fosse stato rimosso con la 10.0: falso. A mancare e' lo **script**
`OnTooltipSetItem` -- gli accessori sono rimasti, gli eventi no. La guardia
legacy di `UI/Tooltip.lua` pretendeva entrambi, cadeva sullo script, e la
funzione usciva dal ramo "nessuno script: siamo nell'harness di test" senza un
errore. I crafter non comparivano mai.

Adesso il tooltip si aggancia con `TooltipDataProcessor.AddTooltipPostCall` su
`Enum.TooltipDataType.Item` e `.Spell`, e prende l'ID dai dati della post-call,
con `TooltipUtil.GetDisplayedItem` / `GetDisplayedSpell` come ripiego. Il
percorso legacy e' stato **tolto**, non tenuto come ripiego: su questo client
non scatta mai, e codice che non scatta mai e' codice morto.

Un dettaglio che non era ovvio. Le post-call arrivano a ogni ricostruzione del
tooltip, e `AddCraftLines` ha una chiave anti-doppione pensata per quando un
evento scatta due volte sulla stessa costruzione. Con la nuova pipeline quella
chiave restava appesa da una costruzione all'altra: al primo aggiornamento del
tooltip le righe dei crafter sparivano e non tornavano piu'. Si azzera a ogni
post-call. `local-tests/specs/tooltip_spec.lua` lo sorveglia, ed e' stato
provato contro il codice senza l'azzeramento: fallisce con zero righe alla
seconda costruzione.

Verificato in gioco: dopo il deploy le righe dei crafter compaiono.

### 2. Il menu di condivisione puo' far saltare la costruzione del frame

`UI/MainFrame.lua` protegge ogni uso di UIDropDownMenu con
`type(UIDropDownMenu_Initialize) == "function"` e ha `EasyMenu` come ripiego --
tranne una riga:

    local shareMenuFrame = CreateFrame("Frame", "RecipeRegistryShareMenu", right, "UIDropDownMenuTemplate")

Non e' protetta. Se il template non esiste, `CreateFrame` solleva un errore e si
porta dietro tutto il resto della costruzione del frame, non solo il menu.

Sonda: aprire la finestra principale. Se non si apre, `/dump UIDropDownMenuTemplate`
non serve (i template non sono globali): guardare l'errore Lua.
`/dump type(UIDropDownMenu_Initialize)` dice se la famiglia c'e' ancora.

### 3. Il pannello opzioni nasce senza genitore

`Options:EnsurePanel` crea il pannello dentro `InterfaceOptionsFramePanelContainer`,
che su retail dalla 10.0 non esiste piu': il genitore arriva `nil`. La
registrazione invece e' gia' a tre vie
(`Settings.RegisterCanvasLayoutCategory` -> `InterfaceOptions_AddCategory` ->
`InterfaceOptionsFrame_AddCategory`), quindi il pannello probabilmente si
registra lo stesso e viene riparentato da `Settings`. Da guardare, non da
riscrivere a scatola chiusa.

Sonda: `/dump InterfaceOptionsFramePanelContainer`, poi aprire le opzioni
dell'addon e vedere se i controlli sono dove dovrebbero.

### Quello che invece risulta gia' a posto

- **Roster di gilda**: `C_GuildInfo.GuildRoster()` provata per prima, `GuildRoster()`
  come ripiego. `GetNumGuildMembers` / `GetGuildRosterInfo` /
  `GetGuildRosterLastOnline` esistono su entrambi.
- **Comunicazioni**: AceComm usa `C_ChatInfo.RegisterAddonMessagePrefix` quando
  la tabella c'e'. Il prefisso sta nei 16 caratteri.
- **Oggetti e incantesimi**: `Core/Compat.lua` incapsula gia' `C_Item.*` e
  `C_Spell.*` con i globali come ripiego.
- **`BackdropTemplate`**: esiste su retail dalla 9.0.

### Percorsi da provare in gioco, che non sono questioni di API

- La ricetta che si registra da sola su `NEW_RECIPE_LEARNED`: scritta, mai vista
  scattare.
- **Il sync, per intero.** Su questo client non e' mai girato un handshake:
  servono due personaggi nella stessa gilda con l'addon. E' la ragione d'essere
  dell'addon ed e' la parte meno verificata -- ma il rischio e' di
  comportamento, non di API: vedi sotto.

### Il sync, dal lato API, non ha niente da verificare

Controllato il 2026-09-20 sull'albero Forever. L'intero cluster `Sync/` tocca
cinque funzioni di gioco -- `IsInGuild`, `GetTime`, `IsInInstance`,
`InCombatLockdown` e `GetRealmName` -- e nessuna e' cambiata fra classic e
retail. Il trasporto e' AceComm, che usa `C_ChatInfo.RegisterAddonMessagePrefix`
quando la tabella c'e', e spedisce su `GUILD` e `WHISPER`.

`GetRealmName` non lo usa piu' nessuno, dal 2026-09-26. Serviva a riconoscere un
suffisso di reame sui nomi del roster, e in gioco quel suffisso non si presenta
mai: il mittente dei messaggi addon arriva nudo, `Kaedros Davian`, sia in
`GUILD` sia in `WHISPER`, e un sussurro al nome completo arriva. Le chiavi che
viaggiano sono nomi nudi, e sono gia' indirizzi validi.

Quindi il sync non ha adeguamenti da fare. Ha da essere provato.

### Alla gilda si dichiara solo cio' che si sa fare

La domanda vale la pena di fissarla, perche' su questo client la trappola c'e'
davvero: `C_TradeSkillUI.GetAllRecipeIDs` restituisce il CATALOGO del mestiere,
apprese e non -- su Alchemy a livello 1 sono 197 righe di cui 3 tue.

Il catalogo non viene salvato. Il database dei membri lo scrive
`ApplyScanResult`, e i due percorsi che lo chiamano filtrano entrambi:

- `ScanTradeSkill` tiene una riga solo `if info.learned`, e solo per quelle
  chiede i link da cui si ricava la chiave.
- `LearnRecipeFromSignal` chiede conferma a `C_SpellBook.IsSpellKnown` prima di
  scrivere.

Il blocco che il sync serve legge `prof.recipes` da li'. Quindi no: il catalogo
non viaggia.

Il secondo percorso pero' aveva due buchi, chiusi il 2026-09-20. La conferma era
avvolta in `if type(CSB) == "table" and type(CSB.IsSpellKnown) == "function"`,
quindi con l'API assente si scriveva senza chiedere; e il test era
`if ok and not known`, che e' falso anche quando `ok` e' falso, quindi una pcall
fallita passava allo stesso modo. In entrambi i casi un `NEW_RECIPE_LEARNED`
spurio sarebbe bastato a pubblicare alla gilda una ricetta non posseduta. Adesso
senza oracolo si rinuncia, e `scan_spec.lua` sorveglia i due casi.

## SavedVariables: scrittura riuscita, rilettura fallita nella beta

Verificato il 2026-09-18 sulla build di riferimento con la sonda poi rimossa:
`/rrprobe persistence`, `/reload`, `/rrprobe persistence`. La sonda scrive
lo stesso marcatore nelle tre globali dichiarate nel TOC, senza modificare
ricette o professioni.

- Screenshot `WoWScrnShot_091826_190235.jpg`: marcatore nuovo
  `1789750922:34823.144`, riferimenti account e personaggio entrambi `true`.
- Alle 19:02:53 il file account contiene quel marcatore sia in
  `RecipeRegistryDB` sia in `RecipeRegistryLogDB`; il file del personaggio
  lo contiene in `RecipeRegistryCharDB`. La scrittura funziona.
- Screenshot `WoWScrnShot_091826_190301.jpg`, dopo il reload: tutte e tre
  riportano `precedente=assente`, con riferimenti ancora corretti.
- Il vecchio salvataggio con 4 professioni e 9 ricette si carica in Lua 5.1
  e conserva i dati attraverso `Data:OnInitialize()` e il logout di AceDB.
  E' una verifica locale; non simula il caricatore del client.

Il risultato indica un guasto nella rilettura del client, coerente con le
[testimonianze dirette di altri sviluppatori del 18 settembre](https://www.reddit.com/r/wowaddons/comments/1wjmzrm/help_psa_lots_of_addons_in_forever_beta_can_not/).
Questa fonte e' una segnalazione della community, non una conferma ufficiale
Blizzard. Aggiungere uno spazio dopo la virgola nel TOC non ha risolto il
problema; la modifica sperimentale e' stata ritirata.

I reload possono quindi sovrascrivere dati precedenti con lo stato vuoto
della sessione. Copie verificate dei file `.lua` e `.bak` sono conservate
localmente in `RecipeRegistry_Forever/Tools/dumps/persistence-20260918-185926`
e `persistence-20260918-190537`. Il secondo backup conserva anche il catalogo
presente nel `.bak` del personaggio. La persistenza fra sessioni resta da
riverificare dopo un aggiornamento del client. Timer, wrapper e comandi
`/rrprobe` sono stati rimossi dopo la diagnosi.

## Prossimo lavoro: raccolta del database interno

Il database statico di risoluzione descrive ricette, prodotti, reagenti e
categorie. I dati del personaggio/gilda descrivono chi conosce cosa: i due flussi
restano separati. Nessun collegamento dal database statico allo scan del login
e' stato introdotto.

Il dump utile e' stato isolato nell'addon di sviluppo
`RecipeRegistry_Forever_Collector`, comando `/rrdump`, con SavedVariables proprie.
La raccolta in citta' procede un mestiere alla volta; l'importatore archivia e
unisce i dump di sessioni diverse senza dipendere dalla rilettura della beta.
Procedura e limiti: [Tools/README.md](../../RecipeRegistry_Forever/Tools/README.md).

## I nomi, che non sono un dettaglio

Chiuso il 2026-09-18 su dati reali. Il client ha risposto cosi':

```
UnitFullName("player")   -> "Kaedros Davian", "ClassicBetaPvE2"
UnitName("player")       -> "Kaedros Davian", nil
GetRealmName()           -> "Classic Beta PvE 2"
GetNormalizedRealmName() -> "ClassicBetaPvE2"
```

Tre cose, e la terza non si vede dalle prime due.

**Il nome contiene uno spazio.** `Kaedros Davian`: nome e cognome, come
dichiarato. Da solo non rompe niente, ed e' l'unica buona notizia gratis di
questa pagina: il pattern che spacchetta una chiave accetta qualunque cosa non
sia un trattino, e il realm ci arriva ripulito da spazi, quindi
`Kaedros Davian-<realm>` era gia' una chiave valida e le due strade che la
producono -- personaggio locale e roster -- arrivavano gia' allo stesso
risultato.

**Il realm esiste ancora come stringa.** Il documento del 17/09 prevedeva che
potesse non arrivare affatto; arriva. Ma e' proprio qui che sta il problema,
perche' arriva senza essere identita'.

**E non e' affidabile.** Forever e' dichiarato senza realm, e la stringa che il
client risponde sembra seguire l'istanza dinamica su cui si sta girando. Se lo
stesso personaggio si presenta come `ClassicBetaPvE2` oggi e con qualcos'altro
domani, ogni cambio crea un secondo proprietario per la stessa persona:
contenuto diviso a meta', fingerprint che non convergono, e nessun errore da
nessuna parte. E' il modo peggiore di sbagliare per un addon il cui mestiere e'
dichiarare agli altri cosa sai fare.

### La decisione

**La chiave di proprietario e' il nome del personaggio, e basta.** Niente
segmento realm: ne' quello del client, ne' una costante che ne prenda il posto.

Il ragionamento e' dell'utente, il 2026-09-18, ed e' quello che chiude la
questione: il confine dei dati non e' mai stato il realm, e' la **gilda** -- ed
e' gia' imposto dal trasporto, non da noi. Il sync va in `"GUILD"`
(`Sync/SyncProtocol.lua`) e in `"WHISPER"` verso chi e' nel roster, quindi da
fuori non arriva niente, e dentro una gilda i nomi sono unici gia' di loro. Un
segmento che non distingue nulla e non difende nulla e' peso morto.

Il realm lo leggiamo ancora, per una cosa sola: se il roster elencasse un nome
come `Kaedros Davian-ClassicBetaPvE2`, riconoscere quella coda e scartarla --
perche' altrimenti personaggio locale e roster darebbero due chiavi diverse per
la stessa persona. Se il roster risponde nomi nudi, quel ramo non si attiva mai.

Cosa ha preso il posto della forma come controllo. Finche' la chiave era
`nome-realm`, `IsValidMemberKey` faceva anche da cancello di forma sulle chiavi
in arrivo dalla rete e rilette dal database. Col nome nudo quel controllo
diventerebbe "una stringa non vuota", quindi e' stato riscritto su cio' che fa
male davvero: `:` (spezzerebbe le chiavi di blocco `proprietario::professione`),
`|` (l'escape di WoW: un nome che lo contiene inietta colori e link nelle
stringhe che la UI compone), i caratteri di controllo, e gli spazi ai bordi, che
darebbero due chiavi gemelle per lo stesso personaggio.

### Il 25 settembre il cognome ha cambiato posto

Letto in gioco il 2026-09-25: `UnitFullName("player")` risponde
`"Kaedros", "Davian"`, non piu' `"Kaedros Davian", "ClassicBetaPvE2"`. Il
cognome e' passato nel secondo valore, dove prima c'era il realm; anche
`UnitName` risponde col solo nome (AceDB ha creato il profilo `"Kaedros - PvE"`).
Il roster invece e' rimasto `"Kaedros Davian"`.

`GetPlayerKey` leggeva solo il primo valore, quindi per qualche sessione ha
scritto le scansioni sotto `"Kaedros"`: un proprietario che il roster non
conosce, sempre offline. Adesso il secondo valore si attacca come cognome, tranne
quando e' il realm della forma vecchia (coincide con `GetRealmName` e il primo
valore ha gia' lo spazio). E il realm si legge solo da `GetRealmName`: letto dal
secondo valore di `UnitFullName`, oggi sarebbe stato il cognome.

Il giorno dopo, 2026-09-26, tutto questo e' stato semplificato su dati letti in
gioco. `UnitFullName("player")` risponde ormai solo `"Kaedros"`, mentre
`UnitNameUnmodified("player")` risponde `"Kaedros", "Davian"` -- ed e' la strada
che ha preso anche AceDB-3.0 dalla minor 39. `GetPlayerKey` usa solo quella: il
secondo valore e' sempre il cognome, perche' Forever non ha realm e i nomi sono
unici anche fra ruleset. Il roster (120 membri) elenca nomi nudi, nessuno con un
trattino, e il mittente dei messaggi addon arriva nudo: il codice che
riconosceva e toglieva un suffisso `-Realm` non scattava mai, e non c'e' piu'.

### Il trattino, che resta il caso da sorvegliare

Il pericolo vero non era lo spazio, era un cognome col trattino. Con i sei
pattern che spaccavano sul **primo** trattino, `Jean-Luc Picard` dava
`Jean-Luc Picard-<realm>` dal personaggio locale e `Jean-LucPicard` dal roster:
due chiavi, una persona. E `IsValidMemberKey` rispondeva `true` a entrambe.

Nella chiave non c'e' piu' niente da spacchettare, quindi quel modo di rompersi
e' sparito insieme al segmento realm. Sul roster non c'e' piu' nemmeno
l'ambiguita' fra `Jean-Luc Picard` e un nome col suffisso di realm: i suffissi
non arrivano, e un nome del roster si usa com'e'.

Se su Forever i cognomi col trattino esistano davvero non lo sappiamo: i tre
nomi visti finora (`Kaedros Davian`, `Lyndaric Mojo`, `Bernes Jored`) sono tutti
due parole separate da uno spazio. La correzione non aspetta la risposta perche'
e' corretta comunque, e perche' il caso che copre e' silenzioso.

### Dove e' finito, nell'albero Forever

| dove | cosa fa ora |
|---|---|
| `Data/Data.lua` `GetPlayerKey` | nome e cognome da `UnitNameUnmodified`, dal 26/09 |
| `Data/Data.lua` `MemberKeyFromFullName` | l'unica costruzione di chiave da un nome di roster: il nome com'e', dal 26/09. Era la stessa regola copiata in tre punti |
| `Data/Data.lua` `IsValidMemberKey` | controllo di forma riscritto su cosa fa male, vedi sopra |
| `Data/Data.lua` `GetMemberKeyName` | come si ricava un nome da una chiave: oggi e' l'identita', e resta il punto unico in cui smetterebbe di esserlo |
| `Data/GuildLifecycleMaintenance.lua` | non costruisce piu' chiavi per conto suo |
| `Sync/Sync.lua`, `UI/MainFrame.lua`, `UI/Tooltip.lua` | non tagliano piu' al primo trattino, che su un cognome era il posto sbagliato |

Il gate: `RecipeRegistry_Forever/local-tests/run-tests.ps1`, che e' nato qui --
era il primo pezzo di codice adattato che valesse la pena sorvegliare.

~~Resta da vedere `GetGuildRosterInfo`~~: chiuso. Il 21/09 i nomi del roster sono
risultati nudi, e il 26/09 lo ha confermato un roster di 120 membri senza un
solo trattino.

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

Ed è il motivo per cui un `if` per flavor non è una risposta: dentro una
funzione che deve iterare in due modi incompatibili diventa illeggibile in
fretta.

**Deciso il 2026-09-18: la separazione è per cartella, non per file.** Forever è
un addon suo, `RecipeRegistry_Forever/`, con la sua copia di Core, Data, Sync,
UI e Integrations:

```
RecipeRegistry.toc                              -> Core/ Data/ Sync/ UI/
RecipeRegistry_Forever/RecipeRegistry_Forever.toc -> la sua copia di tutto
```

Il prezzo è che l'89% di Lua condiviso diventa 89% duplicato, e una fix
condivisa va applicata due volte. La ragione per pagarlo: su un client con API
retail, codice corretto solo su TBC non è codice inerte, sono errori Lua e
instabilità — e Forever continuerà a evolvere mentre TBC è fermo, quindi il
rischio che si corre volentieri è quello di dover replicare una fix su TBC, se
mai servirà.

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

1. Avviare il client e confermare le incognite qui sopra. Finché non è fatto,
   qualunque codice scritto è scritto contro un'ipotesi. **Chiusi il 2026-09-18:
   l'Interface number** (`16001`, letto da `GetBuildInfo()`), che è la
   condizione per caricare l'albero in beta e quindi per provare tutto il resto,
   **e i nomi**, che erano l'incognita più grave e hanno già prodotto codice.
   Restano aperte `C_TradeSkillUI`, il nome del frame, il formato di
   `GetGuildRosterInfo` e il comportamento di AtlasLoot, TSM e Auctionator.
2. Portare le 74 righe dietro una singola cucitura. `Core/Compat.lua` esiste
   già e fa questo mestiere per `C_AddOns`; è il posto giusto.
3. Riscrivere la scansione sul modello a ID di ricetta, eliminando Expand e
   Collapse invece di emularli.
4. Sbloccare il generatore per il flavor `forever` e importare il bundle. Da
   quel momento `forever` entra nella matrice di `recipe-metadata.yml`, che
   oggi contiene solo `tbc` proprio perché il generatore rifiuta il resto.
5. Portare il tutto su `develop`. `RecipeRegistry_Forever.toc` esiste già e
   porta l'Interface confermata al punto 1. È l'esistenza di quel file, non il
   ramo su cui è stato scritto, a far uscire un secondo zip: finché il TOC non
   c'è, un tag su `main` non pubblica niente per Forever.

## Fonti

- Datamining: `../WowForeverMining`, dataset `forever-local-1.60.1.69893`.
- Analisi della scansione, secondo passo: `docs/forever/scan-rewrite.md`.
- La fonte finale per gli Interface number resta il client via `GetBuildInfo()`.
