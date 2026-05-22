local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local ipairs = ipairs
local pairs = pairs
local sort = table.sort
local tonumber = tonumber
local tostring = tostring
local type = type

local cloneAtlasInfo = Private.cloneAtlasInfo
local formatReagents = Private.formatReagents
local getAtlasLootHandles = Private.getAtlasLootHandles
local getAtlasLootProfessionName = Private.getAtlasLootProfessionName
local safeGetItemName = Private.safeGetItemName
local safeGetSpellName = Private.safeGetSpellName

local CRAFTING_MODULE_NAME = "AtlasLootClassic_Crafting"

local PROFESSION_CONTENT_KEYS = {
    Alchemy = "Alchemy",
    Blacksmithing = "Blacksmithing",
    Cooking = "Cooking",
    Enchanting = "Enchanting",
    Engineering = "Engineering",
    Herbalism = "Herbalism",
    Jewelcrafting = "Jewelcrafting",
    Leatherworking = "Leatherworking",
    Mining = "Mining",
    Tailoring = "Tailoring",
}

local function formatOutputDesc(createdItemID, createdItemName, professionID)
    if createdItemID then
        return string.format("%s(%s)", tostring(createdItemName or "?"), tostring(createdItemID))
    end
    if professionID == 10 then
        return "direct enchant/no created item"
    end
    return "no created item"
end

local function getAtlasLootCraftingModuleFromItemDB(itemDB, moduleName)
    if type(itemDB) ~= "table" then return nil end
    if type(itemDB.Get) == "function" then
        local ok, module = pcall(itemDB.Get, itemDB, moduleName)
        if ok and type(module) == "table" then
            return module
        end
    end
    if type(itemDB.Storage) == "table" and type(itemDB.Storage[moduleName]) == "table" then
        return itemDB.Storage[moduleName]
    end
    return nil
end

local function loadAtlasLootCraftingModule(atlas, moduleName)
    if type(atlas) ~= "table" then return end
    local loader = atlas.Loader
    if type(loader) == "table" and type(loader.LoadModule) == "function" then
        pcall(loader.LoadModule, loader, moduleName, nil, "itemDB")
    end
    if type(_G.C_AddOns) == "table" and type(_G.C_AddOns.LoadAddOn) == "function" then
        pcall(_G.C_AddOns.LoadAddOn, moduleName)
    elseif type(_G.LoadAddOn) == "function" then
        pcall(_G.LoadAddOn, moduleName)
    end
end

local function getAtlasLootCraftingModule(allowLoad)
    local atlas = _G.AtlasLoot
    local itemDB = atlas and atlas.ItemDB
    if type(itemDB) ~= "table" then return nil, nil, nil end
    local moduleName = CRAFTING_MODULE_NAME
    local module = getAtlasLootCraftingModuleFromItemDB(itemDB, moduleName)
    if not module and allowLoad ~= false then
        loadAtlasLootCraftingModule(atlas, moduleName)
        module = getAtlasLootCraftingModuleFromItemDB(itemDB, moduleName)
    end
    return module, itemDB, moduleName
end

