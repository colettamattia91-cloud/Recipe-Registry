param(
    [string]$ClientPath = 'C:\Program Files (x86)\World of Warcraft\_classic_beta_',
    [string]$SavedVariablesPath
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
