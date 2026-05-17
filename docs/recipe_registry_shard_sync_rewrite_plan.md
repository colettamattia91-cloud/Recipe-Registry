# Recipe Registry — Wire-3 Summary / Index-Diff / Block-Pull Rewrite Plan

**Stato documento:** semilavorato tecnico per Codex  
**Branch di riferimento:** `develop`  
**Decisione di protocollo:** la versione corrente del branch non è ancora rilasciata; il nuovo sistema mantiene `WIRE_VERSION = 3` ma rompe la compatibilità semantica con la vecchia sincronizzazione.

---

## 1. Obiettivo

Riscrivere la sincronizzazione di Recipe Registry eliminando il modello basato su manifest globale, revision, coordinator, `AD/IDX/MANI/MREQ` e code owner/revision.

Il nuovo modello deve essere:

- active-owner based;
- content-only;
- data-driven;
- pull-based;
- incrementale per blocco;
- non distruttivo durante sync da repliche;
- indipendente dal coordinator;
- senza fallback revision-based;
- non retrocompatibile con la vecchia logica di sync.

Il nuovo flusso logico è:

```text
HELLO globale
→ SUMMARY diretto dai peer disallineati
→ seed election locale con un solo seed outbound
→ INDEX_DIFF_REQUEST verso il seed scelto
→ INDEX_DIFF_RESPONSE con blocchi pullabili
→ BLOCK_PULL_REQUEST per un solo blockKey alla volta
→ BLOCK_SNAPSHOT
→ merge additivo immediato
→ ricalcolo immediato blockFingerprint
→ globalFingerprint dirty
→ globalFingerprint recompute a fine ciclo/interruzione
→ eventuale nuovo HELLO
```

---

## 2. Vincolo wire/versione

Mantenere:

```lua
Addon.WIRE_VERSION = 3
Addon.MIN_SUPPORTED_WIRE_VERSION = 3
```

Non introdurre wire `4` in questa fase.

Le capability devono descrivere il nuovo modello, non il vecchio manifest model. Preferire nomi espliciti:

```lua
Addon.CAPABILITIES.indexDiffSync = true
Addon.CAPABILITIES.blockPullSync = true
```

Evitare, se possibile, di usare `manifestShards` come capability principale. Se per ragioni temporanee resta nel codice, non deve mai guidare routing manifest o comportamento manifest-based.

---

## 3. Principio architetturale

La sync non deve chiedere:

> Chi ha la revision più nuova?

Deve chiedere:

> Quali content key mancano tra i blocchi `owner::profession` conosciuti dai peer active?

L'unità atomica di confronto e pull è:

```text
blockKey = ownerCharacter::professionKey
```

Il blocco contiene content key, non metadata di trasporto.

Le content key includono:

- recipe key reali già normalizzate dal modello dati esistente;
- eventuali pseudo-content-key per specializzazione professione.

La specializzazione non deve essere salt esterno della fingerprint. Deve essere rappresentata come content key sintetica, ad esempio:

```text
spec:<professionKey>:<specializationKey>
```

Questa key deve essere generata solo a runtime per index/fingerprint, non persistita come recipe reale e non mostrata in UI/search/export come ricetta craftabile.

---

## 4. Regole vincolanti di implementazione

### 4.1 Non è un manifest rinominato

Il nuovo protocollo non deve ricreare il manifest model con un altro nome.

`INDEX_DIFF_REQUEST` e `INDEX_DIFF_RESPONSE` sono peer-directed e servono solo a calcolare una pull list. Non sono broadcast manifest, non contengono revision, timestamp, sourceType, skill metadata o payload recipe completi.

Shards/paging, se necessari, sono solo un dettaglio di trasporto/chunking per indici grandi. Non sono il modello primario di seed election.

### 4.2 Gate obbligatorio: eliminazione totale del revision model sync

Revision model sync must be eliminated completely.

Non usare `rev`, `revision`, `blockRevision`, `knownRev`, `wantRev`, `remoteRev`, `localRev`, `ownerRevision` o qualunque campo derivato da revision per:

- sync routing;
- seed selection;
- block comparison;
- pull priority;
- merge precedence;
- freshness decisions;
- equality checks;
- retry logic;
- diagnostiche che influenzano il comportamento.

Il nuovo modello è data-driven:

