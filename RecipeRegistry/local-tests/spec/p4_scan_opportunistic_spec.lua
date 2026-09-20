local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function countAddonComm(wow)
    local total = 0
    for _, row in ipairs(wow.GetSentComm()) do
        if type(row.message) == "table" and type(row.message.kind) == "string" then
            total = total + 1
        end
    end
    return total
end

local function printLogContains(wow, needle)
    for _, line in ipairs(wow.GetPrints()) do
        if tostring(line):find(needle, 1, true) then
            return true
        end
    end
    return false
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
    Test.truthy((entry.updatedAt or 0) > 0, "hidden-frame scan should stamp owner update time")
    Test.eq(entry.professions.Alchemy.count, 1, "Alchemy recipe count")
    Test.hasKey(entry.professions.Alchemy.recipes, 90001, "Alchemy recipe should be stored")
    Test.eq(countAddonComm(wow), 0, "trade scan should not emit inline sync traffic")
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
    Test.eq(countAddonComm(wow), 0, "no changed scan should stay free of inline sync traffic")
end)

Test.it("weapon skill-up does not print an unchanged profession scan message", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(localKey)

    entry.professions.Enchanting = data:NormalizeProfessionBlock(entry, "Enchanting", {
        recipes = { [-90041] = true },
        count = 1,
        signature = tostring(-90041),
        sourceType = "owner",
        guildStatus = "active",
    })
    wow.SetCraftSkill("Enchanting", {
        { name = "Enchant Existing Bracer", spellID = 90041 },
    }, { shown = false })

    addon:OnSkillSignal("SKILL_LINES_CHANGED")
    wow.RunTimers(5)

    Test.truthy(not printLogContains(wow, "Scanned Enchanting: unchanged"), "weapon skill-up should stay silent")
    Test.eq(data:GetScanTelemetry().scanSkippedWeaponSkill or 0, 1, "weapon skip telemetry")
end)

Test.it("weapon skill-up does not trigger a profession scan without a valid open profession frame", function()
    local addon, wow, data = freshAddon()

    wow.SetSkillLines({
        { name = "Swords", skillRank = 25, skillMaxRank = 75 },
    })
    wow.SetCraftSkill("Enchanting", {
        { name = "Hidden Enchant", spellID = 90042 },
    }, { shown = false })

    addon:OnSkillSignal("SKILL_LINES_CHANGED")
    wow.RunTimers(5)

    Test.eq(data:GetScanTelemetry().scansStarted or 0, 0, "weapon skill-up should not start a profession scan")
    Test.falsy(data:GetMember(data:GetPlayerKey()), "weapon skill-up should not create local profession data")
    Test.eq(countAddonComm(wow), 0, "weapon skill-up should not emit inline sync traffic")
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
    Test.truthy((entry.updatedAt or 0) > 0, "owner update time")
    Test.eq(entry.professions.Alchemy.count, 1, "Alchemy count")
    Test.eq(entry.professions.Alchemy.skillRank, 55, "skill rank should come from DetectProfessions")
    Test.hasKey(entry.professions.Alchemy.recipes, 90011, "recipe should be stored")
    Test.eq(countAddonComm(wow), 0, "recipe event should not emit inline sync traffic")
end)

Test.it("automatic unchanged scans stay silent while keeping telemetry", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(localKey)
    local recipeKey = 90012

    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = { [recipeKey] = true },
        count = 1,
        signature = tostring(recipeKey),
        sourceType = "owner",
        guildStatus = "active",
    })
    wow.SetTradeSkill("Alchemy", {
        { name = "Stable Auto Potion", itemID = recipeKey },
    }, { shown = true })

    addon:ProcessSkillSignal("SPELLS_CHANGED")

    Test.truthy(not printLogContains(wow, "Scanned Alchemy: unchanged"), "automatic unchanged scans should not print chat output")
    Test.eq(data:GetScanTelemetry().scansUnchanged or 0, 1, "unchanged telemetry")
    Test.eq(data:GetScanTelemetry().scanAutoSuppressedUnchanged or 0, 1, "suppressed unchanged telemetry")
    Test.eq(data:GetScanTelemetry().lastScanReason, "spell-update", "last scan reason")
    Test.eq(data:GetScanTelemetry().lastScanNotifyMode, "auto", "last notify mode")
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
    Test.eq(countAddonComm(wow), 0, "non-Enchanting skip should not emit inline sync traffic")
