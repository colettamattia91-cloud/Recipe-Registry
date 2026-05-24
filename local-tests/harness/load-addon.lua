local root = rawget(_G, "RECIPE_REGISTRY_TEST_ROOT") or "."

local function join(...)
    local parts = { ... }
    return table.concat(parts, "/")
end

local FILE_PATHS = {
    ["Core.lua"] = "Core/Core.lua",
    ["BuildInfo.lua"] = "Core/BuildInfo.lua",
    ["Performance.lua"] = "Core/Performance.lua",
    ["Data.lua"] = "Data/Data.lua",
    ["DataScan.lua"] = "Data/DataScan.lua",
    ["DataSnapshot.lua"] = "Data/DataSnapshot.lua",
    ["RecipeOwnershipIndex.lua"] = "Data/RecipeOwnershipIndex.lua",
    ["RecipeUiFilters.lua"] = "Data/RecipeUiFilters.lua",
    ["DataCatalog.lua"] = "Data/DataCatalog.lua",
    ["DataIndex.lua"] = "Data/DataIndex.lua",
    ["DataCleanup.lua"] = "Data/DataCleanup.lua",
    ["MergeEngine.lua"] = "Data/MergeEngine.lua",
    ["BootstrapSync.lua"] = "Sync/BootstrapSync.lua",
    ["SyncPausePolicy.lua"] = "Sync/SyncPausePolicy.lua",
    ["GuildLifecycleMaintenance.lua"] = "Data/GuildLifecycleMaintenance.lua",
    ["MockSync.lua"] = "Sync/MockSync.lua",
    ["Market.lua"] = "Integrations/Market.lua",
    ["Sync.lua"] = "Sync/Sync.lua",
    ["SyncRuntime.lua"] = "Sync/SyncRuntime.lua",
    ["SyncProtocol.lua"] = "Sync/SyncProtocol.lua",
    ["SyncCodec.lua"] = "Sync/SyncCodec.lua",
    ["SyncRequests.lua"] = "Sync/SyncRequests.lua",
    ["SyncTransfer.lua"] = "Sync/SyncTransfer.lua",
    ["SyncDiagnostics.lua"] = "Sync/SyncDiagnostics.lua",
    ["Tooltip.lua"] = "UI/Tooltip.lua",
    ["MainFrame.lua"] = "UI/MainFrame.lua",
    ["Options.lua"] = "UI/Options.lua",
    ["MinimapButton.lua"] = "UI/MinimapButton.lua",
}

local METADATA_FILE_PATHS = {
    ["RecipeMetadataAddon.lua"] = "RecipeRegistry_Metadata/Core/RecipeMetadataAddon.lua",
    ["RecipeMetadata_Generated.lua"] = "RecipeRegistry_Metadata/Data/RecipeMetadata_Generated.lua",
    ["RecipeMetadata_Overrides.lua"] = "RecipeRegistry_Metadata/Data/RecipeMetadata_Overrides.lua",
    ["RecipeMetadata.lua"] = "RecipeRegistry_Metadata/Data/RecipeMetadata.lua",
    ["RecipeMetadataDiagnostics.lua"] = "RecipeRegistry_Metadata/Diagnostics/RecipeMetadataDiagnostics.lua",
}

local function fileExists(path)
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function resolveAddonPath(file)
    local direct = join(root, file)
    if fileExists(direct) then
        return direct
    end
    local mapped = FILE_PATHS[file]
    if mapped then
        return join(root, mapped)
    end
    return direct
end

local function resolveMetadataPath(file)
    local direct = join(root, file)
    if fileExists(direct) then
        return direct
    end
    local mapped = METADATA_FILE_PATHS[file]
    if mapped then
        return join(root, mapped)
    end
    return direct
end

local Wow = dofile(join(root, "local-tests", "harness", "wow.lua"))

local Loader = {
    BackendFiles = {
        "Core.lua",
        "BuildInfo.lua",
        "Performance.lua",
        "Data.lua",
        "DataScan.lua",
        "DataSnapshot.lua",
        "RecipeOwnershipIndex.lua",
        "RecipeUiFilters.lua",
        "DataCatalog.lua",
        "DataIndex.lua",
        "DataCleanup.lua",
        "MergeEngine.lua",
        "BootstrapSync.lua",
        "SyncPausePolicy.lua",
        "GuildLifecycleMaintenance.lua",
        "MockSync.lua",
        "Market.lua",
        "Sync.lua",
        "SyncRuntime.lua",
        "SyncProtocol.lua",
        "SyncCodec.lua",
        "SyncRequests.lua",
        "SyncTransfer.lua",
        "SyncDiagnostics.lua",
    },
    MetadataFiles = {
        "RecipeMetadataAddon.lua",
        "RecipeMetadata_Generated.lua",
        "RecipeMetadata_Overrides.lua",
        "RecipeMetadata.lua",
        "RecipeMetadataDiagnostics.lua",
    },
}

local function runAddonLifecycle(addon, methodName)
    if addon and type(addon[methodName]) == "function" then
        addon[methodName](addon)
    end
    for _, module in ipairs(addon and addon.__moduleOrder or {}) do
        if type(module[methodName]) == "function" then
            module[methodName](module)
        end
    end