- `globalFingerprint` deriva da active owner/profession content keys;
- `blockFingerprint` deriva solo dalle content keys del blocco;
- `INDEX_DIFF` decide i blocchi candidati;
- `BLOCK_PULL_REQUEST` è solo `blockKey`;
- `BLOCK_SNAPSHOT` viene mergiato additivamente;
- `blockFingerprint` viene ricalcolata dopo il merge;
- `globalFingerprint` viene ricalcolata solo a completamento/interruzione del ciclo outbound.

I campi revision persistiti nelle SavedVariables possono restare solo come metadata storici ignorati se rimuoverli è troppo invasivo. Nessun codice di sync può leggerli per produrre decisioni.

Tutte le funzioni, code, test e telemetrie revision-driven devono essere eliminate o riscritte.

Search/remove/rewrite obbligatorio su:

```text
rev
revision
blockRevision
knownRev
wantRev
remoteRev
localRev
ownerRevision
RecordRevisionHint
GetKnownRevision
QueueRequest(..., rev, ...)
AdvertiseLocalRevision
BroadcastIndex
HandleIndex
HandleAdvertise
```

### 4.3 Fingerprint solo per discovery/diff

Le fingerprint non sono vincoli di trasferimento.

- `globalFingerprint` serve a capire se due peer sembrano allineati o disallineati.
- `blockFingerprint` serve nella `INDEX_DIFF` per capire se un blocco manca o ha contenuto diverso.
- `BLOCK_PULL_REQUEST` non deve contenere `expectedFingerprint`, `offeredFingerprint`, `knownFingerprint` o campi equivalenti.
- Dopo `BLOCK_SNAPSHOT`, il receiver applica merge additivo, ricalcola il block fingerprint locale, marca global dirty e continua.

### 4.4 Active riguarda l'owner, non la recipe

Le recipe non sono active/stale. L'owner/peer è active o fuori perimetro.

Prima di costruire blocchi e fingerprint, eseguire un roster cleanup gated da warmup, instance/raid pause e stato runtime.

Il cleanup deve:

- prendere gli owner noti all'addon;
- confrontarli con il roster guild corrente;
- se un owner non è più nel roster, purgare immediatamente i suoi dati dalla sync normale;
- non creare blocchi per owner assenti;
- se l'API WoW espone in modo affidabile il last-online, valutare un gate di assenza di 14 giorni per owner ancora presenti nel roster;
- non usare `lastSeen` come criterio primario se il roster corrente è disponibile.

### 4.5 Merge additivo immediato

Ogni `BLOCK_SNAPSHOT` ricevuto deve essere applicato immediatamente.

Il receiver non deve accumulare blocchi per applicarli a fine sessione.

Dopo ogni blocco ricevuto:

1. clean/normalizzazione del payload;
2. merge additivo nella mappa dati interna;
3. ricalcolo immediato del `blockFingerprint` del solo `blockKey` interessato;
4. aggiornamento dell'indice blocchi in memoria;
5. `globalFingerprintDirty = true`;
6. richiesta del blocco successivo solo dopo applicazione e ricalcolo del blocco corrente.

La global fingerprint viene ricalcolata solo quando la sessione outbound completa o abortisce.

---

## 5. Data model

### 5.1 Content key

Usare la logica di normalizzazione già esistente per gli ID recipe, perché gli ID correnti sono considerati sufficientemente validi.

Prima di calcolare blocchi e fingerprint applicare sempre:

- clean di chiavi owner/profession/recipe corrotte;
- normalizzazione delle recipe key;
- estrazione e normalizzazione della specializzazione come pseudo-content-key;
- esclusione dei record corrotti non recuperabili.

La formula concettuale è:

```text
contentKeys = sorted(realRecipeKeys + syntheticSpecializationKeys)
```

### 5.2 Block fingerprint

```text
blockFingerprint = bf3:<contentCount>:<hash(sorted(contentKeys))>
```

`contentCount` include recipe reali + pseudo-content-key.

### 5.3 Global fingerprint

```text
globalFingerprint = gf3:<activeOwnerCount>:<activeBlockCount>:<activeContentCount>:<hash(sorted(blockKey=blockFingerprint))>
```

`activeContentCount` è preferibile a `activeRecipeCount`, perché include anche pseudo-content-key.

