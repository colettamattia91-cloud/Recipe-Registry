<#
.SYNOPSIS
    Mirror both Recipe Registry addons into a WoW Classic AddOns directory
    via a forced copy (alternative to dev-link.ps1's symlinks).

.DESCRIPTION
    When symlinking isn't an option (e.g., Developer Mode off, non-admin
    shell, or you just want a clean physical copy), this script mirrors
    the repo into <AddOns>\RecipeRegistry and <AddOns>\RecipeRegistry_Orders.

    Uses robocopy /MIR so that:
      - Every file the repo has lands in the destination.
      - Files in the destination that are NOT in the repo get DELETED
        (no stale leftovers — this is the whole point).
      - Dev-only directories and files (local-tests, docs, scripts,
        .claude, .git, CLAUDE.md, .pkgmeta, etc.) are excluded.

    If a destination already exists as a symlink/junction the script
    aborts with a clear message — use dev-link.ps1 instead, or remove
    the link first.

.PARAMETER WoWPath
    Path to the WoW install root (the folder that contains the
    .exe). Defaults to $env:RR_WOW_PATH, then to the anniversary
    Classic default install. The script appends Interface\AddOns.

.PARAMETER DryRun
    Print what robocopy would do without actually copying. Adds /L to
    robocopy invocations.

.EXAMPLE
    .\scripts\dev-deploy.ps1
    # Mirrors repo into the default anniversary install.

.EXAMPLE
    .\scripts\dev-deploy.ps1 -WoWPath "D:\Games\World of Warcraft\_classic_"

.EXAMPLE
    .\scripts\dev-deploy.ps1 -DryRun
    # Show the file list without touching anything.
#>

[CmdletBinding()]
param(
    [string]$WoWPath = $(if ($env:RR_WOW_PATH) { $env:RR_WOW_PATH } else { "C:\Program Files (x86)\World of Warcraft\_anniversary_" }),
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $WoWPath -PathType Container)) {
    throw "WoW path not found or not a directory: $WoWPath"
}

$addonsDir = Join-Path $WoWPath "Interface\AddOns"
if (-not (Test-Path -LiteralPath $addonsDir -PathType Container)) {
    throw "AddOns directory not found: $addonsDir`nIs the WoW path correct? Expected to find Interface\AddOns inside it."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pluginRoot = Join-Path $repoRoot "RecipeRegistry_Orders"

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "RecipeRegistry.toc"))) {
    throw "RecipeRegistry.toc not found in $repoRoot - repo layout looks wrong."
}
if (-not (Test-Path -LiteralPath (Join-Path $pluginRoot "RecipeRegistry_Orders.toc"))) {
    throw "RecipeRegistry_Orders.toc not found in $pluginRoot - plugin skeleton missing."
}

function Test-IsLink {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return ($item.LinkType -in @("SymbolicLink", "Junction"))
}

# Directories and files that exist in the repo but should never be
# shipped to the WoW client. Mirrors (and extends) the .pkgmeta ignore
# list. Anything matching here is invisible to robocopy via /XD and /XF.
$excludedDirs = @(
    ".claude",
    ".git",
    ".github",
    ".vscode",
    "docs",
    "local-tests",
    "scripts",
    "RecipeRegistry_Orders"   # excluded from the main addon copy; mirrored separately below.
)
$excludedFiles = @(
    ".gitignore",
    ".pkgmeta",
    "CLAUDE.md",
    "README.md",              # not required at runtime; CurseForge serves it from the project page.
    "CHANGELOG.md"            # ditto.
)

function Invoke-MirrorCopy {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination,
        [string[]]$ExcludeDirs  = @(),
        [string[]]$ExcludeFiles = @(),
        [switch]$DryRun
    )

    if (Test-IsLink -Path $Destination) {
        throw "[abort] $Destination exists as a symlink/junction. Use scripts\dev-link.ps1 instead, or remove the link first (e.g. Remove-Item -LiteralPath '$Destination')."
    }

    $args = @(
        $Source,
        $Destination,
        "/MIR",                # mirror: copy new/changed, delete stale.
        "/NFL", "/NDL",        # quieter output: no per-file/per-dir lines.
        "/NJH", "/NJS",        # no robocopy job header/summary.
        "/NP",                 # no progress indicator.
        "/R:1", "/W:1"         # one retry, one-second wait.
    )

    if ($ExcludeDirs.Count -gt 0) {
        $args += "/XD"
        # Each excluded dir is matched against the full path; passing
        # just the leaf name matches dirs at any depth.
        $args += $ExcludeDirs
    }
    if ($ExcludeFiles.Count -gt 0) {
        $args += "/XF"
        $args += $ExcludeFiles
    }
    if ($DryRun) {
        $args += "/L"          # list only, don't copy.
    }

    Write-Host ("[copy] {0} -> {1}" -f $Source, $Destination)
    & robocopy @args | Out-Null
    $exitCode = $LASTEXITCODE

    # Robocopy exit codes: 0-7 are success (with various combinations of
    # copied/skipped/extra files). 8 and above indicate real failures.
    if ($exitCode -ge 8) {
        throw "robocopy failed for $Source -> $Destination (exit=$exitCode). Run with -DryRun to inspect."
    }
}

# RecipeRegistry (main addon): repo root minus dev-only stuff and minus
# the plugin subdirectory (which is mirrored separately).
$mainDest = Join-Path $addonsDir "RecipeRegistry"
Invoke-MirrorCopy `
    -Source       $repoRoot `
    -Destination  $mainDest `
    -ExcludeDirs  $excludedDirs `
    -ExcludeFiles $excludedFiles `
    -DryRun:$DryRun

# RecipeRegistry_Orders: standalone plugin folder.
$pluginDest = Join-Path $addonsDir "RecipeRegistry_Orders"
Invoke-MirrorCopy `
    -Source       $pluginRoot `
    -Destination  $pluginDest `
    -DryRun:$DryRun

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run complete. No files were modified."
} else {
    Write-Host "Done. Launch WoW and run /reload (or restart) to pick up the changes."
    Write-Host ""
    Write-Host "Verify in-game: /rrord diag"
    Write-Host "  Expect to see a new 'UI hook:' line and 'host-has-tab=true'."
}
