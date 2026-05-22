<#
.SYNOPSIS
    Symlink both Recipe Registry addons into a WoW Classic AddOns directory.

.DESCRIPTION
    Recipe Registry and Recipe Registry — Craft Orders ship as two
    sibling addon folders inside one repository (see
    docs/release-process.md for the packaging model). At dev time WoW
    needs to see them as two separate addons under
    Interface\AddOns, but the Craft Orders folder is nested inside the
    repo and not directly exposed.

    This script creates two directory symbolic links:
      <AddOns>\RecipeRegistry        -> <repo root>
      <AddOns>\RecipeRegistry_Orders -> <repo root>\RecipeRegistry_Orders

    Existing links pointing somewhere else are removed and recreated.
    Existing directories (not links) are left alone to avoid clobbering
    a user's manual install — the script will error and tell you to
    move them aside first.

    Creating directory symlinks on Windows requires either:
      - Developer Mode enabled (Settings -> For developers), or
      - Running PowerShell as Administrator.

.PARAMETER WoWPath
    Path to the WoW Classic install root, the folder that contains the
    WoWClassic.exe binary. The script appends Interface\AddOns and
    creates the links there. Defaults to the value in $env:RR_WOW_PATH
    if set.

.PARAMETER Force
    Replace existing directory symlinks even if they already point at
    the repo. Useful after moving the repo to a new path. Does nothing
    for real (non-link) directories — those still error out.

.PARAMETER Remove
    Remove the symlinks instead of creating them. Real directories are
    left alone.

.EXAMPLE
    .\scripts\dev-link.ps1 -WoWPath "D:\Games\World of Warcraft\_classic_"

.EXAMPLE
    $env:RR_WOW_PATH = "D:\Games\World of Warcraft\_classic_"
    .\scripts\dev-link.ps1

.EXAMPLE
    .\scripts\dev-link.ps1 -Remove
#>

[CmdletBinding()]
param(
    [string]$WoWPath = $env:RR_WOW_PATH,
    [switch]$Force,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

if (-not $WoWPath) {
    throw "WoWPath not provided and `$env:RR_WOW_PATH is not set. Pass -WoWPath or set the env var."
}

if (-not (Test-Path $WoWPath -PathType Container)) {
    throw "WoW path not found or not a directory: $WoWPath"
}

$addonsDir = Join-Path $WoWPath "Interface\AddOns"
if (-not (Test-Path $addonsDir -PathType Container)) {
    throw "AddOns directory not found: $addonsDir`nIs the WoW path correct? Expected to find Interface\AddOns inside it."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pluginRoot = Join-Path $repoRoot "RecipeRegistry_Orders"

if (-not (Test-Path (Join-Path $repoRoot "RecipeRegistry.toc"))) {
    throw "RecipeRegistry.toc not found in $repoRoot — repo layout looks wrong."
}
if (-not (Test-Path (Join-Path $pluginRoot "RecipeRegistry_Orders.toc"))) {
    throw "RecipeRegistry_Orders.toc not found in $pluginRoot — plugin skeleton missing."
}

$links = @(
    [pscustomobject]@{ Name = "RecipeRegistry";        Target = $repoRoot   },
    [pscustomobject]@{ Name = "RecipeRegistry_Orders"; Target = $pluginRoot }
)

function Get-LinkInfo {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $item = Get-Item $Path -Force
    if ($item.LinkType -in @("SymbolicLink", "Junction")) {
        return [pscustomobject]@{ IsLink = $true;  Target = $item.Target | Select-Object -First 1 }
    }
    return [pscustomobject]@{ IsLink = $false; Target = $null }
}

foreach ($link in $links) {
    $linkPath = Join-Path $addonsDir $link.Name
    $info = Get-LinkInfo -Path $linkPath

    if ($Remove) {
        if ($null -eq $info) {
            Write-Host ("[skip]   {0}: nothing at {1}" -f $link.Name, $linkPath)
            continue
        }
        if (-not $info.IsLink) {
            Write-Warning ("[skip]   {0}: {1} is a real directory, not a link. Refusing to delete." -f $link.Name, $linkPath)
            continue
        }
        Remove-Item -LiteralPath $linkPath -Force -Recurse
        Write-Host ("[remove] {0}: removed link at {1}" -f $link.Name, $linkPath)
        continue
    }

    if ($null -ne $info -and -not $info.IsLink) {
        throw "[abort] $($link.Name): $linkPath already exists as a real directory. Move it aside (e.g., to RecipeRegistry.bak) before running this script."
    }

    if ($null -ne $info -and $info.IsLink) {
        $sameTarget = ($info.Target -and ((Resolve-Path -LiteralPath $info.Target -ErrorAction SilentlyContinue).Path -eq $link.Target))
        if ($sameTarget -and -not $Force) {
            Write-Host ("[ok]     {0}: already linked to {1}" -f $link.Name, $link.Target)
            continue
        }
        Remove-Item -LiteralPath $linkPath -Force -Recurse
        Write-Host ("[refresh] {0}: removed stale link (was -> {1})" -f $link.Name, $info.Target)
    }

    New-Item -ItemType SymbolicLink -Path $linkPath -Target $link.Target | Out-Null
    Write-Host ("[link]   {0}: {1} -> {2}" -f $link.Name, $linkPath, $link.Target)
}

Write-Host ""
Write-Host "Done. Launch WoW and run /reload or restart the client to pick up the addons."
