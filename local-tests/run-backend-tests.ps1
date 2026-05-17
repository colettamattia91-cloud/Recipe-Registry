param(
    [ValidateSet("all", "quick", "sync", "soak")]
    [string]$Suite = "all",
    [string]$Spec = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$luaRoot = "C:\Program Files (x86)\Lua\5.1"
$lua = Join-Path $luaRoot "lua.exe"

if (-not (Test-Path $lua)) {
    throw "Lua 5.1 interpreter not found at $lua"
}

$env:Path = "$luaRoot;$luaRoot\clibs;$env:Path"

$allSpecs = Get-ChildItem -Path (Join-Path $PSScriptRoot "spec") -Filter "*.lua" | Sort-Object Name
if (-not $allSpecs -or $allSpecs.Count -eq 0) {
    throw "No backend specs found in local-tests\spec"
}

$normalSoakSpec = "sync_soak_spec.lua"
$heavySoakSpec = "sync_soak_heavy_spec.lua"
$soakSpecs = @($normalSoakSpec, $heavySoakSpec)
$activeAllSpecs = @(
    "acebucket_integration_spec.lua",
    "atlas_category_spec.lua",
    "build_channel_isolation_spec.lua",
    "catalog_cache_spec.lua",
    "options_panel_spec.lua",
    "p4_scan_opportunistic_spec.lua",
    "slash_output_spec.lua",
    "sync_legacy_grep_gate_spec.lua",
    "sync_phase1_legacy_noop_spec.lua",
    "sync_phase2_summary_foundation_spec.lua",
    "sync_phase34_block_pull_spec.lua"
)
$activeSyncSpecs = @(
    "build_channel_isolation_spec.lua",
    "p4_scan_opportunistic_spec.lua",
    "slash_output_spec.lua",
    "sync_legacy_grep_gate_spec.lua",
    "sync_phase1_legacy_noop_spec.lua",
    "sync_phase2_summary_foundation_spec.lua",
    "sync_phase34_block_pull_spec.lua"
)

function Get-SuiteSpecs {
    param(
        [array]$Candidates,
        [string]$SuiteName
    )

    switch ($SuiteName) {
        "all" {
            return $Candidates | Where-Object { $_.Name -in $activeAllSpecs }
        }
        "quick" {
            return $Candidates | Where-Object { $_.Name -in $activeAllSpecs }
        }
        "sync" {
            return $Candidates | Where-Object { $_.Name -in $activeSyncSpecs }
        }
        "soak" {
            return @()
        }
        default {
            throw "Unsupported suite '$SuiteName'"
        }
    }
}

if ($PSBoundParameters.ContainsKey("Spec") -and $Spec) {
    $specLeaf = Split-Path $Spec -Leaf
    $specs = @($allSpecs | Where-Object {
        $_.Name -eq $Spec -or $_.Name -eq $specLeaf -or $_.FullName -eq $Spec
    })
}
else {
    $specs = @(Get-SuiteSpecs -Candidates $allSpecs -SuiteName $Suite)
}

if (-not $specs -or $specs.Count -eq 0) {
    if ($PSBoundParameters.ContainsKey("Spec") -and $Spec) {
        throw "No backend spec matched '$Spec'"
    }
    throw "No backend specs matched suite '$Suite'"
}

$suiteDescriptions = @{
    all = "default/all runs the current supported backend baseline and excludes historical or not-yet-migrated specs."
    quick = "quick currently matches the supported backend baseline."
    sync = "sync runs the supported HELLO/SUMMARY/index-diff/block-pull/runtime-cache/build-isolation rewrite coverage."
    soak = "soak contains no active specs while the historical pre-rewrite soak coverage remains archived in-tree."
}

Push-Location $repoRoot
try {
    if (-not ($PSBoundParameters.ContainsKey("Spec") -and $Spec)) {
        Write-Host ("Selected suite '{0}' with {1} spec(s): {2}" -f $Suite, $specs.Count, $suiteDescriptions[$Suite])
    }
    foreach ($spec in $specs) {
        $specName = if ($spec.PSObject.Properties["Name"]) { $spec.Name } else { Split-Path $spec -Leaf }
        $specPath = if ($spec.PSObject.Properties["FullName"]) { $spec.FullName } else { $spec }
        Write-Host "Running $specName"
        & $lua $specPath
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAILED SPEC: $specName"
            exit $LASTEXITCODE
        }
    }
}
finally {
    Pop-Location
}

if ($PSBoundParameters.ContainsKey("Spec") -and $Spec) {
    Write-Host "Backend spec OK: $(Split-Path $Spec -Leaf)"
}
else {
    Write-Host "Backend tests OK (suite: $Suite)"
}
