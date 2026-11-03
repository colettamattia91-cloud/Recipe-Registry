# Traduce il bundle del datamining in Tools\dumps\mining.lua, la tabella che
# generate-from-dump.lua legge con --mining=.
#
# Non tocca nient'altro: niente archivi dei dump, niente dataset. E' separato da
# import-dumps.ps1 proprio per questo. Quello congela le SavedVariables del
# Collector in un archivio nuovo ogni volta che gira, e siccome per ogni mestiere
# vince l'archivio piu' recente, lanciarlo "per aggiornare il datamining" con una
# cattura parziale in memoria sostituirebbe mestieri completi. Questo si puo'
# lanciare quando si vuole.
#
#   .\Tools\convert-mining.ps1 -MiningBundle ..\..\WowForeverMining\data\bundles\<build>\recipes.json
#
# Con -IfStale non riconverte se mining.lua e' gia' aggiornato rispetto al bundle
# e al formato: e' il modo in cui lo chiama import-dumps.ps1.
#
# -FallbackBundle sono i bundle delle build precedenti, dal piu' recente, per le
# ricette che quello corrente non legge piu'. Sulla 70205 le 27 "Adaptive" sono
# finite in sezioni cifrate: il client le elenca ancora, il datamining non le
# vede, e senza i loro dati il generatore le scriverebbe come ricette vanilla
# vive senza livello. Dal ripiego si prende solo cio' che manca nel bundle
# corrente, mai il resto, e ogni ricetta dal primo ripiego che la conosce: una
# catena e non un bundle solo, perche' dalla 70532 il penultimo bundle e' la
# 70205, dove le Adaptive sono gia' cifrate.
#
# Mancare dal bundle pero' vuol dire due cose. Le Adaptive la build corrente le
# elenca ancora in SkillLineAbility: e' il nome a essere cifrato. Disorienting
# Smog Potion, con la 70532, da li' e' sparita: e' uscita dal gioco, e il
# ripiego la riporterebbe in vita. Per distinguerle serve il SkillLineAbility
# del dataset da cui il bundle e' nato (-Dataset): di norma si trova da solo
# nella cache del datamining, dal nome scritto nel manifest del bundle.
param(
    [Parameter(Mandatory = $true)][string]$MiningBundle,
    [string[]]$FallbackBundle,
    [string]$Dataset,
    [string]$Output = (Join-Path $PSScriptRoot 'dumps\mining.lua'),
    [switch]$IfStale
)
$ErrorActionPreference = 'Stop'

# Il formato di mining.lua. Va alzato ogni volta che cambia cio' che si scrive,
# cosi' un mining.lua vecchio si riconverte anche se il bundle non e' cambiato.
#   1  MiningRecipes: requiredSkill, classMask, expansion, skillLevels
#   2  + MiningItems: il legame di ogni oggetto, da item_sparse.json
#   3  + recipeItemId: l'oggetto che insegna la ricetta (Pattern, Plans...)
#   4  + MiningUnshippedItems: gli oggetti che il client non descrive
#   5  + recipeItemSkill: il livello che l'oggetto-ricetta chiede per insegnarla
#   6  + MiningRemovedSpells: le ricette che la build corrente non elenca piu'
#   7  + la struttura: per ricetta mestiere, oggetto prodotto, categoria,
#        reagenti, nome e `since`; MiningCategories, MiningBuilds e
#        MiningStructure, che dice al generatore che quei campi ci sono
$format = 7
$marker = "-- formato: $format"

$MiningBundle = (Resolve-Path -LiteralPath $MiningBundle).Path
$bundleDir = Split-Path -Parent $MiningBundle
$itemsPath = Join-Path $bundleDir 'item_sparse.json'
$effectsPath = Join-Path $bundleDir 'spell_effects.json'
$categoriesPath = Join-Path $bundleDir 'trade_skill_categories.json'

