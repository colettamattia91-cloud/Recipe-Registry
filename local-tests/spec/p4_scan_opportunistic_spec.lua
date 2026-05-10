local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function countGuildCommKind(wow, kind)
    local total = 0
    for _, row in ipairs(wow.GetSentComm()) do
        if row.distribution == "GUILD" and type(row.message) == "table" and row.message.kind == kind then
            total = total + 1
        end
    end
    return total
end

io.write("P4 opportunistic scan\n")

Test.it("reports active trade skill data as not ready instead of storing an empty owner snapshot", function()
    local _addon, wow, data = freshAddon()

    data:MarkScanNeeded(nil, "recipe-event")
    wow.SetTradeSkill("Alchemy", {}, { shown = true })

    local result = data:ScanTradeSkill()

    Test.truthy(result.skipped, "empty active trade data should be skipped")
    Test.eq(result.skipReason, "trade-data-not-ready", "skip reason")
    Test.falsy(result.valid, "not-ready scan should not be valid")
    Test.truthy(data:HasAnyScanPending(), "pending recipe work should remain")
    Test.falsy(data:GetMember(data:GetPlayerKey()), "not-ready scan should not create local owner data")
end)

Test.it("scans TradeSkill API data after TRADE_SKILL_SHOW even if the frame is already hidden", function()
    local addon, wow, data = freshAddon()

    wow.SetTradeSkill("Alchemy", {
        { name = "Elixir of Tests", itemID = 90001 },
    }, { shown = false })

    addon:OnTradeSkillShow()
    wow.RunTimers(5)

    local entry = data:GetMember(data:GetPlayerKey())

    Test.falsy(_G.TradeSkillFrame:IsShown(), "test fixture frame should remain hidden")
    Test.truthy(entry, "hidden-frame scan should create local owner entry")
    Test.eq(entry.rev, 1, "hidden-frame scan should advance owner revision")
    Test.eq(entry.professions.Alchemy.count, 1, "Alchemy recipe count")
    Test.hasKey(entry.professions.Alchemy.recipes, 90001, "Alchemy recipe should be stored")
    Test.eq(countGuildCommKind(wow, "AD"), 1, "trade scan should advertise local revision")
end)

Test.it("blocks impossible positive item IDs during local TradeSkill scans", function()
    local _addon, wow, data = freshAddon()

    wow.SetTradeSkill("Cooking", {
        { name = "Valid Test Food", itemID = 21072 },
        {
            name = "Corrupt Test Food",
            itemLink = "|Hitem:2107276023613:0:0:0:0:0:0:0|h[Corrupt Test Food]|h",
        },
    }, { shown = false })

    local result = data:ScanTradeSkill()
    local entry = data:GetMember(data:GetPlayerKey())
    local scan = data:GetScanTelemetry()

    Test.truthy(result.valid, "scan should remain valid when at least one recipe is valid")
    Test.eq(result.count, 1, "corrupt item ID should not count as a recipe")
    Test.eq(entry.professions.Cooking.count, 1, "stored Cooking count")
    Test.hasKey(entry.professions.Cooking.recipes, 21072, "valid recipe should remain")
    Test.noKey(entry.professions.Cooking.recipes, 2107276023613, "impossible item ID should be blocked")
    Test.eq(scan.invalidRecipesScan, 1, "scan invalid telemetry")
    Test.eq(scan.lastInvalidRecipeKey, 2107276023613, "last invalid scan key")
end)

Test.it("keeps generic recipe pending when no profession API has active data", function()
    local addon, wow, data = freshAddon()

    wow.SetSkillLines({
        { name = "Alchemy", skillRank = 50, skillMaxRank = 75 },
    })

    addon:ProcessRecipeSignal()

    local scan = data:GetScanTelemetry()

    Test.truthy(data:HasAnyScanPending(), "generic pending should remain")
    Test.eq(scan.scansSkipped, 2, "both trade and craft scans should report skipped")
    Test.eq(scan.lastSkipReason, "craft-no-title", "last skip should come from Craft API")
    Test.eq(countGuildCommKind(wow, "AD"), 0, "no changed scan should advertise")
end)

Test.it("uses recipe events to scan active hidden TradeSkill data and clear generic pending", function()
    local addon, wow, data = freshAddon()

    wow.SetSkillLines({
        { name = "Alchemy", skillRank = 55, skillMaxRank = 75 },
    })
    wow.SetTradeSkill("Alchemy", {
        { name = "Potion of Harnesses", itemID = 90011 },
    }, { shown = false })

    addon:ProcessRecipeSignal()

    local entry = data:GetMember(data:GetPlayerKey())

    Test.falsy(data:HasAnyScanPending(), "changed opportunistic scan should clear generic pending")
    Test.eq(entry.rev, 1, "owner revision")
    Test.eq(entry.professions.Alchemy.count, 1, "Alchemy count")
    Test.eq(entry.professions.Alchemy.skillRank, 55, "skill rank should come from DetectProfessions")
    Test.hasKey(entry.professions.Alchemy.recipes, 90011, "recipe should be stored")
    Test.eq(countGuildCommKind(wow, "AD"), 1, "recipe event should advertise changed scan")
end)

Test.it("does not consume recipe pending or store Enchanting when CraftFrame contains another skill", function()
    local addon, wow, data = freshAddon()

    wow.SetCraftSkill("Beast Training", {
        { name = "Growl", spellID = 90021 },
    }, { shown = false })

    addon:ProcessRecipeSignal()

    local entry = data:GetMember(data:GetPlayerKey())

    Test.truthy(data:HasAnyScanPending(), "non-Enchanting craft data should not consume generic pending")
    Test.eq(data:GetScanTelemetry().lastSkipReason, "craft-not-enchanting", "skip reason")
    Test.falsy(entry and entry.professions and entry.professions.Enchanting, "non-Enchanting craft data should not create Enchanting")
    Test.eq(countGuildCommKind(wow, "AD"), 0, "non-Enchanting skip should not advertise")
end)

Test.it("scans Enchanting Craft API data after CRAFT_SHOW even if the frame is hidden", function()
    local addon, wow, data = freshAddon()

    wow.SetCraftSkill("Enchanting", {
        { name = "Enchant Test Bracer", spellID = 90031 },
    }, { shown = false })

    addon:OnCraftShow()
    wow.RunTimers(5)

    local entry = data:GetMember(data:GetPlayerKey())

    Test.falsy(_G.CraftFrame:IsShown(), "test fixture frame should remain hidden")
    Test.truthy(entry, "hidden craft scan should create local owner entry")
    Test.eq(entry.rev, 1, "hidden craft scan should advance owner revision")
    Test.eq(entry.professions.Enchanting.count, 1, "Enchanting recipe count")
    Test.hasKey(entry.professions.Enchanting.recipes, -90031, "Enchanting spell recipe should be stored")
    Test.eq(countGuildCommKind(wow, "AD"), 1, "craft scan should advertise local revision")
end)

io.write(string.format("P4 opportunistic scan: %d test(s) passed\n", Test.count))