end

function Loader.Load(opts)
    opts = opts or {}
    if opts.reset ~= false then
        Wow.Reset({
            payloadMode = opts.payloadMode,
            addonMetadata = opts.addonMetadata,
        })
    elseif opts.payloadMode or opts.addonMetadata then
        Wow.Configure({
            payloadMode = opts.payloadMode,
            addonMetadata = opts.addonMetadata,
        })
    end

    local files = opts.files or Loader.BackendFiles
    for _, file in ipairs(files) do
        local path = resolveAddonPath(file)
        local chunk, err = loadfile(path)
        if not chunk then
            error("failed to load " .. path .. ": " .. tostring(err), 2)
        end
        chunk("RecipeRegistry", {})
    end

    local addon = _G.RecipeRegistry
    if not addon then
        error("RecipeRegistry addon was not created", 2)
    end

    if opts.initialReqTimeoutsEnabled == nil then
        addon.INITIAL_REQ_TIMEOUTS_ENABLED = true
    else
        addon.INITIAL_REQ_TIMEOUTS_ENABLED = opts.initialReqTimeoutsEnabled ~= false
    end

    if opts.savedVariables then
        _G.RecipeRegistryDB = opts.savedVariables.db or opts.savedVariables.global or {}
        _G.RecipeRegistryCharDB = opts.savedVariables.charDB or opts.savedVariables.char or {}
        _G.RecipeRegistryLogDB = opts.savedVariables.logDB or opts.savedVariables.log or {}
    end

    if opts.initialize ~= false then
        runAddonLifecycle(addon, "OnInitialize")
    end
    if opts.enable == true then
        runAddonLifecycle(addon, "OnEnable")
    end

    return addon, Wow
end

function Loader.LoadMetadata(opts)
    opts = opts or {}
    if opts.reset ~= false then
        Wow.Reset({
            payloadMode = opts.payloadMode,
            addonMetadata = opts.addonMetadata,
        })
    elseif opts.payloadMode or opts.addonMetadata then
        Wow.Configure({
            payloadMode = opts.payloadMode,
            addonMetadata = opts.addonMetadata,
        })
    end

    local coreAddon
    if opts.loadCore ~= false then
        coreAddon = Loader.Load({
            reset = false,
            initialize = opts.initializeCore ~= false,
            enable = opts.enableCore == true,
            initialReqTimeoutsEnabled = opts.initialReqTimeoutsEnabled,
            savedVariables = opts.savedVariables,
        })
    end

    local files = opts.files or Loader.MetadataFiles
    for _, file in ipairs(files) do
        local path = resolveMetadataPath(file)
        local chunk, err = loadfile(path)
        if not chunk then
            error("failed to load " .. path .. ": " .. tostring(err), 2)
        end
        chunk("RecipeRegistry_Metadata", {})
    end

    local metadataAddon = _G.RecipeRegistry_Metadata
    if not metadataAddon then
        error("RecipeRegistry_Metadata addon was not created", 2)
    end

    if opts.initialize ~= false then
        runAddonLifecycle(metadataAddon, "OnInitialize")
    end
    if opts.enable == true then
        runAddonLifecycle(metadataAddon, "OnEnable")
    end

    return metadataAddon, Wow, coreAddon
end

function Loader.Initialize(addon)
    runAddonLifecycle(addon or _G.RecipeRegistry, "OnInitialize")
end

function Loader.Enable(addon)
    runAddonLifecycle(addon or _G.RecipeRegistry, "OnEnable")
end

function Loader.PrimeSyncReady(addon, opts)
    addon = addon or _G.RecipeRegistry
    opts = opts or {}

    if addon.Sync and addon.Sync.Startup then
        addon.Sync:Startup()
    end
    if addon.Sync and addon.Sync.SetSavedVariablesReady then
        addon.Sync:SetSavedVariablesReady(opts.reason or "test-prime")
    end
    if addon.Sync and addon.Sync.SetPlayerReady then
        addon.Sync:SetPlayerReady(opts.reason or "test-prime")
    end
    if addon.Data and addon.Data.RequestRosterSnapshot then
        addon.Data:RequestRosterSnapshot(opts.reason or "test-prime", {
            source = "test-prime",
        })
        addon.Data:ProcessPendingRosterSnapshot(opts.reason or "test-prime", {
            force = true,
            allowFallback = true,
            source = "test-prime",
        })
    end
    if addon.Data and addon.Data.RebuildOnlineCache then
        addon.Data:RebuildOnlineCache()
    end
    if addon.Data and addon.Data.PrepareSyncIndexNow then
        addon.Data:PrepareSyncIndexNow(opts.reason or "test-prime")
    end
    if addon.Sync and addon.Sync.RefreshSyncReadyState then
        addon.Sync:RefreshSyncReadyState(opts.reason or "test-prime")
    end
    if opts.runTimers ~= false then
        Wow.RunDueTimers(20)
    end
    return addon
end

Loader.Wow = Wow

return Loader