# La build di un bundle: dal manifest, o dal nome della cartella.
function Get-BundleBuild([string]$recipesPath) {
    $directory = Split-Path -Parent $recipesPath
    $manifestPath = Join-Path $directory 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        $build = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).source.datasetMeta.build
        if ($build) { return [string]$build }
    }
    if ((Split-Path -Leaf $directory) -match '(\d+\.\d+\.\d+\.\d+)$') { return $Matches[1] }
    return $null
}

# I reagenti di un bundle per spell, gia' scritti in Lua. Il bundle li ordina
# per ID dell'oggetto; l'ordine del gioco lo rimette il generatore dal dump.
function Get-BundleReagents([string]$recipesPath) {
    $path = Join-Path (Split-Path -Parent $recipesPath) 'spell_effects.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $bySpell = @{}
    foreach ($effect in (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)) {
        if ($effect.effectType -ne 'reagent') { continue }
        $key = [string]$effect.spellId
        if (-not $bySpell.ContainsKey($key)) { $bySpell[$key] = New-Object System.Collections.Generic.List[string] }
        $bySpell[$key].Add("{ itemId = $($effect.itemId), count = $($effect.count) }")
    }
    return $bySpell
}

function Get-BundleCategories([string]$recipesPath) {
    $path = Join-Path (Split-Path -Parent $recipesPath) 'trade_skill_categories.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(foreach ($category in (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)) { $category })
}

function ConvertTo-LuaString([string]$text) {
    return '"' + ($text -replace '\\', '\\' -replace '"', '\"') + '"'
}

# Con un ripiego si riconverte sempre: lo stampo dei file non dice se il ripiego
# e' lo stesso dell'ultima volta, e convertire costa un secondo.
if ($IfStale -and -not $FallbackBundle -and (Test-Path -LiteralPath $Output)) {
    $outputStamp = (Get-Item -LiteralPath $Output).LastWriteTimeUtc
    $sources = @($MiningBundle)
    foreach ($companion in @($itemsPath, $effectsPath, $categoriesPath)) {
        if (Test-Path -LiteralPath $companion) { $sources += $companion }
    }
    $newerSource = $sources | Where-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc -gt $outputStamp }
    $sameFormat = Select-String -LiteralPath $Output -SimpleMatch $marker -Quiet
    if (-not $newerSource -and $sameFormat) { return }
}

$writer = New-Object System.Text.StringBuilder
[void]$writer.AppendLine('-- Generato da Tools/convert-mining.ps1 dal bundle di ../WowForeverMining.')
[void]$writer.AppendLine('-- Non modificare a mano: si rigenera quando il bundle o il formato cambiano.')
[void]$writer.AppendLine("-- Fonte: $MiningBundle")

$rows = @(foreach ($entry in (Get-Content -LiteralPath $MiningBundle -Raw | ConvertFrom-Json)) { $entry })
$items = $null
if (Test-Path -LiteralPath $itemsPath) {
    $items = @(foreach ($entry in (Get-Content -LiteralPath $itemsPath -Raw | ConvertFrom-Json)) { $entry })
} else {
    Write-Warning "item_sparse.json assente accanto al bundle: niente legame degli oggetti, niente bopOutput statico."
}

# La struttura. Senza reagenti o senza categorie non la si scrive affatto: un
# generatore che la crede presente leggerebbe "nessun reagente" dove il dato
# manca, e toglierebbe i reagenti del dump.
$currentBuild = Get-BundleBuild $MiningBundle
$reagents = Get-BundleReagents $MiningBundle
$categories = Get-BundleCategories $MiningBundle
$structure = ($null -ne $reagents) -and ($categories.Count -gt 0)
if (-not $structure) {
    Write-Warning "spell_effects.json o trade_skill_categories.json assenti accanto al bundle: reagenti, prodotti e categorie restano quelli del dump."
}
if (-not $currentBuild) {
    Write-Warning "Build del bundle sconosciuta: il generatore non potra' riconoscere le ricette arrivate dopo il dump."
}
$builds = New-Object System.Collections.Generic.List[string]
if ($currentBuild) { $builds.Add($currentBuild) }
$knownCategories = @{}
foreach ($category in $categories) { $knownCategories[[string]$category.id] = $true }
# Per ogni spell, la build piu' vecchia fra quelle lette che lo elenca. Il
# generatore la confronta con la build del dump: cio' che c'era gia' allora e il
# dump non mostra, il gioco lo nasconde; cio' che e' arrivato dopo e' nuovo.
$since = @{}

