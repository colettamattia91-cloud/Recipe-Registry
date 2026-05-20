local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function getUiFiles()
    local files = {}
    for _, file in ipairs(Loader.BackendFiles) do
        files[#files + 1] = file
    end
    files[#files + 1] = "UI/MainFrame.lua"
    return files
end

local function freshAddon()
    local addon, wow = Loader.Load({
        files = getUiFiles(),
    })
    addon.Sync:EnsureBackgroundWorkers()
    addon.UI.frame = {
        recipeRows = {},
        detailLines = {},
    }
    return addon, wow, addon.Data
end

local function seedProfession(data, memberKey, profession, recipeKey, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.sourceType = opts.sourceType or entry.sourceType or "owner"
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = { [recipeKey] = true },
        count = 1,
        signature = tostring(recipeKey),
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
        lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt,
    })
    return entry
end

io.write("UI cached consultation\n")

Test.it("keeps cached recipes consultable during warmup", function()
    local addon, _wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 98001, { sourceType = "owner" })

    addon.Sync:EnterWarmup("test", 15)

    Test.truthy(addon.Sync:IsInWarmup(), "warmup should be active for the test")
    Test.eq(addon.UI:GetDegradedModeReason(), nil, "warmup should not force status-only mode when cached data exists")
end)

Test.it("still reports warmup status-only mode when nothing is cached yet", function()
    local addon, _wow, _data = freshAddon()

    addon.Sync:EnterWarmup("test", 15)

    Test.eq(addon.UI:GetDegradedModeReason(), "warmup", "warmup should stay status-only until local data exists")
end)

Test.it("keeps cached recipes consultable during instance pause", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    seedProfession(data, localKey, "Alchemy", 98001, { sourceType = "owner" })

    wow.SetInstance(true, "raid")
    addon.SyncPausePolicy:RefreshPauseState()

    Test.eq(addon.UI:GetDegradedModeReason(), nil, "instance pause should still allow cached recipe browsing")
end)

io.write(string.format("UI cached consultation: %d test(s) passed\n", Test.count))
