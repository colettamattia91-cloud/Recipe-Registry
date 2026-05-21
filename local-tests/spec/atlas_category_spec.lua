local Loader = dofile("local-tests/harness/load-addon.lua")
local Test = dofile("local-tests/harness/test.lua")

local function freshAddon()
    local addon, wow = Loader.Load()
    return addon, wow, addon.Data
end

local function seedMember(data, memberKey, profession, recipeKeys)
    local entry = data:GetOrCreateMember(memberKey)
    entry.owner = memberKey
    entry.updatedAt = 100
    entry.sourceType = "replica"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = entry.updatedAt
    entry.professions[profession] = data:NormalizeProfessionBlock(entry, profession, {
        recipes = recipeKeys,
        count = 0,
        skillRank = 300,
        skillMaxRank = 375,
        lastUpdatedAt = entry.updatedAt,
        sourceType = entry.sourceType,
        guildStatus = entry.guildStatus,
        lastSeenInGuildAt = entry.lastSeenInGuildAt,
    })
    return entry
end

local function installAtlasMock(wow)
    local state = wow.GetState()
    state.items[98001] = { name = "Arcane Widget", quality = 2, icon = "widget-icon" }
    state.items[98002] = { name = "Primal Transmute", quality = 3, icon = "transmute-icon" }
    state.items[98003] = { name = "Fel Widget", quality = 3, icon = "fel-widget-icon" }
    state.items[99004] = { name = "Adamantite Arrow Maker", quality = 2, icon = "arrow-maker-icon" }
    state.items[72001] = { name = "Recipe: Arcane Widget", quality = 1, icon = "recipe-icon" }
    state.spells[47001] = "Arcane Widget"
    state.spells[47002] = "Primal Transmute"
    state.spells[47003] = "Fel Widget"
    state.spells[47004] = "Adamantite Arrow Maker"

    _G.AtlasLoot = {
        Data = {
            Recipe = {
                GetRecipeForSpell = function(spellID)
                    if spellID == 47001 then return 72001 end
                    if spellID == 47002 then return 72002 end
                    if spellID == 47003 then return 72003 end
                    if spellID == 47004 then return 72004 end
                    return nil
                end,
                GetRecipeData = function(itemID)
                    if itemID == 72001 then return { 1, 300, 47001 } end
                    if itemID == 72002 then return { 1, 300, 47002 } end
                    if itemID == 72003 then return { 1, 350, 47003 } end
                    if itemID == 72004 then return { 1, 335, 47004 } end
                    return nil
                end,
            },
            Profession = {
                GetCraftSpellForCreatedItem = function(itemID)
                    if itemID == 98001 then return 47001 end
                    if itemID == 98002 then return 47002 end
                    if itemID == 98003 then return 47003 end
                    if itemID == 99004 then return 47004 end
                    return nil
                end,
                GetCreatedItemID = function(spellID)
                    if spellID == 47001 then return 98001 end
                    if spellID == 47002 then return 98002 end
                    if spellID == 47003 then return 98003 end
                    if spellID == 47004 then return 98004 end
                    return nil
                end,
                GetProfessionData = function(spellID)
                    if spellID == 47001 then
                        return { 98001, 1, 300, 300, 375, { 24001 }, { 2 }, 1 }
                    end
                    if spellID == 47002 then
                        return { 98002, 1, 350, 350, 375, { 24002 }, { 1 }, 1 }
                    end
                    if spellID == 47003 then
                        return { 98003, 1, 350, 350, 375, { 24003 }, { 1 }, 1 }
                    end
                    if spellID == 47004 then
                        return { 98004, 1, 335, 335, 355, { 24004 }, { 1 }, 1 }
                    end
                    return nil
                end,
                GetProfessionName = function(professionID)
                    return professionID == 1 and "Alchemy" or nil
                end,
            },
        },
    }

    local module = {
        __contentOrder = { "Alchemy", "AlchemyBC" },
        Alchemy = {
            name = "Localized Alchemy",
            items = {
                {
                    name = "Classic Potions",
                    [1] = {
                        { 1, 47001 },
                    },
                },
            },
        },
        AlchemyBC = {
            name = "Localized Alchemy",
            items = {
                {
                    name = "Outland Potions",
                    [1] = {
                        { 1, 47003 },
                    },
                },
                {
                    name = "Projectiles",
                    [1] = {
                        { 16, 47004, 99004 },
                    },
                },
                {
                    name = "Transmutes",
                    [1] = {
                        { 1, 47002 },
                    },
                },
                {
                    name = "Decorative",
                    [1] = {
                        { 1, "INV_misc_questionmark", nil, "Header" },
                        { 2, 23077 },
                    },
                },
            },
        },
    }
    _G.AtlasLoot.ItemDB = {
        Storage = {
            AtlasLootClassic_Crafting = module,
        },
        Get = function(_self, name)
            return _self.Storage and _self.Storage[name] or nil
        end,
        GetModuleList = function(_self, name)
            local currentModule = _self.Storage and _self.Storage[name] or nil
            return currentModule and currentModule.__contentOrder or nil
        end,
    }