$carried = New-Object System.Collections.Generic.List[string]
$removedSpells = New-Object System.Collections.Generic.List[string]
if ($FallbackBundle) {
    # Gli spell che la build corrente elenca ancora. Senza, il ripiego porta
    # tutto, come prima, e lo si dice: una ricetta tolta resterebbe viva.
    if (-not $Dataset) {
        $manifestPath = Join-Path (Split-Path -Parent $MiningBundle) 'manifest.json'
        if (Test-Path -LiteralPath $manifestPath) {
            $datasetName = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).source.dataset
            # <repo>\out\bundle\<ref>\recipes.json oppure <repo>\data\bundles\<ref>\recipes.json
            $miningRepo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MiningBundle)))
            $guess = Join-Path $miningRepo "cache\datasets\$datasetName"
            if ($datasetName -and (Test-Path -LiteralPath (Join-Path $guess 'SkillLineAbility.csv'))) { $Dataset = $guess }
        }
    }
    $listed = $null
    if ($Dataset) {
        $listed = @{}
        foreach ($row in (Import-Csv -LiteralPath (Join-Path $Dataset 'SkillLineAbility.csv'))) { $listed[[string]$row.Spell] = $true }
    } else {
        Write-Warning "SkillLineAbility della build corrente non trovato: il ripiego porta anche le ricette uscite dal gioco."
    }

    $known = @{}
    foreach ($row in $rows) { if ($null -ne $row.spellId) { $known[[string]$row.spellId] = $true } }
    $neededItems = @{}
    $fallbackItemPaths = New-Object System.Collections.Generic.List[string]
    $fallbackNames = New-Object System.Collections.Generic.List[string]
    foreach ($fallback in $FallbackBundle) {
        $fallback = (Resolve-Path -LiteralPath $fallback).Path
        $fallbackNames.Add((Split-Path -Leaf (Split-Path -Parent $fallback)))
        $fallbackItemPaths.Add((Join-Path (Split-Path -Parent $fallback) 'item_sparse.json'))
        $fallbackBuild = Get-BundleBuild $fallback
        if ($fallbackBuild) { $builds.Add($fallbackBuild) }
        # Le categorie che il bundle corrente non ha piu', per le ricette che
        # arrivano da qui. I reagenti solo se servono: e' il file piu' grosso.
        foreach ($category in (Get-BundleCategories $fallback)) {
            $id = [string]$category.id
            if (-not $knownCategories.ContainsKey($id)) { $categories += $category; $knownCategories[$id] = $true }
        }
        $fallbackReagents = $null
        foreach ($row in (Get-Content -LiteralPath $fallback -Raw | ConvertFrom-Json)) {
            if ($null -eq $row.spellId) { continue }
            $key = [string]$row.spellId
            # I ripieghi vanno dal piu' recente al piu' vecchio: l'ultimo che
            # scrive e' il piu' vecchio che la elenca.
            if ($fallbackBuild) { $since[$key] = $fallbackBuild }
            if ($known.ContainsKey($key)) { continue }
            if ($structure -and -not $reagents.ContainsKey($key)) {
                if ($null -eq $fallbackReagents) { $fallbackReagents = Get-BundleReagents $fallback }
                if ($fallbackReagents -and $fallbackReagents.ContainsKey($key)) { $reagents[$key] = $fallbackReagents[$key] }
            }
            $known[$key] = $true
            # Uscita dal gioco: si porta lo stesso, perche' un record rimosso si
            # marca e resta intero -- mestiere, espansione, oggetto-ricetta --
            # cosi' rimetterlo e' togliere una riga, non ricostruirlo.
            if ($listed -and -not $listed.ContainsKey($key)) {
                $removedSpells.Add("$key $($row.name)")
            } else {
                $carried.Add("$key $($row.name)")
            }
            $rows += $row
            foreach ($id in @($row.createdItemId, $row.recipeItemId)) { if ($id) { $neededItems[[string]$id] = $true } }
        }
    }
    # Gli oggetti di quelle ricette, se il bundle corrente non li ha: e' da qui
    # che il generatore sa che il prodotto non e' descritto dal client, e quindi
    # che la ricetta e' `removed`. Anche questi dal primo ripiego che li ha.
    if ($neededItems.Count -gt 0) {
        $haveItems = @{}
        foreach ($item in $items) { if ($null -ne $item.itemId) { $haveItems[[string]$item.itemId] = $true } }
        foreach ($fallbackItemsPath in $fallbackItemPaths) {
            if (-not (Test-Path -LiteralPath $fallbackItemsPath)) { continue }
            foreach ($item in (Get-Content -LiteralPath $fallbackItemsPath -Raw | ConvertFrom-Json)) {
                $key = [string]$item.itemId
                if ($neededItems.ContainsKey($key) -and -not $haveItems.ContainsKey($key)) {
                    $items += $item
                    $haveItems[$key] = $true
                }
            }
        }
    }
    [void]$writer.AppendLine("-- Ripiego: $($fallbackNames -join ', ') ($($carried.Count) ricette che la fonte non legge piu')")
    [void]$writer.AppendLine("-- Uscite dal gioco, secondo SkillLineAbility di ${Dataset}: $($removedSpells.Count)")
}
[void]$writer.AppendLine($marker)

