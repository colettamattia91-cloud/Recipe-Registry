$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$luaRoot = "C:\Program Files (x86)\Lua\5.1"

if (-not (Test-Path (Join-Path $luaRoot "luac.exe"))) {
    throw "Lua 5.1 compiler not found at $luaRoot"
}

$env:Path = "$luaRoot;$luaRoot\clibs;$env:Path"

$files = @(
    "Core.lua",
    "Performance.lua",
    "Data.lua",
    "MergeEngine.lua",
    "BootstrapSync.lua",
    "TrickleSync.lua",
    "SyncPausePolicy.lua",
    "GuildLifecycleMaintenance.lua",
    "MockSync.lua",
    "Market.lua",
    "Sync.lua",
    "Tooltip.lua",
    "MinimapButton.lua",
    "Options.lua",
    "UI\MainFrame.lua"
) | ForEach-Object { Join-Path $repoRoot $_ }

& (Join-Path $luaRoot "luac.exe") -p @files
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Lua syntax OK"
