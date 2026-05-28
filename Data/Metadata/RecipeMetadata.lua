local Addon = _G.RecipeRegistry
if not Addon then
    return
end

local generated = _G.RecipeRegistryRecipeMetadata or {}
local overrides = _G.RecipeRegistryRecipeMetadataOverrides or {}

local RecipeMetadata = {
    metadataVersion = generated.metadataVersion,
    schemaVersion = generated.schemaVersion,
    flavor = generated.flavor,
    _generated = generated,
    _overrides = overrides,
    _recordsBySpellId = {},
    _recipeItemToSpellId = {},
    _createdItemToSpellIds = {},
}

local function countTable(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function countOverrideEntries()
    local count = 0
    for _, bucket in pairs(overrides or {}) do
        count = count + countTable(bucket)
    end
    return count
end

local function cloneReagents(reagents)
    if type(reagents) ~= "table" then
        return nil
    end
    local out = {}
    for index, reagent in ipairs(reagents) do
        out[index] = {
            itemId = reagent.itemId,
            count = reagent.count,
        }
    end
    return out
end

local function cloneRecord(spellId, record)
    if type(record) ~= "table" then
        return nil
    end
    return {
        spellId = tonumber(spellId),
        profession = record.profession,
        expansion = record.expansion,
        recipeItemId = record.recipeItemId,
        createdItemId = record.createdItemId,
        category = record.category,
        subcategory = record.subcategory,
        sortOrder = record.sortOrder,
        requiredSkill = record.requiredSkill,
        selfOnlyOutputless = record.selfOnlyOutputless == true,
        bopOutput = record.bopOutput,
        reagents = cloneReagents(record.reagents),
    }
end

local function cloneSpellIdList(list)
    local out = {}
    for index, spellId in ipairs(list or {}) do
        out[index] = spellId
    end
    return out
end

local function cloneSubcategoryList(list)
    local out = {}
    for index, subcategory in ipairs(list or {}) do
        out[index] = {
            key = subcategory.key,
            label = subcategory.label,
            order = subcategory.order,
        }
    end
    return out
end

local function cloneCategoryList(list, subcategoriesByCategory)
    local out = {}
    for index, category in ipairs(list or {}) do
        local key = category.key
        out[index] = {
            key = key,
            label = category.label,
            order = category.order,
            subcategories = cloneSubcategoryList(subcategoriesByCategory and subcategoriesByCategory[key] or nil),
        }
    end
    return out
end

local function sortedRecordIds(records)
    local ids = {}
    for spellId in pairs(records or {}) do
        ids[#ids + 1] = spellId
    end
    table.sort(ids, function(left, right)
        return tonumber(left) < tonumber(right)
    end)
    return ids
end

local function applyOverrides(record)
    if type(record) ~= "table" then
        return
    end
    local spellId = record.spellId

    local expansion = overrides.expansionBySpellId and overrides.expansionBySpellId[spellId]
    if expansion ~= nil then
        record.expansion = expansion
    end

    local createdItemId = overrides.createdItemBySpellId and overrides.createdItemBySpellId[spellId]
    if createdItemId ~= nil then
        record.createdItemId = createdItemId
    end

    local recipeItemId = overrides.recipeItemBySpellId and overrides.recipeItemBySpellId[spellId]
    if recipeItemId ~= nil then
        record.recipeItemId = recipeItemId
    end

    local category = overrides.categoryBySpellId and overrides.categoryBySpellId[spellId]
    if type(category) == "table" then
        if category.category ~= nil then
            record.category = category.category
        end
        if category.subcategory ~= nil then
            record.subcategory = category.subcategory
        end
        if category.sortOrder ~= nil then
            record.sortOrder = category.sortOrder
        end
    end

    local selfOnly = overrides.selfOnlyOutputlessBySpellId and overrides.selfOnlyOutputlessBySpellId[spellId]
    if selfOnly ~= nil then
        record.selfOnlyOutputless = selfOnly == true
    end

    local bopOutput = overrides.bopOutputBySpellId and overrides.bopOutputBySpellId[spellId]
    if bopOutput ~= nil then
        record.bopOutput = bopOutput == true
    elseif record.createdItemId and overrides.bindTypeByCreatedItemId then
        local bindType = overrides.bindTypeByCreatedItemId[record.createdItemId]
        if bindType ~= nil then
            record.bopOutput = tonumber(bindType) == 1
        end
    end
end

local function addCreatedItemIndex(index, createdItemId, spellId)
    if not createdItemId then
        return
    end
    local bucket = index[createdItemId]
    if not bucket then
        bucket = {}
        index[createdItemId] = bucket
    end
    bucket[#bucket + 1] = spellId
end

local function buildNavTreeFromRecords(recordsBySpellId)
    -- Mirror the structure the Python generator emits: a nested map
    -- expansion → profession → category → subcategory keyed by recipe IDs.
    -- Each non-leaf node carries an `_all` array that unions every recipe
    -- under it so the runtime can answer "all recipes for this expansion×
    -- profession" or "all recipes in this category" with a single table get.
    local tree = {}
    for spellId, record in pairs(recordsBySpellId) do
        local expansion = record.expansion
        local profession = record.profession
        if expansion and profession then
            local expNode = tree[expansion]
            if not expNode then
                expNode = {}
                tree[expansion] = expNode
            end
            local profNode = expNode[profession]
            if not profNode then
                profNode = { _all = {} }
                expNode[profession] = profNode
            end
            profNode._all[#profNode._all + 1] = spellId

            local categoryKey = record.category or "misc"
            local catNode = profNode[categoryKey]
            if not catNode then
                catNode = { _all = {} }
                profNode[categoryKey] = catNode
            end
            catNode._all[#catNode._all + 1] = spellId

            local subKey = record.subcategory
            if subKey ~= nil then
                local subList = catNode[subKey]
                if not subList then
                    subList = {}
                    catNode[subKey] = subList
                end
                subList[#subList + 1] = spellId
            end
        end
    end
    for _, expNode in pairs(tree) do
        for _, profNode in pairs(expNode) do
            table.sort(profNode._all)
            for categoryKey, catNode in pairs(profNode) do
                if categoryKey ~= "_all" then
                    table.sort(catNode._all)
                    for subKey, subList in pairs(catNode) do
                        if subKey ~= "_all" then
                            table.sort(subList)
                        end
                    end
                end
            end
        end
    end
    return tree
end

local function overridesAffectClassification(overrideTable)
    if type(overrideTable) ~= "table" then return false end
    -- Only expansion + category overrides change the navTree's shape;
    -- other override buckets (createdItem, recipeItem, bopOutput, etc.) leave
    -- the nav classification unchanged.
    if type(overrideTable.expansionBySpellId) == "table"
        and next(overrideTable.expansionBySpellId) ~= nil then
        return true
    end
    if type(overrideTable.categoryBySpellId) == "table"
        and next(overrideTable.categoryBySpellId) ~= nil then
        return true
    end
    return false
end

function RecipeMetadata:_Rebuild()
    generated = _G.RecipeRegistryRecipeMetadata or generated or {}
    overrides = _G.RecipeRegistryRecipeMetadataOverrides or overrides or {}
    self._generated = generated
    self._overrides = overrides
    self.metadataVersion = generated.metadataVersion
    self.schemaVersion = generated.schemaVersion
    self.flavor = generated.flavor
    self._recordsBySpellId = {}
    self._recipeItemToSpellId = {}
    self._createdItemToSpellIds = {}

    for _, spellId in ipairs(sortedRecordIds(generated.recipesBySpellId)) do
        local record = cloneRecord(spellId, generated.recipesBySpellId[spellId])
        if record then
            applyOverrides(record)
            self._recordsBySpellId[record.spellId] = record
            if record.recipeItemId then
                self._recipeItemToSpellId[record.recipeItemId] = record.spellId
            end
            addCreatedItemIndex(self._createdItemToSpellIds, record.createdItemId, record.spellId)
        end
    end

    for _, spellIds in pairs(self._createdItemToSpellIds) do
        table.sort(spellIds)
    end

    -- Prefer the static nav-tree baked into Generated.lua (fast, no Lua
    -- iteration at load) but fall back to a runtime build when it is absent
    -- (sample fixture) or when runtime overrides change classification.
    if generated.navTree and not overridesAffectClassification(overrides) then
        self._navTree = generated.navTree
    else
        self._navTree = buildNavTreeFromRecords(self._recordsBySpellId)
    end

    return self
end

local function normalizeNumericRecipeKey(recipeKey)
    local numeric = tonumber(recipeKey)
    if not numeric then
        return nil
    end
    return math.floor(numeric)
end

function RecipeMetadata:NormalizeRecipeKey(recipeKey)
    local normalized = {
        recipeKey = recipeKey,
        source = "unknown",
    }

    local numeric = normalizeNumericRecipeKey(recipeKey)
    if not numeric then
        return normalized
    end

    if numeric < 0 then
        local spellId = -numeric
        local record = self._recordsBySpellId[spellId]
        normalized.spellId = spellId
        normalized.source = "spell"
        if record then
            normalized.recipeItemId = record.recipeItemId
            normalized.createdItemId = record.createdItemId
        end
        return normalized
    end

    if numeric == 0 then
        normalized.source = "invalidItem"
        return normalized
    end

    local recipeSpellId = self._recipeItemToSpellId[numeric]
    if recipeSpellId then
        local record = self._recordsBySpellId[recipeSpellId]
        normalized.spellId = recipeSpellId
        normalized.recipeItemId = numeric
        normalized.createdItemId = record and record.createdItemId or nil
        normalized.source = "recipeItem"
        return normalized
    end

    local createdSpellIds = self._createdItemToSpellIds[numeric]
    if createdSpellIds then
        normalized.createdItemId = numeric
        normalized.source = "createdItem"
        if #createdSpellIds == 1 then
            local spellId = createdSpellIds[1]
            local record = self._recordsBySpellId[spellId]
            normalized.spellId = spellId
            normalized.recipeItemId = record and record.recipeItemId or nil
        else
            normalized.ambiguousSpellIds = cloneSpellIdList(createdSpellIds)
        end
        return normalized
    end

    normalized.source = "unknown"
    return normalized
end

function RecipeMetadata:GetRecipeInfo(recipeKey)
    local normalized = self:NormalizeRecipeKey(recipeKey)
    if not normalized.spellId then
        return nil
    end
    return self._recordsBySpellId[normalized.spellId]
end

local function getInfo(self, recipeKey, info)
    if type(info) == "table" then
        return info
    end
    return self:GetRecipeInfo(recipeKey)
end

function RecipeMetadata:GetRecipeExpansion(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.expansion or nil
end

function RecipeMetadata:GetProfession(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.profession or nil
end

function RecipeMetadata:GetCategory(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    if not info or not info.category then
        return nil
    end
    return {
        category = info.category,
        subcategory = info.subcategory,
        sortOrder = info.sortOrder,
    }
end

function RecipeMetadata:GetNavTree()
    return self._navTree
end

-- O(1) presence map: which expansions hold at least one recipe for the
-- given profession. Used by the sidebar to drop professions whose only
-- expansions are filtered away (e.g. Jewelcrafting in a Vanilla-only view).
function RecipeMetadata:GetProfessionExpansionsFromNav(professionKey)
    local tree = self._navTree
    if not tree then return nil end
    return {
        vanilla = tree.vanilla and tree.vanilla[professionKey] ~= nil or false,
        tbc = tree.tbc and tree.tbc[professionKey] ~= nil or false,
    }
end

-- True if `professionKey/categoryKey` holds at least one recipe under any of
-- the visible expansions. `visibility = { vanilla = bool, tbc = bool }`.
function RecipeMetadata:CategoryHasRecipeUnderVisibility(professionKey, categoryKey, visibility)
    local tree = self._navTree
    if not tree or not professionKey or not categoryKey then return false end
    if visibility.vanilla ~= false then
        local node = tree.vanilla and tree.vanilla[professionKey] and tree.vanilla[professionKey][categoryKey]
        if node and node._all and #node._all > 0 then return true end
    end
    if visibility.tbc ~= false then
        local node = tree.tbc and tree.tbc[professionKey] and tree.tbc[professionKey][categoryKey]
        if node and node._all and #node._all > 0 then return true end
    end
    return false
end

-- True if `professionKey/categoryKey/subcategoryKey` holds at least one
-- recipe under any of the visible expansions.
function RecipeMetadata:SubcategoryHasRecipeUnderVisibility(professionKey, categoryKey, subcategoryKey, visibility)
    local tree = self._navTree
    if not tree or not professionKey or not categoryKey or not subcategoryKey then return false end
    if visibility.vanilla ~= false then
        local catNode = tree.vanilla and tree.vanilla[professionKey] and tree.vanilla[professionKey][categoryKey]
        local subList = catNode and catNode[subcategoryKey]
        if type(subList) == "table" and #subList > 0 then return true end
    end
    if visibility.tbc ~= false then
        local catNode = tree.tbc and tree.tbc[professionKey] and tree.tbc[professionKey][categoryKey]
        local subList = catNode and catNode[subcategoryKey]
        if type(subList) == "table" and #subList > 0 then return true end
    end
    return false
end

function RecipeMetadata:GetCategoriesForProfession(professionKey)
    local generatedCategories = self._generated and self._generated.categoriesByProfession
    local generatedSubcategories = self._generated and self._generated.subcategoriesByProfession
    return cloneCategoryList(
        generatedCategories and generatedCategories[professionKey] or nil,
        generatedSubcategories and generatedSubcategories[professionKey] or nil
    )
end

function RecipeMetadata:GetSubcategoriesForProfession(professionKey, categoryKey)
    local generatedSubcategories = self._generated and self._generated.subcategoriesByProfession
    return cloneSubcategoryList(
        generatedSubcategories
            and generatedSubcategories[professionKey]
            and generatedSubcategories[professionKey][categoryKey]
            or nil
    )
end

function RecipeMetadata:GetCreatedItemId(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.createdItemId or nil
end

function RecipeMetadata:GetRecipeItemId(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.recipeItemId or nil
end

function RecipeMetadata:GetReagents(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and cloneReagents(info.reagents) or nil
end

function RecipeMetadata:IsOutputlessSelfOnly(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    return info and info.selfOnlyOutputless == true or false
end

function RecipeMetadata:IsBopOutput(recipeKey, info)
    info = getInfo(self, recipeKey, info)
    if not info then
        return nil
    end
    return info.bopOutput
end

local function addUnresolved(out, spellId, field, severity, message)
    out[#out + 1] = {
        spellId = spellId,
        field = field,
        severity = severity,
        message = message,
    }
end

local function isExpectedOutputless(record)
    return record.selfOnlyOutputless == true
        or (record.profession == "enchanting" and record.createdItemId == nil)
end

function RecipeMetadata:_CollectUnresolvedRecords()
    local out = {}
    for _, spellId in ipairs(sortedRecordIds(self._recordsBySpellId)) do
        local record = self._recordsBySpellId[spellId]
        local expectedOutputless = isExpectedOutputless(record)
        if not record.profession or record.profession == "" then
            addUnresolved(out, spellId, "profession", "release-blocking", "missing profession")
        end
        if record.expansion ~= "vanilla" and record.expansion ~= "tbc" then
            addUnresolved(out, spellId, "expansion", "release-blocking", "missing or unsupported expansion")
        end
        if not record.category or record.category == "" then
            addUnresolved(out, spellId, "category", "release-blocking", "missing category")
        end
        if record.sortOrder == nil then
            addUnresolved(out, spellId, "sortOrder", "release-blocking", "missing sort order")
        end
        if not expectedOutputless and record.createdItemId == nil then
            addUnresolved(out, spellId, "createdItemId", "warning", "missing created item for normal craft")
        end
        if not record.selfOnlyOutputless and (type(record.reagents) ~= "table" or #record.reagents == 0) then
            addUnresolved(out, spellId, "reagents", "warning", "missing reagents")
        end
    end
    return out
end

function RecipeMetadata:GetMetadataResolutionStatus(recipeKey, info)
    local normalized = self:NormalizeRecipeKey(recipeKey)
    if normalized.ambiguousSpellIds then
        return "ambiguous"
    end

    info = getInfo(self, recipeKey, info)
    if not info then
        return "unresolved"
    end

    for _, unresolved in ipairs(self:_CollectUnresolvedRecords()) do
        if unresolved.spellId == info.spellId then
            return "unresolved"
        end
    end

    return "resolved"
end

function RecipeMetadata:GetUnresolvedRecords(severity)
    local out = {}
    for _, unresolved in ipairs(self:_CollectUnresolvedRecords()) do
        if severity == nil or unresolved.severity == severity then
            out[#out + 1] = unresolved
        end
    end
    return out
end

function RecipeMetadata:GetRecordCounts()
    local counts = {
        recipes = 0,
        vanilla = 0,
        tbc = 0,
        unresolved = 0,
        ambiguousCreatedItems = 0,
        recipeItems = countTable(self._recipeItemToSpellId),
        createdItems = countTable(self._createdItemToSpellIds),
        overrides = countOverrideEntries(),
    }

    for _, record in pairs(self._recordsBySpellId or {}) do
        counts.recipes = counts.recipes + 1
        if record.expansion == "vanilla" then
            counts.vanilla = counts.vanilla + 1
        elseif record.expansion == "tbc" then
            counts.tbc = counts.tbc + 1
        end
    end

    for _, spellIds in pairs(self._createdItemToSpellIds or {}) do
        if #spellIds > 1 then
            counts.ambiguousCreatedItems = counts.ambiguousCreatedItems + 1
        end
    end

    counts.unresolved = #self:GetUnresolvedRecords()
    return counts
end

RecipeMetadata:_Rebuild()
Addon.RecipeMetadata = RecipeMetadata