### 5.4 Hashing e compressione

Fare prima un inventario delle librerie già presenti/già usate dall'addon.

È ammesso riusare librerie di serializzazione, compressione/decompressione e chunking per payload grandi.

L'hashing deve essere calcolato sui dati canonici ordinati, non sul payload compresso o su serializzazioni non deterministiche.

Se una libreria già usata offre una funzione hash stabile e disponibile nell'ambiente WoW Classic, valutarla. In caso contrario, mantenere una funzione hash deterministica locale già testata.

---

## 6. Messaggi protocollo

### 6.1 HELLO

Guild-wide, leggero, inviato solo quando:

- warmup completato;
- roster cleanup completato;
- indice locale calcolato;
- non in pause per instance/raid;
- non saturo;
- summary pronta.

Payload concettuale:

```text
HELLO:
  kind
  sender
  wireVersion = 3
  syncModel = "index-diff-block-pull"
  indexStatus = "ready"
  activeOwnerCount
  activeBlockCount
  activeContentCount
  globalFingerprint
```

`indexStatus` rappresenta se il peer ha completato cleanup + calcolo indice. Se non è `ready`, gli altri peer possono registrare presenza ma non avviare seed election.

### 6.2 SUMMARY

Direct whisper verso il sender dell'HELLO.

Un peer risponde con `SUMMARY` solo se:

- è ready;
- non è in pausa;
- non è saturo;
- la sua `globalFingerprint` differisce da quella ricevuta;
- rispetta jitter/cooldown.

Payload concettuale:

```text
SUMMARY:
  kind
  sender
  target
  helloId
  activeOwnerCount
  activeBlockCount
  activeContentCount
  globalFingerprint
```

### 6.3 INDEX_DIFF_REQUEST

Invio diretto dal client al seed scelto.

Non riproporre `globalFingerprint` o tutti i dati già presenti nell'HELLO, salvo campi minimi di correlazione/debug.

Payload concettuale:

```text
INDEX_DIFF_REQUEST:
  kind
  requestId
  sender
  target
  blocks:
    blockKey -> {
      count
      fingerprint
    }
```

### 6.4 INDEX_DIFF_RESPONSE

Il seed confronta l'indice del requester con il proprio indice corrente e restituisce solo i blocchi che il requester può pullare dal seed.

Payload concettuale:

```text
INDEX_DIFF_RESPONSE:
  kind
  requestId
  sender
  target
  offeredBlocks:
    - blockKey
      count
      fingerprint
      reason
```

La fingerprint qui serve solo come informazione di diff/debug/discovery. Non diventa vincolo di pull.

### 6.5 BLOCK_PULL_REQUEST

Sempre un solo blocco.

```text
BLOCK_PULL_REQUEST:
  kind
  requestId
  sender
  target
  blockKey
```

Non includere fingerprint.

### 6.6 BLOCK_SNAPSHOT

Invio diretto del contenuto attuale del blocco posseduto dal seed.

```text
BLOCK_SNAPSHOT:
  kind
  requestId
  sender
  target
  blockKey
  blockPayload
```

Il payload può essere chunked/compresso usando primitive neutre già esistenti.

---

## 7. Seed election

A seguito di `HELLO`, il peer raccoglie `SUMMARY` per una finestra breve.

Valori iniziali da tarare:

```text
SUMMARY_COLLECTION_WINDOW = 5-8 secondi
MAX_OUTBOUND_SEEDS_PER_CYCLE = 1
```

Ranking seed:

1. `globalFingerprint` diverso dal locale;
2. `activeContentCount` maggiore;
3. `activeBlockCount` maggiore;
4. `activeOwnerCount` maggiore;
5. peer non in cooldown/backoff;
6. peer health/responsiveness migliore;
7. tie-break deterministico su `peerKey`.

Usare un solo seed outbound per ciclo. Non parallelizzare seed diversi nella prima implementazione.

Motivo: evitare concorrenza tra blocchi con valori diversi provenienti da seed diversi e relativi sottoscenari.

---

## 8. INDEX_DIFF rules

Quando seed C riceve l'indice di A:

