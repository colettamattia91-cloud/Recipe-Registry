local root = rawget(_G, "RECIPE_REGISTRY_TEST_ROOT") or "."

local function join(...)
    local parts = { ... }
    return table.concat(parts, "/")
end

local Wow = dofile(join(root, "local-tests", "harness", "wow.lua"))

local Loader = {
    BackendFiles = {
        "Core.lua",
        "BuildInfo.lua",
        "Performance.lua",
        "Data.lua",
        "DataAtlasLoot.lua",
        "DataManifest.lua",
        "DataScan.lua",
        "DataSnapshot.lua",
        "DataCatalog.lua",
        "DataCleanup.lua",
        "MergeEngine.lua",
        "BootstrapSync.lua",
        "TrickleSync.lua",
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
        "SyncManifest.lua",
        "SyncDiagnostics.lua",
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
        local path = join(root, file)
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

function Loader.Initialize(addon)
    runAddonLifecycle(addon or _G.RecipeRegistry, "OnInitialize")
end

function Loader.Enable(addon)
    runAddonLifecycle(addon or _G.RecipeRegistry, "OnEnable")
end

Loader.Wow = Wow

return Loader
