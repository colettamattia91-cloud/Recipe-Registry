# Il codice di adesso fa esattamente quello che faceva quello di un commit?
#
# Per i cambiamenti che non devono cambiare niente -- un riordino, una pulizia --
# "i test passano" non basta: un dato sbagliato che entra nei database della
# gilda non si toglie piu'. Questo script esegue la gilda simulata e la tabella
# dei cancelli due volte, coi client "working" sul codice del commit dato e sul
# codice del disco, e confronta:
#
#   * strict: ogni pezzo passato sul filo, i database di ogni client ogni 60 s
#     simulati, la tabella dei cancelli, gli esiti degli spec. Deve coincidere
#     byte per byte, altrimenti lo script fallisce e mostra la prima differenza;
#   * info: conteggi delle tracce, da leggere a mano.
#
# Il simulatore e' deterministico (seme fisso, orologio virtuale), quindi due
# esecuzioni dello stesso codice danno file identici.
#
#   .\RecipeRegistry_Forever\local-tests\run-equivalence.ps1 -Base c6923e5
param(
    [Parameter(Mandatory = $true)][string]$Base,
    [string]$ChaosSeeds = "131,137,139,149,151,157,163,167,173,179",
    [string]$OutRoot
)

$ErrorActionPreference = "Stop"

$addonRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$luaExe = "C:\Program Files (x86)\Lua\5.1\lua.exe"
if (-not (Test-Path $luaExe)) { throw "Lua 5.1 non trovato in $luaExe" }

Push-Location $addonRoot
try {
    $baseSha = (git rev-parse --verify "$Base^{commit}").Trim()
    if ($LASTEXITCODE -ne 0 -or -not $baseSha) { throw "commit sconosciuto: $Base" }
} finally {
    Pop-Location
}

if (-not $OutRoot) {
    $OutRoot = Join-Path ([IO.Path]::GetTempPath()) ("rr-equivalence-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
$dirBase = Join-Path $OutRoot "base"
$dirNew = Join-Path $OutRoot "nuovo"
New-Item -ItemType Directory -Force -Path $dirBase, $dirNew | Out-Null

function Invoke-Recorded([string]$ref, [string]$dir) {
    $env:RR_SIM_RECORD = $dir
    $env:RR_SIM_CHAOS_SEEDS = $ChaosSeeds
    if ($ref) { $env:RR_SIM_WORKING_REF = $ref } else { Remove-Item Env:RR_SIM_WORKING_REF -ErrorAction SilentlyContinue }
    Push-Location $addonRoot
    try {
        $simOut = & $luaExe "local-tests/specs/sync_sim_spec.lua" 2>&1
        $simExit = $LASTEXITCODE
        $gatesOut = & $luaExe "local-tests/equivalence/gates_table.lua" 2>&1
        $gatesExit = $LASTEXITCODE
    } finally {
        Pop-Location
        Remove-Item Env:RR_SIM_RECORD, Env:RR_SIM_CHAOS_SEEDS, Env:RR_SIM_WORKING_REF -ErrorAction SilentlyContinue
    }
    # l'esito degli spec fa parte del confronto; i tempi di CPU no
    $simOut | ForEach-Object { "$_" } | Where-Object { $_ -notmatch "di CPU\)" } |
        Set-Content -Encoding utf8 -Path (Join-Path $dir "esiti.strict.txt")
    Add-Content -Encoding utf8 -Path (Join-Path $dir "esiti.strict.txt") -Value "sync_sim_spec exit=$simExit"
    $gatesOut | ForEach-Object { "$_" } | Add-Content -Encoding utf8 -Path (Join-Path $dir "esiti.strict.txt")
    Add-Content -Encoding utf8 -Path (Join-Path $dir "esiti.strict.txt") -Value "gates_table exit=$gatesExit"
    return $gatesExit
}

Write-Host "Base: $Base ($baseSha)"
Write-Host "Registri in: $OutRoot"
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host "-- esecuzione col codice di $Base"
$null = Invoke-Recorded $baseSha $dirBase
Write-Host ("   {0:N0} s" -f $sw.Elapsed.TotalSeconds)
Write-Host "-- esecuzione col codice del disco"
$null = Invoke-Recorded "" $dirNew
Write-Host ("   {0:N0} s" -f $sw.Elapsed.TotalSeconds)

$failed = @()
$strictBase = Get-ChildItem -Path $dirBase -File | Where-Object { $_.Name -like "*.strict.txt" -or $_.Name -eq "gates.txt" } | Sort-Object Name
$strictNew = Get-ChildItem -Path $dirNew -File | Where-Object { $_.Name -like "*.strict.txt" -or $_.Name -eq "gates.txt" } | Sort-Object Name

if ($strictBase.Count -lt 10) { throw "troppo pochi registri ($($strictBase.Count)): il registratore non ha girato" }
$namesBase = $strictBase | ForEach-Object Name
$namesNew = $strictNew | ForEach-Object Name
foreach ($n in $namesBase) { if ($namesNew -notcontains $n) { $failed += $n; Write-Host "MANCA nel nuovo: $n" } }
foreach ($n in $namesNew) { if ($namesBase -notcontains $n) { $failed += $n; Write-Host "IN PIU' nel nuovo: $n" } }

foreach ($f in $strictBase) {
    $other = Join-Path $dirNew $f.Name
    if (-not (Test-Path $other)) { continue }
    $ha = (Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash
    $hb = (Get-FileHash -Algorithm SHA256 -Path $other).Hash
    if ($ha -eq $hb) {
        Write-Host ("uguale   {0} ({1:N0} KB)" -f $f.Name, ($f.Length / 1KB))
    } else {
        Write-Host "DIVERSO  $($f.Name)"
        & $luaExe (Join-Path $PSScriptRoot "equivalence\compare.lua") strict $f.FullName $other | Out-Host
        $failed += $f.Name
    }
}

Write-Host ""
Write-Host "-- tracce (solo informazione)"
$infoDiffs = 0
foreach ($f in (Get-ChildItem -Path $dirBase -File -Filter "*.info.txt" | Sort-Object Name)) {
    $other = Join-Path $dirNew $f.Name
    $diff = & $luaExe (Join-Path $PSScriptRoot "equivalence\compare.lua") info $f.FullName $other
    if ($diff) {
        $infoDiffs++
        Write-Host $f.Name
        $diff | ForEach-Object { Write-Host $_ }
    }
}
if ($infoDiffs -eq 0) { Write-Host "nessuna differenza" }

Write-Host ""
if ($failed.Count -gt 0) {
    throw "NON equivalente: $($failed.Count) registri diversi ($($failed -join ', '))"
}
Write-Host ("EQUIVALENTE a {0}: {1} registri identici, {2:N0} s" -f $Base, $strictBase.Count, $sw.Elapsed.TotalSeconds)
