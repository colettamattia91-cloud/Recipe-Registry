# Installa l'albero Forever nel client beta, per provarlo in gioco.
#
# Non e' packaging: il packager vero e' release.sh con il .pkgmeta. Questo copia
# e basta, saltando quello che non deve girare su un client (local-tests).
#
#   .\RecipeRegistry_Forever\local-tests\deploy-beta.ps1           installa
#   .\RecipeRegistry_Forever\local-tests\deploy-beta.ps1 -Fresh    installa e azzera
#
# Azzerare le SavedVariables era il default, perche' partire puliti e' l'unico
# modo di distinguere "l'addon ha letto questo dal client" da "l'addon si ricorda
# una lettura di mezz'ora fa". Non lo e' piu': da quando quel file contiene anche
# i dump delle professioni, azzerarlo per sbaglio costa un giro in gioco per
# mestiere. Adesso si azzera solo chiedendolo, con -Fresh.
#
# ATTENZIONE al momento in cui si lancia -Fresh. WoW tiene le SavedVariables in
# memoria mentre giochi e le riscrive al /reload e al logout: azzerare i file
# mentre sei in gioco non serve a niente, perche' il prossimo /reload ci riscrive
# sopra quello che l'addon ha in pancia. Va fatto con il client **alla schermata
# di selezione personaggio**, o chiuso. Lo script lo ricorda quando lo fa.
param(
    [string]$ClientPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_",
    [switch]$Fresh,
    [switch]$Collector
)

$ErrorActionPreference = "Stop"

$addonRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$addonName = "RecipeRegistry_Forever"
$addonsDir = Join-Path $ClientPath "Interface\AddOns"
$target    = Join-Path $addonsDir $addonName

if (-not (Test-Path $addonsDir)) {
    throw "Cartella AddOns non trovata: $addonsDir"
}

# le cartelle che il TOC carica, piu' i file di contorno. local-tests resta fuori:
# e' l'attrezzatura, non l'addon
$folders = @("Core", "Data", "Integrations", "Libs", "Sync", "UI")
$files   = @("$addonName.toc", "LICENSE")

New-Item -ItemType Directory -Force -Path $target | Out-Null
foreach ($f in $folders) {
    $src = Join-Path $addonRoot $f
    if (Test-Path $src) { Copy-Item -Path $src -Destination $target -Recurse -Force }
}
foreach ($f in $files) {
    $src = Join-Path $addonRoot $f
    if (Test-Path $src) { Copy-Item -Path $src -Destination $target -Force }
}

# Togliere cio' che non c'e' piu' nel repo. Copy-Item sovrascrive ma non
# cancella, quindi senza questo una libreria rimossa dal sorgente resta nel
# client per sempre: inerte finche' nessun TOC la nomina, e una sorpresa il
# giorno che qualcuno la nomina di nuovo.
$expected = @{}
foreach ($f in $folders + $files) { $expected[$f] = $true }
foreach ($existing in Get-ChildItem $target) {
    if (-not $expected.ContainsKey($existing.Name)) {
        $resolved = [IO.Path]::GetFullPath($existing.FullName)
        $targetPrefix = [IO.Path]::GetFullPath($target).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Cleanup path outside addon: $resolved"
        }
        try {
            Remove-Item $existing.FullName -Recurse -Force -ErrorAction Stop
            Write-Host "Rimosso   $($existing.Name) (non e' piu' nel repo)"
        } catch {
            Write-Warning "Non ho potuto rimuovere $($existing.Name): $($_.Exception.Message)"
        }
    }
}
# e dentro Libs, dove le rimozioni sono per cartella
$libSource = Join-Path $addonRoot "Libs"
$libTarget = Join-Path $target "Libs"
if ((Test-Path $libSource) -and (Test-Path $libTarget)) {
    foreach ($lib in Get-ChildItem $libTarget -Directory) {
        if (-not (Test-Path (Join-Path $libSource $lib.Name))) {
            $resolved = [IO.Path]::GetFullPath($lib.FullName)
            $libPrefix = [IO.Path]::GetFullPath($libTarget).TrimEnd('\') + '\'
            if (-not $resolved.StartsWith($libPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Cleanup path outside Libs: $resolved"
            }
            try {
                Remove-Item $lib.FullName -Recurse -Force -ErrorAction Stop
                Write-Host "Rimossa   Libs\$($lib.Name) (non e' piu' nel repo)"
            } catch {
                Write-Warning "Non ho potuto rimuovere Libs\$($lib.Name): $($_.Exception.Message)"
            }
        }
    }
}

$count = (Get-ChildItem $target -Recurse -File | Measure-Object).Count
Write-Host "Copiati $count file in $target"

if ($Collector) {
    $collectorName = 'RecipeRegistry_Forever_Collector'
    $collectorTarget = Join-Path $addonsDir $collectorName
    New-Item -ItemType Directory -Force -Path $collectorTarget | Out-Null
    foreach ($file in @('Collector.lua', "$collectorName.toc")) {
        Copy-Item -LiteralPath (Join-Path $addonRoot "Tools\$collectorName\$file") -Destination $collectorTarget -Force
    }
    Write-Host 'Collector installato: /rrdump cattura il mestiere aperto, /rrdump status elenca i dump.'
}

if (-not $Fresh) {
    Write-Host "SavedVariables lasciate com'erano (usa -Fresh per azzerarle)"
    return
}

# Svuotare invece di cancellare: il file resta, WoW lo rilegge vuoto e l'addon
# riparte con i suoi default. Cancellarlo darebbe lo stesso risultato ma tocca
# meno bene una cartella di sistema.
$saved = Get-ChildItem -Path (Join-Path $ClientPath "WTF") -Recurse -File -Filter "$addonName.lua" -ErrorAction SilentlyContinue
if (-not $saved) {
    Write-Host "Nessuna SavedVariable da azzerare (mai avviato su questo client?)"
} else {
    # I dump delle professioni non sono dati di prova, sono l'ingresso del
    # generatore del dataset: costano un giro in gioco per mestiere e non si
    # rifanno con un tasto. Prima di azzerare, il file si mette da parte.
    $backupDir = Join-Path $addonRoot "Tools\dumps"
    foreach ($s in $saved) {
        $where = $s.FullName.Substring($ClientPath.Length + 1)
        $content = Get-Content -Path $s.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Contains('["dumps"]')) {
            if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $backup = Join-Path $backupDir "$stamp-$addonName.lua"
            Set-Content -Path $backup -Value $content -NoNewline
            Write-Host "Salvati i dump in Tools\dumps\$stamp-$addonName.lua"
        }
        Set-Content -Path $s.FullName -Value "" -NoNewline
        Write-Host "Azzerata  $where"
    }
}

Write-Host ""
Write-Host "Ricorda: perche' l'azzeramento valga, il client deve essere alla schermata"
Write-Host "di selezione personaggio o chiuso. Se sei in gioco, il prossimo /reload"
Write-Host "riscrive i dati che l'addon ha ancora in memoria."
