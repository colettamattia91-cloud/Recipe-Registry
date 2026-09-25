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
param(
    [Parameter(Mandatory = $true)][string]$MiningBundle,
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
$format = 5
$marker = "-- formato: $format"

$MiningBundle = (Resolve-Path -LiteralPath $MiningBundle).Path
$itemsPath = Join-Path (Split-Path -Parent $MiningBundle) 'item_sparse.json'

if ($IfStale -and (Test-Path -LiteralPath $Output)) {
    $outputStamp = (Get-Item -LiteralPath $Output).LastWriteTimeUtc
    $sources = @($MiningBundle)
    if (Test-Path -LiteralPath $itemsPath) { $sources += $itemsPath }
    $newerSource = $sources | Where-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc -gt $outputStamp }
    $sameFormat = Select-String -LiteralPath $Output -SimpleMatch $marker -Quiet
    if (-not $newerSource -and $sameFormat) { return }
}

$writer = New-Object System.Text.StringBuilder
[void]$writer.AppendLine('-- Generato da Tools/convert-mining.ps1 dal bundle di ../WowForeverMining.')
[void]$writer.AppendLine('-- Non modificare a mano: si rigenera quando il bundle o il formato cambiano.')
[void]$writer.AppendLine("-- Fonte: $MiningBundle")
[void]$writer.AppendLine($marker)

$rows = Get-Content -LiteralPath $MiningBundle -Raw | ConvertFrom-Json
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
    if ($parts.Count -gt 0) {
        [void]$writer.AppendLine("    [$($row.spellId)] = { $($parts -join ', ') },")
    }
}
[void]$writer.AppendLine('}')

# Il legame di ogni oggetto, cosi' com'e' in ItemSparse: 0 nessuno, 1 quando si
# raccoglie, 2 quando si equipaggia, 3 quando si usa, 4 oggetto di missione. Il
# generatore ne tiene solo la domanda che gli serve -- e' BoP o no -- ma qui si
# scrive il valore intero, perche' la domanda potrebbe cambiare e il dato no.
$itemCount = 0
$unshipped = New-Object System.Collections.Generic.List[string]
$items = $null
if (Test-Path -LiteralPath $itemsPath) {
    $items = Get-Content -LiteralPath $itemsPath -Raw | ConvertFrom-Json
} else {
    Write-Warning "item_sparse.json assente accanto al bundle: niente legame degli oggetti, niente bopOutput statico."
}
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

Set-Content -LiteralPath $Output -Value $writer.ToString() -NoNewline
Write-Host "Datamining convertito: $Output ($($rows.Count) ricette, $itemCount oggetti, $($unshipped.Count) non spediti)"