```text
1. A non ha blockKey, C sì:
   C offre il blocco ad A.

2. A ha blockKey, C non lo ha:
   C non avvia reverse pull durante questa inbound seed session.
   Eventuali delta saranno gestiti da un futuro ciclo HELLO.

3. A.fingerprint == C.fingerprint:
   nessuna azione.

4. A.count == C.count e fingerprint diversa:
   C offre il proprio blocco ad A.
   C non avvia reverse pull immediato da A.

5. A.count < C.count e fingerprint diversa:
   C offre il proprio blocco ad A.

6. A.count > C.count e fingerprint diversa:
   C non offre il proprio blocco ad A.
   Il delta di C verrà gestito in un futuro ciclo HELLO dopo che C avrà eventualmente pullato da A in un suo ciclo outbound.
```

Il caso limite in cui il blocco con count minore abbia una content key unica verrà riallineato in cicli futuri ed è da coprire nei test, non da complicare nel protocollo.

---

## 9. Pull scheduling

Per ogni outbound session:

```text
MAX_OUTBOUND_PULL_SESSIONS = 1
MAX_BLOCK_PULL_IN_FLIGHT_PER_SESSION = 1
BLOCK_PULL_DELAY_NORMAL = 1-2 secondi
```

Regole:

- richiedere un solo blockKey alla volta;
- attendere `BLOCK_SNAPSHOT`;
- applicare immediatamente;
- ricalcolare il block fingerprint;
- attendere il delay minimo;
- chiedere il blocco successivo.

Non richiedere il blocco successivo prima che il precedente sia stato applicato e ricalcolato.

---

## 10. Timeout, reset e fine ciclo

Il timeout serve solo a capire quando una richiesta verso seed è fallita o il seed non è più in grado di servire.

Se dopo `BLOCK_PULL_REQUEST` il seed non risponde entro X secondi, oppure risponde con stato pause/unavailable:

1. reset della sessione verso quel seed;
2. cancellazione di tutte le pending request verso quel seed;
3. mantenimento dei blocchi già applicati;
4. trattamento come termine/interruzione della sync;
5. ricalcolo della global fingerprint;
6. eventuale nuovo HELLO se la fingerprint è cambiata.

Valori iniziali da tarare:

```text
BLOCK_PULL_RESPONSE_TIMEOUT = 15-30 secondi
POST_SYNC_HELLO_JITTER = 5-15 secondi
POST_SYNC_HELLO_COOLDOWN = 30-60 secondi
```

---

## 11. Concorrenza

Ogni peer può avere:

- al massimo una outbound pull session attiva;
- più inbound seed session entro limite basso;
- letture inbound mentre una outbound scrive sui dati.

Regole:

- se A sta pullando da C, non può scegliere altri seed outbound;
- se A sta pullando da C, può servire B come seed;
- se B pulla da A un blocco appena modificato da C, B riceve implicitamente la versione aggiornata;
- il ricalcolo del fingerprint del blocco porterà la convergenza;
- A non avvia reverse pull da B sulla base della sessione inbound B→A;
- eventuali delta inversi sono gestiti da futuri cicli HELLO.

---

## 12. Cleanup/stale policy

La sync normale non propaga cancellazioni e non propaga stale.

Il cleanup roster è separato e deve avvenire prima della costruzione dell'indice.

Se un owner noto non è più nel roster corrente, i suoi dati devono essere purgati dal perimetro della sync normale e nessun blocco deve essere generato per quell'owner.

Se l'API WoW restituisce un last-online affidabile per membri ancora presenti nel roster, valutare un gate di 14 giorni. Questo gate deve essere testato in-game prima di renderlo distruttivo.

---

## 13. Debug e diagnostica

Aggiornare debug sia chat sia file/log.

Rimuovere diagnostiche manifest/coordinator/revision come segnali operativi.

Nuovi contatori minimi:

```text
helloSent
summarySent
summaryReceived
seedSelected
indexDiffRequestSent
indexDiffResponseReceived
blocksOffered
blockPullRequestSent
blockSnapshotReceived
blockMergedImmediate
blockFingerprintRecomputed
globalFingerprintDirty
globalFingerprintCommitted
sessionCompleted
sessionAborted
legacyMessageIgnored
revisionPathRemoved
rosterCleanupPurgedOwners
```

I log devono rendere chiaro:

