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

local getAtlasLootProfessionName = Private.getAtlasLootProfessionName
local getItemData = Private.getItemData
local isValidRecipeKey = Private.isValidRecipeKey
local lowerSafe = Private.lowerSafe
local safeGetItemName = Private.safeGetItemName
local safeGetSpellName = Private.safeGetSpellName
local shouldRefreshItemName = Private.shouldRefreshItemName

local MAX_RECIPE_LIST_CACHE_ENTRIES = 12
local MAX_RECIPE_DETAIL_CACHE_ENTRIES = 256

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

    if info.professionID then
        info.professionName = getAtlasLootProfessionName(info.professionID)
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
    return index
end

function Data:GetRecipeIndex()
    return self._recipeIndex or self:BuildRecipeIndex()
end

function Data:ResolveRecipeLabel(recipeKey)
    if not recipeKey then return nil end
    local n = tonumber(recipeKey)
    if not n then return nil end

    if n > 0 then
        local itemName = GetItemInfo(n)
        if itemName then return itemName end
    else
        local spellName = GetSpellInfo(-n)
        if spellName then return spellName end
    end

    if _G.AtlasLoot and type(_G.AtlasLoot) == "table" then
        return nil
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

    if n and n < 0 then
        local atlas = self:GetAtlasLootSpellInfo(-n)
        if atlas then
            info.spellID = atlas.spellID
            info.spellName = atlas.spellName
            info.spellIcon = atlas.spellID and (GetSpellTexture and GetSpellTexture(atlas.spellID) or nil) or nil
            info.createdItemID = atlas.createdItemID
            info.createdItemName = atlas.createdItemName
            info.recipeItemID = atlas.recipeItemID
            info.recipeItemName = atlas.recipeItemName
            info.professionID = atlas.professionID
            info.minRank = atlas.minRank
            info.lowRank = atlas.lowRank
            info.highRank = atlas.highRank
            info.numCreated = atlas.numCreated or 1
            info.directEnchant = atlas.createdItemID == nil and atlas.professionID == 10
            for i = 1, #(atlas.reagentIDs or {}) do
                local reagentID = atlas.reagentIDs[i]
                local reagentName, reagentIcon, reagentQuality = getItemData(reagentID)
                info.reagents[#info.reagents + 1] = {
                    itemID = reagentID,
                    count = (atlas.reagentCounts and atlas.reagentCounts[i]) or 1,
                    name = reagentName or ("item:" .. tostring(reagentID)),
                    icon = reagentIcon,
                    quality = reagentQuality,
                }
            end
        end
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
        local atlas = self:GetAtlasLootCreatedItemInfo(n)
        if atlas then
            info.spellID = atlas.spellID
            info.spellName = atlas.spellName
            info.spellIcon = atlas.spellID and (GetSpellTexture and GetSpellTexture(atlas.spellID) or nil) or nil
            info.createdItemID = atlas.createdItemID
            info.createdItemName = atlas.createdItemName
            info.recipeItemID = atlas.recipeItemID
            info.recipeItemName = atlas.recipeItemName
            info.professionID = atlas.professionID
            info.minRank = atlas.minRank
            info.lowRank = atlas.lowRank
            info.highRank = atlas.highRank
            info.numCreated = atlas.numCreated or 1
            info.directEnchant = atlas.createdItemID == nil and atlas.professionID == 10
            for i = 1, #(atlas.reagentIDs or {}) do
                local reagentID = atlas.reagentIDs[i]
                local reagentName, reagentIcon, reagentQuality = getItemData(reagentID)
                info.reagents[#info.reagents + 1] = {
                    itemID = reagentID,
                    count = (atlas.reagentCounts and atlas.reagentCounts[i]) or 1,
                    name = reagentName or ("item:" .. tostring(reagentID)),
                    icon = reagentIcon,
                    quality = reagentQuality,
                }
            end
        end
        info.createdItemID = info.createdItemID or n
        local currentName, currentIcon, currentQuality = getItemData(info.createdItemID)
        info.createdItemName = info.createdItemName or currentName
        info.createdItemIcon = info.createdItemIcon or currentIcon
        if currentQuality ~= nil then info.createdItemQuality = currentQuality end
        info.label = info.createdItemName or ("item:" .. tostring(n))
    else
        info.label = tostring(recipeKey)
    end

    if info.professionID then
        info.professionName = getAtlasLootProfessionName(info.professionID)
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

function Data:GetRecipeList(profName, query, sortMode, searchMode, categoryName)
    sortMode = sortMode or "alpha"
    searchMode = searchMode == "materials" and "materials" or "recipe"
    local categoryFilter = categoryName and categoryName ~= "" and categoryName ~= "All" and categoryName or nil
    local cacheKey = tostring(profName or "") .. "\t" .. lowerSafe(query) .. "\t" .. tostring(sortMode) .. "\t" .. searchMode .. "\t" .. tostring(categoryFilter or "")
    self._recipeListCache = self._recipeListCache or {}
    self._recipeListCacheOrder = self._recipeListCacheOrder or {}
    if self._recipeListCache[cacheKey] then
        return self._recipeListCache[cacheKey]
    end

    local out = {}
    local q = lowerSafe(query)
    local recipeIndex = self:GetRecipeIndex()
    for recipeKey, indexed in pairs(recipeIndex) do
        local include = (not profName or profName == "All")
        if not include and indexed.profNames[profName] then
            include = true
        end
        if include and categoryFilter and profName and profName ~= "All" then
            include = self:GetRecipeCategory(recipeKey, profName) == categoryFilter
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
