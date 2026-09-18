param(
    [string]$ClientPath = 'C:\Program Files (x86)\World of Warcraft\_classic_beta_',
    [string]$SavedVariablesPath,
    # Il bundle del datamining, che porta i campi che il client non espone per
    # ricetta: requiredSkill, skillLevels, espansione, classMask. Si cerca da
    # solo accanto al repo; con -NoMining si genera senza.
    [string]$MiningBundle,
    [switch]$NoMining
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
$archiveRoot = Join-Path $PSScriptRoot 'dumps\catalog'
New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
$id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
$pending = Join-Path $archiveRoot "$id.pending"
$temporaryOutput = Join-Path $archiveRoot "$id.output"
$output = Join-Path $addonRoot 'Data\Metadata\RecipeMetadata_Generated.lua'

# Il datamining, tradotto in Lua una volta sola.
#
# Il bundle e' JSON e il generatore e' Lua 5.1, che non lo legge. PowerShell si':
# quindi la conversione sta qui e il generatore riceve una tabella gia' pronta.
# Il file convertito si rigenera solo se il bundle e' piu' recente.
$miningLua = $null
if (-not $NoMining) {
    if (-not $MiningBundle) {
        $guess = Join-Path (Split-Path -Parent (Split-Path -Parent $addonRoot)) 'WowForeverMining\out\bundle'
        if (Test-Path -LiteralPath $guess) {
            $found = Get-ChildItem -LiteralPath $guess -Recurse -File -Filter 'recipes.json' |
                Sort-Object LastWriteTime | Select-Object -Last 1
            if ($found) { $MiningBundle = $found.FullName }
        }
    }
    if ($MiningBundle -and (Test-Path -LiteralPath $MiningBundle)) {
        $MiningBundle = (Resolve-Path -LiteralPath $MiningBundle).Path
        $miningLua = Join-Path $PSScriptRoot 'dumps\mining.lua'
        $bundleStamp = (Get-Item -LiteralPath $MiningBundle).LastWriteTimeUtc
        $needsConversion = -not (Test-Path -LiteralPath $miningLua) -or
            (Get-Item -LiteralPath $miningLua).LastWriteTimeUtc -lt $bundleStamp
        if ($needsConversion) {
            $rows = Get-Content -LiteralPath $MiningBundle -Raw | ConvertFrom-Json
            $writer = New-Object System.Text.StringBuilder
            [void]$writer.AppendLine('-- Generato da Tools/import-dumps.ps1 dal bundle di ../WowForeverMining.')
            [void]$writer.AppendLine('-- Non modificare a mano: si rigenera quando il bundle cambia.')
            [void]$writer.AppendLine("-- Fonte: $MiningBundle")
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
                if ($parts.Count -gt 0) {
                    [void]$writer.AppendLine("    [$($row.spellId)] = { $($parts -join ', ') },")
                }
            }
            [void]$writer.AppendLine('}')
            Set-Content -LiteralPath $miningLua -Value $writer.ToString() -NoNewline
            Write-Host "Datamining convertito: $miningLua ($($rows.Count) righe lette)"
        }
    } else {
        Write-Host "Datamining non trovato: il database conterra' solo cio' che il client espone."
    }
}

# Freeze this file before generating: the client may save again while we work.
Copy-Item -LiteralPath $SavedVariablesPath -Destination $pending
$inputs = @()
$legacy = Join-Path $PSScriptRoot 'dumps\20260918-1744-RecipeRegistry_Forever.lua'
if (Test-Path -LiteralPath $legacy) { $inputs += $legacy }
$inputs += @(Get-ChildItem -LiteralPath $archiveRoot -File -Filter '*.lua' | Sort-Object Name | ForEach-Object FullName)
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