end)

Test.it("recipe-learned trigger can scan the relevant profession", function()
    local addon, wow, data = freshAddon()

    wow.SetSkillLines({
        { name = "Alchemy", skillRank = 56, skillMaxRank = 75 },
    })
    wow.SetTradeSkill("Alchemy", {
        { name = "Learned Test Potion", itemID = 90022 },
    }, { shown = true })

    addon:OnRecipeSignal()
    wow.RunTimers(5)

    local entry = data:GetMember(data:GetPlayerKey())
    Test.truthy(entry and entry.professions and entry.professions.Alchemy, "recipe-learned should scan Alchemy")
    Test.hasKey(entry.professions.Alchemy.recipes, 90022, "learned recipe should be stored")
    Test.eq(data:GetScanTelemetry().scanTriggeredRecipeLearned or 0, 1, "recipe-learn trigger telemetry")
    Test.eq(countAddonComm(wow), 0, "recipe-learned scan should not emit inline sync traffic")
end)

Test.it("generic SPELLS_CHANGED and SKILL_LINES_CHANGED do not spam scans or chat", function()
    local addon, wow, data = freshAddon()

    addon:OnSkillSignal("SPELLS_CHANGED")
    wow.RunTimers(5)
    addon:OnSkillSignal("SKILL_LINES_CHANGED")
    wow.RunTimers(5)

    Test.eq(data:GetScanTelemetry().scansStarted or 0, 0, "generic skill events should not start scans without an open profession frame")
    Test.eq(data:GetScanTelemetry().scanSkippedGenericSkill or 0, 1, "generic spell skip telemetry")
    Test.eq(data:GetScanTelemetry().scanSkippedWeaponSkill or 0, 1, "generic skill-line skip telemetry")
    Test.truthy(not printLogContains(wow, "Scanned "), "generic skill events should not spam scan messages")
end)

Test.it("debug mode still logs suppressed automatic unchanged scans without normal chat spam", function()
    local addon, wow, data = freshAddon()
    local localKey = data:GetPlayerKey()
    local entry = data:GetOrCreateMember(localKey)
    local recipeKey = 90023

    addon.debugMode = true
    entry.professions.Alchemy = data:NormalizeProfessionBlock(entry, "Alchemy", {
        recipes = { [recipeKey] = true },
        count = 1,
        signature = tostring(recipeKey),
        sourceType = "owner",
        guildStatus = "active",
    })
    wow.SetTradeSkill("Alchemy", {
        { name = "Debug Auto Potion", itemID = recipeKey },
    }, { shown = true })

    addon:ProcessSkillSignal("SPELLS_CHANGED")

    Test.truthy(printLogContains(wow, "Suppressed scan spell-update auto Alchemy unchanged"), "debug mode should log suppressed auto scans")
    Test.truthy(not printLogContains(wow, "Scanned Alchemy: unchanged"), "debug logging should not restore normal unchanged chat spam")
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
    Test.truthy((entry.updatedAt or 0) > 0, "hidden craft scan should stamp owner update time")
    Test.eq(entry.professions.Enchanting.count, 1, "Enchanting recipe count")
    Test.hasKey(entry.professions.Enchanting.recipes, -90031, "Enchanting spell recipe should be stored")
    Test.eq(countAddonComm(wow), 0, "craft scan should not emit inline sync traffic")
end)

