# Deploy the working-tree addon straight into the WoW AddOns folder for
# in-game testing. Mirrors the runtime folders (stale files at the
# destination are removed) and copies the TOC.
#
# Usage:
#   .\local-tests\deploy-to-wow.ps1                 # deploy as-is (release channel)
#   .\local-tests\deploy-to-wow.ps1 -Channel dev    # deploy on the RRDEV comm prefix
#   .\local-tests\deploy-to-wow.ps1 -DryRun         # show what would change
#   .\local-tests\deploy-to-wow.ps1 -Link           # one-time: junction folders to the repo
#
# -Channel dev patches X-Build-Channel/X-Build-ID in the DEPLOYED TOC only
# (the repo TOC is untouched). Dev and release clients do not sync with each
# other, so use dev when you want to test without publishing scan changes to
# guildmates on the release build.
#
# -Link replaces the copied runtime folders with NTFS junctions into the
# repo working tree. After that, edits in the repo are live in game with a
# plain /reload and no further deploys (or writes into the WoW folder) are
# needed — only the TOC stays a real file so -Channel keeps working; re-run
# the script only when the TOC or the channel changes. Running without
# -Link later converts back to real copied folders automatically.
param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns",
    [ValidateSet("release", "dev")]
    [string]$Channel = "release",
    [switch]$DryRun,
    [switch]$Link
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $AddOnsPath "RecipeRegistry"
$folders = @("Core", "Data", "Integrations", "Libs", "Sync", "UI")

if (-not (Test-Path $AddOnsPath)) {
    Write-Error "AddOns folder not found: $AddOnsPath"
}
if (-not (Test-Path (Join-Path $repoRoot "RecipeRegistry.toc"))) {
    Write-Error "RecipeRegistry.toc not found in $repoRoot — run from the repo."
}

if (Get-Process -Name "WowClassic", "Wow" -ErrorAction SilentlyContinue) {
    Write-Host "Note: WoW is running — files deploy fine, use /reload in game afterwards." -ForegroundColor Yellow
}

$robocopyFlags = @("/MIR", "/NJH", "/NJS", "/NDL", "/NP")
if ($DryRun) { $robocopyFlags += "/L" }

function Test-IsJunction([string]$path) {
    if (-not (Test-Path $path)) { return $false }
    $item = Get-Item $path -Force
    return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

if ($Link) {
    if (-not $DryRun -and -not (Test-Path $dest)) {
        New-Item -ItemType Directory -Path $dest | Out-Null
    }
    foreach ($folder in $folders) {
        $src = Join-Path $repoRoot $folder
        $dst = Join-Path $dest $folder
        if (Test-IsJunction $dst) {
            Write-Host ("  {0,-14} already linked" -f $folder)
            continue
        }
        if ($DryRun) {
            Write-Host ("  {0,-14} would link -> {1}" -f $folder, $src)
            continue
        }
        if (Test-Path $dst) {
            Remove-Item -Recurse -Force $dst
        }
        New-Item -ItemType Junction -Path $dst -Target $src | Out-Null
        Write-Host ("  {0,-14} linked -> {1}" -f $folder, $src)
    }
} else {
    $failed = $false
    foreach ($folder in $folders) {
        $src = Join-Path $repoRoot $folder
        $dst = Join-Path $dest $folder
        # A leftover junction from -Link mode must not be mirrored into:
        # robocopy would follow it and "copy" the repo onto itself. Replace
        # it with a real folder copy.
        if (Test-IsJunction $dst) {
            if ($DryRun) {
                Write-Host ("  {0,-14} would unlink and copy" -f $folder)
                continue
            }
            Remove-Item -Force $dst
        }
        $output = robocopy $src $dst @robocopyFlags
        if ($LASTEXITCODE -ge 8) {
            Write-Host "ROBOCOPY FAILED for ${folder}:" -ForegroundColor Red
            $output | Write-Host
            $failed = $true
        } else {
            $changed = ($output | Where-Object { $_ -match "\S" }).Count
            Write-Host ("  {0,-14} {1}" -f $folder, $(if ($changed -gt 0) { "$changed change(s)" } else { "up to date" }))
        }
    }
    if ($failed) {
        Write-Error "Deploy failed (access denied? try an elevated shell)."
    }
}

$tocLines = Get-Content (Join-Path $repoRoot "RecipeRegistry.toc")
if ($Channel -eq "dev") {
    $tocLines = $tocLines -replace "^## X-Build-Channel:.*$", "## X-Build-Channel: dev" `
                          -replace "^## X-Build-ID:.*$", "## X-Build-ID: dev-local"
}
if ($DryRun) {
    Write-Host "  RecipeRegistry.toc (channel=$Channel) [dry-run, not written]"
} else {
    Set-Content -Path (Join-Path $dest "RecipeRegistry.toc") -Value $tocLines
    Write-Host "  RecipeRegistry.toc (channel=$Channel)"
    Write-Host "Deployed to $dest" -ForegroundColor Green
}

# Robocopy exits 1-7 on successful copies; don't let that leak as a failure.
exit 0
