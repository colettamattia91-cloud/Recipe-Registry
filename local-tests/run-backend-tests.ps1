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

$activeSoakSpecs = @(
    "soak_block_pull_saturation_spec.lua",
    "soak_discovery_backoff_churn_spec.lua",
    "soak_hello_storm_spec.lua",
    "soak_memory_bound_spec.lua",
    "soak_seed_election_crowd_spec.lua"
)
$activeAllSpecs = @(
    "acebucket_integration_spec.lua",
    "atlasloot_call_site_gate_spec.lua",
    "atlasloot_projection_parity_spec.lua",
    "block_merge_list_cache_invalidation_spec.lua",
    "build_channel_isolation_spec.lua",
    "catalog_cache_spec.lua",
    "catalog_recipes_by_profession_spec.lua",
    "category_metadata_navigation_spec.lua",
    "category_visible_prefilter_spec.lua",
    "data_cleanup_spec.lua",
    "diagnostics_snapshot_spec.lua",
    "detail_cost_estimate_internal_reagents_spec.lua",
    "detail_requestability_remote_bop_spec.lua",
    "detail_selection_stale_after_filter_change_spec.lua",
    "discovery_debug_spec.lua",
    "dirty_active_pull_debug_spec.lua",
    "external_tabs_registry_spec.lua",
    "filter_async_stale_callback_spec.lua",
    "filter_cache_invalidation_spec.lua",
    "filter_favorites_preserve_hidden_spec.lua",
    "filter_favorites_reappear_on_unhide_spec.lua",
    "filter_global_search_per_profession_spec.lua",
    "filter_plugin_absent_fallback_spec.lua",
    "filter_predicate_bop_spec.lua",
    "filter_predicate_expansion_spec.lua",
    "filter_predicate_outputless_spec.lua",
    "filter_predicate_uncatalogued_spec.lua",
    "inbound_seed_debug_spec.lua",
    "metadata_normalize_key_spec.lua",
    "metadata_override_merge_spec.lua",
    "metadata_runtime_lookup_spec.lua",
    "metadata_scaffold_spec.lua",
    "metadata_unresolved_spec.lua",
    "options_panel_spec.lua",
    "options_per_profession_inheritance_spec.lua",
    "options_profile_migration_spec.lua",
    "orders_board_actions_spec.lua",
    "orders_board_events_spec.lua",
    "orders_board_scope_spec.lua",
    "orders_cart_panel_spec.lua",
    "orders_cart_spec.lua",
    "orders_order_dialog_spec.lua",
    "orders_phase1_planner_spec.lua",
    "orders_phase1_state_machine_spec.lua",
    "orders_phase1_store_spec.lua",
    "orders_phase3_board_spec.lua",
    "orders_phase6_codec_spec.lua",
    "orders_phase6_diagnostics_spec.lua",
    "orders_phase6_protocol_spec.lua",
    "orders_phase6_reducer_spec.lua",
    "orders_phase6_runtime_spec.lua",
    "orders_reducer_change_broadcast_spec.lua",
    "p4_scan_opportunistic_spec.lua",
    "recipe_actions_registry_spec.lua",
    "slash_output_spec.lua",
    "sync_debug_output_spec.lua",
    "sync_event_log_spec.lua",
    "sync_codec_spec.lua",
    "sync_legacy_grep_gate_spec.lua",
    "block_snapshot_error_paths_spec.lua",
    "sync_phase1_unsupported_message_spec.lua",
    "sync_phase2_summary_foundation_spec.lua",
    "sync_phase34_block_pull_spec.lua",
    "sync_roster_invalidation_spec.lua",
    "ui_cached_consultation_spec.lua",
    "tooltip_spec.lua",
    "soak_block_pull_saturation_spec.lua",
    "soak_discovery_backoff_churn_spec.lua",
    "soak_hello_storm_spec.lua",
    "soak_memory_bound_spec.lua",
    "soak_seed_election_crowd_spec.lua"
)
$activeSyncSpecs = @(
    "build_channel_isolation_spec.lua",
    "block_snapshot_error_paths_spec.lua",
    "diagnostics_snapshot_spec.lua",
    "discovery_debug_spec.lua",
    "dirty_active_pull_debug_spec.lua",
    "inbound_seed_debug_spec.lua",
    "p4_scan_opportunistic_spec.lua",
    "slash_output_spec.lua",
    "sync_debug_output_spec.lua",
    "sync_event_log_spec.lua",
    "sync_codec_spec.lua",
    "sync_legacy_grep_gate_spec.lua",
    "sync_phase1_unsupported_message_spec.lua",
    "sync_phase2_summary_foundation_spec.lua",
    "sync_phase34_block_pull_spec.lua",
    "sync_roster_invalidation_spec.lua",
    "soak_block_pull_saturation_spec.lua",
    "soak_discovery_backoff_churn_spec.lua",
    "soak_hello_storm_spec.lua",
    "soak_memory_bound_spec.lua",
    "soak_seed_election_crowd_spec.lua"
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
            return $Candidates | Where-Object { $_.Name -in $activeSoakSpecs }
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
    all = "default/all runs the current supported backend baseline."
    quick = "quick currently matches the supported backend baseline."
    sync = "sync runs the supported HELLO/SUMMARY/index-diff/block-pull/runtime-cache/build-isolation rewrite coverage."
    soak = "soak runs active HELLO storm, seed election, block-pull saturation, discovery backoff, and memory-bounds coverage."
}

Push-Location $repoRoot
try {
    if (-not ($PSBoundParameters.ContainsKey("Spec") -and $Spec)) {
        Write-Host ("Selected suite '{0}' with {1} spec(s): {2}" -f $Suite, $specs.Count, $suiteDescriptions[$Suite])
    }
    foreach ($spec in $specs) {
        $specName = if ($spec.Name) { $spec.Name } else { Split-Path ([string]$spec) -Leaf }
        if ($spec.FullName -and (Test-Path $spec.FullName)) {
            $specPath = $spec.FullName
        }
        elseif (Test-Path ([string]$spec)) {
            $specPath = (Resolve-Path ([string]$spec)).Path
        }
        else {
            $specPath = Join-Path (Join-Path $PSScriptRoot "spec") $specName
        }
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
