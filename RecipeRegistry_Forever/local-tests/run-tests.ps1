# Backend specs for the Forever tree only.
#
# A copy of the shape of run-syntax.ps1, and separate from the TBC runner for
# the same reason: the two addons are separate on purpose, and a shared tool is
# a shared thing that breaks both when one moves.
#
# There is no shared harness here yet. TBC's local-tests/harness mocks the
# classic APIs, which is the one thing this client does not have, so each spec
# carries the stub it needs and is run as a plain Lua script from the addon
# root. A harness arrives when two specs want the same stub.
#
#   .\RecipeRegistry_Forever\local-tests\run-tests.ps1
#   .\RecipeRegistry_Forever\local-tests\run-tests.ps1 -Spec member_key_spec.lua
param(
    [string]$Spec
)

$ErrorActionPreference = "Stop"

$addonRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$luaRoot = "C:\Program Files (x86)\Lua\5.1"
$luaExe = Join-Path $luaRoot "lua.exe"
$specRoot = Join-Path $PSScriptRoot "specs"

if (-not (Test-Path $luaExe)) {
    throw "Lua 5.1 interpreter not found at $luaRoot"
}
if (-not (Test-Path $specRoot)) {
    throw "Spec folder not found at $specRoot"
}

$specs = if ($Spec) {
    $one = Join-Path $specRoot $Spec
    if (-not (Test-Path $one)) { throw "Spec not found: $Spec" }
    @(Get-Item $one)
} else {
    @(Get-ChildItem -Path $specRoot -Filter "*_spec.lua" | Sort-Object Name)
}

if ($specs.Count -eq 0) {
    throw "No specs discovered in $specRoot"
}

# the specs address the addon by paths relative to the addon root, as TBC's do
Push-Location $addonRoot
try {
    $failed = @()
    foreach ($s in $specs) {
        Write-Host "--- $($s.Name) ---"
        & $luaExe $s.FullName
        if ($LASTEXITCODE -ne 0) { $failed += $s.Name }
    }
} finally {
    Pop-Location
}

if ($failed.Count -gt 0) {
    throw "Failing specs: $($failed -join ', ')"
}

Write-Host "All Forever specs passed ($($specs.Count))"