- seed scelto;
- perché è stato scelto;
- numero blocchi offerti;
- blocco corrente in pull;
- timeout/reset;
- ricalcolo global fingerprint post-ciclo;
- eventuali legacy messages ignorati.

---

## 14. Legacy removal

Classificare codice esistente:

- `delete`: solo vecchio manifest/revision/coordinator;
- `rewrite`: serve ancora ma con semantica nuova;
- `neutral-reuse`: envelope, serializer, chunking, compressione, pacing;
- `debug-only`: utile solo a diagnostica;
- `deprecated-noop`: handler legacy ignorati senza errori Lua.

Rimozioni/riscritture richieste:

- `DataManifest.lua`;
- `SyncManifest.lua`;
- `TrickleSync.lua`;
- `MANI/MREQ` automatici;
- `AD/IDX` come routing sync;
- coordinator convergence;
- revision hints;
- `QueueRequest(... rev ...)`;
- test manifest/revision/coordinator.

Prima di rimuovere file dal `.toc`, effettuare call-site migration pass:

- runtime;
- slash commands;
- diagnostica;
- mock;
- harness;
- test;
- README.

Nessun riferimento pendente deve restare a moduli rimossi.

---

## 15. Test rewrite

I test esistenti vanno classificati come:

- `delete`;
- `rewrite`;
- `keep`;
- `legacy-ignore`;
- `soak-rewrite`.

Test minimi richiesti:

1. `HELLO -> SUMMARY` diretto, nessun `MANI/MREQ/IDX/AD` side effect.
2. Fingerprint ignora revision, timestamp, sourceType, online state, skill metadata.
3. Specializzazione come synthetic content key.
4. Roster cleanup prima di index/fingerprint.
5. Un solo seed outbound per ciclo.
6. `INDEX_DIFF`: A count > C count + fingerprint mismatch => C non offre blocco inferiore.
7. `INDEX_DIFF`: count uguale + fingerprint mismatch => C offre blocco ad A.
8. `BLOCK_PULL_REQUEST` contiene solo `blockKey`.
9. Blocco N+1 non viene richiesto prima del merge + ricalcolo fingerprint del blocco N.
10. Ogni blocco ricevuto viene applicato immediatamente.
11. Nessun nuovo HELLO/global summary pubblicato mid-cycle.
12. Interruzione seed: blocchi già applicati restano, pending verso seed cancellate, global recompute, eventuale nuovo HELLO.
13. A può servire inbound mentre pulla outbound, ma non apre reverse pull.
14. Legacy `AD/IDX/MANI/MREQ` ignorati senza errori Lua.
15. Nessuna funzione revision-driven influenza comportamento.
16. Soak: niente storm di SUMMARY.
17. Soak: bounded block pulls e una sola outbound session.
18. Massive: molti peer, un solo seed per ciclo, convergenza eventuale in più cicli.
19. Debug chat/file coerente con nuovo protocollo.
20. Nessun riferimento pendente a moduli legacy rimossi.

---

## 16. Prompt operativo per Codex

```text
Read this markdown carefully.

Implement the new wire-3 summary/index-diff/block-pull sync protocol as a clean replacement for the old sync model.

Do not preserve the old revision/manifest/coordinator sync path.

Core flow:
HELLO -> direct SUMMARY responses -> one selected outbound seed -> INDEX_DIFF_REQUEST -> INDEX_DIFF_RESPONSE -> sequential BLOCK_PULL_REQUEST/BLOCK_SNAPSHOT, one block at a time.

Important constraints:
- keep WIRE_VERSION = 3;
- eliminate revision model sync completely;
- remove MANI/MREQ/IDX/coordinator convergence;
- fingerprints are for discovery/diff only;
- BLOCK_PULL_REQUEST is blockKey-only;
- merge every received block immediately;
- recompute blockFingerprint immediately after each merge;
- recompute globalFingerprint only when outbound cycle completes or aborts;
- use one outbound seed per cycle;
- allow inbound seed service during outbound sync, but no reverse pull from inbound clients;
- run roster cleanup before building indexes/fingerprints;
- treat specialization as synthetic content key generated at index/fingerprint time only;
- rewrite unit, soak, heavy and massive tests.

Before coding, produce a revised file-by-file implementation plan and classify legacy code as delete/rewrite/neutral-reuse/debug-only/deprecated-noop.
```
