local Addon = _G.RecipeRegistry_Metadata
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

local function cloneCategoryList(list)
    local out = {}
    for index, category in ipairs(list or {}) do
        out[index] = {
            key = category.key,
            label = category.label,
            order = category.order,
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

function RecipeMetadata:GetCategoriesForProfession(professionKey)
    local generatedCategories = self._generated and self._generated.categoriesByProfession
    return cloneCategoryList(generatedCategories and generatedCategories[professionKey] or nil)
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

function RecipeMetadata:_CollectUnresolvedRecords()
    local out = {}
    for _, spellId in ipairs(sortedRecordIds(self._recordsBySpellId)) do
        local record = self._recordsBySpellId[spellId]
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
        if not record.selfOnlyOutputless and record.createdItemId == nil then
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
