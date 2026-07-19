local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function getFiles()
    local files = {}
    for _, file in ipairs(Loader.BackendFiles) do
        files[#files + 1] = file
    end
    files[#files + 1] = "Tooltip.lua"
    return files
end

local function freshAddon()
    local addon, wow = Loader.Load({ files = getFiles() })
    addon.Tooltip.index = {}
    addon.Tooltip.indexDirty = true
    addon.Tooltip.indexVersion = 0
    addon.Tooltip._indexBuildGeneration = 0
    addon.Tooltip._indexBuildJobActive = false
    return addon, wow, addon.Data, addon.Tooltip
end

local function seedProfession(data, memberKey, profession, recipeKey, opts)
    opts = opts or {}
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.updatedAt = opts.updatedAt or 100
    entry.sourceType = opts.sourceType or "replica"
    entry.guildStatus = opts.guildStatus or "active"
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = { [recipeKey] = true },
        count = 1,
        skillRank = opts.skillRank or 300,
        skillMaxRank = opts.skillMaxRank or 375,
        specialization = opts.specialization,
        sourceType = entry.sourceType,
        guildStatus = entry.guildStatus,
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
        lastUpdatedAt = entry.updatedAt,
    })
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

local function tooltipStub()
    local stub = {
        lines = {},
        shown = false,
    }
    function stub:AddLine(text, r, g, b)
        self.lines[#self.lines + 1] = {
            text = tostring(text or ""),
            r = r,
            g = g,
            b = b,
        }
    end
    function stub:Show()
        self.shown = true
    end
    return stub
end

io.write("Tooltip\n")

