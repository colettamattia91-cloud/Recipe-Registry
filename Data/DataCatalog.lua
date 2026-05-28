local Addon = _G.RecipeRegistry
local Data = Addon.Data
local Private = Data._private

local GetItemInfo = GetItemInfo
local GetSpellInfo = GetSpellInfo
local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local tostring = tostring

local getItemData = Private.getItemData
local isValidRecipeKey = Private.isValidRecipeKey
local lowerSafe = Private.lowerSafe
local safeGetItemName = Private.safeGetItemName
local safeGetSpellName = Private.safeGetSpellName
local shouldRefreshItemName = Private.shouldRefreshItemName

local MAX_RECIPE_LIST_CACHE_ENTRIES = 12
local MAX_RECIPE_DETAIL_CACHE_ENTRIES = 256
local RECIPES_PER_LIST_BUILD_STEP = 60
local LIST_BUILD_BUDGET_MS = 3
local MEMBERS_PER_INDEX_BUILD_STEP = 12
local INDEX_BUILD_BUDGET_MS = 3

local PROFESSION_LABELS = {
    alchemy = "Alchemy",
    blacksmithing = "Blacksmithing",
    cooking = "Cooking",
    enchanting = "Enchanting",
    engineering = "Engineering",
    jewelcrafting = "Jewelcrafting",
    leatherworking = "Leatherworking",
    tailoring = "Tailoring",
}

local PROFESSION_IDS = {
    enchanting = 10,
}

local function getRecipeMetadata()
    return Addon.RecipeMetadata
end

local function getMetadataProfessionKey(profession)
    if not profession then return nil end
    if Addon.RecipeUiFilters and Addon.RecipeUiFilters.NormalizeProfessionKey then
        return Addon.RecipeUiFilters:NormalizeProfessionKey(profession)
    end
    local text = tostring(profession)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return lowerSafe(text)
end

local function cloneCategoryRows(rows)
    local out = {}
    for index, row in ipairs(rows or {}) do
        local subcategories = {}
        for subIndex, subcategory in ipairs(row.subcategories or {}) do
            subcategories[subIndex] = {
                key = subcategory.key,
                label = subcategory.label,
                order = subcategory.order,
            }
        end
        out[index] = {
            key = row.key,
            label = row.label,
            order = row.order,
            subcategories = subcategories,
        }
    end
    return out
end

