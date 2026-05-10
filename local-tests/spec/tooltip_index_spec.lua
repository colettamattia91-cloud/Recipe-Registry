local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local files = {}
    for _, file in ipairs(Loader.BackendFiles or {}) do
        files[#files + 1] = file
    end
    files[#files + 1] = "Tooltip.lua"
    local addon, wow = Loader.Load({ files = files })
    local tooltip = addon.Tooltip
    tooltip.index = {}
    tooltip.indexDirty = false
    tooltip.indexVersion = 0
    tooltip._indexBuildGeneration = 0
    tooltip._indexBuildJobActive = false
    return addon, wow, addon.Data, tooltip
end

local function seedMember(data, memberKey, profession, recipeKeys, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.rev = opts.rev or 1
    entry.updatedAt = opts.updatedAt or 100
    entry.sourceType = opts.sourceType or "replica"
    entry.guildStatus = opts.guildStatus or "active"
    entry.lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.updatedAt
    entry.professions = entry.professions or {}
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipeKeys,
        count = opts.count or 0,
        skillRank = opts.skillRank or 300,
        skillMaxRank = opts.skillMaxRank or 375,
        blockRevision = opts.blockRevision or entry.rev,
        lastUpdatedAt = opts.updatedAt or entry.updatedAt,
        sourceType = opts.sourceType or entry.sourceType,
        guildStatus = opts.guildStatus or entry.guildStatus,
        lastSeenInGuildAt = opts.lastSeenInGuildAt or entry.lastSeenInGuildAt,
    })
    return entry
end

local function recipeSet(firstKey, lastKey)
    local recipes = {}
    if type(firstKey) == "number" and type(lastKey) == "number" then
        for recipeKey = firstKey, lastKey do
            recipes[recipeKey] = true
        end
    elseif type(firstKey) == "table" then
        for recipeKey, enabled in pairs(firstKey) do
            if enabled then
                recipes[recipeKey] = true
            end
        end
    end
    return recipes
end

local function runUntilIdle(addon, maxSteps)
    maxSteps = maxSteps or 20
    for _ = 1, maxSteps do
        addon.Performance:RunNextStep()
        local queues = addon.Performance:GetQueueLengths()
        if (queues.ui or 0) == 0 and not addon.Tooltip._indexBuildJobActive then
            return
        end
    end
end

io.write("Tooltip index\n")

Test.it("keeps hover reads on the stale index while rebuilding asynchronously", function()
    local addon, _wow, data, tooltip = freshAddon()
    local memberKey = "Crafterone-TestRealm"
    seedMember(data, memberKey, "Alchemy", recipeSet({ [95001] = true }), {
        sourceType = "replica",
        count = 1,
    })

    data._recipeIndex = nil
    tooltip:RebuildIndex()
    local initialVersion = tooltip.indexVersion
    local oldRows = tooltip:GetRowsForKey("item:95001")
    Test.eq(#(oldRows or {}), 1, "initial tooltip rows should exist")

    local entry = data:GetMember(memberKey)
    entry.professions.Alchemy.recipes[95002] = true
    entry.professions.Alchemy.count = 2
    entry.professions.Alchemy.signature = "95001,95002"
    data:InvalidateRecipeCaches("presence")

    local queues = addon.Performance:GetQueueLengths()
    Test.eq(queues.ui or 0, 1, "invalidate should schedule a background tooltip rebuild")

    local staleRows = tooltip:GetRowsForKey("item:95001")
    local missingRows = tooltip:GetRowsForKey("item:95002")
    Test.eq(#(staleRows or {}), 1, "stale index should still serve previous rows during rebuild")
    Test.eq(#(missingRows or {}), 0, "new rows should not appear before the rebuild job runs")
    Test.eq(tooltip.indexVersion, initialVersion, "hover path should not rebuild synchronously")

    runUntilIdle(addon)

    local rebuiltRows = tooltip:GetRowsForKey("item:95002")
    Test.eq(#(rebuiltRows or {}), 1, "new rows should appear after the background rebuild")
    Test.eq(tooltip.indexVersion, initialVersion + 1, "background rebuild should advance tooltip index version")
end)

Test.it("restarts the tooltip rebuild when data changes again during an active build", function()
    local addon, _wow, data, tooltip = freshAddon()
    local memberKey = "Craftertwo-TestRealm"
    seedMember(data, memberKey, "Alchemy", recipeSet(96001, 96500), {
        sourceType = "replica",
        count = 500,
    })

    data:InvalidateRecipeCaches("presence")
    addon.Performance:RunNextStep()
    Test.truthy(tooltip._indexBuildJobActive, "large tooltip index should still be rebuilding after one scheduler tick")

    local entry = data:GetMember(memberKey)
    entry.professions.Alchemy.recipes[97001] = true
    entry.professions.Alchemy.count = 501
    entry.professions.Alchemy.signature = "many+97001"
    data:InvalidateRecipeCaches("presence")

    runUntilIdle(addon, 40)

    local rows = tooltip:GetRowsForKey("item:97001")
    Test.eq(#(rows or {}), 1, "latest data should win after invalidation during an active tooltip rebuild")
    Test.falsy(tooltip.indexDirty, "tooltip index should be clean after the restarted build completes")
end)

io.write(string.format("Tooltip index: %d test(s) passed\n", Test.count))