Test.it("indexes item and spell recipes and returns live sorted crafter rows", function()
    local _addon, wow, data, tooltip = freshAddon()
    local onlineKey = "Tooltiponline-TestRealm"
    local offlineKey = "Tooltipoffline-TestRealm"
    wow.SetGuildRoster({
        { name = onlineKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
        { name = offlineKey, online = false, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Priest", classFileName = "PRIEST" },
    })
    data:RebuildOnlineCache()

    seedProfession(data, offlineKey, "Alchemy", 91001, {
        skillRank = 375,
        specialization = "Potion Master",
    })
    seedProfession(data, onlineKey, "Alchemy", 91001, {
        skillRank = 300,
    })
    seedProfession(data, onlineKey, "Enchanting", -47001, {
        skillRank = 350,
    })

    tooltip:RebuildIndex()

    local itemRows = tooltip:GetRowsForItemID(91001)
    Test.eq(#itemRows, 2, "item recipe should return both crafters")
    Test.eq(itemRows[1].memberKey, onlineKey, "online crafter should sort first")
    Test.eq(itemRows[2].memberKey, offlineKey, "offline crafter should sort second")
    Test.eq(itemRows[2].specialization, "Potion Master", "specialization should be preserved")

    local spellRows = tooltip:GetRowsForSpellID(47001)
    Test.eq(#spellRows, 1, "negative recipe key should index as spell")
    Test.eq(spellRows[1].profession, "Enchanting", "spell row profession")
end)

Test.it("renders at most five tooltip crafters and prevents duplicate rendering for the same version", function()
    local _addon, _wow, _data, tooltip = freshAddon()
    local rows = {}
    for index = 1, 7 do
        rows[index] = {
            memberKey = string.format("Crafter%02d-TestRealm", index),
            profession = "Alchemy",
            online = index <= 6,
            skillRank = 375 - index,
        }
    end
    tooltip.indexVersion = 7
    local stub = tooltipStub()

    tooltip:AddCraftLines(stub, rows, "item:91001")

    Test.truthy(stub.shown, "tooltip should be shown after render")
    Test.eq(stub.lines[2].text, "Recipe Registry", "tooltip header")
    Test.eq(stub.lines[3].text, "6 online", "online count label")
    Test.eq(stub.lines[9].text, "+1 more", "overflow line")
    local lineCount = #stub.lines

    tooltip:AddCraftLines(stub, rows, "item:91001")
    Test.eq(#stub.lines, lineCount, "same render key should not append duplicate lines")
end)

Test.it("honours the showTooltipCrafters profile option", function()
    local addon, _wow, _data, tooltip = freshAddon()
    local rows = {
        { memberKey = "Crafterone-TestRealm", profession = "Alchemy", online = true, skillRank = 375 },
    }
    tooltip.indexVersion = 3

    addon.db.profile.showTooltipCrafters = false
    local stub = tooltipStub()
    tooltip:AddCraftLines(stub, rows, "item:91001")
    Test.eq(#stub.lines, 0, "disabled option must render no crafter lines")
    Test.falsy(stub.shown, "disabled option must not show the tooltip")

    addon.db.profile.showTooltipCrafters = true
    tooltip:AddCraftLines(stub, rows, "item:91001")
    Test.truthy(#stub.lines > 0, "re-enabled option renders immediately")
    Test.eq(stub.lines[2].text, "Recipe Registry", "tooltip header present when enabled")
end)

Test.it("serves stale tooltip rows during a background rebuild after invalidation", function()
    local addon, _wow, data, tooltip = freshAddon()
    local memberKey = "Crafterone-TestRealm"
    seedProfession(data, memberKey, "Alchemy", 22900, { sourceType = "replica" })

    data._recipeIndex = nil
    tooltip:RebuildIndex()
    local initialVersion = tooltip.indexVersion
    local oldRows = tooltip:GetRowsForKey("item:22900")
    Test.eq(#(oldRows or {}), 1, "initial tooltip rows should exist")

    -- Mutate the profession block in place to add a second recipe, then
    -- invalidate the metadata cache. InvalidateIndex only marks dirty —
    -- the rebuild is deferred to the next hover or lifecycle event.
    local entry = data:GetMember(memberKey)
    entry.professions.Alchemy.recipes[22907] = true
    entry.professions.Alchemy.count = 2
    entry.professions.Alchemy.signature = "22900,22907"
    data:InvalidateRecipeCaches("metadata")

    local queuesAfterInvalidate = addon.Performance:GetQueueLengths()
    Test.eq(queuesAfterInvalidate.ui or 0, 0,
        "invalidate alone should not schedule a tooltip rebuild")
    Test.truthy(tooltip.indexDirty, "invalidate should mark the tooltip index dirty")

    local staleRows = tooltip:GetRowsForKey("item:22900")
    local missingRows = tooltip:GetRowsForKey("item:22907")
    Test.eq(#(staleRows or {}), 1, "stale index should still serve previous rows during rebuild")
    Test.eq(#(missingRows or {}), 0, "new rows should not appear before the rebuild job runs")
    Test.eq(tooltip.indexVersion, initialVersion, "hover path should not rebuild synchronously")

    local queuesAfterHover = addon.Performance:GetQueueLengths()
    Test.eq(queuesAfterHover.ui or 0, 1,
        "hover on a dirty index in idle state should schedule the background rebuild")

    runUntilIdle(addon)

    local rebuiltRows = tooltip:GetRowsForKey("item:22907")
    Test.eq(#(rebuiltRows or {}), 1, "new rows should appear after the background rebuild")
    Test.eq(tooltip.indexVersion, initialVersion + 1, "background rebuild should advance tooltip index version")
end)

Test.it("restarts the tooltip rebuild when data changes again during an active build", function()
    local addon, _wow, data, tooltip = freshAddon()
    local memberKey = "Craftertwo-TestRealm"
    -- Seed enough recipes that one scheduler tick won't finish the build,
    -- so we can observe the mid-build invalidation/restart. After
    -- TICK_BUDGET_MS climbed to 30 and maxStepsPerRun is honored, a single
    -- tick fits ~10 tooltip-job steps; the seed must outpace that.
    local recipes = {}
    for key = 96001, 99000 do recipes[-key] = true end
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.updatedAt = 100
    entry.sourceType = "replica"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = recipes,
        count = 500,
        skillRank = 300,
        skillMaxRank = 375,
        sourceType = "replica",
        guildStatus = "active",
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
        lastUpdatedAt = entry.updatedAt,
    })

    data:InvalidateRecipeCaches("metadata")
    tooltip:EnsureIndexBuildScheduled()
    addon.Performance:RunNextStep()
    Test.truthy(tooltip._indexBuildJobActive,
        "large tooltip index should still be rebuilding after one scheduler tick")

    -- Bump the data while a build is mid-flight. The previous build's
    -- generation token is now stale; the next scheduler tick will abort
    -- it. Trigger a fresh build to pick up the new data.
    entry.professions.Alchemy.recipes[-97001] = true
    entry.professions.Alchemy.count = 501
    entry.professions.Alchemy.signature = "many+97001"
    data:InvalidateRecipeCaches("metadata")
    tooltip:EnsureIndexBuildScheduled()

    runUntilIdle(addon, 40)

    local rows = tooltip:GetRowsForKey("spell:97001")
    Test.eq(#(rows or {}), 1, "latest data should win after invalidation during an active rebuild")
    Test.falsy(tooltip.indexDirty, "tooltip index should be clean after the restarted build completes")
end)

Test.it("hooks the legacy tooltip scripts when the client exposes OnTooltipSetItem", function()
    local _addon, wow, data, tooltip = freshAddon()
    local memberKey = "Legacycrafter-TestRealm"
    wow.SetGuildRoster({
        { name = memberKey, online = true, rankName = "Member", rankIndex = 5, level = 70, classDisplayName = "Mage", classFileName = "MAGE" },
    })
    data:RebuildOnlineCache()
    seedProfession(data, memberKey, "Alchemy", 91001)
    seedProfession(data, memberKey, "Enchanting", -47001)
    tooltip:RebuildIndex()

    -- Fake 2.5.6-anniversary GameTooltip: legacy script types and
    -- GetItem()/GetSpell() accessors exist, TooltipDataProcessor post
    -- calls never fire (the table may exist but is dead code there).
    local legacyScripts = { OnTooltipSetItem = true, OnTooltipSetSpell = true, OnTooltipCleared = true }
    local fake = tooltipStub()
    fake.scripts = {}
    function fake:HasScript(name) return legacyScripts[name] == true end
    function fake:HookScript(name, handler) self.scripts[name] = handler end
    function fake:GetItem() return "Test Recipe", "item:91001:0:0:0" end
    function fake:GetSpell() return "Test Enchant", nil, 47001 end

    tooltip._tooltipHooksRegistered = false
    tooltip.watchedTooltips = { [fake] = true }
    tooltip:RegisterTooltipHooks()

    Test.truthy(tooltip._tooltipHooksRegistered, "legacy scripts should mark hooks as registered")
    Test.truthy(fake.scripts.OnTooltipSetItem, "OnTooltipSetItem should be hooked")
    Test.truthy(fake.scripts.OnTooltipSetSpell, "OnTooltipSetSpell should be hooked")
    Test.truthy(fake.scripts.OnTooltipCleared, "OnTooltipCleared should be hooked")

    fake.scripts.OnTooltipSetItem(fake)
    Test.eq(fake.lines[2] and fake.lines[2].text, "Recipe Registry", "item hover should render crafter header")
    Test.truthy(fake.shown, "item hover should show the tooltip")

    fake.scripts.OnTooltipCleared(fake)
    fake.lines = {}
    fake.scripts.OnTooltipSetSpell(fake)
    Test.eq(fake.lines[2] and fake.lines[2].text, "Recipe Registry", "spell hover should render crafter header")
end)

Test.it("defers index rebuild while warmup is active and schedules it afterwards", function()
    local addon, _wow, _data, tooltip = freshAddon()

    addon.Sync:EnterWarmup("tooltip-test", 30)
    tooltip:InvalidateIndex("warmup")
    Test.truthy(tooltip.indexDirty, "index should stay dirty during warmup")
    Test.falsy(tooltip._indexBuildJobActive, "warmup should not start a tooltip build job")

    addon.Sync.warmupUntil = 0
    tooltip:OnSyncWarmupEnded()
    Test.truthy(tooltip._indexBuildJobActive, "warmup end should schedule the tooltip build")
end)

io.write(string.format("Tooltip: %d test(s) passed\n", Test.count))
