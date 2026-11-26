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
inventati. Il livello a cui un trainer insegna una ricetta e' dato del server (il
client dice 1): viene dagli elenchi degli spell di Wowhead, con
`python RecipeRegistry_Forever/Tools/scrape-wowhead.py --spells all`, che scrive
`captures/wowhead-trainer-skill.tsv`; `import-dumps.ps1` lo passa al generatore
se c'e'. Il database interno descrive le ricette; la conoscenza del personaggio
deve continuare a essere rilevata separatamente dalle API del client.

## Quando Wowhead blocca lo script

Per una prima prova di cinque pagine ancora da risolvere:

```powershell
python RecipeRegistry_Forever/Tools/scrape-wowhead.py --triage --limit 5 --interactive --delay 5 --max-refusals 1
```

Lo script apre un Chrome con un profilo dedicato e persistente. Se compare una
verifica, completala in quella finestra (ricaricando la scheda se necessario),
e lo script riprende automaticamente quando arrivano i dati, senza input dal
terminale. Aspetta al massimo cinque minuti: `--verification-timeout 600`
porta l'attesa a dieci minuti. Lo script rilegge la stessa pagina. La verifica
rimane manuale; se non passa, il giro si ferma senza sostituire i dati validi
gia' raccolti. `--interactive` funziona anche con `--lists all` e `--spells all`.

Se Wowhead funziona solo nel tuo Chrome abituale, puoi importare da quello:

1. Apri la pagina `https://www.wowhead.com/forever/item=2555` e aspetta che
   compaiano i dati dell'oggetto.
2. Con Ctrl+S salva come **Pagina web, solo HTML**, chiamandola `item-2555.html`
   in una cartella locale. Non usare il formato MHTML.
3. Importala indicando quella cartella:

```powershell
python RecipeRegistry_Forever/Tools/scrape-wowhead.py --items 2555 --from-html .\build\wowhead-html
```

Sostituisci l'ID e la cartella con quelli salvati. Per piu' oggetti usa
`--items 2555,2697`; per le pagine-elenco salva `list-alchemy.html` e usa
`--lists alchemy --from-html <cartella>`, poi `--report` per aggiornare il TSV.
Gli spell usano `spells-alchemy.html` con `--spells alchemy --from-html <cartella>`.
Le zone usano `zones.html`, `zones-eastern-kingdoms.html`, `zones-kalimdor.html`.
La modalita' `--from-html` non apre Chrome e non fa richieste di rete.

Una pagina di verifica o priva dei blocchi di dati attesi viene rifiutata anche
se salvata su disco. I file mancanti vengono ignorati; una lettura fallita non
cancella una pagina valida gia' in cache. Per ritentare oggetti registrati come
rifiutati usa `--retry-refused`, oppure selezionali con `--items` o `--triage`.
Il limite `--max-refusals` vale anche per gli elenchi e le zone.
Con `--save-html <cartella>` vengono salvate anche le risposte rifiutate come
`refused-item-ID.html` (o `refused-list-MESTIERE.html`), per diagnosticare il blocco.

I controlli dello scraper si eseguono senza rete e senza aprire il browser:

```powershell
python -m unittest discover -s RecipeRegistry_Forever/local-tests -p "test_wowhead_scraper.py" -v
```
