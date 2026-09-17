# Forever: la scansione delle ricette

Secondo passo dopo `forever-api-adaptation.md`, che ha inventariato le API. Qui
si guarda una cosa sola, la scansione, perché è il punto dove il client classic
e un client retail non si assomigliano affatto.

La domanda di partenza era se la scansione serva ancora. La risposta corta è
che la parola "scansione" sta tenendo insieme due cose diverse: un **rituale
sulla UI di Blizzard**, che sparisce quasi tutto, e un'**enumerazione di quello
che il personaggio sa**, che non sparisce ma si riduce a poche righe. E c'è una
terza cosa, sotto, che nessuno ha ancora verificato e che decide quanto vale
tutto il resto: se i dati arrivino anche a finestra chiusa.

Data: 2026-09-17. Nessun dato in-game esiste ancora: il capture in
`../WowForeverMining/out/ingame` è sintetico.

## Cosa fa oggi la scansione

Cinque obblighi, non uno. Quattro esistono solo perché il client classic espone
una lista di UI invece dei dati.

| # | obbligo | dove | perché |
|---|---|---|---|
| 1 | Aspettare la finestra aperta | `Core.lua:498`, `DataScan.lua:438` | i dati vivono nella lista, e la lista esiste quando esiste il frame |
| 2 | Spegnere i filtri dell'utente e rimetterli | `Data.lua:376-561`, ~185 righe | la lista è già filtrata da "solo producibili", "solo skill-up", nome, sottoclasse |
| 3 | Espandere le intestazioni e ri-collassarle | `DataScan.lua:484-523` | le ricette dentro un gruppo chiuso non compaiono nella lista |
| 4 | Iterare l'indice piatto saltando `header` e `subheader` | `DataScan.lua:494-511` | intestazioni e ricette stanno nello stesso array |
| 5 | Costruire la chiave | `DataScan.lua:103` | da `GetTradeSkillItemLink` e `GetTradeSkillRecipeLink` |

E tutto questo due volte, perché Enchanting ha API proprie: `ScanCraft`
(`DataScan.lua:550-619`) più i suoi cancelli (`DataScan.lua:405-438`) sono un
duplicato del percorso TradeSkill che esiste per un mestiere solo.

I punti 2 e 3 sono anche la parte più invasiva dell'addon: è l'unico posto dove
tocchiamo lo stato della UI di Blizzard, con snapshot e ripristino, e se lo scan
muore a metà l'utente si ritrova i filtri cambiati.

## Cosa sopravvive alla riscrittura

Più di quanto sembri, ed è la ragione per cui questa è la riscrittura di un file
e non dell'addon.

- **La chiave di ricetta.** È un numero: positivo l'itemID del prodotto,
  negativo `-spellID` quando l'oggetto non c'è o è ambiguo (Gold Bar via Smelt
  Gold e Transmute). Nessuna dipendenza dal modello del client, quindi nessun
  cambio di formato sul wire, in SavedVariables o nelle fingerprint. Su retail
  la chiave si costruisce anche meglio: `recipeID` **è** lo spell ID, e non
  serve più passare dal parsing di un link.
- **Tutto ciò che viene dopo la chiave.** `ApplyScanResult`, il diff fra set di
  chiavi, `MarkScanNeeded`, la telemetria, le fingerprint, il sync: nessuna di
  queste funzioni sa da dove arrivano le chiavi. Prendono una mappa di numeri.
- **`detectSpecialization`** (`Data.lua:325`): interroga `IsSpellKnown`, non la
  finestra e non le API classic. Sopravvive così com'è. Quello che manca è un
  problema di dati, non di API: gli spell ID delle specializzazioni su Forever.

Non sopravvive `DetectProfessions` (`DataScan.lua:165`): `GetNumSkillLines` e
`GetSkillLineInfo` sono l'API della finestra abilità classic. Il sostituto
retail è `GetProfessions()` più `GetProfessionInfo(index)`, che danno nome, rank
e maxRank **senza finestra aperta**, ed esistono anche su Classic Era — quindi
qui il rischio è basso. È un guadagno: oggi il rank arriva da una finestra,
domani da una chiamata.

## Cosa sparisce

| via | righe | al suo posto |
|---|---:|---|
| Snapshot / clear / restore dei filtri | ~185 | niente: `GetAllRecipeIDs` non è filtrata, la filtrata è `GetFilteredRecipeIDs` |
| Expand / Collapse delle intestazioni | ~40 | niente: in una lista di ID non c'è nulla da aprire |
| Salto delle righe `header` / `subheader` | — | niente: sono ID di ricetta, non righe di lista |
| Percorso Craft per Enchanting | ~100 | niente: su retail Enchanting è un mestiere come gli altri |
| Iterazione al contrario e doppio ricalcolo di `GetNumTradeSkills` | — | un `for` su una lista |