[void]$writer.AppendLine('MiningRecipes = {')
foreach ($row in $rows) {
    if ($null -eq $row.spellId) { continue }
    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $row.requiredSkill) { $parts.Add("requiredSkill = $($row.requiredSkill)") }
    if ($null -ne $row.classMask) { $parts.Add("classMask = $($row.classMask)") }
    if ($row.firstSeenExpansion) { $parts.Add("expansion = '$($row.firstSeenExpansion)'") }
    if ($row.skillLevels -and $row.skillLevels.Count -gt 0) {
        $parts.Add("skillLevels = { $($row.skillLevels -join ', ') }")
    }
    if ($row.recipeItemId) { $parts.Add("recipeItemId = $($row.recipeItemId)") }
    if ($row.recipeItemRequiredSkillRank) { $parts.Add("recipeItemSkill = $($row.recipeItemRequiredSkillRank)") }
    if ($structure) {
        $key = [string]$row.spellId
        if ($row.profession) { $parts.Add("profession = '$($row.profession)'") }
        if ($row.createdItemId) { $parts.Add("createdItemId = $($row.createdItemId)") }
        if ($row.tradeSkillCategoryId) { $parts.Add("category = $($row.tradeSkillCategoryId)") }
        $first = if ($since.ContainsKey($key)) { $since[$key] } else { $currentBuild }
        if ($first) { $parts.Add("since = '$first'") }
        if ($reagents.ContainsKey($key)) { $parts.Add("reagents = { $($reagents[$key] -join ', ') }") }
        # Solo per il rapporto del generatore, che senza nome stamperebbe numeri.
        if ($row.name) { $parts.Add("name = $(ConvertTo-LuaString $row.name)") }
    }
    if ($parts.Count -gt 0) {
        [void]$writer.AppendLine("    [$($row.spellId)] = { $($parts -join ', ') },")
    }
}
[void]$writer.AppendLine('}')