-- Build the per-profession recipe index from a populated content index.
-- This is the inversion of `index[recipeKey].profNames` — a flat list of
-- recipeKeys per profession so the list builder can iterate only the
-- relevant slice instead of walking the entire guild catalog every time
-- the user clicks a profession in the left menu.
local function buildRecipesByProfession(index)
    local byProfession = {}
    for recipeKey, row in pairs(index) do
        local profNames = row.profNames
        if profNames then
            for profName in pairs(profNames) do
                local list = byProfession[profName]
                if not list then
                    list = {}
                    byProfession[profName] = list
                end
                list[#list + 1] = recipeKey
            end
        end
    end
    return byProfession
end

-- Return the candidate recipeKey list to feed the list builder. For a
-- profession-specific view we use the precomputed `_recipesByProfession`
-- slice (typically 10-15× smaller than the global catalog); for "All" /
-- global search / Favorites paths we fall back to materializing every key
-- from the content index. The returned array is always a fresh copy so
-- async jobs holding it as cursor state survive an index rebuild.
local function getRecipeCandidates(data, recipeIndex, profName)
    if profName and profName ~= "All" then
        local scoped = data._recipesByProfession and data._recipesByProfession[profName]
        if scoped then
            local out = {}
            for i = 1, #scoped do
                out[i] = scoped[i]
            end
            return out
        end
        return {}
    end
    local out = {}
    for recipeKey in pairs(recipeIndex) do
        out[#out + 1] = recipeKey
    end
    return out
end

local function getMetadataCategories(metadata, profession)
    if not metadata then return nil end
    local professionKey = getMetadataProfessionKey(profession)
    if not professionKey then return nil end
    if type(metadata.GetCategoriesForProfession) == "function" then
        return metadata:GetCategoriesForProfession(professionKey)
    end
    local generated = metadata._generated or {}
    local rows = cloneCategoryRows(generated.categoriesByProfession and generated.categoriesByProfession[professionKey] or nil)
    local subcategoriesByCategory = generated.subcategoriesByProfession and generated.subcategoriesByProfession[professionKey] or {}
    for _, row in ipairs(rows) do
        row.subcategories = cloneCategoryRows(subcategoriesByCategory[row.key] or nil)
    end
    return rows
end

local function getMetadataCategoryInfoForRecipe(metadata, recipeKey)
    if not metadata then return nil end
    local info = metadata:GetRecipeInfo(recipeKey)
    if not info then return nil end
    return metadata:GetCategory(recipeKey, info)
end

local function getMetadataCategoryForRecipe(metadata, recipeKey)
    local category = getMetadataCategoryInfoForRecipe(metadata, recipeKey)
    return category and category.category or nil
end

local function categoryFilterToken(categoryName)
    if type(categoryName) == "table" then
        if categoryName.filterToken then
            return categoryName.filterToken
        end
        if categoryName.subcategory then
            return "subcategory:" .. tostring(categoryName.key or "") .. ":" .. tostring(categoryName.subcategory)
        end
        return categoryName.key
    end
    return categoryName
end

local function recipeMatchesCategoryFilter(metadata, recipeKey, categoryFilter)
    local token = categoryFilterToken(categoryFilter)
    if not token or token == "" or token == "All" then
        return true
    end

    local category = getMetadataCategoryInfoForRecipe(metadata, recipeKey)
    if not category then
        return false
    end

    local subCategory = tostring(token):match("^subcategory:([^:]+):(.+)$")
    if subCategory then
        local categoryKey, subcategoryKey = tostring(token):match("^subcategory:([^:]+):(.+)$")
        return category.category == categoryKey and category.subcategory == subcategoryKey
    end

    local categoryKey = tostring(token):match("^category:(.+)$") or token
    return category.category == categoryKey
end

local function getItemBindType(itemID)
    if not itemID or type(GetItemInfo) ~= "function" then
        return nil, "unavailable"
    end
    local name = GetItemInfo(itemID)
    if not name then
        return nil, "pending"
    end
    local bindType = select(14, GetItemInfo(itemID))
    if bindType == nil then
        return nil, "unknown"
    end
    return tonumber(bindType), "resolved"
end

local function addMetadataReagents(info, metadata, recipeKey, metadataInfo)
    local reagents = metadata:GetReagents(recipeKey, metadataInfo) or {}
    for _, reagent in ipairs(reagents) do
        local itemID = reagent.itemId
        local reagentName, reagentIcon, reagentQuality = getItemData(itemID)
        info.reagents[#info.reagents + 1] = {
            itemID = itemID,
            count = reagent.count or 1,
            name = reagentName or ("item:" .. tostring(itemID)),
            icon = reagentIcon,
            quality = reagentQuality,
        }
    end
end

local function applyMetadataInfo(info, metadata, recipeKey, numericKey)
    if not metadata then return false end
    local metadataInfo = metadata:GetRecipeInfo(recipeKey)
    if not metadataInfo then return false end

    local spellID = metadataInfo.spellId
    local createdItemID = metadata:GetCreatedItemId(recipeKey, metadataInfo)
    local recipeItemID = metadata:GetRecipeItemId(recipeKey, metadataInfo)
    local professionKey = metadata:GetProfession(recipeKey, metadataInfo)

    info.spellID = spellID
    info.spellName = safeGetSpellName(spellID)
    info.spellIcon = spellID and (GetSpellTexture and GetSpellTexture(spellID) or nil) or nil
    info.createdItemID = createdItemID
    info.recipeItemID = recipeItemID
    info.professionID = PROFESSION_IDS[professionKey]
    info.professionName = PROFESSION_LABELS[professionKey] or professionKey
    info.minRank = metadataInfo.requiredSkill
    info.numCreated = 1
    info.directEnchant = metadata:IsOutputlessSelfOnly(recipeKey, metadataInfo) == true or createdItemID == nil

    addMetadataReagents(info, metadata, recipeKey, metadataInfo)

    if createdItemID then
        local name, icon, quality = getItemData(createdItemID)
        info.createdItemName = name
        info.createdItemIcon = icon
        info.createdItemQuality = quality
    end
    if recipeItemID then
        local name, icon, quality = getItemData(recipeItemID)
        info.recipeItemName = name
        info.recipeItemIcon = icon
        info.recipeItemQuality = quality
    end

    if numericKey and numericKey > 0 then
        info.label = info.createdItemName or info.recipeItemName or info.spellName or ("item:" .. tostring(numericKey))
    else
        info.label = info.spellName or (spellID and ("spell:" .. tostring(spellID))) or tostring(recipeKey)
    end

    return true
end

local function nowMsLocal()
    if type(debugprofilestop) == "function" then
        return debugprofilestop()
    end
    return GetTime() * 1000
end

local function refreshDetailAssets(info)
    if not info then return end

    if info.createdItemID then
        local name, icon, quality = getItemData(info.createdItemID)
        if name then info.createdItemName = name end
        if icon then info.createdItemIcon = icon end
        if quality ~= nil then info.createdItemQuality = quality end
    end

    if info.recipeItemID then
        local name, icon, quality = getItemData(info.recipeItemID)
        if name then info.recipeItemName = name end
        if icon then info.recipeItemIcon = icon end
        if quality ~= nil then info.recipeItemQuality = quality end
    end

    if info.spellID and not info.spellIcon then
        info.spellIcon = GetSpellTexture and GetSpellTexture(info.spellID) or nil
    end

    local changedSearch = false
    for _, reagent in ipairs(info.reagents or {}) do
        local name, icon, quality = getItemData(reagent.itemID)
        if name and shouldRefreshItemName(reagent.name, reagent.itemID) then
            reagent.name = name
            changedSearch = true
        end
        if icon then reagent.icon = icon end
        if quality ~= nil then reagent.quality = quality end
    end

    if info.createdItemID and shouldRefreshItemName(info.createdItemName, info.createdItemID) then
        local name = safeGetItemName(info.createdItemID)
        if name then
            info.createdItemName = name
            changedSearch = true
        end
    end
    if info.recipeItemID and shouldRefreshItemName(info.recipeItemName, info.recipeItemID) then
        local name = safeGetItemName(info.recipeItemID)
        if name then
            info.recipeItemName = name
            changedSearch = true
        end
    end

    if info.isItem and info.createdItemName and shouldRefreshItemName(info.label, info.createdItemID) then
        info.label = info.createdItemName
        changedSearch = true
    elseif info.isSpell and info.spellID then
        local placeholderSpell = "spell:" .. tostring(info.spellID)
        if info.label == placeholderSpell or not info.label or info.label == "" then
            local spellName = info.spellName or safeGetSpellName(info.spellID)
            if spellName then
                info.label = spellName
                info.spellName = spellName
                changedSearch = true
            end
        end
    end

    if changedSearch then
        local parts = {
            info.label or "",
            info.spellName or "",
            info.createdItemName or "",
            info.recipeItemName or "",
        }
        info.recipeSearchText = lowerSafe(table.concat(parts, " "))
        for _, reagent in ipairs(info.reagents or {}) do
            parts[#parts + 1] = reagent.name or ""
        end
        info.searchText = lowerSafe(table.concat(parts, " "))
    end
end

local function rememberBoundedCache(cache, order, key, value, maxEntries)
    if cache[key] == nil then
        order[#order + 1] = key
        if #order > maxEntries then
            local evictedKey = table.remove(order, 1)
            cache[evictedKey] = nil
        end
    end
    cache[key] = value
end

-- Presence-free crafter ordering used by the build path. The live `online`
-- tiebreaker now happens in GetRecipeCrafters where we have access to the
-- current online cache; this stored-row sort just gives a stable initial
-- ordering by content (skillRank, then key).
local function sortCrafterRowsByContent(rows)
    sort(rows, function(a, b)
        if (a.skillRank or 0) ~= (b.skillRank or 0) then return (a.skillRank or 0) > (b.skillRank or 0) end
        if a.memberKey ~= b.memberKey then return a.memberKey < b.memberKey end
        return tostring(a.profession) < tostring(b.profession)
    end)
end

local function getCatalogDiagnostics(data)
    data._catalogDiagnostics = data._catalogDiagnostics or {
        duplicateCrafterRowsDetected = 0,
        duplicateCrafterRowsCollapsed = 0,
        lastDuplicateRecipeKey = nil,
        lastDuplicateMemberKey = nil,
    }
    return data._catalogDiagnostics
end

local function getFilterCacheKey(filterContext)
    if Addon.RecipeUiFilters and Addon.RecipeUiFilters.BuildFilterCacheKey then
        return Addon.RecipeUiFilters:BuildFilterCacheKey(filterContext)
    end
    return "filters=unavailable"
end

local function recipePassesUiFilter(recipeKey, filterContext)
    if Addon.RecipeUiFilters and Addon.RecipeUiFilters.RecipePasses then
        return Addon.RecipeUiFilters:RecipePasses(recipeKey, nil, filterContext)
    end
    return true, "visible-no-filter"
end

-- Duplicate-row tiebreaker used during build. Both rows are for the SAME
-- member (same recipe seen in two professions), so live presence is the
-- same on both — only content fields decide which copy survives.
local function isBetterCrafterRow(candidate, current)
    if not current then return true end
    if (candidate.skillRank or 0) ~= (current.skillRank or 0) then
        return (candidate.skillRank or 0) > (current.skillRank or 0)
    end
    if (candidate.skillMaxRank or 0) ~= (current.skillMaxRank or 0) then
        return (candidate.skillMaxRank or 0) > (current.skillMaxRank or 0)
    end
    if tostring(candidate.profession or "") ~= tostring(current.profession or "") then
        return tostring(candidate.profession or "") < tostring(current.profession or "")
    end
    return (candidate.updatedAt or 0) > (current.updatedAt or 0)
end

function Data:GetCatalogDiagnostics()
    return getCatalogDiagnostics(self)
end

function Data:ResetCatalogDiagnostics()
    self._catalogDiagnostics = nil
end

function Data:GetRecipeCategory(recipeKey, profession)
    local metadata = getRecipeMetadata()
    if metadata then
        return getMetadataCategoryForRecipe(metadata, recipeKey)
    end
    return nil
end

function Data:GetRecipeCategoryInfo(recipeKey, profession)
    local metadata = getRecipeMetadata()
    if metadata then
        return getMetadataCategoryInfoForRecipe(metadata, recipeKey)
    end
    return nil
end

function Data:GetRecipeCategories(profession, includeEmpty)
    local metadata = getRecipeMetadata()
    if metadata then
        return cloneCategoryRows(getMetadataCategories(metadata, profession))
    end
    return {}
end

-- Like GetRecipeCategories, but pruned to the categories/subcategories that
-- actually contain at least one recipe visible under the active UI filters.
-- The sidebar uses this so expansion/BoP filters that hide every recipe in a
-- category also hide that category's button: the filtered projection drives
-- the tree, never the static taxonomy alone (UI-only filter contract).
--
-- Cached by profession + filter cache key. That key already folds in metadata
-- version, ownership generation, and the profession's effective expansion
-- visibility, so a filter change yields a new key and stale entries fall out
-- of the bounded cache without explicit invalidation.
function Data:GetVisibleRecipeCategories(profession, filterContext)
    local metadata = getRecipeMetadata()
    if not metadata then
        return {}
    end
    local fullRows = getMetadataCategories(metadata, profession)
    if not fullRows or #fullRows == 0 then
        return {}
    end

    local filtersModule = Addon.RecipeUiFilters
    local visibility = (filtersModule
        and filtersModule.GetEffectiveExpansionVisibility
        and filtersModule:GetEffectiveExpansionVisibility(profession))
        or { vanilla = true, tbc = true }

    local professionKey = getMetadataProfessionKey(profession)
    if not professionKey then
        return fullRows
    end
    local tree = metadata._navTree
    if not tree then
        return fullRows
    end

    -- Build the owned spell-id set for this profession by intersecting the
    -- guild's recipe slice with the metadata catalogue. The sidebar prune
    -- below uses this set so categories the user has nothing in are hidden
    -- (the previous nav-tree-only prune answered "the dataset has recipes
    -- here" which surfaced empty buttons for content the user didn't own).
    -- Touch the recipe index so `_recipesByProfession` reflects the current
    -- members DB (the prune runs from a stable cached slice; an outdated
    -- index would silently hide categories the user actually owns).
    self:GetRecipeIndex()
    local ownedSpellIds = {}
    local recipesByProf = self._recipesByProfession or {}
    local slice = recipesByProf[profession]
    if slice then
        for i = 1, #slice do
            local info = metadata:GetRecipeInfo(slice[i])
            if info and info.spellId then
                ownedSpellIds[info.spellId] = true
            end
        end
    end

    local visibleExpansions = {}
    if visibility.vanilla ~= false then visibleExpansions[#visibleExpansions + 1] = "vanilla" end
    if visibility.tbc ~= false then visibleExpansions[#visibleExpansions + 1] = "tbc" end

    local function arrayHasOwned(arr)
        if type(arr) ~= "table" then return false end
        for i = 1, #arr do
            if ownedSpellIds[arr[i]] then return true end
        end
        return false
    end

    local function nodeForCategory(expansion, catKey)
        local profNode = tree[expansion] and tree[expansion][professionKey]
        return profNode and profNode[catKey] or nil
    end

    local function categoryHasOwnedVisible(catKey)
        for _, expansion in ipairs(visibleExpansions) do
            local catNode = nodeForCategory(expansion, catKey)
            if catNode and arrayHasOwned(catNode._all) then return true end
        end
        return false
    end

    local function subcategoryHasOwnedVisible(catKey, subKey)
        for _, expansion in ipairs(visibleExpansions) do
            local catNode = nodeForCategory(expansion, catKey)
            if catNode and arrayHasOwned(catNode[subKey]) then return true end
        end
        return false
    end

    local out = {}
    for _, row in ipairs(fullRows) do
        if categoryHasOwnedVisible(row.key) then
            local subs = {}
            for _, sub in ipairs(row.subcategories or {}) do
                if subcategoryHasOwnedVisible(row.key, sub.key) then
                    subs[#subs + 1] = sub
                end
            end
            row.subcategories = subs
            out[#out + 1] = row
        end
    end
    return out
end

-- Which expansions hold at least one recipe for this profession in the
-- generated metadata. Used by the sidebar to drop professions whose only
-- expansions are currently hidden (e.g. Jewelcrafting in a Vanilla-only
-- view). Backed by the pre-built nav-tree in the metadata module — O(1).
function Data:GetProfessionExpansions(profession)
    local metadata = getRecipeMetadata()
    if not metadata then return nil end
    local key = getMetadataProfessionKey(profession)
    if not key then return nil end
    if metadata.GetProfessionExpansionsFromNav then
        return metadata:GetProfessionExpansionsFromNav(key)
    end
    return { vanilla = false, tbc = false }
end

function Data:ResolveRecipeBopOutput(recipeKey, metadataInfo)
    local metadata = getRecipeMetadata()
    if not metadata then
        return nil, "no-plugin"
    end

    local info = metadataInfo or metadata:GetRecipeInfo(recipeKey)
    if not info then
        return nil, "unresolved"
    end

    local static = metadata:IsBopOutput(recipeKey, info)
    if static ~= nil then
        return static == true, "static"
    end

    local createdItemID = metadata:GetCreatedItemId(recipeKey, info)
    if not createdItemID then
        return nil, "no-created-item"
    end

    local bindType, status = getItemBindType(createdItemID)
    if bindType ~= nil then
        return bindType == 1, "item-info"
    end

    self._pendingBopItemInfoByItemID = self._pendingBopItemInfoByItemID or {}
    local bucket = self._pendingBopItemInfoByItemID[createdItemID]
    if not bucket then
        bucket = {}
        self._pendingBopItemInfoByItemID[createdItemID] = bucket
    end
    bucket[recipeKey] = true
    bucket[tostring(recipeKey)] = true
    return nil, status == "pending" and "pending-item-info" or "unknown-item-bind"
end

function Data:OnMetadataItemInfoReceived(events)
    local pending = self._pendingBopItemInfoByItemID
    if type(pending) ~= "table" then
        return false
    end

    local metadata = getRecipeMetadata()
    local affectedProfessions = {}
    local affected = false
    for itemID in pairs(events or {}) do
        local numericItemID = tonumber(itemID)
        local bucket = numericItemID and pending[numericItemID] or nil
        if bucket then
            pending[numericItemID] = nil
            affected = true
            for recipeKey in pairs(bucket) do
                local info = metadata and metadata:GetRecipeInfo(recipeKey) or nil
                local professionKey = metadata and metadata:GetProfession(recipeKey, info) or nil
                if professionKey then
                    affectedProfessions[professionKey] = true
                end
                if self._recipeDetailCache then
                    self._recipeDetailCache[recipeKey] = nil
                end
            end
        end
    end

    if not affected then
        return false
    end

    local invalidatedAny = false
    for professionKey in pairs(affectedProfessions) do
        invalidatedAny = true
        if self.InvalidateRecipeListCacheForFilter then
            self:InvalidateRecipeListCacheForFilter(professionKey, "item-cache-bop")
        end
    end
    if not invalidatedAny and self.InvalidateRecipeCaches then
        self:InvalidateRecipeCaches("list")
    end
    return true
end

function Data:InvalidateRecipeListCacheForFilter(professionKey, reason)
    self._recipeFilterGenerationByProfession = self._recipeFilterGenerationByProfession or {}
    if not professionKey then
        self._recipeFilterGenerationAll = (self._recipeFilterGenerationAll or 0) + 1
        if self.InvalidateRecipeCaches then
            self:InvalidateRecipeCaches("list")
        end
        return
    end

    self._recipeFilterGenerationByProfession[professionKey] = (self._recipeFilterGenerationByProfession[professionKey] or 0) + 1
    local professionLabel = PROFESSION_LABELS[professionKey] or professionKey
    local professionPrefix = tostring(professionLabel or "") .. "\t"
    local globalPrefix = "\t"

    local cache = self._recipeListCache
    local order = self._recipeListCacheOrder
    if type(cache) ~= "table" then
        return
    end

    for key in pairs(cache) do
        local text = tostring(key)
        if text:sub(1, #professionPrefix) == professionPrefix or text:sub(1, 1) == globalPrefix then
            cache[key] = nil
        end
    end

    if type(order) == "table" then
        local kept = {}
        for _, key in ipairs(order) do
            if cache[key] ~= nil then
                kept[#kept + 1] = key
            end
        end
        self._recipeListCacheOrder = kept
    end
end

function Data:GetProfessionSummary()
    local result = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsUserVisibleMember(memberKey, entry) then
            for profName, prof in pairs(entry.professions or {}) do
                local row = result[profName] or { members = 0, recipes = 0 }
                row.members = row.members + 1
                row.recipes = row.recipes + (prof.count or 0)
                result[profName] = row
            end
        end
    end
    return result
end

function Data:GetMembersForProfession(profName)
    local rows = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        local prof = self:IsUserVisibleMember(memberKey, entry) and entry.professions and entry.professions[profName]
        if prof then
            rows[#rows + 1] = {
                memberKey = memberKey,
                online = self:IsMemberOnline(memberKey),
                skillRank = prof.skillRank or 0,
                skillMaxRank = prof.skillMaxRank or 0,
                recipeCount = prof.count or 0,
                updatedAt = entry.updatedAt or 0,
            }
        end
    end
    sort(rows, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.memberKey < b.memberKey
    end)
    return rows
end

function Data:GetCraftersForItem(itemID)
    local rows = {}
    if not itemID then return rows end
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsUserVisibleMember(memberKey, entry) then
            for profName, prof in pairs(entry.professions or {}) do
                if prof.recipes and prof.recipes[itemID] then
                    rows[#rows + 1] = { memberKey = memberKey, profession = profName, online = self:IsMemberOnline(memberKey) }
                end
            end
        end
    end
    sort(rows, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.memberKey < b.memberKey
    end)
    return rows
end

-- The recipe index is purely a content aggregation: who knows what, at what
-- skill rank, with what specialization. Live presence (`online`,
-- `onlineCount`) is decided at query time against the online cache so the
-- index doesn't have to be rebuilt every time someone in the guild flips
-- their login state.
function Data:BuildRecipeIndex()
    local diagnostics = getCatalogDiagnostics(self)
    local index = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsUserVisibleMember(memberKey, entry) then
            local profs = entry.professions or {}
            for currentProfName, prof in pairs(profs) do
                for recipeKey in pairs(prof.recipes or {}) do
                    if isValidRecipeKey(recipeKey) then
                        local row = index[recipeKey]
                        if not row then
                            row = {
                                recipeKey = recipeKey,
                                profNames = {},
                                crafterRows = {},
                                crafterCount = 0,
                                _seenMembers = {},
                                _crafterByMemberKey = {},
                            }
                            index[recipeKey] = row
                        end

                        row.profNames[currentProfName] = true
                        local crafterRow = {
                            memberKey = memberKey,
                            profession = currentProfName,
                            skillRank = prof.skillRank or 0,
                            skillMaxRank = prof.skillMaxRank or 0,
                            specialization = prof.specialization or nil,
                            updatedAt = entry.updatedAt or 0,
                        }
                        local existingCrafterRow = row._crafterByMemberKey[memberKey]
                        if existingCrafterRow then
                            diagnostics.duplicateCrafterRowsDetected = (diagnostics.duplicateCrafterRowsDetected or 0) + 1
                            diagnostics.duplicateCrafterRowsCollapsed = (diagnostics.duplicateCrafterRowsCollapsed or 0) + 1
                            diagnostics.lastDuplicateRecipeKey = recipeKey
                            diagnostics.lastDuplicateMemberKey = memberKey
                            if Addon.Sync and Addon.Sync.telemetry then
                                Addon.Sync.telemetry.duplicateCrafterRowsDetected = (Addon.Sync.telemetry.duplicateCrafterRowsDetected or 0) + 1
                                Addon.Sync.telemetry.duplicateCrafterRowsCollapsed = (Addon.Sync.telemetry.duplicateCrafterRowsCollapsed or 0) + 1
                                Addon.Sync.telemetry.lastDuplicateRecipeKey = recipeKey
                                Addon.Sync.telemetry.lastDuplicateMemberKey = memberKey
                            end
                            if isBetterCrafterRow(crafterRow, existingCrafterRow) then
                                for key, value in pairs(crafterRow) do
                                    existingCrafterRow[key] = value
                                end
                            end
                        else
                            row.crafterRows[#row.crafterRows + 1] = crafterRow
                            row._crafterByMemberKey[memberKey] = crafterRow
                        end

                        if not row._seenMembers[memberKey] then
                            row._seenMembers[memberKey] = true
                            row.crafterCount = row.crafterCount + 1
                        end
                    end
                end
            end
        end
    end

    for _, row in pairs(index) do
        sortCrafterRowsByContent(row.crafterRows)
        row._seenMembers = nil
        row._crafterByMemberKey = nil
    end

    self._recipeIndex = index
    self._recipesByProfession = buildRecipesByProfession(index)
    return index
end

function Data:GetRecipeIndex()
    return self._recipeIndex or self:BuildRecipeIndex()
end

-- Public accessor for the per-profession recipe slice. Returns the live
-- array; callers must not mutate it. Returns nil when no member is known
-- for the profession (distinct from an empty result — empty would mean
-- "profession exists, no recipes match").
function Data:GetRecipeKeysForProfession(profName)
    if not profName then return nil end
    if not self._recipeIndex then
        self:BuildRecipeIndex()
    end
    return self._recipesByProfession and self._recipesByProfession[profName] or nil
end

-- Chunked counterpart to BuildRecipeIndex. The synchronous version walks
-- members × professions × recipes in one go; on large guild rosters that's
-- a multi-hundred-ms freeze that the UI's async list builder would otherwise
-- pay on first call. Cache hit fires onComplete inline; cache miss runs via
-- Performance:ScheduleJob, processing ~12 members per step. Multiple callers
-- (e.g., two near-simultaneous RefreshRecipeList invocations) coalesce onto
-- the same job — only the first kicks it off, the rest queue their callback.
function Data:BuildRecipeIndexAsync(onComplete)
    if self._recipeIndex then
        if onComplete then onComplete(self._recipeIndex) end
        return
    end

    if self._recipeIndexBuildCallbacks then
        if onComplete then
            self._recipeIndexBuildCallbacks[#self._recipeIndexBuildCallbacks + 1] = onComplete
        end
        return
    end

    self._recipeIndexBuildCallbacks = onComplete and { onComplete } or {}

    if not (Addon.Performance and Addon.Performance.ScheduleJob) then
        local index = self:BuildRecipeIndex()
        local callbacks = self._recipeIndexBuildCallbacks
        self._recipeIndexBuildCallbacks = nil
        for _, cb in ipairs(callbacks) do
            if cb then cb(index) end
        end
        return
    end

    local memberKeys = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsUserVisibleMember(memberKey, entry) then
            memberKeys[#memberKeys + 1] = memberKey
        end
    end

    local jobState = {
        memberKeys = memberKeys,
        cursor = 1,
        index = {},
        indexGenerationAtStart = self._recipeIndexGeneration or 0,
    }

    Addon.Performance:ScheduleJob("recipe-index-build", function(state, ctx)
        return self:RunRecipeIndexBuildStep(state, ctx)
    end, {
        -- "ui-data" is intentionally distinct from "ui": SyncPausePolicy
        -- pauses "ui" in combat/instance to keep tooltip rebuilds quiet
        -- during heavy moments. The recipe data builders run with a tiny
        -- per-step budget (~3 ms) and are the only thing standing between
        -- the user and a usable Recipe Registry window — pausing them in
        -- a dungeon would leave the panel stuck on "Loading..." forever.
        category = "ui-data",
        label = "recipe-index-build",
        budgetMs = INDEX_BUILD_BUDGET_MS,
        state = jobState,
    })
end

function Data:RunRecipeIndexBuildStep(state, ctx)
    local budgetMs = (ctx and ctx.budgetMs) or INDEX_BUILD_BUDGET_MS
    local startedAt = nowMsLocal()
    local processed = 0
    local memberKeys = state.memberKeys
    local total = #memberKeys
    local index = state.index
    local diagnostics = getCatalogDiagnostics(self)

    while state.cursor <= total do
        local memberKey = memberKeys[state.cursor]
        state.cursor = state.cursor + 1
        local entry = self:GetMember(memberKey)
        if entry and self:IsUserVisibleMember(memberKey, entry) then
            local profs = entry.professions or {}
            for currentProfName, prof in pairs(profs) do
                for recipeKey in pairs(prof.recipes or {}) do
                    if isValidRecipeKey(recipeKey) then
                        local row = index[recipeKey]
                        if not row then
                            row = {
                                recipeKey = recipeKey,
                                profNames = {},
                                crafterRows = {},
                                crafterCount = 0,
                                _seenMembers = {},
                                _crafterByMemberKey = {},
                            }
                            index[recipeKey] = row
                        end

                        row.profNames[currentProfName] = true
                        local crafterRow = {
                            memberKey = memberKey,
                            profession = currentProfName,
                            skillRank = prof.skillRank or 0,
                            skillMaxRank = prof.skillMaxRank or 0,
                            specialization = prof.specialization or nil,
                            updatedAt = entry.updatedAt or 0,
                        }
                        local existingCrafterRow = row._crafterByMemberKey[memberKey]
                        if existingCrafterRow then
                            diagnostics.duplicateCrafterRowsDetected = (diagnostics.duplicateCrafterRowsDetected or 0) + 1
                            diagnostics.duplicateCrafterRowsCollapsed = (diagnostics.duplicateCrafterRowsCollapsed or 0) + 1
                            diagnostics.lastDuplicateRecipeKey = recipeKey
                            diagnostics.lastDuplicateMemberKey = memberKey
                            if Addon.Sync and Addon.Sync.telemetry then
                                Addon.Sync.telemetry.duplicateCrafterRowsDetected = (Addon.Sync.telemetry.duplicateCrafterRowsDetected or 0) + 1
                                Addon.Sync.telemetry.duplicateCrafterRowsCollapsed = (Addon.Sync.telemetry.duplicateCrafterRowsCollapsed or 0) + 1
                                Addon.Sync.telemetry.lastDuplicateRecipeKey = recipeKey
                                Addon.Sync.telemetry.lastDuplicateMemberKey = memberKey
                            end
                            if isBetterCrafterRow(crafterRow, existingCrafterRow) then
                                for key, value in pairs(crafterRow) do
                                    existingCrafterRow[key] = value
                                end
                            end
                        else
                            row.crafterRows[#row.crafterRows + 1] = crafterRow
                            row._crafterByMemberKey[memberKey] = crafterRow
                        end

                        if not row._seenMembers[memberKey] then
                            row._seenMembers[memberKey] = true
                            row.crafterCount = row.crafterCount + 1
                        end
                    end
                end
            end
        end
        processed = processed + 1
        if processed >= MEMBERS_PER_INDEX_BUILD_STEP then
            return true, state
        end
        if (nowMsLocal() - startedAt) >= budgetMs then
            return true, state
        end
    end

    for _, row in pairs(index) do
        sortCrafterRowsByContent(row.crafterRows)
        row._seenMembers = nil
        row._crafterByMemberKey = nil
    end

    local byProfession = buildRecipesByProfession(index)

    -- Only abandon the build if the INDEX was invalidated (metadata/full
    -- scope). Presence/list invalidations leave content untouched so the
    -- partial index we just assembled is still valid; the list builder
    -- that depends on it has its own _recipeListCacheGeneration check.
    local currentGeneration = self._recipeIndexGeneration or 0
    if currentGeneration ~= (state.indexGenerationAtStart or 0) then
        local callbacks = self._recipeIndexBuildCallbacks
        self._recipeIndexBuildCallbacks = nil
        if callbacks then
            for _, cb in ipairs(callbacks) do
                if cb then cb(nil) end
            end
        end
        return false, state
    end

    self._recipeIndex = index
    self._recipesByProfession = byProfession
    local callbacks = self._recipeIndexBuildCallbacks
    self._recipeIndexBuildCallbacks = nil
    if callbacks then
        for _, cb in ipairs(callbacks) do
            if cb then cb(index) end
        end
    end
    return false, state
end

function Data:ResolveRecipeLabel(recipeKey)
    if not recipeKey then return nil end
    local n = tonumber(recipeKey)
    if not n then return nil end

    local metadata = getRecipeMetadata()
    if metadata then
        local metadataInfo = metadata:GetRecipeInfo(recipeKey)
        if metadataInfo then
            if n > 0 then
                local createdItemID = metadata:GetCreatedItemId(recipeKey, metadataInfo)
                local recipeItemID = metadata:GetRecipeItemId(recipeKey, metadataInfo)
                local itemName = createdItemID and GetItemInfo(createdItemID) or nil
                itemName = itemName or (recipeItemID and GetItemInfo(recipeItemID) or nil)
                if itemName then return itemName end
            end
            local spellID = metadataInfo.spellId
            local spellName = spellID and GetSpellInfo(spellID) or nil
            if spellName then return spellName end
        end
    end

    if n > 0 then
        local itemName = GetItemInfo(n)
        if itemName then return itemName end
    else
        local spellName = GetSpellInfo(-n)
        if spellName then return spellName end
    end

    return nil
end

function Data:GetRecipeDisplayInfo(recipeKey)
    if recipeKey == nil then return nil end
    self._recipeDetailCache = self._recipeDetailCache or {}
    self._recipeDetailCacheOrder = self._recipeDetailCacheOrder or {}
    local cached = self._recipeDetailCache[recipeKey]
    if cached then
        refreshDetailAssets(cached)
        return cached
    end

    local n = tonumber(recipeKey)
    local info = {
        recipeKey = recipeKey,
        numericKey = n,
        isSpell = n and n < 0 or false,
        isItem = n and n > 0 or false,
        spellID = nil,
        spellName = nil,
        createdItemID = nil,
        createdItemName = nil,
        recipeItemID = nil,
        recipeItemName = nil,
        professionID = nil,
        professionName = nil,
        minRank = nil,
        lowRank = nil,
        highRank = nil,
        reagents = {},
        numCreated = 1,
        directEnchant = false,
        label = nil,
        searchText = nil,
    }

    local metadata = getRecipeMetadata()
    applyMetadataInfo(info, metadata, recipeKey, n)

    if n and n < 0 then
        if not info.spellID then
            info.spellID = -n
        end
        if not info.spellName then
            info.spellName = safeGetSpellName(info.spellID)
        end
        if not info.spellIcon and info.spellID then
            info.spellIcon = GetSpellTexture and GetSpellTexture(info.spellID) or nil
        end
        info.label = info.spellName or safeGetSpellName(-n) or ("spell:" .. tostring(-n))
    elseif n and n > 0 then
        info.createdItemID = info.createdItemID or n
        local currentName, currentIcon, currentQuality = getItemData(info.createdItemID)
        info.createdItemName = info.createdItemName or currentName
        info.createdItemIcon = info.createdItemIcon or currentIcon
        if currentQuality ~= nil then info.createdItemQuality = currentQuality end
        info.label = info.label or info.createdItemName or ("item:" .. tostring(n))
    else
        info.label = tostring(recipeKey)
    end

    local parts = {
        info.label or "",
        info.spellName or "",
        info.createdItemName or "",
        info.recipeItemName or "",
    }
    info.recipeSearchText = lowerSafe(table.concat(parts, " "))
    for _, reagent in ipairs(info.reagents) do
        parts[#parts + 1] = reagent.name or ""
    end
    info.searchText = lowerSafe(table.concat(parts, " "))
    refreshDetailAssets(info)
    rememberBoundedCache(
        self._recipeDetailCache,
        self._recipeDetailCacheOrder,
        recipeKey,
        info,
        MAX_RECIPE_DETAIL_CACHE_ENTRIES
    )
    return info
end

function Data:GetRecipeList(profName, query, sortMode, searchMode, categoryName, filterContext)
    sortMode = sortMode or "alpha"
    searchMode = searchMode == "materials" and "materials" or "recipe"
    local categoryFilter = categoryFilterToken(categoryName)
    categoryFilter = categoryFilter and categoryFilter ~= "" and categoryFilter ~= "All" and categoryFilter or nil
    -- Out-of-scope professions (Mining, First Aid, Fishing) have no metadata
    -- to filter against; tell RecipePasses to bypass the hide-uncatalogued
    -- gate so their scanned recipes survive the predicate.
    if profName and profName ~= "All" and Addon.RecipeUiFilters and Addon.RecipeUiFilters.IsSupportedProfession then
        local profKey = Addon.RecipeUiFilters:NormalizeProfessionKey(profName)
        if not Addon.RecipeUiFilters:IsSupportedProfession(profKey) then
            filterContext = filterContext or {}
            filterContext.allowUncataloguedRecipes = true
        end
    end
    local filterCacheKey = getFilterCacheKey(filterContext)
    local cacheKey = tostring(profName or "") .. "\t" .. lowerSafe(query) .. "\t" .. tostring(sortMode) .. "\t" .. searchMode .. "\t" .. tostring(categoryFilter or "") .. "\t" .. filterCacheKey
    self._recipeListCache = self._recipeListCache or {}
    self._recipeListCacheOrder = self._recipeListCacheOrder or {}
    if self._recipeListCache[cacheKey] then
        return self._recipeListCache[cacheKey]
    end

    local out = {}
    local q = lowerSafe(query)
    local recipeIndex = self:GetRecipeIndex()
    local candidates = getRecipeCandidates(self, recipeIndex, profName)

    -- Static pre-filter: when an expansion is hidden for this profession,
    -- build a hash of catalogued spell IDs that satisfy the active filter
    -- (and optional category narrowing) directly from the metadata nav-tree.
    -- Candidates whose normalized spell ID is catalogued but absent from
    -- this hash are rejected without paying the per-recipe RecipePasses
    -- expansion check. Uncatalogued candidates fall through to RecipePasses
    -- so spell-keyed out-of-scope recipes (Mining smelting) keep showing
    -- per the conservative policy.
    local listMetadata = getRecipeMetadata()
    local filtersModule = Addon.RecipeUiFilters
    local visibleSpellIdsHash
    if listMetadata and filtersModule
        and profName and profName ~= "All"
        and listMetadata.BuildVisibleSpellIdHash
        and filtersModule.GetEffectiveExpansionVisibility
    then
        local visibility = filtersModule:GetEffectiveExpansionVisibility(profName)
        if visibility and (visibility.vanilla == false or visibility.tbc == false) then
            local catKey, subKey
            if categoryFilter then
                local filterText = tostring(categoryFilter)
                local cat, sub = filterText:match("^subcategory:([^:]+):(.+)$")
                if cat then
                    catKey, subKey = cat, sub
                else
                    catKey = filterText:match("^category:(.+)$") or filterText
                end
            end
            local profKey = filtersModule.NormalizeProfessionKey
                and filtersModule:NormalizeProfessionKey(profName)
                or profName
            visibleSpellIdsHash = listMetadata:BuildVisibleSpellIdHash(profKey, visibility, catKey, subKey)
            -- Empty hash means the profession isn't in metadata at all
            -- (Mining/Fishing) or every expansion is hidden — fall back to the
            -- per-recipe predicate so the conservative path stays correct.
            if visibleSpellIdsHash and not next(visibleSpellIdsHash) then
                visibleSpellIdsHash = nil
            end
        end
    end

    for cIdx = 1, #candidates do
        local recipeKey = candidates[cIdx]
        local indexed = recipeIndex[recipeKey]
        local include = indexed and (not profName or profName == "All")
        if indexed and not include and indexed.profNames[profName] then
            include = true
        end
        if include and categoryFilter and profName and profName ~= "All" then
            include = recipeMatchesCategoryFilter(getRecipeMetadata(), recipeKey, categoryFilter)
        end
        if include and visibleSpellIdsHash then
            -- Use the record's canonical spellId, not just the normalized key.
            -- Normalization sets spellId for any negative key even when no
            -- record exists (e.g. the key was an item ID that happens to look
            -- like a spell); only the actual record proves the recipe is
            -- catalogued and thus subject to the hash filter.
            local info = listMetadata:GetRecipeInfo(recipeKey)
            if info and info.spellId and not visibleSpellIdsHash[info.spellId] then
                include = false
            end
        end
        local visibilityReason
        if include then
            local passes, reason = recipePassesUiFilter(recipeKey, filterContext)
            visibilityReason = reason
            include = passes == true
            if not include then
                Addon:Trace("filters", "recipe hidden", recipeKey, reason)
            end
        end
        if include then
            local detail = self:GetRecipeDisplayInfo(recipeKey)
            -- Compute onlineCount live from the current online cache. The
            -- recipe index no longer carries it (it's a presence-derived
            -- value, not content) so we walk crafterRows here. Cost is
            -- O(crafters-for-this-recipe) — typically 1-5, fast.
            local onlineCount = 0
            local crafterRows = indexed.crafterRows or {}
            for craftIdx = 1, #crafterRows do
                if self:IsMemberOnline(crafterRows[craftIdx].memberKey) then
                    onlineCount = onlineCount + 1
                end
            end
            local row = {
                recipeKey = recipeKey,
                detail = detail,
                label = (detail and detail.label) or self:ResolveRecipeLabel(recipeKey) or tostring(recipeKey),
                crafterCount = indexed.crafterCount or 0,
                onlineCount = onlineCount,
                visibilityReason = visibilityReason,
            }
            row.professionList = {}
            for currentProfName in pairs(indexed.profNames) do
                row.professionList[#row.professionList + 1] = currentProfName
            end
            sort(row.professionList)
            local searchText
            if searchMode == "materials" then
                searchText = row.detail and row.detail.searchText or lowerSafe(row.label)
            else
                searchText = row.detail and row.detail.recipeSearchText or lowerSafe(row.label)
            end
            if q == "" or searchText:find(q, 1, true) then
                out[#out + 1] = row
            end
        end
    end

    sort(out, function(a, b)
        if sortMode == "rarity" then
            local aq = (a.detail and (a.detail.createdItemQuality or a.detail.recipeItemQuality))
            local bq = (b.detail and (b.detail.createdItemQuality or b.detail.recipeItemQuality))
            aq = aq == nil and -1 or aq
            bq = bq == nil and -1 or bq
            if aq ~= bq then return aq > bq end
        end
        local al = lowerSafe(a.label)
        local bl = lowerSafe(b.label)
        if al ~= bl then return al < bl end
        local ao = a.onlineCount or 0
        local bo = b.onlineCount or 0
        if ao ~= bo then return ao > bo end
        local ac = a.crafterCount or 0
        local bc = b.crafterCount or 0
        if ac ~= bc then return ac > bc end
        return tostring(a.recipeKey) < tostring(b.recipeKey)
    end)

    rememberBoundedCache(
        self._recipeListCache,
        self._recipeListCacheOrder,
        cacheKey,
        out,
        MAX_RECIPE_LIST_CACHE_ENTRIES
    )
    return out
end

-- Build a recipe list asynchronously, spreading the per-recipe work across
-- multiple frames via the job scheduler. The freeze on first /show after a
-- /reload came from this loop running synchronously: ~hundreds of
-- GetRecipeDisplayInfo calls + a full sort, blocking the main thread for
-- seconds on large guild rosters. Cached results take the fast path and
-- fire onComplete inline (so cache hits feel synchronous to the caller).
--
-- Cache misses run via Performance:ScheduleJob with a per-step budget; the
-- caller shows a "Loading..." placeholder while the build progresses. The
-- caller uses a generation token to discard the callback if the filter
-- changed mid-build, so the wasted work is bounded to the time already spent.
function Data:BuildRecipeListAsync(profName, query, sortMode, searchMode, categoryName, filterContext, onComplete)
    if type(filterContext) == "function" and onComplete == nil then
        onComplete = filterContext
        filterContext = nil
    end
    sortMode = sortMode or "alpha"
    searchMode = searchMode == "materials" and "materials" or "recipe"
    local categoryFilter = categoryFilterToken(categoryName)
    categoryFilter = categoryFilter and categoryFilter ~= "" and categoryFilter ~= "All" and categoryFilter or nil
    if profName and profName ~= "All" and Addon.RecipeUiFilters and Addon.RecipeUiFilters.IsSupportedProfession then
        local profKey = Addon.RecipeUiFilters:NormalizeProfessionKey(profName)
        if not Addon.RecipeUiFilters:IsSupportedProfession(profKey) then
            filterContext = filterContext or {}
            filterContext.allowUncataloguedRecipes = true
        end
    end
    local filterCacheKey = getFilterCacheKey(filterContext)
    local cacheKey = tostring(profName or "") .. "\t" .. lowerSafe(query) .. "\t" .. tostring(sortMode) .. "\t" .. searchMode .. "\t" .. tostring(categoryFilter or "") .. "\t" .. filterCacheKey
    self._recipeListCache = self._recipeListCache or {}
    self._recipeListCacheOrder = self._recipeListCacheOrder or {}

    if self._recipeListCache[cacheKey] then
        if onComplete then onComplete(self._recipeListCache[cacheKey], true) end
        return
    end

    if not (Addon.Performance and Addon.Performance.ScheduleJob) then
        local rows = self:GetRecipeList(profName, query, sortMode, searchMode, categoryName, filterContext)
        if onComplete then onComplete(rows, false) end
        return
    end

    -- Two-phase async: first ensure the recipe index is built (chunked if
    -- not yet cached), then schedule the list build. The list job inherits
    -- the index that was just produced. If the index callback receives
    -- `nil` (invalidation mid-build) we surface that to the caller so it
    -- can wait for the follow-up RequestRefresh instead of finalizing
    -- against stale data.
    self:BuildRecipeIndexAsync(function(recipeIndex)
        if not recipeIndex then
            if onComplete then onComplete(nil, false) end
            return
        end

        -- The list cache may have been nulled by an InvalidateRecipeCaches
        -- call between the BuildRecipeListAsync entry and this callback;
        -- re-init defensively before the lookup. Cache hit here happens if
        -- a peer caller raced ahead and finished the same cacheKey.
        self._recipeListCache = self._recipeListCache or {}
        self._recipeListCacheOrder = self._recipeListCacheOrder or {}
        if self._recipeListCache[cacheKey] then
            if onComplete then onComplete(self._recipeListCache[cacheKey], true) end
            return
        end

        local candidates = getRecipeCandidates(self, recipeIndex, profName)

        -- Pre-compute the visible-spell-ids hash once for the whole async
        -- build so each step skips RecipePasses on catalogued recipes that
        -- can't possibly pass the active expansion filter. See the matching
        -- block in GetRecipeList for the rationale.
        local listMetadata = getRecipeMetadata()
        local filtersModule = Addon.RecipeUiFilters
        local visibleSpellIdsHash
        if listMetadata and filtersModule
            and profName and profName ~= "All"
            and listMetadata.BuildVisibleSpellIdHash
            and filtersModule.GetEffectiveExpansionVisibility
        then
            local visibility = filtersModule:GetEffectiveExpansionVisibility(profName)
            if visibility and (visibility.vanilla == false or visibility.tbc == false) then
                local catKey, subKey
                if categoryFilter then
                    local filterText = tostring(categoryFilter)
                    local cat, sub = filterText:match("^subcategory:([^:]+):(.+)$")
                    if cat then
                        catKey, subKey = cat, sub
                    else
                        catKey = filterText:match("^category:(.+)$") or filterText
                    end
                end
                local profKey = filtersModule.NormalizeProfessionKey
                    and filtersModule:NormalizeProfessionKey(profName)
                    or profName
                visibleSpellIdsHash = listMetadata:BuildVisibleSpellIdHash(profKey, visibility, catKey, subKey)
                if visibleSpellIdsHash and not next(visibleSpellIdsHash) then
                    visibleSpellIdsHash = nil
                end
            end
        end

        local jobState = {
            candidates = candidates,
            recipeIndex = recipeIndex,
            cursor = 1,
            out = {},
            visibleSpellIdsHash = visibleSpellIdsHash,
            listMetadata = listMetadata,
            q = lowerSafe(query),
            profName = profName,
            categoryFilter = categoryFilter,
            searchMode = searchMode,
            sortMode = sortMode,
            cacheKey = cacheKey,
            filterContext = filterContext,
            filterCacheKey = filterCacheKey,
            cacheGenerationAtStart = self._recipeListCacheGeneration or 0,
            onComplete = onComplete,
        }

        Addon.Performance:ScheduleJob("recipe-list-build", function(state, ctx)
            return self:RunRecipeListBuildStep(state, ctx)
        end, {
            category = "ui-data",
            label = "recipe-list-build",
            budgetMs = LIST_BUILD_BUDGET_MS,
            state = jobState,
        })
    end)
end

function Data:RunRecipeListBuildStep(state, ctx)
    local budgetMs = (ctx and ctx.budgetMs) or LIST_BUILD_BUDGET_MS
    local startedAt = nowMsLocal()
    local processedThisStep = 0

    local candidates = state.candidates
    local recipeIndex = state.recipeIndex
    local out = state.out
    local profName = state.profName
    local categoryFilter = state.categoryFilter
    local searchMode = state.searchMode
    local filterContext = state.filterContext
    local q = state.q
    local total = #candidates
    local visibleSpellIdsHash = state.visibleSpellIdsHash
    local listMetadata = state.listMetadata

    while state.cursor <= total do
        local recipeKey = candidates[state.cursor]
        state.cursor = state.cursor + 1
        processedThisStep = processedThisStep + 1

        local indexed = recipeIndex[recipeKey]
        if indexed then
            local include = (not profName or profName == "All")
            local visibilityReason
            if not include and indexed.profNames[profName] then
                include = true
            end
            if include and categoryFilter and profName and profName ~= "All" then
                include = recipeMatchesCategoryFilter(getRecipeMetadata(), recipeKey, categoryFilter)
            end
            if include and visibleSpellIdsHash and listMetadata then
                -- See the matching block in GetRecipeList for why we look up
                -- the record explicitly instead of trusting the normalized
                -- spellId alone.
                local info = listMetadata:GetRecipeInfo(recipeKey)
                if info and info.spellId and not visibleSpellIdsHash[info.spellId] then
                    include = false
                end
            end
            if include then
                local passes, reason = recipePassesUiFilter(recipeKey, filterContext)
                visibilityReason = reason
                include = passes == true
                if not include then
                    Addon:Trace("filters", "recipe hidden", recipeKey, reason)
                end
            end
            if include then
                local detail = self:GetRecipeDisplayInfo(recipeKey)
                local onlineCount = 0
                local crafterRows = indexed.crafterRows or {}
                for craftIdx = 1, #crafterRows do
                    if self:IsMemberOnline(crafterRows[craftIdx].memberKey) then
                        onlineCount = onlineCount + 1
                    end
                end
                local row = {
                    recipeKey = recipeKey,
                    detail = detail,
                    label = (detail and detail.label) or self:ResolveRecipeLabel(recipeKey) or tostring(recipeKey),
                    crafterCount = indexed.crafterCount or 0,
                    onlineCount = onlineCount,
                    visibilityReason = visibilityReason,
                }
                row.professionList = {}
                for currentProfName in pairs(indexed.profNames) do
                    row.professionList[#row.professionList + 1] = currentProfName
                end
                sort(row.professionList)
                local searchText
                if searchMode == "materials" then
                    searchText = row.detail and row.detail.searchText or lowerSafe(row.label)
                else
                    searchText = row.detail and row.detail.recipeSearchText or lowerSafe(row.label)
                end
                if q == "" or searchText:find(q, 1, true) then
                    out[#out + 1] = row
                end
            end
        end

        if processedThisStep >= RECIPES_PER_LIST_BUILD_STEP then
            return true, state
        end
        if (nowMsLocal() - startedAt) >= budgetMs then
            return true, state
        end
    end

    local sortMode = state.sortMode
    sort(out, function(a, b)
        if sortMode == "rarity" then
            local aq = (a.detail and (a.detail.createdItemQuality or a.detail.recipeItemQuality))
            local bq = (b.detail and (b.detail.createdItemQuality or b.detail.recipeItemQuality))
            aq = aq == nil and -1 or aq
            bq = bq == nil and -1 or bq
            if aq ~= bq then return aq > bq end
        end
        local al = lowerSafe(a.label)
        local bl = lowerSafe(b.label)
        if al ~= bl then return al < bl end
        local ao = a.onlineCount or 0
        local bo = b.onlineCount or 0
        if ao ~= bo then return ao > bo end
        local ac = a.crafterCount or 0
        local bc = b.crafterCount or 0
        if ac ~= bc then return ac > bc end
        return tostring(a.recipeKey) < tostring(b.recipeKey)
    end)

    -- If the underlying caches were invalidated mid-build (roster presence
    -- flip, scan completion, etc.) the rows we just assembled may already be
    -- stale. Abandon the result rather than poisoning the cache with it.
    -- The caller's UI generation token already discards the callback in
    -- that situation, so dropping silently is the cleanest contract.
    local currentGeneration = self._recipeListCacheGeneration or 0
    if currentGeneration ~= (state.cacheGenerationAtStart or 0) then
        if state.onComplete then
            state.onComplete(nil, false)
        end
        return false, state
    end

    self._recipeListCache = self._recipeListCache or {}
    self._recipeListCacheOrder = self._recipeListCacheOrder or {}
    local cached = self._recipeListCache[state.cacheKey]
    if not cached then
        rememberBoundedCache(
            self._recipeListCache,
            self._recipeListCacheOrder,
            state.cacheKey,
            out,
            MAX_RECIPE_LIST_CACHE_ENTRIES
        )
    else
        out = cached
    end

    if state.onComplete then
        state.onComplete(out, false)
    end
    return false, state
end

-- Return a fresh crafter list with live `online` flags. The stored rows
-- are presence-free; we copy them here and stamp the current online state
-- so callers (UI detail panel, Tooltip) keep the same shape they had
-- before presence was decoupled from the index. The copy + sort cost is
-- O(crafters-for-this-recipe) — bounded and only paid per query, not per
-- login/logout.
function Data:GetRecipeCrafters(recipeKey)
    local indexed = self:GetRecipeIndex()[recipeKey]
    local stored = indexed and indexed.crafterRows or nil
    if not stored or #stored == 0 then
        return {}
    end
    local out = {}
    for i = 1, #stored do
        local src = stored[i]
        out[i] = {
            memberKey = src.memberKey,
            profession = src.profession,
            skillRank = src.skillRank,
            skillMaxRank = src.skillMaxRank,
            specialization = src.specialization,
            updatedAt = src.updatedAt,
            online = self:IsMemberOnline(src.memberKey),
        }
    end
    sort(out, function(a, b)
        if a.online ~= b.online then return a.online end
        if (a.skillRank or 0) ~= (b.skillRank or 0) then return (a.skillRank or 0) > (b.skillRank or 0) end
        if a.memberKey ~= b.memberKey then return a.memberKey < b.memberKey end
        return tostring(a.profession) < tostring(b.profession)
    end)
    return out
end

function Data:GetRecipeRequestability(recipeKey, memberKey)
    if recipeKey == nil then
        return false, "missing-recipe"
    end

    local selfKey = self.GetPlayerKey and self:GetPlayerKey() or nil
    if selfKey and memberKey and memberKey == selfKey then
        return false, "current-player"
    end

    local metadata = getRecipeMetadata()
    if not metadata then
        return true, "requestable-no-plugin"
    end

    local info = metadata:GetRecipeInfo(recipeKey)
    if not info then
        return true, "requestable-unresolved"
    end

    if metadata:IsOutputlessSelfOnly(recipeKey, info) == true then
        return false, "not-requestable-self-only"
    end
    local bopOutput = metadata:IsBopOutput(recipeKey, info)
    if bopOutput == nil and self.ResolveRecipeBopOutput then
        bopOutput = self:ResolveRecipeBopOutput(recipeKey, info)
    end
    if bopOutput == true then
        return false, "not-requestable-bop-output"
    end

    return true, "requestable"
end

function Data:GetRecipeDetail(recipeKey)
    local detail = self:GetRecipeDisplayInfo(recipeKey) or { recipeKey = recipeKey, label = tostring(recipeKey) }
    refreshDetailAssets(detail)
    detail.crafters = self:GetRecipeCrafters(recipeKey)
    detail.crafterCount = #detail.crafters
    if Addon.Market and Addon.Market.ApplyRecipeCosts then
        Addon.Market:ApplyRecipeCosts(detail)
    end
    return detail
end

function Data:DumpSummary()
    local totalMembers, totalProfs, totalRecipes = 0, 0, 0
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsUserVisibleMember(memberKey, entry, true) then
            totalMembers = totalMembers + 1
            for _, prof in pairs(entry.professions or {}) do
                totalProfs = totalProfs + 1
                totalRecipes = totalRecipes + (prof.count or 0)
            end
        end
    end
    local s = self:GetLocalSummary()
    Addon:SystemPrint(string.format(
        "Members=%d Professions=%d Recipes=%d | Local owners=%d blocks=%d content=%d updated=%d",
        totalMembers,
        totalProfs,
        totalRecipes,
        s.activeOwnerCount or 0,
        s.activeBlockCount or 0,
        s.activeContentCount or 0,
        s.builtAt or 0
    ))
    local diagnostics = self:GetCatalogDiagnostics()
    Addon:SystemPrint(string.format(
        "Catalog duplicateCrafterRows=%d collapsed=%d lastRecipe=%s lastMember=%s",
        diagnostics.duplicateCrafterRowsDetected or 0,
        diagnostics.duplicateCrafterRowsCollapsed or 0,
        tostring(diagnostics.lastDuplicateRecipeKey or "none"),
        tostring(diagnostics.lastDuplicateMemberKey or "none")
    ))
    self:DumpScanStatus()
end
