# Guild Addon Adoption Status

## Summary

Aggiungere nel pannello principale una vista **Addon Status** che incrocia il roster di gilda live con una memoria locale dei peer Recipe Registry visti sul protocollo.

La feature mostrera tutto il roster e usera una soglia di **30 giorni** per etichettare chi non e stato visto recentemente, senza dichiarare mai che qualcuno abbia disinstallato l'addon.

## Key Changes

- Salvare in `RecipeRegistryDB.global.addonPeers` una memoria locale dei peer addon:
  - `firstSeenAt`
  - `lastSeenAt`
  - `addonVersion`
  - `wireVersion`
  - `buildChannel`
  - `buildId`

- Bump schema SavedVariables a `schemaVersion = 3`.

- Inizializzare/migrare `addonPeers = {}` senza toccare `members`, perche `members` resta il database dei crafter/recipe owner.

- Aggiornare la memoria peer quando:
  - `Sync:ObservePeerVersion` riceve un `HELLO` / version info valido;
  - `Sync:TouchNode` vede traffico valido da un peer gia noto.

- Aggiungere API dati tipo:

  ```lua
  Data:GetGuildAddonStatusRows({
      searchText = "...",
      staleAfterDays = 30,
  })
  ```

- Integrare una voce **Addon Status** nella navigazione principale della finestra, riusando la lista centrale virtualizzata.

- Stati mostrati:
  - `Online with addon`
  - `Online, addon not seen`
  - `Seen before`
  - `Not seen recently`
  - `Never seen`

- Ricerca per:
  - nome;
  - rank;
  - stato addon.

- Dettaglio a destra con:
  - versione addon;
  - ultimo visto addon;
  - stato online roster;
  - rank / level / zone se disponibili.

- Aggiornare summary/status cards quando la vista e attiva:
  - roster totale;
  - righe mostrate;
  - peer addon attivi;
  - ultimo refresh roster.

- Aggiungere comando diagnostico:

  ```text
  /rr adoption
  ```

  oppure:

  ```text
  /rr addonstatus
  ```

- Aggiornare help, README e CHANGELOG solo per la nuova feature.

- Non toccare i file `docs/` attualmente dirty.

## Behavior Details

- "With addon" significa peer visto parlare con Recipe Registry, non semplice presenza online.

- "Not seen recently" scatta dopo 30 giorni da `lastSeenAt`.

- Il player locale viene sempre mostrato come usando l'addon quando presente nel roster.

- Se il roster non e ancora caricato, la vista chiede/attende refresh roster e mostra uno stato vuoto esplicito.

- Nessun nuovo messaggio wire/protocollo: la feature usa HELLO e traffico sync esistenti.

## Test Plan

- Eseguire `luac -p` su:
  - `Core/`
  - `Data/`
  - `Sync/`
  - `UI/`
  - `Integrations/`

- Verificare che `RecipeRegistry.toc` continui a puntare a file esistenti.

- Test manuali in game:
  - roster caricato con membri mai visti: appaiono come `Never seen`;
  - peer online con HELLO ricevuto: appare `Online with addon`;
  - membro online senza peer addon: appare `Online, addon not seen`;
  - peer visto in passato ma non online ora: appare `Seen before`;
  - `lastSeenAt` oltre 30 giorni: appare `Not seen recently`.

- Verificare che la vista recipe normale, Favorites, ricerca e dettagli ricetta continuino a funzionare.

- Verificare che `/rr adoption` produca riepilogo senza richiedere debug mode.

## Assumptions

- Branch di lavoro: `develop`.

- Soglia stale V1: 30 giorni.

- La feature e locale: ogni client vede cio che il proprio addon ha osservato/salvato.

- Nessun tentativo di inferire "ha disinstallato l'addon"; wording sempre prudente.