end

local function installEngineeringAtlasMock(wow)
    local state = wow.GetState()
    for id = 98101, 98110 do
        state.items[id] = { name = "Engineering Item " .. tostring(id), quality = 2, icon = "engineering-icon" }
    end
    state.items[99106] = { name = "Adamantite Arrow Maker", quality = 2, icon = "arrow-maker-icon" }
    for spellID = 48101, 48110 do
        state.spells[spellID] = "Engineering Spell " .. tostring(spellID)
    end

    _G.AtlasLoot = {
        Data = {
            Recipe = {
                GetRecipeForSpell = function(spellID)
                    if spellID >= 48101 and spellID <= 48110 then
                        return 72100 + (spellID - 48100)
                    end
                    return nil
                end,
                GetRecipeData = function(itemID)
                    if itemID >= 72101 and itemID <= 72110 then
                        return { 9, 300, 48100 + (itemID - 72100) }
                    end
                    return nil
                end,
            },
            Profession = {
                GetCraftSpellForCreatedItem = function(itemID)
                    if itemID >= 98101 and itemID <= 98110 then
                        return 48100 + (itemID - 98100)
                    end
                    if itemID == 99106 then return 48106 end
                    return nil
                end,
                GetCreatedItemID = function(spellID)
                    if spellID >= 48101 and spellID <= 48110 then
                        return 98100 + (spellID - 48100)
                    end
                    return nil
                end,
                GetProfessionData = function(spellID)
                    if spellID >= 48101 and spellID <= 48110 then
                        return { 98100 + (spellID - 48100), 9, 300, 300, 375, { 24001 }, { 1 }, 1 }
                    end
                    return nil
                end,
                GetProfessionName = function(professionID)
                    return professionID == 9 and "Engineering" or nil
                end,
            },
        },
    }

    local module = {
        __contentOrder = { "Engineering", "EngineeringBC" },
        Engineering = {
            name = "Engineering",
            items = {
                {
                    name = "Armor",
                    [1] = {
                        { 1, 48101 },
                    },
                },
                {
                    name = "Armor - Head",
                    [1] = {
                        { 1, 48102 },
                    },
                },
                {
                    name = "Weapons - Guns",
                    [1] = {
                        { 1, 48103 },
                    },
                },
            },
        },
        EngineeringBC = {
            name = "Engineering",
            items = {
                {
                    name = "Armor - Head - Cloth",
                    [1] = {
                        { 1, 48104 },
                    },
                },
                {
                    name = "Armor - Head - Leather",
                    [1] = {
                        { 1, 48105 },
                    },
                },
                {
                    name = "Projectile",
                    [1] = {
                        { 16, 48106, 99106 },
                    },
                },
                {
                    name = "Parts",
                    [1] = {
                        { 1, 48107 },
                    },
                },
                {
                    name = "Explosives",
                    [1] = {
                        { 1, 48108 },
                    },
                },
                {
                    name = "Pets",
                    [1] = {
                        { 1, 48109 },
                    },
                },
                {
                    name = "Misc",
                    [1] = {
                        { 1, 48110 },
                    },
                },
            },
        },
    }

    _G.AtlasLoot.ItemDB = {
        Storage = {
            AtlasLootClassic_Crafting = module,
        },
        Get = function(_self, name)
            return _self.Storage and _self.Storage[name] or nil
        end,
        GetModuleList = function(_self, name)
            local currentModule = _self.Storage and _self.Storage[name] or nil
            return currentModule and currentModule.__contentOrder or nil
        end,
    }