Test.it("keeps direct Enchanting spells when spell subtext is blank", function()
    local addon, wow, data = freshAddon()
    local previousGetSpellSubtext = _G.GetSpellSubtext
    _G.GetSpellSubtext = function()
        return nil
    end

    wow.SetCraftSkill("Enchanting", {
        { name = "Enchant Blank Subtext Bracer", spellID = 90032 },
    }, { shown = true })

    addon:OnCraftShow()
    wow.RunTimers(5)
    _G.GetSpellSubtext = previousGetSpellSubtext

    local entry = data:GetMember(data:GetPlayerKey())
    Test.eq(entry.professions.Enchanting.count, 1, "blank-subtext direct enchant should be stored")
    Test.hasKey(entry.professions.Enchanting.recipes, -90032, "blank-subtext direct enchant key")
    Test.eq(data:GetScanTelemetry().invalidRecipesScan or 0, 0, "blank subtext should not mark craft spell invalid")
end)

Test.it("uses Craft API row type from the third GetCraftInfo return", function()
    local addon, wow, data = freshAddon()

    wow.SetCraftSkill("Enchanting", {
        { name = "Bracer", type = "header", isExpanded = true },
        { name = "Enchant Bracer - Test", subSpellName = "Enchant", type = "optimal", spellID = 90035 },
    }, { shown = true })

    addon:OnCraftShow()
    wow.RunTimers(5)

    local entry = data:GetMember(data:GetPlayerKey())
    Test.eq(entry.professions.Enchanting.count, 1, "header rows should not be scanned as missing recipes")
    Test.hasKey(entry.professions.Enchanting.recipes, -90035, "direct enchant spell key")
    Test.eq(data:GetScanTelemetry().invalidRecipesScan or 0, 0, "Craft headers should not be reported as invalid recipes")
end)

Test.it("persists locally scanned Enchanting recipes across same-account alt logins", function()
    local addon, wow = Loader.Load({ initialize = false })
    wow.SetPlayer("Enchanter", "TestRealm")
    Loader.Initialize(addon)

    wow.SetCraftSkill("Enchanting", {
        { name = "Enchant Persistent Bracer", subSpellName = "Enchant", type = "optimal", spellID = 90036 },
    }, { shown = true })

    addon:OnCraftShow()
    wow.RunTimers(5)

    local data = addon.Data
    local enchanterKey = data:GetPlayerKey()
    local sharedDB = _G.RecipeRegistryDB
    local entry = data:GetMember(enchanterKey)
    Test.hasKey(entry.professions.Enchanting.recipes, -90036, "initial Enchanting scan should store the spell key")

    local altAddon, altWow = Loader.Load({
        initialize = false,
        savedVariables = {
            db = sharedDB,
            charDB = {},
            logDB = {},
        },
    })
    altWow.SetPlayer("Bankalt", "TestRealm")
    Loader.Initialize(altAddon)

    local altData = altAddon.Data
    local persisted = altData:GetMember(enchanterKey)
    Test.truthy(persisted, "same-account alt should still see the enchanter member entry")
    Test.hasKey(persisted.professions.Enchanting.recipes, -90036, "Enchanting spell key should persist in saved variables")

    local rows = altData:GetRecipeCrafters(-90036)
    Test.eq(#rows, 1, "persisted Enchanting recipe should be locally consultable without peers")
    Test.eq(rows[1].memberKey, enchanterKey, "persisted crafter should be the enchanter alt")
    Test.eq(rows[1].profession, "Enchanting", "persisted profession")
end)

Test.it("does not store transient Craft row indexes when recipe links are unavailable", function()
    local addon, wow, data = freshAddon()

    wow.SetCraftSkill("Enchanting", {
        { name = "Enchant Missing Link" },
    }, { shown = true })

    addon:OnCraftShow()
    wow.RunTimers(5)

    local entry = data:GetMember(data:GetPlayerKey())
    Test.eq(entry.professions.Enchanting.count, 0, "missing recipe link should not produce a transient key")
    Test.noKey(entry.professions.Enchanting.recipes, -1, "transient row index should not be stored")
    Test.eq(data:GetScanTelemetry().invalidRecipesScan or 0, 1, "missing recipe link should be reported")
end)

io.write(string.format("P4 opportunistic scan: %d test(s) passed\n", Test.count))
