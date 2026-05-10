$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$luaRoot = "C:\Program Files (x86)\Lua\5.1"
$lua = Join-Path $luaRoot "lua.exe"

if (-not (Test-Path $lua)) {
    throw "Lua 5.1 interpreter not found at $lua"
}

$env:Path = "$luaRoot;$luaRoot\clibs;$env:Path"

$specs = Get-ChildItem -Path (Join-Path $PSScriptRoot "spec") -Filter "*.lua" | Sort-Object Name
if (-not $specs -or $specs.Count -eq 0) {
    throw "No backend specs found in local-tests\spec"
}

Push-Location $repoRoot
try {
    foreach ($spec in $specs) {
        Write-Host "Running $($spec.Name)"
        & $lua $spec.FullName
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
}
finally {
    Pop-Location
}

Write-Host "Backend tests OK"