end

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function assertCategoryCoverage(data, profession)
    local allRows = data:GetRecipeList(profession, "", "alpha", "recipe", "All")
    local allSet = {}
    for _, row in ipairs(allRows) do
        allSet[tostring(row.recipeKey)] = true
    end

    local union = {}
    local summedRows = 0
    for _, categoryName in ipairs(data:GetRecipeCategories(profession, true)) do
        local rows = data:GetRecipeList(profession, "", "alpha", "recipe", categoryName)
        summedRows = summedRows + #rows
        for _, row in ipairs(rows) do
            local key = tostring(row.recipeKey)
            Test.falsy(union[key], "recipe should not appear in more than one normalized category")
            union[key] = true
        end
    end

    Test.eq(summedRows, #allRows, "sum of normalized categories should match All")
    Test.eq(countKeys(union), #allRows, "category union should match All count")
    for key in pairs(allSet) do
        Test.truthy(union[key], "every All recipe should be covered by a category")
    end
end

io.write("AtlasLoot categories\n")

Test.it("maps AtlasLoot crafting sections to all supported recipe key shapes", function()
    local _addon, wow, data = freshAddon()
    installAtlasMock(wow)

    local categories = data:GetRecipeCategories("Alchemy", true)
    Test.eq(categories[1], "Classic Potions", "first category should preserve AtlasLoot order")
    Test.eq(categories[2], "Outland Potions", "second category should include TBC content")
    Test.eq(categories[3], "Projectiles", "third category should include row aliases from tbc content")
    Test.eq(categories[4], "Transmutes", "fourth category should preserve TBC order")
    Test.eq(#categories, 4, "non-craft decorative rows should not create categories")
    Test.eq(data:GetRecipeCategory(98001, "Alchemy"), "Classic Potions", "classic created item key should map to category")
    Test.eq(data:GetRecipeCategory(72001, "Alchemy"), "Classic Potions", "classic recipe item key should map to category")
    Test.eq(data:GetRecipeCategory(98003, "Alchemy"), "Outland Potions", "tbc created item key should map to category")
    Test.eq(data:GetRecipeCategory(99004, "Alchemy"), "Projectiles", "display item alias should map to category")
    Test.eq(data:GetRecipeCategory(-47002, "Alchemy"), "Transmutes", "spell recipe key should map to category")
end)

Test.it("filters recipe lists by AtlasLoot category without changing all-recipes behavior", function()
    local _addon, wow, data = freshAddon()
    installAtlasMock(wow)
    seedMember(data, "Categoryone-TestRealm", "Alchemy", {
        [98001] = true,
        [98003] = true,
        [99004] = true,
        [-47002] = true,
    })

    local knownCategories = data:GetRecipeCategories("Alchemy")
    Test.eq(#knownCategories, 4, "known categories should include vanilla and tbc categories represented in saved recipes")
    Test.eq(#data:GetRecipeList("Alchemy", "", "alpha", "recipe", "Classic Potions"), 1, "classic category should show only classic recipes")
    Test.eq(#data:GetRecipeList("Alchemy", "", "alpha", "recipe", "Outland Potions"), 1, "tbc category should show only tbc recipes")
    Test.eq(#data:GetRecipeList("Alchemy", "", "alpha", "recipe", "Projectiles"), 1, "projectile category should match row display item aliases")
    Test.eq(#data:GetRecipeList("Alchemy", "", "alpha", "recipe", "Transmutes"), 1, "transmute category should show only transmute recipes")
    Test.eq(#data:GetRecipeList("Alchemy", "", "alpha", "recipe", "All"), 4, "all category should preserve full profession list")
end)

Test.it("loads AtlasLootClassic_Crafting on demand before building categories", function()
    local _addon, wow, data = freshAddon()
    installAtlasMock(wow)
    local storageModule = _G.AtlasLoot.ItemDB:Get("AtlasLootClassic_Crafting")
    _G.AtlasLoot.ItemDB.Storage = {}
    local loaded = false
    _G.AtlasLoot.Loader = {
        LoadModule = function(_self, moduleName)
            if moduleName == "AtlasLootClassic_Crafting" then
                _G.AtlasLoot.ItemDB.Storage[moduleName] = storageModule
                loaded = true
            end
        end,
    }

    local categories = data:GetRecipeCategories("Alchemy", true)

    Test.truthy(loaded, "crafting module should be loaded on demand")
    Test.eq(categories[1], "Classic Potions", "categories should be available after on-demand load")
end)

Test.it("normalizes Engineering AtlasLoot categories and preserves All coverage", function()
    local _addon, wow, data = freshAddon()
    installEngineeringAtlasMock(wow)
    seedMember(data, "Engineerone-TestRealm", "Engineering", {
        [98101] = true,
        [98102] = true,
        [98103] = true,
        [98104] = true,
        [98105] = true,
        [99106] = true,
        [98107] = true,
        [98108] = true,
        [98109] = true,
        [98110] = true,
    })

    local categories = data:GetRecipeCategories("Engineering", true)
    Test.eq(categories[1], "Armor", "vanilla armor should be the first normalized engineering category")
    Test.eq(categories[2], "Weapons", "weapon categories should stay compact")
    Test.eq(categories[3], "Projectiles", "projectile category should include tbc aliases")
    Test.eq(categories[4], "Parts", "parts category should be preserved")
    Test.eq(categories[5], "Explosives", "explosives category should be preserved")
    Test.eq(categories[6], "Pets", "pets category should be preserved")
    Test.eq(categories[7], "Misc", "misc category should be preserved")
    Test.eq(#categories, 7, "engineering raw armor-head variants should collapse into one category")
    Test.eq(#data:GetRecipeList("Engineering", "", "alpha", "recipe", "Armor"), 4, "all armor-head variants should be grouped")
    Test.eq(#data:GetRecipeList("Engineering", "", "alpha", "recipe", "Projectiles"), 1, "projectile alias should be grouped")
    assertCategoryCoverage(data, "Engineering")
end)

io.write(string.format("AtlasLoot categories: %d test(s) passed\n", Test.count))
