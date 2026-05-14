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

function Get-SuiteSpecs {
    param(
        [array]$Candidates,
        [string]$SuiteName
    )

    switch ($SuiteName) {
        "all" {
            # Default coverage keeps the controlled soak in-band, but reserves the heavy
            # release-readiness soak for the explicit soak suite.
            return $Candidates | Where-Object { $_.Name -ne $heavySoakSpec }
        }
        "quick" {
            return $Candidates | Where-Object {
                $_.Name -notin $soakSpecs -and $_.Name -ne "manifest_comm_bus_spec.lua"
            }
        }
        "sync" {
            return $Candidates | Where-Object {
                $_.Name -match "(sync|manifest|snapshot|transport|chunk|runtime_queue_caps|transfer_identity)" -and $_.Name -ne $heavySoakSpec
            }
        }
        "soak" {
            return $Candidates | Where-Object {
                $_.Name -in $soakSpecs
            }
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
    all = "default/all includes the normal soak (`"$normalSoakSpec`") and excludes the heavy release-readiness soak (`"$heavySoakSpec`")."
    quick = "quick excludes all soak specs and the broader manifest comm-bus coverage."
    sync = "sync includes normal sync/manifest/transport coverage and excludes the heavy release-readiness soak."
    soak = "soak runs both sync soak specs, including the heavy release-readiness soak."
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