local function getOrderedContentKeys(module, itemDB, moduleName)
    local keys = {}
    if itemDB and type(itemDB.GetModuleList) == "function" then
        local ok, list = pcall(itemDB.GetModuleList, itemDB, moduleName)
        if ok and type(list) == "table" then
            for i = 1, #list do
                if module[list[i]] then
                    keys[#keys + 1] = list[i]
                end
            end
            if #keys > 0 then return keys end
        end
    end
    if type(module.__contentOrder) == "table" then
        for i = 1, #module.__contentOrder do
            if module[module.__contentOrder[i]] then
                keys[#keys + 1] = module.__contentOrder[i]
            end
        end
        if #keys > 0 then return keys end
    end
    for key, content in pairs(module or {}) do
        if type(content) == "table" and type(content.items) == "table" then
            keys[#keys + 1] = key
        end
    end
    sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function getContentName(content)
    if type(content) ~= "table" then return nil end
    if content.name then return content.name end
    if type(content.GetName) == "function" then
        local ok, name = pcall(content.GetName, content, true)
        if ok and name then return name end
    end
    return nil
end

local function getProfessionFromContentKey(contentKey)
    local key = tostring(contentKey or "")
    key = key:gsub("Wrath$", ""):gsub("BC$", "")
    return PROFESSION_CONTENT_KEYS[key]
end

local function getProfessionFromContent(data, contentKey, content)
    local rawName = getContentName(content)
    local professionName = rawName and data:GetCanonicalProfession(rawName) or nil
    if PROFESSION_CONTENT_KEYS[professionName] then
        return professionName
    end
    return getProfessionFromContentKey(contentKey)
end

local function normalizeCategoryText(categoryName)
    local text = tostring(categoryName or "")
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("%s+", " ")
    return text:lower()
end

local function normalizeAtlasCategory(professionName, categoryName)
    if not categoryName then return nil end
    if professionName == "Cooking" then
        local firstStat = tostring(categoryName):match("^%s*([^+&/]+)%s*[%+&/]")
        if firstStat then
            firstStat = firstStat:gsub("^%s+", ""):gsub("%s+$", "")
            if firstStat ~= "" then
                return firstStat
            end
        end
    end
    if professionName ~= "Engineering" then return categoryName end

    local text = normalizeCategoryText(categoryName)
    if text:find("projectile", 1, true) or text:find("bullet", 1, true) or text:find("arrow", 1, true) then
        return "Projectiles"
    end
    if text:find("parts", 1, true) or text:find("part", 1, true) then
        return "Parts"
    end
    if text:find("flare", 1, true) then
        return "Flares"
    end
    if text:find("explosive", 1, true) or text:find("bomb", 1, true) or text:find("grenade", 1, true) then
        return "Explosives"
    end
    if text:find("pet", 1, true) then
        return "Pets"
    end
    if text:find("trinket", 1, true) then
        return "Devices / Trinkets"
    end
    if text:find("weapon", 1, true) and text:find("enhancement", 1, true) then
        return "Scopes / Enhancements"
    end
    if text:find("scope", 1, true) then
        return "Scopes / Enhancements"
    end
    if text:find("weapon", 1, true) or text:find("gun", 1, true) then
        return "Weapons"
    end
    if text:find("armor", 1, true) or text:find("head", 1, true) then
        return "Armor"
    end
    if text:find("misc", 1, true) then
        return "Misc"
    end
    return categoryName
end

local function registerCategory(index, professionName, categoryName)
    index.categoriesByProfession[professionName] = index.categoriesByProfession[professionName] or {}
    index.categorySeenByProfession[professionName] = index.categorySeenByProfession[professionName] or {}
    if not index.categorySeenByProfession[professionName][categoryName] then
        index.categorySeenByProfession[professionName][categoryName] = true
        local categories = index.categoriesByProfession[professionName]
        categories[#categories + 1] = categoryName
    end
end

local function registerRecipeCategory(index, professionName, recipeKey, categoryName)
    if not recipeKey then return false end
    categoryName = normalizeAtlasCategory(professionName, categoryName)
    if not categoryName then return false end
    index.categoryByRecipe[professionName] = index.categoryByRecipe[professionName] or {}
    local byRecipe = index.categoryByRecipe[professionName]
    local key = tostring(recipeKey)
    if byRecipe[key] then return false end
    byRecipe[key] = categoryName
    registerCategory(index, professionName, categoryName)
    return true
end

local function registerAtlasInfo(index, professionName, categoryName, info)
    if type(info) ~= "table" then return false end
    local added = registerRecipeCategory(index, professionName, info.createdItemID, categoryName)
    added = registerRecipeCategory(index, professionName, info.recipeItemID, categoryName) or added
    if info.spellID then
        added = registerRecipeCategory(index, professionName, -info.spellID, categoryName) or added
    end
    return added
end

local function registerAtlasRow(index, data, professionName, categoryName, row)
    if type(row) ~= "table" then return false end

    local added = false
    local rowMapped = false
    local rowSpellID = tonumber(row[2])
    if rowSpellID then
        local info = data:GetAtlasLootSpellInfo(rowSpellID)
        if info then
            added = registerAtlasInfo(index, professionName, categoryName, info) or added
            added = registerRecipeCategory(index, professionName, rowSpellID, categoryName) or added
            rowMapped = true
        end
    end

    for i = 2, 3 do
        local value = tonumber(row[i])
        if value then
            local info = data:GetAtlasLootCreatedItemInfo(value) or data:GetAtlasLootRecipeInfo(value)
            added = registerAtlasInfo(index, professionName, categoryName, info) or added
            if info or rowMapped then
                added = registerRecipeCategory(index, professionName, value, categoryName) or added
            end
        end
    end

    return added
end

function Data:InvalidateAtlasLootCategoryIndex()
    self._atlasCategoryIndex = nil
    self:InvalidateRecipeCaches("list")
end

function Data:BuildAtlasLootCategoryIndex()
    local module, itemDB, moduleName = getAtlasLootCraftingModule(true)
    local index = {
        categoriesByProfession = {},
        categorySeenByProfession = {},
        categoryByRecipe = {},
    }
    if not module then
        index.unavailable = true
        self._atlasCategoryIndex = index
        return index
    end

    for _, contentKey in ipairs(getOrderedContentKeys(module, itemDB, moduleName)) do
        local content = module[contentKey]
        local professionName = getProfessionFromContent(self, contentKey, content)
        if professionName and type(content.items) == "table" then
            for _, category in ipairs(content.items) do
                local categoryName = category and category.name
                if categoryName then
                    for diffKey, rows in pairs(category) do
                        if diffKey ~= "name" and type(rows) == "table" then
                            for _, row in ipairs(rows) do
                                registerAtlasRow(index, self, professionName, categoryName, row)
                            end
                        end
                    end
                end
            end
        end
    end

    index.categorySeenByProfession = nil
    self._atlasCategoryIndex = index
    return index
end

function Data:GetAtlasLootCategoryIndex()
    if self._atlasCategoryIndex and not self._atlasCategoryIndex.unavailable then
        return self._atlasCategoryIndex
    end
    return self:BuildAtlasLootCategoryIndex()
end

-- Chunked counterpart to BuildAtlasLootCategoryIndex. The sync build walks
-- the entire AtlasLoot crafting module in one pass — hundreds of rows per
-- profession, ~50–200 ms total. Triggered at PLAYER_LOGIN so the work
-- happens during sync warmup (when the UI is in degraded mode and the
-- player isn't waiting on it). Callers that hit the lookup before the
-- prebuild finishes still fall back to the sync builder via
-- GetAtlasLootCategoryIndex; that's a rare path because warmup usually
-- gives the prebuild more than enough time to complete.
function Data:BuildAtlasLootCategoryIndexAsync(onComplete)
    if self._atlasCategoryIndex and not self._atlasCategoryIndex.unavailable then
        if onComplete then onComplete(self._atlasCategoryIndex) end
        return
    end

    if self._atlasCategoryIndexBuildCallbacks then
        if onComplete then
            self._atlasCategoryIndexBuildCallbacks[#self._atlasCategoryIndexBuildCallbacks + 1] = onComplete
        end
        return
    end

    self._atlasCategoryIndexBuildCallbacks = onComplete and { onComplete } or {}

    if not (Addon.Performance and Addon.Performance.ScheduleJob) then
        local index = self:BuildAtlasLootCategoryIndex()
        local callbacks = self._atlasCategoryIndexBuildCallbacks
        self._atlasCategoryIndexBuildCallbacks = nil
        for _, cb in ipairs(callbacks) do
            if cb then cb(index) end
        end
        return
    end

    local module, itemDB, moduleName = getAtlasLootCraftingModule(true)
    local index = {
        categoriesByProfession = {},
        categorySeenByProfession = {},
        categoryByRecipe = {},
    }
    if not module then
        index.unavailable = true
        self._atlasCategoryIndex = index
        local callbacks = self._atlasCategoryIndexBuildCallbacks
        self._atlasCategoryIndexBuildCallbacks = nil
        for _, cb in ipairs(callbacks) do
            if cb then cb(index) end
        end
        return
    end

    local jobState = {
        module = module,
        orderedKeys = getOrderedContentKeys(module, itemDB, moduleName),
        cursor = 1,
        index = index,
    }

    Addon.Performance:ScheduleJob("atlas-category-build", function(state, ctx)
        return self:RunAtlasLootCategoryBuildStep(state, ctx)
    end, {
        category = "ui-data",
        label = "atlas-category-build",
        budgetMs = 3,
        state = jobState,
    })
end

function Data:RunAtlasLootCategoryBuildStep(state, ctx)
    local budgetMs = (ctx and ctx.budgetMs) or 3
    local startedAt = (type(debugprofilestop) == "function") and debugprofilestop() or 0
    local module = state.module
    local orderedKeys = state.orderedKeys
    local index = state.index
    local total = #orderedKeys

    while state.cursor <= total do
        local contentKey = orderedKeys[state.cursor]
        state.cursor = state.cursor + 1
        local content = module[contentKey]
        local professionName = content and getProfessionFromContent(self, contentKey, content) or nil
        if professionName and type(content.items) == "table" then
            for _, category in ipairs(content.items) do
                local categoryName = category and category.name
                if categoryName then
                    for diffKey, rows in pairs(category) do
                        if diffKey ~= "name" and type(rows) == "table" then
                            for _, row in ipairs(rows) do
                                registerAtlasRow(index, self, professionName, categoryName, row)
                            end
                        end
                    end
                end
            end
        end
        local now = (type(debugprofilestop) == "function") and debugprofilestop() or 0
        if (now - startedAt) >= budgetMs then
            return true, state
        end
    end

    index.categorySeenByProfession = nil
    self._atlasCategoryIndex = index
    local callbacks = self._atlasCategoryIndexBuildCallbacks
    self._atlasCategoryIndexBuildCallbacks = nil
    if callbacks then
        for _, cb in ipairs(callbacks) do
            if cb then cb(index) end
        end
    end
    return false, state
end

function Data:GetRecipeCategory(recipeKey, profession)
    if not recipeKey or not profession then return nil end
    local index = self:GetAtlasLootCategoryIndex()
    local byRecipe = index.categoryByRecipe and index.categoryByRecipe[profession]
    return byRecipe and byRecipe[tostring(recipeKey)] or nil
end

function Data:GetRecipeCategories(profession, includeEmpty)
    if not profession then return {} end
    local index = self:GetAtlasLootCategoryIndex()
    local categories = index.categoriesByProfession and index.categoriesByProfession[profession] or {}
    local out = {}
    if includeEmpty then
        for i = 1, #categories do
            out[#out + 1] = categories[i]
        end
        return out
    end

    local seen = {}
    local recipeIndex = self:GetRecipeIndex()
    for recipeKey, row in pairs(recipeIndex or {}) do
        if row.profNames and row.profNames[profession] then
            local categoryName = self:GetRecipeCategory(recipeKey, profession)
            if categoryName then
                seen[categoryName] = true
            end
        end
    end
    for i = 1, #categories do
        if seen[categories[i]] then
            out[#out + 1] = categories[i]
        end
    end
    return out
end

function Data:ResolveRecipeProfession(recipeKey)
    local n = tonumber(recipeKey)
    if not n then return nil end

    local info
    if n < 0 then
        info = self:GetAtlasLootSpellInfo(-n)
    elseif n > 0 then
        info = self:GetAtlasLootCreatedItemInfo(n) or self:GetAtlasLootRecipeInfo(n)
    end

    local professionName = info and info.professionID and getAtlasLootProfessionName(info.professionID) or nil
    if professionName then
        return self:GetCanonicalProfession(professionName), professionName
    end
    return nil
end

function Data:HasAtlasLootResolver()
    local recipe, profession = getAtlasLootHandles()
    return recipe ~= nil and profession ~= nil
end

function Data:GetAtlasLootRecipeInfo(recipeItemID)
    local cached = self._atlasRecipeInfoCache and self._atlasRecipeInfoCache[recipeItemID]
    if cached then
        return cloneAtlasInfo(cached)
    end

    local recipe, profession = getAtlasLootHandles()
    if not recipe or not profession or not recipeItemID then return nil end
    local recipeData = recipe.GetRecipeData and recipe.GetRecipeData(recipeItemID)
    if not recipeData then return nil end
    local spellID = recipeData[3]
    local spellData = spellID and profession.GetProfessionData and profession.GetProfessionData(spellID) or nil
    local createdItemID = spellID and profession.GetCreatedItemID and profession.GetCreatedItemID(spellID) or nil
    local info = {
        recipeItemID = recipeItemID,
        professionID = recipeData[1],
        minRank = recipeData[2],
        spellID = spellID,
        spellName = safeGetSpellName(spellID),
        createdItemID = createdItemID,
        createdItemName = safeGetItemName(createdItemID),
        spellData = spellData,
    }
    self._atlasRecipeInfoCache[recipeItemID] = cloneAtlasInfo(info)
    return info
end

function Data:GetAtlasLootSpellInfo(spellID)
    local cached = self._atlasSpellInfoCache and self._atlasSpellInfoCache[spellID]
    if cached then
        return cloneAtlasInfo(cached)
    end

    local recipe, profession = getAtlasLootHandles()
    if not recipe or not profession or not spellID then return nil end
    local spellData = profession.GetProfessionData and profession.GetProfessionData(spellID)
    if not spellData then return nil end
    local recipeItemID = recipe.GetRecipeForSpell and recipe.GetRecipeForSpell(spellID) or nil
    local info = {
        spellID = spellID,
        spellName = safeGetSpellName(spellID),
        professionID = spellData[2],
        minRank = spellData[3],
        lowRank = spellData[4],
        highRank = spellData[5],
        createdItemID = spellData[1],
        createdItemName = safeGetItemName(spellData[1]),
        recipeItemID = recipeItemID,
        recipeItemName = safeGetItemName(recipeItemID),
        reagentIDs = spellData[6] or {},
        reagentCounts = spellData[7] or {},
        numCreated = spellData[8] or 1,
    }
    self._atlasSpellInfoCache[spellID] = cloneAtlasInfo(info)
    return info
end

function Data:GetAtlasLootCreatedItemInfo(createdItemID)
    local cached = self._atlasCreatedItemInfoCache and self._atlasCreatedItemInfoCache[createdItemID]
    if cached then
        return cloneAtlasInfo(cached)
    end

    local recipe, profession = getAtlasLootHandles()
    if not recipe or not profession or not createdItemID then return nil end
    local spellID = profession.GetCraftSpellForCreatedItem and profession.GetCraftSpellForCreatedItem(createdItemID) or nil
    if not spellID then return nil end
    local info = self:GetAtlasLootSpellInfo(spellID) or {}
    info.createdItemID = createdItemID
    info.createdItemName = safeGetItemName(createdItemID)
    self._atlasCreatedItemInfoCache[createdItemID] = cloneAtlasInfo(info)
    return info
end

function Data:DumpAtlasLootStatus()
    local recipe, profession = getAtlasLootHandles()
    local module = getAtlasLootCraftingModule(false)
    local categoryIndex = self._atlasCategoryIndex
    Addon:SystemPrint(string.format(
        "AtlasLoot resolver: %s | Recipe=%s | Profession=%s | Crafting=%s | Categories=%s",
        self:HasAtlasLootResolver() and "ready" or "missing",
        recipe and "yes" or "no",
        profession and "yes" or "no",
        module and "loaded" or "missing",
        categoryIndex and (categoryIndex.unavailable and "unavailable" or "ready") or "not-built"
    ))
end

function Data:DebugRecipeItem(recipeItemID)
    if not recipeItemID then
        Addon:Print("Usage: /rr r <recipeItemID>")
        return
    end
    local info = self:GetAtlasLootRecipeInfo(recipeItemID)
    if not info then
        Addon:SystemPrint("No AtlasLoot recipe data for item " .. tostring(recipeItemID))
        return
    end
    local reagents = info.spellData and formatReagents(info.spellData[6], info.spellData[7]) or "none"
    Addon:SystemPrint(string.format(
        "Recipe %d -> prof=%s rank=%d spell=%s(%d) output=%s reagents=[%s]",
        recipeItemID,
        tostring(info.professionID),
        tonumber(info.minRank or 0),
        tostring(info.spellName or "?"),
        tonumber(info.spellID or 0),
        formatOutputDesc(info.createdItemID, info.createdItemName, info.professionID),
        reagents
    ))
end

function Data:DebugSpell(spellID)
    if not spellID then
        Addon:Print("Usage: /rr s <spellID>")
        return
    end
    local info = self:GetAtlasLootSpellInfo(spellID)
    if not info then
        Addon:SystemPrint("No AtlasLoot profession data for spell " .. tostring(spellID))
        return
    end
    Addon:SystemPrint(string.format(
        "Spell %s(%d) -> prof=%s min=%d low=%d high=%d output=%s recipe=%s(%s) num=%d reagents=[%s]",
        tostring(info.spellName or "?"),
        tonumber(info.spellID or 0),
        tostring(info.professionID),
        tonumber(info.minRank or 0),
        tonumber(info.lowRank or 0),
        tonumber(info.highRank or 0),
        formatOutputDesc(info.createdItemID, info.createdItemName, info.professionID),
        tostring(info.recipeItemName or "nil"),
        tostring(info.recipeItemID or "nil"),
        tonumber(info.numCreated or 1),
        formatReagents(info.reagentIDs, info.reagentCounts)
    ))
end

function Data:DebugCreatedItem(createdItemID)
    if not createdItemID then
        Addon:Print("Usage: /rr i <createdItemID>")
        return
    end
    local info = self:GetAtlasLootCreatedItemInfo(createdItemID)
    if not info then
        Addon:SystemPrint(
            "No AtlasLoot craft mapping for created item "
                .. tostring(createdItemID)
                .. ". In TBC many enchanting formulas are direct enchants and do not create an item; use /rr r <recipeItemID> or /rr s <spellID> for those."
        )
        return
    end
    Addon:SystemPrint(string.format(
        "Created item %s(%d) -> spell=%s(%d) recipe=%s(%s)",
        tostring(info.createdItemName or "?"),
        tonumber(createdItemID or 0),
        tostring(info.spellName or "?"),
        tonumber(info.spellID or 0),
        tostring(info.recipeItemName or "nil"),
        tostring(info.recipeItemID or "nil")
    ))
end
