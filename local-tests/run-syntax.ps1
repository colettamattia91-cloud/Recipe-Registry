$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$luaRoot = "C:\Program Files (x86)\Lua\5.1"
$tocPath = Join-Path $repoRoot "RecipeRegistry.toc"

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
    if ($trimmed.StartsWith("##")) { continue }
    if ($trimmed -notmatch "\.lua$") { continue }

    $path = Join-Path $repoRoot $trimmed
    if (-not (Test-Path $path)) {
        throw "TOC Lua file not found: $trimmed"
    }
    $files += $path
}

if (-not $files -or $files.Count -eq 0) {
    throw "No Lua files discovered from RecipeRegistry.toc"
}

& (Join-Path $luaRoot "luac.exe") -p @files
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Lua syntax OK ($($files.Count) files from TOC)"
