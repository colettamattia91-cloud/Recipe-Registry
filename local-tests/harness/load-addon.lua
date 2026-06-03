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
    ["RecipeMetadata_Generated.lua"] = "Data/Metadata/RecipeMetadata_Generated.lua",
    ["RecipeMetadata_Overrides.lua"] = "Data/Metadata/RecipeMetadata_Overrides.lua",
    ["RecipeMetadata.lua"] = "Data/Metadata/RecipeMetadata.lua",
    ["RecipeMetadataDiagnostics.lua"] = "Data/Metadata/RecipeMetadataDiagnostics.lua",
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
    ["ExternalTabs.lua"] = "UI/ExternalTabs.lua",
    ["RecipeActions.lua"] = "UI/RecipeActions.lua",
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
        "RecipeMetadata_Generated.lua",
        "RecipeMetadata_Overrides.lua",
        "RecipeMetadata.lua",
        "RecipeMetadataDiagnostics.lua",
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
}

-- The UI module is defined in UI/MainFrame.lua; ExternalTabs.lua decorates
-- it with the public external-tab registry. Specs that exercise the hook
-- can opt into loading the UI layer via opts.files = Loader.BackendFilesWithUI.
Loader.BackendFilesWithUI = {}
for _, name in ipairs(Loader.BackendFiles) do
    Loader.BackendFilesWithUI[#Loader.BackendFilesWithUI + 1] = name
end
Loader.BackendFilesWithUI[#Loader.BackendFilesWithUI + 1] = "MainFrame.lua"
Loader.BackendFilesWithUI[#Loader.BackendFilesWithUI + 1] = "ExternalTabs.lua"
Loader.BackendFilesWithUI[#Loader.BackendFilesWithUI + 1] = "RecipeActions.lua"

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
    -- Sync gates and the tooltip garbage filter call
    -- `Data:IsRecipeKeyCatalogued` to drop real-but-not-a-recipe items
    -- (Worn Axe and similar). Many specs seed synthetic positive recipe
    -- keys that don't exist in production metadata, so the global flag
    -- below lets the test harness bypass that strict check while keeping
    -- the looser "resolvable in client" check active. Set it to nil if a
    -- specific spec wants the production behavior.
    _G._RR_TEST_HARNESS_BYPASS_CATALOGUE_GATE = opts.enforceCatalogueGate
        and nil
        or true

    local files = opts.files or Loader.BackendFiles
    -- Unit specs that assert exact record-level facts load a small, stable
    -- sample dataset instead of the volatile production metadata so they stay
    -- deterministic across `generate` runs. `metadataFixture` swaps only the
    -- generated table file; the metadata code under test is unchanged.
    local fixtureGeneratedPath = opts.metadataFixture
        and join(root, "local-tests", "fixtures", "RecipeMetadata_Generated.lua")
        or nil
    for _, file in ipairs(files) do
        local path = (fixtureGeneratedPath and file == "RecipeMetadata_Generated.lua")
            and fixtureGeneratedPath
            or resolveAddonPath(file)
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

-- After the metadata fold-in, metadata is loaded as part of RR's own backend
-- files. LoadMetadata stays as a thin compat wrapper so existing specs that
-- destructure (metadataAddon, wow, coreAddon) keep working — both
-- `metadataAddon` and `coreAddon` are now the same RR addon, since the
-- metadata module hangs off it as `addon.RecipeMetadata`.
function Loader.LoadMetadata(opts)
    opts = opts or {}
    local addon = Loader.Load({
        reset = opts.reset,
        initialize = opts.initialize ~= false,
        enable = opts.enable == true,
        payloadMode = opts.payloadMode,
        addonMetadata = opts.addonMetadata,
        initialReqTimeoutsEnabled = opts.initialReqTimeoutsEnabled,
        savedVariables = opts.savedVariables,
        metadataFixture = opts.fixture,
        files = opts.files,
    })
    return addon, Wow, addon
end

function Loader.Initialize(addon)
    runAddonLifecycle(addon or _G.RecipeRegistry, "OnInitialize")
end

function Loader.Enable(addon)
    runAddonLifecycle(addon or _G.RecipeRegistry, "OnEnable")
end

Loader.OrdersFiles = {
    "RecipeRegistry_Orders/Core/CraftOrders.lua",
    "RecipeRegistry_Orders/Core/BuildInfo.lua",
    "RecipeRegistry_Orders/Store/CraftOrdersStateMachine.lua",
    "RecipeRegistry_Orders/Store/CraftOrdersStore.lua",
    "RecipeRegistry_Orders/Planner/CraftOrdersPlanner.lua",
    "RecipeRegistry_Orders/Cart/CraftOrdersCart.lua",
    "RecipeRegistry_Orders/Sync/CraftOrdersCodec.lua",
    "RecipeRegistry_Orders/Sync/CraftOrdersReducer.lua",
    "RecipeRegistry_Orders/Sync/CraftOrdersProtocol.lua",
    "RecipeRegistry_Orders/Sync/CraftOrdersRuntime.lua",
    "RecipeRegistry_Orders/Sync/CraftOrdersDiagnostics.lua",
    "RecipeRegistry_Orders/UI/CraftOrdersBoard.lua",
    "RecipeRegistry_Orders/UI/CraftOrdersOrderDialog.lua",
    "RecipeRegistry_Orders/UI/CraftOrdersCartPanel.lua",
}

-- Loads the RecipeRegistry_Orders plugin chunks on top of whatever RR state
-- the caller has prepared (real RR via Loader.Load, or a hand-rolled stub
-- assigned to _G.RecipeRegistry). Phase 1 specs use a tiny stub since the
-- planner only needs Data:GetRecipeDisplayInfo, and the store needs
-- Addon:GetLocalPlayerKey to work — both already do without RR loaded.
function Loader.LoadOrders(opts)
    opts = opts or {}

    if opts.recipeRegistryStub ~= nil then
        _G.RecipeRegistry = opts.recipeRegistryStub
    end

    if opts.savedVariables then
        _G.RecipeRegistry_OrdersDB = opts.savedVariables.db or opts.savedVariables.global or {}
        _G.RecipeRegistry_OrdersCharDB = opts.savedVariables.charDB or opts.savedVariables.char or {}
        _G.RecipeRegistry_OrdersLogDB = opts.savedVariables.logDB or opts.savedVariables.log or {}
    end

    local files = opts.files or Loader.OrdersFiles
    for _, file in ipairs(files) do
        local path = join(root, file)
        local chunk, err = loadfile(path)
        if not chunk then
            error("failed to load " .. path .. ": " .. tostring(err), 2)
        end
        chunk("RecipeRegistry_Orders", {})
    end

    local plugin = _G.RecipeRegistry_Orders
    if not plugin then
        error("RecipeRegistry_Orders addon was not created", 2)
    end

    if opts.initialize ~= false then
        runAddonLifecycle(plugin, "OnInitialize")
    end
    if opts.enable == true then
        runAddonLifecycle(plugin, "OnEnable")
    end

    return plugin
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