Il cuore diventa: chiedi gli ID, per ognuno chiedi se è appreso, costruisci la
chiave. Quindici righe contro le centocinquanta di oggi, e zero interferenze con
la UI dell'utente.

## Le due forme possibili

**A. Enumerazione dal client.** `C_TradeSkillUI.GetAllRecipeIDs()` per gli ID,
`GetRecipeInfo(recipeID)` per sapere se è appreso, e la chiave dal `recipeID` più
l'oggetto prodotto. Vede tutto quello che il client sa, comprese le ricette che
il nostro dataset non conosce — e su Forever ce ne sono per definizione:
Blueprint dai boss, ricette da campeggio. Su retail questi dati sono legati alla
skill line aperta, ed è da lì che nasce l'unica incognita che conta.

**B. Nessuna finestra.** Il dataset dei metadati conosce già gli spell ID di ogni
ricetta per mestiere: per ognuno si chiede `IsSpellKnown`. Zero UI, zero eventi,
scansione completa al login. Il difetto non è tecnico: vede solo ciò che il
dataset conosce, e su una beta che cambia ogni settimana questo è la garanzia di
un buco silenzioso — il modo peggiore di sbagliare, per un addon il cui mestiere
è dichiarare agli altri cosa sai fare.

Quindi B non può essere la fonte di verità. Ha senso solo come copertura fra due
aperture di finestra, e soltanto se A si rivelasse vincolata alla finestra.

## Le incognite che decidono, e i comandi che le chiudono

Da eseguire in ordine sul client, la prima volta **senza aprire niente**.

```
/dump C_TradeSkillUI ~= nil, C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs ~= nil
/dump GetProfessions()
/dump GetProfessionInfo(1)
/dump type(GetNumTradeSkills), type(GetCraftInfo), type(ExpandTradeSkillSubClass)
/dump C_TradeSkillUI.GetAllRecipeIDs and #C_TradeSkillUI.GetAllRecipeIDs()
```

Poi, con la finestra del mestiere aperta:

```
/dump #C_TradeSkillUI.GetAllRecipeIDs()
/dump C_TradeSkillUI.GetRecipeInfo(C_TradeSkillUI.GetAllRecipeIDs()[1])
/dump C_TradeSkillUI.GetRecipeItemLink(C_TradeSkillUI.GetAllRecipeIDs()[1])
/dump GetNumTradeSkills and GetNumTradeSkills()
```

Cosa dice ciascuna:

1. **Se `C_TradeSkillUI` esista.** Oggi è deduzione, appoggiata all'indizio di
   `TradeSkillCategory` popolata nei file del client. Tutto il resto viene dopo.
2. **Se la quinta riga risponde a finestra chiusa.** È l'unica domanda che fa
   cadere davvero la scansione: senza finestra, `TRADE_SKILL_SHOW` non serve più
   e l'addon si aggiorna al login. Se risponde `nil` o `0`, la finestra resta un
   obbligo e cambia soltanto cosa facciamo dentro.
3. **Cosa contiene `GetRecipeInfo`.** Serve `learned`, e serve un modo di
   arrivare all'oggetto prodotto. Se c'è `categoryID`, allora l'albero delle 216
   categorie trovate nei file del client è vivo e servibile alla UI.
4. **Se le API classic sopravvivano in parallelo.** Forever è costruito su
   vanilla: `GetNumTradeSkills` e compagnia potrebbero essere ancora lì. Se ci
   sono e funzionano, al day one **non c'è niente da riscrivere**, e questa
   riscrittura torna a essere una pulizia da fare con calma invece che un lavoro
   sotto la beta. Questa riga vale da sola il costo del probe.

## Il primo passo che non dipende da niente di tutto questo

Oggi `Core.lua` chiama `ScanTradeSkill` e `ScanCraft` come due cose distinte e
sceglie in base a quale frame è visibile. Due file alternativi per flavor
(`DataScan_Classic.lua`, `DataScan_Forever.lua`) hanno bisogno di **una sola
porta**: un `Data:ScanVisibleProfession()` che dentro sappia se esiste un
percorso Craft o no.

Quel raccordo si può fare subito su TBC, con le suite verdi a dimostrarlo, e non
assume niente sul client Forever: riduce la superficie da duplicare prima di
sapere cosa duplicare. È il posto giusto da cui partire mentre il probe aspetta.

Una conseguenza sui test, da mettere in conto: `local-tests/harness/wow.lua`
mocka le API classic. Un percorso Forever ha bisogno di stub `C_TradeSkillUI`
nell'harness, altrimenti non è testabile qui e si verifica solo in gioco.