if ($structure) {
    [void]$writer.AppendLine('MiningStructure = true')
    # Dalla piu' recente: la prima e' quella del bundle, che da' il nome ai dati.
    [void]$writer.AppendLine("MiningBuilds = { $(($builds | ForEach-Object { "'$_'" }) -join ', ') }")
    # L'albero delle categorie del client. La radice di ogni mestiere non ha
    # padre; il generatore risale fino a li', come fa sul dump.
    [void]$writer.AppendLine('MiningCategories = {')
    foreach ($category in ($categories | Sort-Object { [int]$_.id })) {
        $fields = New-Object System.Collections.Generic.List[string]
        if ($category.name) { $fields.Add("name = $(ConvertTo-LuaString $category.name)") }
        if ($null -ne $category.orderIndex) { $fields.Add("order = $($category.orderIndex)") }
        if ($null -ne $category.parentId) { $fields.Add("parent = $($category.parentId)") }
        [void]$writer.AppendLine("    [$($category.id)] = { $($fields -join ', ') },")
    }
    [void]$writer.AppendLine('}')
}

# Il legame di ogni oggetto, cosi' com'e' in ItemSparse: 0 nessuno, 1 quando si
# raccoglie, 2 quando si equipaggia, 3 quando si usa, 4 oggetto di missione. Il
# generatore ne tiene solo la domanda che gli serve -- e' BoP o no -- ma qui si
# scrive il valore intero, perche' la domanda potrebbe cambiare e il dato no.
$itemCount = 0
$unshipped = New-Object System.Collections.Generic.List[string]
[void]$writer.AppendLine('MiningItems = {')
foreach ($item in $items) {
    if ($null -eq $item.itemId) { continue }
    # Un oggetto senza NOME non e' un oggetto con dati parziali: e' un oggetto
    # che non ha riga in ItemSparse, cioe' che questa build non spedisce. Il
    # bundle lo emette con tutti i campi nulli, e sono 563 su 4358. Il legame
    # nullo da solo non basta a dirlo -- "Recipe: Westfall Stew" ha bindType
    # nullo ma nome e qualita' ci sono -- quindi il cancello e' il nome.
    if ($null -eq $item.name) {
        $unshipped.Add("    [$($item.itemId)] = true,")
        continue
    }
    if ($null -eq $item.bindType) { continue }
    [void]$writer.AppendLine("    [$($item.itemId)] = $($item.bindType),")
    $itemCount++
}
[void]$writer.AppendLine('}')

# Gli oggetti che il client non descrive. Servono al generatore per marcare
# `removed` le ricette che li producono: esistono nei dati del client ma non
# nel gioco, e listarle come "ti mancano" manda il giocatore a cercare una
# ricetta che non c'e'.
[void]$writer.AppendLine('MiningUnshippedItems = {')
foreach ($line in $unshipped) { [void]$writer.AppendLine($line) }
[void]$writer.AppendLine('}')

# Le ricette che un ripiego conosceva e che la build corrente non elenca piu':
# stanno anche in MiningRecipes, coi dati del ripiego, e il generatore le marca
# `removed`, come quelle il cui prodotto non c'e'.
[void]$writer.AppendLine('MiningRemovedSpells = {')
foreach ($line in $removedSpells) { [void]$writer.AppendLine("    [$($line.Split(' ')[0])] = true, -- $($line.Substring($line.IndexOf(' ') + 1))") }
[void]$writer.AppendLine('}')

Set-Content -LiteralPath $Output -Value $writer.ToString() -NoNewline
Write-Host "Datamining convertito: $Output ($($rows.Count) ricette, $itemCount oggetti, $($unshipped.Count) non spediti)"
if ($structure) {
    Write-Host "Struttura dal datamining: build $($builds -join ', '); $($reagents.Count) ricette con reagenti, $($categories.Count) categorie"
}
if ($carried.Count -gt 0) {
    Write-Host "Dal ripiego, perche' la fonte non le legge piu': $($carried.Count) ricette"
    foreach ($line in $carried) { Write-Host "  $line" }
}
if ($removedSpells.Count -gt 0) {
    Write-Host "Uscite dal gioco, la build corrente non le elenca piu': $($removedSpells.Count) ricette"
    foreach ($line in $removedSpells) { Write-Host "  $line" }
}
