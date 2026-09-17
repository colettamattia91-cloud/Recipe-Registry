# Syntax gate for the Forever tree only.
#
# A copy of the TBC one rather than a shared script with a flavor argument: the
# two addons are separate on purpose, and a shared tool is a shared thing that
# breaks both when one moves. This one knows a single TOC, its own.
$ErrorActionPreference = "Stop"

$addonRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$luaRoot = "C:\Program Files (x86)\Lua\5.1"
$tocPath = Join-Path $addonRoot "RecipeRegistry_Forever.toc"

if (-not (Test-Path (Join-Path $luaRoot "luac.exe"))) {
    throw "Lua 5.1 compiler not found at $luaRoot"
}
if (-not (Test-Path $tocPath)) {
    throw "TOC file not found at $tocPath"
}

$env:Path = "$luaRoot;$luaRoot\clibs;$env:Path"

$files = @()
foreach ($line in Get-Content -Path $tocPath) {
    $trimmed = $line.Trim()
    if (-not $trimmed) { continue }
    if ($trimmed.StartsWith("#")) { continue }
    if ($trimmed -notmatch "\.lua$") { continue }

    $path = Join-Path $addonRoot $trimmed
    if (-not (Test-Path $path)) {
        throw "TOC Lua file not found: $trimmed"
    }
    $files += $path
}

if (-not $files -or $files.Count -eq 0) {
    throw "No Lua files discovered from the TOC"
}

& (Join-Path $luaRoot "luac.exe") -p @files
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Lua syntax OK ($($files.Count) files from RecipeRegistry_Forever.toc)"
