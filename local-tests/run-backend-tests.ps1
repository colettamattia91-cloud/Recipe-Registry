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

function Get-SuiteSpecs {
    param(
        [array]$Candidates,
        [string]$SuiteName
    )

    $heavySoak = @($Candidates | Where-Object { $_.Name -eq "sync_soak_heavy_spec.lua" })

    switch ($SuiteName) {
        "all" {
            return $Candidates | Where-Object { $_.Name -ne "sync_soak_heavy_spec.lua" }
        }
        "quick" {
            return $Candidates | Where-Object {
                $_.Name -notlike "*soak*_spec.lua" -and $_.Name -ne "manifest_comm_bus_spec.lua"
            }
        }
        "sync" {
            return $Candidates | Where-Object {
                $_.Name -match "(sync|manifest|snapshot|transport|chunk|runtime_queue_caps|transfer_identity)" -and $_.Name -ne "sync_soak_heavy_spec.lua"
            }
        }
        "soak" {
            return $Candidates | Where-Object {
                $_.Name -like "*soak*_spec.lua"
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

Push-Location $repoRoot
try {
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
