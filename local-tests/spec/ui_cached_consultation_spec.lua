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
    entry.rev = opts.rev or entry.rev or 1
    entry.updatedAt = opts.updatedAt or entry.updatedAt or 100
    entry.sourceType = opts.sourceType or entry.sourceType or "owner"
    entry.guildStatus = opts.guildStatus or entry.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = { [recipeKey] = true },
        count = 1,
        signature = tostring(recipeKey),
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
        lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt,
    })
    return entry
end

local function textRegion()
    return {
        text = nil,
        SetText = function(self, value)
            self.text = value
        end,
    }
end

local function colorRegion()
    return {
        SetVertexColor = function(self, r, g, b, a)
            self.color = { r, g, b, a }
        end,
        SetTextColor = function(self, r, g, b, a)
            self.textColor = { r, g, b, a }
        end,
    }
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

Test.it("status refresh avoids sync summary rebuilds", function()
    local addon, _wow, data = freshAddon()
    local calledSummary = false
    data.GetLocalSummary = function()
        calledSummary = true
        error("status refresh should not rebuild sync summary")
    end
    data.GetUiStatusSnapshot = function()
        return {
            members = 7,
            updatedAt = 120,
        }
    end
    addon.Sync.GetUiState = function()
        return {
            onlineNodes = 2,
            registry = 3,
            queued = 0,
            role = "Client",
            paused = false,
        }
    end
    addon.UI.frame = {
        subtitle = textRegion(),
        syncDot = colorRegion(),
        autoLabel = colorRegion(),
        cards = {
            members = { value = textRegion() },
            network = { value = textRegion() },
            updated = { value = textRegion(), text = textRegion() },
        },
    }

    addon.UI:RefreshStatusBar()

    Test.falsy(calledSummary, "status bar should avoid GetLocalSummary")
    Test.eq(addon.UI.frame.cards.members.value.text, "7", "member count should come from the lightweight UI snapshot")
    Test.eq(addon.UI.frame.cards.network.value.text, "2 / 3", "network count should still use sync UI state")
end)

Test.it("item cache refresh does not walk the whole recipe list", function()
    local addon, _wow, data = freshAddon()
    local detailCalls = 0
    data.GetRecipeDisplayInfo = function()
        detailCalls = detailCalls + 1
        return {
            label = "updated",
        }
    end
    local renderCalls = 0
    addon.UI.RenderVisibleRecipeRows = function()
        renderCalls = renderCalls + 1
    end
    addon.UI.frame = {
        recipeRows = {},
    }
    addon.UI.currentRecipeRows = {
        { recipeKey = 1 },
        { recipeKey = 2 },
        { recipeKey = 3 },
    }

    addon.UI:RefreshVisibleRecipeRowAssets()

    Test.eq(detailCalls, 0, "visible-row refresh should defer detail work to row binding")
    Test.eq(renderCalls, 1, "visible-row refresh should still trigger a virtualized re-render")
end)

Test.it("row binding asset refresh updates one row lazily", function()
    local addon, _wow, data = freshAddon()
    local detailCalls = 0
    data.GetRecipeDisplayInfo = function(_self, recipeKey)
        detailCalls = detailCalls + 1
        return {
            recipeKey = recipeKey,
            label = "Fresh label",
        }
    end
    local rowData = {
        recipeKey = 42,
        label = "Old label",
    }

    addon.UI:RefreshRecipeRowAssets(rowData)

    Test.eq(detailCalls, 1, "lazy row refresh should touch only the requested row")
    Test.eq(rowData.label, "Fresh label", "row label should update from refreshed detail")
end)

io.write(string.format("UI cached consultation: %d test(s) passed\n", Test.count))
