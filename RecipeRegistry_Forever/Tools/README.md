# Raccolta del database di risoluzione Forever

Il Collector raccoglie ricette, prodotti, reagenti e categorie per il database
statico. Non aggiorna le ricette conosciute dal personaggio, non scrive nel
database di gilda e non alimenta la scansione al login.

## Installazione

Dalla radice del repository:

```powershell
.\RecipeRegistry_Forever\local-tests\deploy-beta.ps1 -Collector
```

Nel client abilita **Recipe Registry - Database Collector**. Il Collector e' un
addon separato di sviluppo, non usa Recipe Registry e non entra nel suo
pacchetto.

**Durante la raccolta conviene disabilitare Recipe Registry.** Il giro dai
trainer prevede di imparare un mestiere, dumparlo e dimenticarlo: per Recipe
Registry ogni "dimentica" e' un mestiere abbandonato, quindi cancella quel
blocco e lo annuncia alla gilda. Sono decine di cambiamenti veri pubblicati a
dei compagni per un lavoro che riguarda solo te, piu' la pulizia automatica che
gira su dati che stanno cambiando sotto. Il Collector da solo basta.

## Giro delle professioni

1. Impara una professione, aprila e aspetta che la lista delle ricette sia pronta.
2. Esegui `/rrdump`. Raccoglie l'intero catalogo restituito dalle API, comprese
   le ricette non apprese, con reagenti e categorie. Un dump incompleto viene
   rifiutato senza sostituire quello precedente.
3. Ripeti con le altre professioni. Puoi cambiare professione nella stessa
   sessione: i dump gia' raccolti rimangono nel Collector. `/rrdump status`
   elenca le professioni raccolte e il numero di ricette.
4. Fai `/reload` per scrivere il file. **Prima del reload o logout successivo**
   archivialo e importalo con:

```powershell
.\RecipeRegistry_Forever\Tools\import-dumps.ps1
```

Il file sorgente si chiama `RecipeRegistry_Forever_Collector.lua` nella cartella
SavedVariables dell'account. Lo script ne conserva una copia in `Tools/dumps/catalog`
e genera `Data/Metadata/RecipeMetadata_Generated.lua` usando tutte le sessioni
archiviate e il dump iniziale del 18 settembre. La cattura piu' recente sostituisce
solo la stessa professione; le altre restano. Con piu' account, specifica
`-SavedVariablesPath 'percorso completo del file'`.

La beta scrive i dump ma non li ricarica: dopo il reload `/rrdump status` puo'
essere vuoto anche se il file sul disco contiene i dati appena raccolti.
L'archiviazione va fatta prima che il client riscriva quel file.

Detto per il giro lungo, dove costa di piu': il Collector riparte vuoto a ogni
sessione, quindi il reload successivo riscrive il file con i soli mestieri di
quella sessione e i precedenti spariscono dal disco. **Si archivia dopo ogni
sessione**, non alla fine del giro. Le sessioni archiviate si sommano fra loro:
`import-dumps.ps1` le usa tutte, e la cattura piu' recente sostituisce solo lo
stesso mestiere.

Dopo l'importazione, ripeti il comando di deploy e fai reload per usare il nuovo
database interno. I dati gia' disponibili coprono Alchemy, Cooking, First Aid e
Herbalism: 364 ricette. Restano da raccogliere gli altri mestieri con ricette.
La lista e' completa rispetto a `GetAllRecipeIDs` della sessione; l'API puo'
avere limitazioni di grado o specializzazione da verificare durante la raccolta.

## Limiti dei dati

Il dump conserva anche tutti gli slot e le alternative dei reagenti. Il formato
attuale del database genera una lista piatta usando il primo oggetto di ciascuno
slot: eventuali ricette con scelte alternative richiedono un adeguamento del
modello prima di considerare complete le stime dei materiali.

Fonti di apprendimento, trainer e requisiti non restituiti dalle API non vengono
inventati. Il database interno descrive le ricette; la conoscenza del personaggio
deve continuare a essere rilevata separatamente dalle API del client.
