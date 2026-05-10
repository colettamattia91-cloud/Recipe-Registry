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
local MAX_RECIPE_DETAIL_CACHE_ENTRIES = 128

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

local function sortCrafterRows(rows)
    sort(rows, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.skillRank ~= b.skillRank then return a.skillRank > b.skillRank end
        if a.memberKey ~= b.memberKey then return a.memberKey < b.memberKey end
        return tostring(a.profession) < tostring(b.profession)
    end)
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

function Data:BuildRecipeIndex()
    local index = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsUserVisibleMember(memberKey, entry) then
            local profs = entry.professions or {}
            local isOnline = self:IsMemberOnline(memberKey)
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
                                onlineCount = 0,
                                _seenMembers = {},
                            }
                            index[recipeKey] = row
                        end

                        row.profNames[currentProfName] = true
                        row.crafterRows[#row.crafterRows + 1] = {
                            memberKey = memberKey,
                            profession = currentProfName,
                            online = isOnline,
                            skillRank = prof.skillRank or 0,
                            skillMaxRank = prof.skillMaxRank or 0,
                            specialization = prof.specialization or nil,
                            updatedAt = entry.updatedAt or 0,
                        }

                        if not row._seenMembers[memberKey] then
                            row._seenMembers[memberKey] = true
                            row.crafterCount = row.crafterCount + 1
                            if isOnline then
                                row.onlineCount = row.onlineCount + 1
                            end
                        end
                    end
                end
            end
        end
    end

    for _, row in pairs(index) do
        sortCrafterRows(row.crafterRows)
        row._seenMembers = nil
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
        info.professionName or "",
    }
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

function Data:GetRecipeList(profName, query, sortMode)
    sortMode = sortMode or "alpha"
    local cacheKey = tostring(profName or "") .. "\t" .. lowerSafe(query) .. "\t" .. tostring(sortMode)
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
        if include then
            local detail = self:GetRecipeDisplayInfo(recipeKey)
            local row = {
                recipeKey = recipeKey,
                detail = detail,
                label = (detail and detail.label) or self:ResolveRecipeLabel(recipeKey) or tostring(recipeKey),
                crafterCount = indexed.crafterCount or 0,
                onlineCount = indexed.onlineCount or 0,
            }
            row.professionList = {}
            for currentProfName in pairs(indexed.profNames) do
                row.professionList[#row.professionList + 1] = currentProfName
            end
            sort(row.professionList)
            local searchText = row.detail and row.detail.searchText or lowerSafe(row.label)
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

function Data:GetRecipeCrafters(recipeKey)
    local indexed = self:GetRecipeIndex()[recipeKey]
    return indexed and indexed.crafterRows or {}
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
        "Members=%d Professions=%d Recipes=%d | Local rev=%d updated=%d",
        totalMembers,
        totalProfs,
        totalRecipes,
        s.rev,
        s.updatedAt
    ))
    self:DumpScanStatus()
end