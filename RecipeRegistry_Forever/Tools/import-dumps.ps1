param(
    [string]$ClientPath = 'C:\Program Files (x86)\World of Warcraft\_classic_beta_',
    [string]$SavedVariablesPath,
    # Il bundle del datamining, che porta i campi che il client non espone per
    # ricetta: requiredSkill, skillLevels, espansione, classMask, e il legame
    # degli oggetti prodotti. Si cerca da solo accanto al repo; con -NoMining si
    # genera senza.
    [string]$MiningBundle,
    [switch]$NoMining,
    # Dove si archiviano le catture del Collector. Di norma e' il repo privato
    # accanto a questo, ../WowForeverMining/data/collector: le catture sono dati,
    # si rifanno solo giocando, e questo repo e' pubblico. Chi quel repo non ce
    # l'ha ricade sulla cartella locale Tools/dumps/catalog.
    [string]$ArchiveRoot
)
$ErrorActionPreference = 'Stop'
$addonRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lua = 'C:\Program Files (x86)\Lua\5.1\lua.exe'
if (-not (Test-Path -LiteralPath $lua)) { throw "Lua 5.1 assente: $lua" }
if (-not $SavedVariablesPath) {
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $ClientPath 'WTF\Account') -Recurse -File -Filter 'RecipeRegistry_Forever_Collector.lua')
    if ($candidates.Count -ne 1) {
        throw 'Indica -SavedVariablesPath: serve un unico file RecipeRegistry_Forever_Collector.lua.'
    }
    $SavedVariablesPath = $candidates[0].FullName
}
$SavedVariablesPath = (Resolve-Path -LiteralPath $SavedVariablesPath).Path
$miningRepo = Join-Path (Split-Path -Parent (Split-Path -Parent $addonRoot)) 'WowForeverMining'
if (-not $ArchiveRoot) {
    $privateArchive = Join-Path $miningRepo 'data\collector'
    $ArchiveRoot = if (Test-Path -LiteralPath $privateArchive) { $privateArchive } else { Join-Path $PSScriptRoot 'dumps\catalog' }
}
$archiveRoot = $ArchiveRoot
New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
# I file di lavoro restano qui, nella cartella locale: nell'archivio -- che puo'
# essere un altro repo -- arriva solo la cattura finita.
$workRoot = Join-Path $PSScriptRoot 'dumps'
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
Write-Host "Archivio delle catture: $archiveRoot"
$id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
$pending = Join-Path $workRoot "$id.pending"
$temporaryOutput = Join-Path $workRoot "$id.output"
$output = Join-Path $addonRoot 'Data\Metadata\RecipeMetadata_Generated.lua'

# Il datamining, tradotto in Lua da convert-mining.ps1.
#
# Il bundle e' JSON e il generatore e' Lua 5.1, che non lo legge. La conversione
# sta in uno script suo, che si puo' lanciare da solo: questo invece congela le
# SavedVariables del Collector in un archivio ogni volta che gira, e non va usato
# per aggiornare solo il datamining. Con -IfStale si riconverte solo se il bundle
# o il formato di mining.lua sono cambiati.
$miningLua = $null
if (-not $NoMining) {
    if (-not $MiningBundle) {
        # Prima i bundle archiviati nel repo privato, che sono quelli da cui il
        # database e' stato generato; poi l'uscita di un emit appena fatto.
        foreach ($guess in @((Join-Path $miningRepo 'data\bundles'), (Join-Path $miningRepo 'out\bundle'))) {
            if ($MiningBundle -or -not (Test-Path -LiteralPath $guess)) { continue }
            $found = Get-ChildItem -LiteralPath $guess -Recurse -File -Filter 'recipes.json' |
                Sort-Object FullName | Select-Object -Last 1
            if ($found) { $MiningBundle = $found.FullName }
        }
    }
    if ($MiningBundle -and (Test-Path -LiteralPath $MiningBundle)) {
        $miningLua = Join-Path $PSScriptRoot 'dumps\mining.lua'
        & (Join-Path $PSScriptRoot 'convert-mining.ps1') -MiningBundle $MiningBundle -Output $miningLua -IfStale
    } else {
        Write-Host "Datamining non trovato: il database conterra' solo cio' che il client espone."
    }
}

# Freeze this file before generating: the client may save again while we work.
Copy-Item -LiteralPath $SavedVariablesPath -Destination $pending
# Tutti gli archivi, piu' la cattura appena congelata. Si sommano per mestiere
# e la piu' recente vince: e' quello che permette di raccogliere in piu'
# sessioni, visto che il Collector riparte vuoto a ogni reload.
$inputs = @(Get-ChildItem -LiteralPath $archiveRoot -File -Filter '*.lua' | Sort-Object Name | ForEach-Object FullName)
$inputs += $pending
try {
    $arguments = @((Join-Path $PSScriptRoot 'generate-from-dump.lua'), $inputs[0], $temporaryOutput)
    if ($inputs.Count -gt 1) { $arguments += $inputs[1..($inputs.Count - 1)] }
    if ($miningLua -and (Test-Path -LiteralPath $miningLua)) { $arguments += "--mining=$miningLua" }
    & $lua @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Importazione fallita: database interno invariato.' }
    $archive = Join-Path $archiveRoot "$id.lua"
    Move-Item -LiteralPath $pending -Destination $archive
    Copy-Item -LiteralPath $temporaryOutput -Destination $output -Force
    Write-Host "Dump archiviato: $archive"
    Write-Host 'Database interno aggiornato. Ridistribuisci con local-tests\deploy-beta.ps1 -Collector.'
} finally {
    foreach ($temporary in @($pending, $temporaryOutput)) {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
