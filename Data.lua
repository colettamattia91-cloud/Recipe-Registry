local _, _ns = ...
local Addon = _G.RecipeRegistry
local Data = Addon:NewModule("Data", "AceTimer-3.0")
Addon.Data = Data
local Private = Data._private or {}
Data._private = Private

local GetNumSkillLines = GetNumSkillLines
local GetSkillLineInfo = GetSkillLineInfo
local GetNumTradeSkills = GetNumTradeSkills
local GetTradeSkillInfo = GetTradeSkillInfo
local GetTradeSkillItemLink = GetTradeSkillItemLink
local GetTradeSkillRecipeLink = GetTradeSkillRecipeLink
local ExpandTradeSkillSubClass = ExpandTradeSkillSubClass
local GetTradeSkillLine = GetTradeSkillLine
local GetTradeSkillSubClasses = GetTradeSkillSubClasses
local GetTradeSkillSubClassFilter = GetTradeSkillSubClassFilter
local SetTradeSkillSubClassFilter = SetTradeSkillSubClassFilter
local GetTradeSkillInvSlots = GetTradeSkillInvSlots
local GetTradeSkillInvSlotFilter = GetTradeSkillInvSlotFilter
local SetTradeSkillInvSlotFilter = SetTradeSkillInvSlotFilter
local GetTradeSkillItemNameFilter = GetTradeSkillItemNameFilter
local SetTradeSkillItemNameFilter = SetTradeSkillItemNameFilter
local GetTradeSkillItemLevelFilter = GetTradeSkillItemLevelFilter
local SetTradeSkillItemLevelFilter = SetTradeSkillItemLevelFilter
local TradeSkillOnlyShowMakeable = TradeSkillOnlyShowMakeable
local TradeSkillOnlyShowSkillUps = TradeSkillOnlyShowSkillUps
local GetNumCrafts = GetNumCrafts
local GetCraftInfo = GetCraftInfo
local GetCraftItemLink = GetCraftItemLink
local GetCraftRecipeLink = GetCraftRecipeLink
local GetCraftSkillLine = GetCraftSkillLine
local GetCraftDisplaySkillLine = GetCraftDisplaySkillLine
local GetCraftItemNameFilter = GetCraftItemNameFilter
local SetCraftItemNameFilter = SetCraftItemNameFilter
local GetNumGuildMembers = GetNumGuildMembers
local GetGuildRosterInfo = GetGuildRosterInfo
local GetGuildRosterLastOnline = GetGuildRosterLastOnline
local GetItemInfo = GetItemInfo
local GetSpellInfo = GetSpellInfo
local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local tostring = tostring

local KNOWN_OWNER_OFFLINE_STALE_DAYS = 14

local DB_DEFAULTS = {
    global = {
        meta = {
            schemaVersion = 2,
            lastWeeklyCleanupAt = 0,
            lastTrustedRosterCleanupAt = 0,
            bootstrapCompletedAt = 0,
        },
        updateNotice = {
            latestRemoteVersionSeen = nil,
            lastNoticedVersion = nil,
            lastUpdateNoticeAt = 0,
            lastProtocolNoticeAt = 0,
            lastNoticedPeer = nil,
            lastNoticedWireVersion = nil,
        },
        members = {},
    },
    profile = {
        selectedProfession = nil,
        sortMode = "alpha",
        searchMode = "recipe",
        defaultSearchMode = "recipe",
        useRecipeCategories = true,
        mainFrame = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = 0,
            width = 1200,
            height = 750,
        },
        minimap = {
            hide = false,
            minimapPos = 220,
        },
        -- User-tunable sync knobs. Defaults mirror the internal constants in
        -- Sync.lua and are clamped at read time by Sync:GetBlockPullDelay /
        -- :GetMaxInboundSeedSessions / :GetBlockPullResponseTimeout so a bad
        -- SavedVariables value (or a stale config from an old version) can't
        -- push the sync engine outside safe bounds.
        tuning = {
            blockPullDelaySeconds = 2.5,
            maxInboundSeedSessions = 4,
            blockPullResponseTimeoutSeconds = 60,
        },
    },
}

local TRACKED = {
    ["Alchemy"] = true,
    ["Blacksmithing"] = true,
    ["Cooking"] = true,
    ["Enchanting"] = true,
    ["Engineering"] = true,
    ["Herbalism"] = true,
    ["Jewelcrafting"] = true,
    ["Leatherworking"] = true,
    ["Mining"] = true,
    ["Skinning"] = true,
    ["Tailoring"] = true,
}

local PROFESSION_SPELL_IDS = {
    ["Alchemy"] = 2259,
    ["Blacksmithing"] = 2018,
    ["Cooking"] = 2550,
    ["Enchanting"] = 7411,
    ["Engineering"] = 4036,
    ["Herbalism"] = 2366,
    ["Jewelcrafting"] = 25229,
    ["Leatherworking"] = 2108,
    ["Mining"] = 2575,
    ["Skinning"] = 8613,
    ["Tailoring"] = 3908,
}

local TITLE_ALIAS_SPELL_IDS = {
    ["Mining"] = 2656,
}

-- Professions that support specializations in TBC Classic.
-- Each entry maps a specialization display name to the spell ID the player
-- must know in order to have that spec.
local PROFESSION_SPECIALIZATIONS = {
    ["Alchemy"] = {
        { name = "Potion Master",         spellID = 28675 },
        { name = "Elixir Master",         spellID = 28677 },
        { name = "Transmutation Master",  spellID = 28672 },
    },
    ["Blacksmithing"] = {
        { name = "Armorsmith",            spellID = 9788  },
        { name = "Master Axesmith",       spellID = 17041 },
        { name = "Master Hammersmith",    spellID = 17040 },
        { name = "Master Swordsmith",     spellID = 17039 },
        { name = "Weaponsmith",           spellID = 9787  },
    },
    ["Tailoring"] = {
        { name = "Mooncloth Tailoring",   spellID = 26798 },
        { name = "Shadoweave Tailoring",  spellID = 26801 },
        { name = "Spellfire Tailoring",   spellID = 26797 },
    },
    ["Leatherworking"] = {
        { name = "Dragonscale Leatherworking", spellID = 10656 },
        { name = "Elemental Leatherworking",   spellID = 10658 },
        { name = "Tribal Leatherworking",      spellID = 10660 },
    },
    ["Engineering"] = {
        { name = "Gnomish Engineering",   spellID = 20219 },
        { name = "Goblin Engineering",    spellID = 20222 },
    },
}

local localeMap
local recipeValidityCache = {}
local atlasHandlesCache
local atlasProfessionNameCache = {}

local function cloneArray(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for i = 1, #src do
        out[i] = src[i]
    end
    return out
end

local function countRecipeKeys(recipeKeys)
    local count = 0
    for _ in pairs(recipeKeys or {}) do
        count = count + 1
    end
    return count
end

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function cloneTableShallow(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value
    end
    return out
end

local function nowMs()
    if type(debugprofilestop) == "function" then
        return debugprofilestop()
    end
    if type(GetTime) == "function" then
        return GetTime() * 1000
    end
    return 0
end

Private.countRecipeKeys = countRecipeKeys
Private.countKeys = countKeys
Private.cloneTableShallow = cloneTableShallow
Private.nowMs = nowMs

local function cloneAtlasInfo(info)
    if type(info) ~= "table" then return info end
    local out = {}
    for k, v in pairs(info) do
        out[k] = v
    end
    if info.reagentIDs then
        out.reagentIDs = cloneArray(info.reagentIDs)
    end
    if info.reagentCounts then
        out.reagentCounts = cloneArray(info.reagentCounts)
    end
    return out
end

local function getAtlasLootHandles()
    if atlasHandlesCache and atlasHandlesCache.recipe and atlasHandlesCache.profession then
        return atlasHandlesCache.recipe, atlasHandlesCache.profession
    end

    -- Build candidates without nil holes (ipairs stops at first nil).
    local candidates = {}
    if type(_G.AtlasLootClassic) == "table" then
        candidates[#candidates + 1] = _G.AtlasLootClassic
    end
    if type(_G.AtlasLoot) == "table" then
        candidates[#candidates + 1] = _G.AtlasLoot
    end

    for _, atlas in ipairs(candidates) do
        -- Prefer modern shape: AtlasLoot.Data.Recipe / AtlasLoot.Data.Profession
        local data = type(atlas.Data) == "table" and atlas.Data or atlas
        local recipe = data.Recipe
        local profession = data.Profession
        if type(recipe) == "table" and type(profession) == "table" then
            atlasHandlesCache = {
                recipe = recipe,
                profession = profession,
            }
            return recipe, profession
        end
    end

    return nil, nil
end

local function getAtlasLootProfessionName(professionID)
    if not professionID then return nil end
    if atlasProfessionNameCache[professionID] ~= nil then
        return atlasProfessionNameCache[professionID]
    end
    local _, profession = getAtlasLootHandles()
    if profession and type(profession.GetProfessionName) == "function" then
        local name = profession.GetProfessionName(professionID)
        atlasProfessionNameCache[professionID] = name
        return name
    end
    return nil
end

local function safeGetItemName(itemID)
    if not itemID then return nil end
    local itemName = GetItemInfo(itemID)
    return itemName
end

local function safeGetSpellName(spellID)
    if not spellID then return nil end
    return GetSpellInfo(spellID)
end

local function getItemData(itemID)
    if not itemID then return nil, nil, nil, nil end
    local name, link, quality, _, _, _, _, _, _, icon = GetItemInfo(itemID)
    if not icon and GetItemInfoInstant then
        local _, _, _, _, instantIcon = GetItemInfoInstant(itemID)
        icon = instantIcon
    end
    return name, icon, quality, link
end

local function safeGetItemIcon(itemID)
    local _, icon = getItemData(itemID)
    return icon
end

local function shouldRefreshItemName(name, itemID)
    if not itemID then return false end
    if not name or name == "" then return true end
    return name == ("item:" .. tostring(itemID))
end

-- Validates that a recipe key represents a real craft, not a non-craft spell.
-- Positive keys (item-based) are accepted only inside a sane TBC-era numeric
-- range; very large positive values are usually concatenated/corrupt IDs.
-- Negative keys (spell-based) prefer a known AtlasLoot profession mapping.
-- If AtlasLoot is present but misses a mapping, fall back to spell metadata
-- instead of dropping the key immediately; this avoids destructive false
-- negatives when optional data is incomplete.
-- Fallback after AtlasLoot check: check spell subtext for profession rank
-- keywords (Apprentice/Journeyman/Expert/Artisan/Master) which only craft
-- spells have; class spells use "Rank N" or have no subtext.
local CRAFT_RANK_KEYWORDS = {
    ["Apprentice"] = true, ["Journeyman"] = true, ["Expert"] = true,
    ["Artisan"] = true, ["Master"] = true,
}
local MAX_REASONABLE_RECIPE_KEY = 100000000
local function isValidRecipeKey(recipeKey)
    local n = tonumber(recipeKey)
    if not n then return false end
    if recipeValidityCache[n] ~= nil then
        return recipeValidityCache[n]
    end
    if n == 0 or math.abs(n) > MAX_REASONABLE_RECIPE_KEY then
        recipeValidityCache[n] = false
        return false
    end
    if n > 0 then
        recipeValidityCache[n] = true
        return true
    end  -- item-based: always valid
    local _, profession = getAtlasLootHandles()
    if profession and profession.GetProfessionData then
        if profession.GetProfessionData(-n) ~= nil then
            recipeValidityCache[n] = true
            return true
        end
    end
    -- Fallback: check spell subtext for craft rank keywords.
    local spellName = safeGetSpellName(-n)
    if not spellName then
        recipeValidityCache[n] = true
        return true
    end  -- can't resolve spell: benefit of doubt
    local subtext
    if type(GetSpellSubtext) == "function" then
        subtext = GetSpellSubtext(-n)
    elseif type(GetSpellBookItemInfo) ~= "function" then
        -- No API to check subtext: allow through
        return true
    end
    if subtext and CRAFT_RANK_KEYWORDS[subtext] then
        recipeValidityCache[n] = true
        return true
    end
    -- No recognised craft subtext: block it
    recipeValidityCache[n] = false
    return false
end

local function formatReagents(reagentIDs, reagentCounts)
    local parts = {}
    for i = 1, #(reagentIDs or {}) do
        local reagentID = reagentIDs[i]
        local reagentCount = (reagentCounts and reagentCounts[i]) or 1
        local reagentName = safeGetItemName(reagentID) or ("item:" .. tostring(reagentID))
        parts[#parts + 1] = string.format("%s x%d", reagentName, reagentCount)
    end
    return table.concat(parts, ", ")
end

local function detectSpecialization(professionName)
    local specs = PROFESSION_SPECIALIZATIONS[professionName]
    if not specs then return nil end
    for _, spec in ipairs(specs) do
        if IsSpellKnown and IsSpellKnown(spec.spellID) then
            return spec.name
        end
    end
    return nil
end

local function buildLocaleMap()
    localeMap = {}
    for canonical, spellID in pairs(PROFESSION_SPELL_IDS) do
        local localized = GetSpellInfo(spellID)
        if localized then localeMap[localized] = canonical end
    end
    for canonical, spellID in pairs(TITLE_ALIAS_SPELL_IDS) do
        local localized = GetSpellInfo(spellID)
        if localized then localeMap[localized] = canonical end
    end
    localeMap["Smelting"] = "Mining"
end

local function lowerSafe(v)
    if v == nil then return "" end
    return tostring(v):lower()
end

local function extractItemID(link)
    if not link then return nil end
    local rawItemID = link:match("item:(%-?%d+)")
    if not rawItemID then
        if link:find("item:", 1, true) then
            return nil, "item-link"
        end
        return nil
    end
    local itemID = tonumber(rawItemID)
    if itemID and itemID > 0 and itemID <= MAX_REASONABLE_RECIPE_KEY then
        return itemID
    end
    return nil, itemID or rawItemID
end

local function extractSpellID(link)
    if not link then return nil end
    local spellID = link:match("enchant:(%d+)") or link:match("spell:(%d+)")
    return spellID and tonumber(spellID) or nil
end

local function snapshotTradeSkillFilters()
    local state = {
        nameFilter = nil,
        itemLevelMin = nil,
        itemLevelMax = nil,
        subclassIndex = 0,
        invslotIndex = 0,
        onlyMakeable = false,
        onlySkillUps = false,
    }

    -- Name filter: prefer the EditBox widget text as authoritative source.
    -- On reopen, Blizzard restores EditBox text from memory but may not yet have
    -- called OnTextChanged, so GetTradeSkillItemNameFilter() can still return ""
    -- even though the box visually shows the previous filter.
    local filterBox = _G.TradeSkillFilterBox
    local filterBoxText = (filterBox and type(filterBox.GetText) == "function")
        and filterBox:GetText() or nil

    if type(GetTradeSkillItemNameFilter) == "function" then
        local ok, value = pcall(GetTradeSkillItemNameFilter)
        if ok then state.nameFilter = value or "" end
    end

    -- If the EditBox has text but the API filter is empty, Blizzard hasn't applied
    -- the EditBox value yet → take the EditBox text as the real filter.
    if filterBoxText and filterBoxText ~= "" and (state.nameFilter == nil or state.nameFilter == "") then
        state.nameFilter = filterBoxText
    end

    if type(GetTradeSkillItemLevelFilter) == "function" then
        local ok, minLevel, maxLevel = pcall(GetTradeSkillItemLevelFilter)
        if ok then
            state.itemLevelMin = minLevel
            state.itemLevelMax = maxLevel
        end
    end

    -- In TBC Classic SetTradeSkillSubClassFilter takes a single index:
    -- 0 = show all, i = show only subclass i.
    -- Determine whether all are active (0) or a specific one.
    if type(GetTradeSkillSubClasses) == "function" and type(GetTradeSkillSubClassFilter) == "function" then
        local count = select("#", GetTradeSkillSubClasses())
        local activeIndex = 0
        local activeCount = 0
        for i = 1, count do
            if GetTradeSkillSubClassFilter(i) then
                activeCount = activeCount + 1
                activeIndex = i
            end
        end
        state.subclassIndex = (activeCount == count or count == 0) and 0 or activeIndex
    end

    if type(GetTradeSkillInvSlots) == "function" and type(GetTradeSkillInvSlotFilter) == "function" then
        local count = select("#", GetTradeSkillInvSlots())
        local activeIndex = 0
        local activeCount = 0
        for i = 1, count do
            if GetTradeSkillInvSlotFilter(i) then
                activeCount = activeCount + 1
                activeIndex = i
            end
        end
        state.invslotIndex = (activeCount == count or count == 0) and 0 or activeIndex
    end

    -- Snapshot the "Have Materials" checkbox if the Blizzard frame is available.
    local makeableBtn = _G.TradeSkillFrameAvailableFilterCheckButton
    if makeableBtn and type(makeableBtn.GetChecked) == "function" then
        state.onlyMakeable = makeableBtn:GetChecked() and true or false
    end

    -- Snapshot the "Has Skill Up" checkbox.
    local skillUpBtn = _G.TradeSkillFrameFilterSkillUps
    if skillUpBtn and type(skillUpBtn.GetChecked) == "function" then
        state.onlySkillUps = skillUpBtn:GetChecked() and true or false
    end

    return state
end

local function clearTradeSkillFilters()
    -- Clear the EditBox widget first: this triggers OnTextChanged which calls
    -- SetTradeSkillItemNameFilter("") and TradeSkillFrame_Update internally,
    -- keeping the API state and the visual in full sync during the scan.
    local filterBox = _G.TradeSkillFilterBox
    if filterBox and type(filterBox.SetText) == "function" then
        filterBox:SetText("")
    elseif type(SetTradeSkillItemNameFilter) == "function" then
        pcall(SetTradeSkillItemNameFilter, "")
    end
    if type(SetTradeSkillItemLevelFilter) == "function" then
        pcall(SetTradeSkillItemLevelFilter, 0, 0)
    end
    if type(TradeSkillOnlyShowMakeable) == "function" then
        pcall(TradeSkillOnlyShowMakeable, false)
    end
    if type(TradeSkillOnlyShowSkillUps) == "function" then
        pcall(TradeSkillOnlyShowSkillUps, false)
    end
    -- 0 = show all subclasses / inv slots in TBC Classic
    if type(SetTradeSkillSubClassFilter) == "function" then
        pcall(SetTradeSkillSubClassFilter, 0)
    end
    if type(SetTradeSkillInvSlotFilter) == "function" then
        pcall(SetTradeSkillInvSlotFilter, 0)
    end
end

local function restoreTradeSkillFilters(state)
    if not state then return end

    -- Single-index restore: 0 = all, i = specific subclass/slot
    if type(SetTradeSkillSubClassFilter) == "function" then
        pcall(SetTradeSkillSubClassFilter, state.subclassIndex or 0)
    end

    if type(SetTradeSkillInvSlotFilter) == "function" then
        pcall(SetTradeSkillInvSlotFilter, state.invslotIndex or 0)
    end

    if type(SetTradeSkillItemNameFilter) == "function" and state.nameFilter ~= nil then
        pcall(SetTradeSkillItemNameFilter, state.nameFilter)
    end
    -- Restore the EditBox widget and trigger Blizzard's OnTextChanged handler.
    -- This is the authoritative path: the handler calls SetTradeSkillItemNameFilter
    -- and TradeSkillFrame_Update on its own, ensuring the list is actually filtered.
    local filterBox = _G.TradeSkillFilterBox
    if filterBox and type(filterBox.SetText) == "function" then
        filterBox:SetText(state.nameFilter or "")
    end

    if type(SetTradeSkillItemLevelFilter) == "function" and state.itemLevelMin ~= nil and state.itemLevelMax ~= nil then
        pcall(SetTradeSkillItemLevelFilter, state.itemLevelMin, state.itemLevelMax)
    end

    -- Restore "Have Materials" / "Has Skill Up" toggles
    if type(TradeSkillOnlyShowMakeable) == "function" then
        pcall(TradeSkillOnlyShowMakeable, state.onlyMakeable or false)
    end
    if type(TradeSkillOnlyShowSkillUps) == "function" then
        pcall(TradeSkillOnlyShowSkillUps, state.onlySkillUps or false)
    end

    -- Sync the Blizzard checkbox visuals to match the restored state
    local makeableBtn = _G.TradeSkillFrameAvailableFilterCheckButton
    if makeableBtn and type(makeableBtn.SetChecked) == "function" then
        makeableBtn:SetChecked(state.onlyMakeable or false)
    end
    local skillUpBtn = _G.TradeSkillFrameFilterSkillUps
    if skillUpBtn and type(skillUpBtn.SetChecked) == "function" then
        skillUpBtn:SetChecked(state.onlySkillUps or false)
    end

    -- Force Blizzard frame to re-render with the restored filters
    if TradeSkillFrame and TradeSkillFrame:IsShown() and type(TradeSkillFrame_Update) == "function" then
        pcall(TradeSkillFrame_Update)
    end
end

local function snapshotCraftFilters()
    local state = { nameFilter = nil }
    if type(GetCraftItemNameFilter) == "function" then
        local ok, value = pcall(GetCraftItemNameFilter)
        if ok then state.nameFilter = value or "" end
    end
    return state
end

local function clearCraftFilters()
    if type(SetCraftItemNameFilter) == "function" then
        pcall(SetCraftItemNameFilter, "")
    end
end

local function restoreCraftFilters(state)
    if not state then return end
    if type(SetCraftItemNameFilter) == "function" and state.nameFilter ~= nil then
        pcall(SetCraftItemNameFilter, state.nameFilter)
    end
    -- Force Blizzard CraftFrame to re-render with restored filters
    if CraftFrame and CraftFrame:IsShown() and type(CraftFrame_Update) == "function" then
        pcall(CraftFrame_Update)
    end
end

local function isSubsetOf(smaller, bigger)
    for k in pairs(smaller or {}) do
        if not (bigger and bigger[k]) then
            return false
        end
    end
    return true
end

local function newScanTelemetry()
    return {
        signals = 0,
        scansStarted = 0,
        scansChanged = 0,
        scansUnchanged = 0,
        scansSkipped = 0,
        scansFailed = 0,
        scanAutoSuppressedUnchanged = 0,
        scanSkippedWeaponSkill = 0,
        scanSkippedGenericSkill = 0,
        scanTriggeredRecipeLearned = 0,
        scanTriggeredManual = 0,
        suspectedPartial = 0,
        invalidRecipesBlocked = 0,
        invalidRecipesSnapshot = 0,
        invalidRecipesInbound = 0,
        invalidRecipesCleaned = 0,
        lastInvalidRecipeKey = nil,
        lastInvalidRecipeContext = nil,
        lastInvalidRecipeMember = nil,
        lastInvalidRecipeProfession = nil,
        lastProfession = nil,
        lastSkipReason = nil,
        lastScanReason = nil,
        lastScanNotifyMode = nil,
    }
end

Private.TRACKED = TRACKED
Private.cloneArray = cloneArray
Private.cloneAtlasInfo = cloneAtlasInfo
Private.getAtlasLootHandles = getAtlasLootHandles
Private.getAtlasLootProfessionName = getAtlasLootProfessionName
Private.safeGetItemName = safeGetItemName
Private.safeGetSpellName = safeGetSpellName
Private.getItemData = getItemData
Private.safeGetItemIcon = safeGetItemIcon
Private.shouldRefreshItemName = shouldRefreshItemName
Private.isValidRecipeKey = isValidRecipeKey
Private.formatReagents = formatReagents
Private.detectSpecialization = detectSpecialization
Private.buildLocaleMap = buildLocaleMap
Private.lowerSafe = lowerSafe
Private.extractItemID = extractItemID
Private.extractSpellID = extractSpellID
Private.snapshotTradeSkillFilters = snapshotTradeSkillFilters
Private.clearTradeSkillFilters = clearTradeSkillFilters
Private.restoreTradeSkillFilters = restoreTradeSkillFilters
Private.snapshotCraftFilters = snapshotCraftFilters
Private.clearCraftFilters = clearCraftFilters
Private.restoreCraftFilters = restoreCraftFilters
Private.isSubsetOf = isSubsetOf
Private.newScanTelemetry = newScanTelemetry

function Data:OnInitialize()
    Addon.db = LibStub("AceDB-3.0"):New("RecipeRegistryDB", DB_DEFAULTS, true)
    self.db = Addon.db
    if type(_G.RecipeRegistryCharDB) ~= "table" then
        _G.RecipeRegistryCharDB = {}
    end
    if type(_G.RecipeRegistryCharDB.favorites) ~= "table" then
        _G.RecipeRegistryCharDB.favorites = {}
    end
    Addon.charDB = _G.RecipeRegistryCharDB
    self._atlasRecipeInfoCache = {}
    self._atlasSpellInfoCache = {}
    self._atlasCreatedItemInfoCache = {}
    self._scanNeededByProfession = {}
    self._genericScanAttempts = {}
    self._scanTelemetry = newScanTelemetry()
    -- Deprecated compatibility mirror. New code tracks pending scan work by
    -- profession plus a generic fallback for recipe events that do not identify
    -- the changed profession.
    self._scanNeeded = false
    if type(self.db.profile.minimap) ~= "table" then
        self.db.profile.minimap = {
            hide = false,
            minimapPos = 220,
        }
    else
        if self.db.profile.minimap.hide == nil then self.db.profile.minimap.hide = false end
        if type(self.db.profile.minimap.minimapPos) ~= "number" then
            local legacyAngle = self.db.profile.minimap.angle
            if type(legacyAngle) == "number" then
                if math.abs(legacyAngle) <= (math.pi * 2 + 0.001) then
                    self.db.profile.minimap.minimapPos = math.deg(legacyAngle) % 360
                else
                    self.db.profile.minimap.minimapPos = legacyAngle % 360
                end
            else
                self.db.profile.minimap.minimapPos = 220
            end
        end
    end
    if self.db.profile.searchMode ~= "materials" then
        self.db.profile.searchMode = "recipe"
    end
    if self.db.profile.defaultSearchMode ~= "materials" then
        self.db.profile.defaultSearchMode = "recipe"
    end
    if self.db.profile.useRecipeCategories == nil then
        self.db.profile.useRecipeCategories = true
    end
    self._onlineCache = {}
    self._guildMetaCache = {}
    self._guildRosterBuiltAt = 0
    self._guildRosterRefreshRequestedAt = 0
    self._rosterPreflightState = {
        pending = false,
        trusted = false,
        reason = "not-requested",
        snapshot = nil,
        snapshotCount = 0,
        knownActive = 0,
        knownOwnersChecked = 0,
        changedOwners = 0,
        evaluatedAt = 0,
        requestedAt = 0,
        requestReason = nil,
        source = nil,
    }
    self._currentProfs = {}
    self:MigrateDatabase()
    if Addon.MarkSavedVariablesReady then
        Addon:MarkSavedVariablesReady("addon-initialize")
    elseif Addon.Sync then
        Addon.Sync._savedVariablesReadyBootstrap = true
        if Addon.Sync.SetSavedVariablesReady then
            Addon.Sync:SetSavedVariablesReady("addon-initialize")
        end
    end
end

local function normalizeGuildRosterMemberKey(fullName)
    if type(fullName) ~= "string" or fullName == "" then
        return nil
    end
    local name, realm = fullName:match("^([^%-]+)%-(.+)$")
    if not name then
        name = fullName
        realm = GetRealmName() or "UnknownRealm"
    end
    realm = (realm or "UnknownRealm"):gsub("[%s%-]", "")
    return string.format("%s-%s", name, realm)
end

local function computeOfflineDays(yearsOffline, monthsOffline, daysOffline, hoursOffline)
    if yearsOffline == nil and monthsOffline == nil and daysOffline == nil and hoursOffline == nil then
        return nil
    end
    return (tonumber(yearsOffline) or 0) * 365
        + (tonumber(monthsOffline) or 0) * 30
        + (tonumber(daysOffline) or 0)
        + ((tonumber(hoursOffline) or 0) / 24)
end

local function cloneRosterSnapshot(snapshot)
    local out = {}
    for memberKey, present in pairs(snapshot or {}) do
        if present == true then
            out[memberKey] = true
        end
    end
    return out
end

local function buildLiveGuildRosterSnapshot()
    local snapshot = {}
    local details = {}
    local snapshotCount = 0
    local lastOnlineSupported = type(GetGuildRosterLastOnline) == "function"
    local lastOnlineUnavailable = false
    local total = GetNumGuildMembers and (GetNumGuildMembers() or 0) or 0
    for index = 1, total do
        local fullName, _, _, _, _, _, _, _, online = GetGuildRosterInfo and GetGuildRosterInfo(index)
        local memberKey = normalizeGuildRosterMemberKey(fullName)
        if memberKey and not snapshot[memberKey] then
            snapshot[memberKey] = true
            snapshotCount = snapshotCount + 1
            local offlineDays = nil
            local offlineKnown = false
            if online then
                offlineDays = 0
                offlineKnown = true
            elseif lastOnlineSupported then
                offlineDays = computeOfflineDays(GetGuildRosterLastOnline(index))
                offlineKnown = offlineDays ~= nil
                if not offlineKnown then
                    lastOnlineUnavailable = true
                end
            else
                lastOnlineUnavailable = true
            end
            details[memberKey] = {
                online = online == true,
                offlineDays = offlineDays,
                offlineKnown = offlineKnown,
            }
        end
    end
    return snapshot, details, snapshotCount, {
        lastOnlineSupported = lastOnlineSupported,
        lastOnlineUnavailable = lastOnlineUnavailable,
    }
end

function Data:GetRosterPreflightState()
    if type(IsInGuild) == "function" and not IsInGuild() then
        return {
            pending = false,
            trusted = true,
            reason = "not-in-guild",
            snapshot = nil,
            snapshotCount = 0,
            knownActive = 0,
            knownOwnersChecked = 0,
            changedOwners = 0,
            evaluatedAt = time(),
            requestedAt = 0,
            requestReason = nil,
            source = "not-in-guild",
        }
    end

    local state = self._rosterPreflightState or {}
    return {
        pending = state.pending == true,
        trusted = state.trusted == true,
        reason = tostring(state.reason or "not-requested"),
        snapshot = state.snapshot and cloneRosterSnapshot(state.snapshot) or nil,
        snapshotCount = tonumber(state.snapshotCount or 0) or 0,
        knownActive = tonumber(state.knownActive or 0) or 0,
        knownOwnersChecked = tonumber(state.knownOwnersChecked or 0) or 0,
        changedOwners = tonumber(state.changedOwners or 0) or 0,
        evaluatedAt = tonumber(state.evaluatedAt or 0) or 0,
        requestedAt = tonumber(state.requestedAt or 0) or 0,
        requestReason = state.requestReason,
        source = state.source,
    }
end

function Data:IsRosterSnapshotPending()
    local state = self._rosterPreflightState or {}
    return state.pending == true
end

function Data:RequestRosterSnapshot(reason, opts)
    opts = opts or {}
    local requestReason = tostring(reason or "login")
    local state = self._rosterPreflightState or {}
    if state.pending == true and not opts.force then
        return false, "already-pending"
    end

    local now = time()
    self._rosterPreflightState = {
        pending = true,
        trusted = false,
        reason = "pending",
        snapshot = nil,
        snapshotCount = 0,
        knownActive = 0,
        knownOwnersChecked = 0,
        changedOwners = 0,
        evaluatedAt = 0,
        requestedAt = now,
        requestReason = requestReason,
        source = tostring(opts.source or "startup"),
    }

    Addon:Tracef("sync","roster-snapshot-requested reason=%s", requestReason)
    local requested = self:RequestGuildRosterRefresh(requestReason, {
        force = true,
        cooldown = tonumber(opts.cooldown or 0) or 0,
    })
    return requested, requested and "requested" or "request-unavailable"
end

function Data:ProcessPendingRosterSnapshot(reason, opts)
    opts = opts or {}
    local state = self._rosterPreflightState or {}
    if state.pending ~= true and opts.force ~= true then
        return false, "not-pending"
    end

    local knownOwnerKeys = self:GetKnownSyncOwnerKeys()
    local now = time()
    local snapshot, details, snapshotCount, capability = buildLiveGuildRosterSnapshot()
    local usable = snapshotCount > 0 or (#knownOwnerKeys == 0)
    if not usable and opts.allowFallback ~= true then
        return false, "not-usable"
    end

    Addon:Tracef("sync",
        "roster-snapshot-received members=%d knownOwners=%d",
        snapshotCount,
        #knownOwnerKeys
    )

    local affectedBlockKeys = {}
    local changedOwners = {}
    local seenBlocks = {}
    local membershipFallbackUsed = false
    local selfKey = self:GetPlayerKey()

    for index = 1, #knownOwnerKeys do
        local ownerKey = knownOwnerKeys[index]
        local inGuild = snapshot[ownerKey] == true
        local detail = details[ownerKey] or {}
        local offlineDays = detail.offlineKnown == true and detail.offlineDays or nil
        local keepEligible = ownerKey == selfKey
        local staleReason = nil

        if ownerKey ~= selfKey then
            if usable and inGuild ~= true then
                keepEligible = false
                staleReason = "no-longer-in-guild"
            elseif usable and detail.offlineKnown == true then
                keepEligible = (detail.offlineDays or 0) <= KNOWN_OWNER_OFFLINE_STALE_DAYS
                if not keepEligible then
                    staleReason = "offline-14d"
                end
            else
                membershipFallbackUsed = true
                keepEligible = inGuild == true
                if not keepEligible then
                    staleReason = "no-longer-in-guild"
                end
            end
        end

        Addon:Tracef("sync",
            "roster-known-owner-check owner=%s inGuild=%s offlineDays=%s",
            tostring(ownerKey),
            tostring(inGuild == true or ownerKey == selfKey),
            offlineDays and tostring(math.floor(offlineDays)) or "unknown"
        )

        local changed = false
        if keepEligible then
            changed = self:MarkMemberActive(ownerKey, now, "known-owner-eligibility-change")
        else
            changed = self:MarkMemberStale(ownerKey, now, "known-owner-eligibility-change")
            Addon:Tracef("sync",
                "roster-owner-stale owner=%s reason=%s",
                tostring(ownerKey),
                tostring(staleReason or "unknown")
            )
        end

        if changed then
            changedOwners[#changedOwners + 1] = ownerKey
            for _, blockKey in ipairs(self:GetMemberProfessionBlockKeys(ownerKey)) do
                if not seenBlocks[blockKey] then
                    seenBlocks[blockKey] = true
                    affectedBlockKeys[#affectedBlockKeys + 1] = blockKey
                end
            end
        end
    end

    if membershipFallbackUsed or (usable and capability.lastOnlineSupported ~= true) then
        Addon:Trace("sync", "roster-last-online-unavailable fallback=membership-only")
    end

    local knownActive = 0
    for index = 1, #knownOwnerKeys do
        local entry = self:GetMember(knownOwnerKeys[index])
        if knownOwnerKeys[index] == selfKey or (entry and (entry.guildStatus or "active") == "active") then
            knownActive = knownActive + 1
        end
    end

    self._rosterPreflightState = {
        pending = false,
        trusted = true,
        reason = usable and "trusted" or "fallback-membership-only",
        snapshot = usable and cloneRosterSnapshot(snapshot) or nil,
        snapshotCount = usable and snapshotCount or 0,
        knownActive = knownActive,
        knownOwnersChecked = #knownOwnerKeys,
        changedOwners = #changedOwners,
        evaluatedAt = now,
        requestedAt = state.requestedAt or now,
        requestReason = state.requestReason or tostring(reason or "roster-update"),
        source = tostring(opts.source or (usable and "event" or "watchdog")),
    }

    Addon:Tracef("sync",
        "roster-preflight-ready changedOwners=%d",
        #changedOwners
    )

    return true, "processed", {
        reason = #changedOwners > 0 and "known-owner-eligibility-change" or tostring(reason or "roster-preflight"),
        changedOwners = changedOwners,
        affectedBlockKeys = affectedBlockKeys,
        knownOwnerEligibilityChanged = #changedOwners > 0,
        fullDirty = #changedOwners > 0 and #affectedBlockKeys == 0,
        snapshotCount = usable and snapshotCount or 0,
        knownOwnersChecked = #knownOwnerKeys,
        unknownMembersIgnored = math.max(0, snapshotCount - #knownOwnerKeys),
        membershipFallbackUsed = membershipFallbackUsed,
        usableSnapshot = usable,
    }
end

function Data:GetCanonicalProfession(name)
    if not localeMap then buildLocaleMap() end
    return localeMap[name] or name
end

function Data:GetPlayerKey()
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName() or "UnknownRealm"
    realm = realm:gsub("[%s%-]", "")
    return string.format("%s-%s", name or "Unknown", realm)
end

function Data:IsValidMemberKey(memberKey)
    if type(memberKey) ~= "string" or memberKey == "" then return false end
    if memberKey:find(":", 1, true) then return false end
    local name, realm = memberKey:match("^([^-]+)%-(.+)$")
    return name ~= nil and name ~= "" and realm ~= nil and realm ~= ""
end

function Data:GetMembersDB()
    return self.db.global.members
end

function Data:GetUpdateNoticeState()
    self.db.global.updateNotice = self.db.global.updateNotice or {}
    if type(self.db.global.updateNotice.lastUpdateNoticeAt) ~= "number" then
        self.db.global.updateNotice.lastUpdateNoticeAt = 0
    end
    if type(self.db.global.updateNotice.lastProtocolNoticeAt) ~= "number" then
        self.db.global.updateNotice.lastProtocolNoticeAt = 0
    end
    if self.db.global.updateNotice.lastSeenVersion ~= nil and self.db.global.updateNotice.latestRemoteVersionSeen == nil then
        self.db.global.updateNotice.latestRemoteVersionSeen = self.db.global.updateNotice.lastSeenVersion
    end
    if self.db.global.updateNotice.lastNoticeAt ~= nil and self.db.global.updateNotice.lastUpdateNoticeAt == 0 then
        self.db.global.updateNotice.lastUpdateNoticeAt = tonumber(self.db.global.updateNotice.lastNoticeAt) or 0
    end
    if self.db.global.updateNotice.lastProtocolWarningAt ~= nil and self.db.global.updateNotice.lastProtocolNoticeAt == 0 then
        self.db.global.updateNotice.lastProtocolNoticeAt = tonumber(self.db.global.updateNotice.lastProtocolWarningAt) or 0
    end
    if self.db.global.updateNotice.lastSeenVersion ~= nil then
        self.db.global.updateNotice.lastSeenVersion = nil
    end
    if self.db.global.updateNotice.lastNoticeAt ~= nil then
        self.db.global.updateNotice.lastNoticeAt = nil
    end
    if self.db.global.updateNotice.lastProtocolWarningAt ~= nil then
        self.db.global.updateNotice.lastProtocolWarningAt = nil
    end
    return self.db.global.updateNotice
end

function Data:GetGlobalMeta()
    self.db.global.meta = self.db.global.meta or {}
    if type(self.db.global.meta.schemaVersion) ~= "number" then
        self.db.global.meta.schemaVersion = 1
    end
    if type(self.db.global.meta.lastWeeklyCleanupAt) ~= "number" then
        self.db.global.meta.lastWeeklyCleanupAt = 0
    end
    if type(self.db.global.meta.lastTrustedRosterCleanupAt) ~= "number" then
        self.db.global.meta.lastTrustedRosterCleanupAt = 0
    end
    if type(self.db.global.meta.bootstrapCompletedAt) ~= "number" then
        self.db.global.meta.bootstrapCompletedAt = 0
    end
    return self.db.global.meta
end

function Data:GetSchemaVersion()
    return self:GetGlobalMeta().schemaVersion or 1
end

function Data:SetLastWeeklyCleanupAt(ts)
    self:GetGlobalMeta().lastWeeklyCleanupAt = ts or time()
end

function Data:SetLastTrustedRosterCleanupAt(ts)
    self:GetGlobalMeta().lastTrustedRosterCleanupAt = ts or time()
end

function Data:MarkBootstrapCompleted(ts)
    self:GetGlobalMeta().bootstrapCompletedAt = ts or time()
end

function Data:GetMember(memberKey)
    return self.db.global.members[memberKey]
end

function Data:GetMemberSourceType(memberKey)
    if memberKey == self:GetPlayerKey() then
        return "owner"
    end
    return "replica"
end

function Data:GetOrCreateMember(memberKey)
    local db = self:GetMembersDB()
    if not db[memberKey] then
        db[memberKey] = {
            owner = memberKey,
            updatedAt = 0,
            sourceType = self:GetMemberSourceType(memberKey),
            guildStatus = "active",
            lastSeenInGuildAt = time(),
            professions = {},
        }
    end
    self:NormalizeMemberEntry(db[memberKey], memberKey)
    return db[memberKey]
end

function Data:NormalizeProfessionBlock(entry, professionKey, prof)
    prof = prof or {}
    prof.recipes = prof.recipes or {}
    prof.count = countRecipeKeys(prof.recipes)
    -- Legacy `signature` field is no longer used (scan now does set-diff
    -- inline). Strip it on normalize so SavedVariables shed it next save.
    prof.signature = nil
    prof.skillRank = prof.skillRank or 0
    prof.skillMaxRank = prof.skillMaxRank or 0
    prof.specialization = prof.specialization or nil
    prof.lastUpdatedAt = type(prof.lastUpdatedAt) == "number" and prof.lastUpdatedAt or (entry.updatedAt or 0)
    prof.sourceType = prof.sourceType or entry.sourceType or self:GetMemberSourceType(entry.owner)
    prof.guildStatus = prof.guildStatus or entry.guildStatus or "active"
    prof.lastSeenInGuildAt = type(prof.lastSeenInGuildAt) == "number" and prof.lastSeenInGuildAt or (entry.lastSeenInGuildAt or entry.updatedAt or 0)
    return prof
end

function Data:NormalizeMemberEntry(entry, memberKey)
    if type(entry) ~= "table" then return nil end
    entry.owner = entry.owner or memberKey
    entry.updatedAt = entry.updatedAt or 0
    entry.sourceType = entry.sourceType or self:GetMemberSourceType(memberKey)
    entry.guildStatus = entry.guildStatus or "active"
    entry.lastSeenInGuildAt = type(entry.lastSeenInGuildAt) == "number" and entry.lastSeenInGuildAt or (entry.updatedAt or 0)
    entry.staleAt = type(entry.staleAt) == "number" and entry.staleAt or 0
    entry.professions = entry.professions or {}
    for professionKey, prof in pairs(entry.professions) do
        entry.professions[professionKey] = self:NormalizeProfessionBlock(entry, professionKey, prof)
    end
    return entry
end

function Data:MigrateDatabase()
    local meta = self:GetGlobalMeta()
    local schemaVersion = meta.schemaVersion or 1
    local now = time()

    for memberKey, entry in pairs(self:GetMembersDB()) do
        self:NormalizeMemberEntry(entry, memberKey)
        if schemaVersion < 2 then
            if entry.owner == self:GetPlayerKey() then
                entry.sourceType = "owner"
            elseif entry.sourceType ~= "bootstrap" then
                entry.sourceType = "replica"
            end
            if not entry.lastSeenInGuildAt or entry.lastSeenInGuildAt <= 0 then
                entry.lastSeenInGuildAt = entry.updatedAt or now
            end
            entry.guildStatus = entry.guildStatus or "active"
            for professionKey, prof in pairs(entry.professions or {}) do
                prof.lastUpdatedAt = prof.lastUpdatedAt or entry.updatedAt or now
                prof.sourceType = prof.sourceType or entry.sourceType
                prof.guildStatus = prof.guildStatus or entry.guildStatus
                prof.lastSeenInGuildAt = prof.lastSeenInGuildAt or entry.lastSeenInGuildAt or now
                entry.professions[professionKey] = self:NormalizeProfessionBlock(entry, professionKey, prof)
            end
        end
    end

    meta.schemaVersion = 2
end

function Data:GetMemberProfessionBlockKeys(memberKey)
    local entry = self:GetMember(memberKey)
    local blockKeys = {}
    for professionKey in pairs(entry and entry.professions or {}) do
        local blockKey = self:BuildSyncBlockKey(memberKey, professionKey)
        if blockKey then
            blockKeys[#blockKeys + 1] = blockKey
        end
    end
    sort(blockKeys)
    return blockKeys
end

function Data:MarkOwnerSyncBlocksDirty(memberKey, reason)
    local blockKeys = self:GetMemberProfessionBlockKeys(memberKey)
    if #blockKeys == 0 then
        return false, {}
    end
    for index = 1, #blockKeys do
        self:MarkSyncIndexDirty(reason or "owner-dirty", blockKeys[index])
    end
    return true, blockKeys
end

function Data:GetKnownSyncOwnerKeys()
    local keys = {}
    local selfKey = self:GetPlayerKey()
    local seen = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if not self:IsMockMember(memberKey, entry) and not seen[memberKey] then
            seen[memberKey] = true
            keys[#keys + 1] = memberKey
        end
    end
    if not seen[selfKey] then
        keys[#keys + 1] = selfKey
    end
    sort(keys)
    return keys
end

function Data:BuildCachedGuildRosterSnapshot()
    local snapshot = {}
    local count = 0
    for memberKey in pairs(self._guildMetaCache or {}) do
        if not snapshot[memberKey] then
            snapshot[memberKey] = true
            count = count + 1
        end
    end
    return snapshot, count
end

function Data:InvalidateRecipeCaches(scope)
    if scope == "list" then
        self._recipeListCache = nil
        self._recipeListCacheOrder = nil
        return
    end
    if scope == "metadata" then
        self._recipeDetailCache = nil
        self._recipeDetailCacheOrder = nil
        self._recipeIndex = nil
        if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
            Addon.Tooltip:InvalidateIndex("metadata")
        end
        return
    end
    if scope == "presence" then
        -- Presence is no longer materialized inside _recipeIndex — online
        -- flags and onlineCount are derived live from _onlineCache when
        -- GetRecipeCrafters / GetRecipeList run. Roster presence flips
        -- therefore don't invalidate the content index; we only need to
        -- drop the list cache because its sort uses live onlineCount.
        self._recipeListCache = nil
        self._recipeListCacheOrder = nil
        if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
            Addon.Tooltip:InvalidateIndex("presence")
        end
        return
    end

    self._recipeListCache = nil
    self._recipeListCacheOrder = nil
    self._recipeDetailCache = nil
    self._recipeDetailCacheOrder = nil
    self._recipeIndex = nil
    if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
        Addon.Tooltip:InvalidateIndex(scope or "full")
    end
end

function Data:IsMemberVisible(memberKey, includeStale)
    local entry = type(memberKey) == "table" and memberKey or self:GetMember(memberKey)
    if not entry then return false end
    if includeStale then return true end
    return (entry.guildStatus or "active") == "active"
end

function Data:IsUserVisibleMember(memberKey, entry, includeStale)
    entry = type(memberKey) == "table" and memberKey or entry or self:GetMember(memberKey)
    if not entry then return false end
    if self:IsMockMember(memberKey, entry) then return false end
    return self:IsMemberVisible(entry, includeStale)
end

function Data:GetSortedMemberKeys(includeStale)
    local keys = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsUserVisibleMember(memberKey, entry, includeStale) then
            keys[#keys + 1] = memberKey
        end
    end
    sort(keys)
    return keys
end

function Data:GetUiStatusSnapshot(includeStale)
    local members = 0
    local updatedAt = 0
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsUserVisibleMember(memberKey, entry, includeStale) then
            members = members + 1
            local entryUpdatedAt = tonumber(entry.updatedAt or 0) or 0
            if entryUpdatedAt > updatedAt then
                updatedAt = entryUpdatedAt
            end
            for _, prof in pairs(entry.professions or {}) do
                local profUpdatedAt = tonumber(prof.lastUpdatedAt or prof.lastScan or 0) or 0
                if profUpdatedAt > updatedAt then
                    updatedAt = profUpdatedAt
                end
            end
        end
    end
    return {
        members = members,
        updatedAt = updatedAt,
    }
end

function Data:MarkMemberActive(memberKey, seenAt, dirtyReason)
    local entry = self:GetMember(memberKey)
    if not entry then return false end
    local changed = (entry.guildStatus or "active") ~= "active" or (entry.staleAt or 0) > 0
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = seenAt or time()
    entry.staleAt = 0
    for professionKey, prof in pairs(entry.professions or {}) do
        if (prof.guildStatus or "active") ~= "active" then
            changed = true
        end
        prof.guildStatus = "active"
        prof.lastSeenInGuildAt = entry.lastSeenInGuildAt
        entry.professions[professionKey] = self:NormalizeProfessionBlock(entry, professionKey, prof)
    end
    if not changed then
        return false
    end
    Addon:Tracef("sync",
        "member-marked-active owner=%s reason=%s professions=%d",
        tostring(memberKey),
        tostring(dirtyReason or "member-active"),
        countKeys(entry.professions)
    )
    if self.MarkOwnerSyncBlocksDirty then
        self:MarkOwnerSyncBlocksDirty(memberKey, dirtyReason or "member-active")
    end
    return true
end

function Data:MarkMemberStale(memberKey, staleAt, dirtyReason)
    local entry = self:GetMember(memberKey)
    if not entry or entry.owner == self:GetPlayerKey() then return false end
    if entry.guildStatus == "stale" then return false end
    entry.guildStatus = "stale"
    entry.staleAt = staleAt or time()
    for professionKey, prof in pairs(entry.professions or {}) do
        prof.guildStatus = "stale"
        entry.professions[professionKey] = self:NormalizeProfessionBlock(entry, professionKey, prof)
    end
    Addon:Tracef("sync",
        "member-marked-stale owner=%s reason=%s professions=%d",
        tostring(memberKey),
        tostring(dirtyReason or "member-stale"),
        countKeys(entry.professions)
    )
    if self.MarkOwnerSyncBlocksDirty then
        self:MarkOwnerSyncBlocksDirty(memberKey, dirtyReason or "member-stale")
    end
    self:InvalidateRecipeCaches("presence")
    return true
end

function Data:DeleteMember(memberKey)
    if not memberKey then return false end
    local blockKeys = self:GetMemberProfessionBlockKeys(memberKey)
    self.db.global.members[memberKey] = nil
    if self.MarkSyncIndexDirty then
        if #blockKeys > 0 then
            for index = 1, #blockKeys do
                self:MarkSyncIndexDirty("member-delete", blockKeys[index])
            end
        else
            self:MarkSyncIndexDirty("member-delete")
        end
    end
    self:InvalidateRecipeCaches("presence")
    if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
        Addon.Tooltip:InvalidateIndex()
    end
    return true
end

function Data:IsMockMember(memberKey, entry)
    entry = entry or self:GetMember(memberKey)
    if type(memberKey) == "string"
        and (memberKey:find("__RRMockPeer", 1, true) == 1 or memberKey:find("__RRMockOwner", 1, true) == 1) then
        return true
    end
    return entry and entry.isMock == true or false
end

function Data:DeleteMockMembers()
    local removed = 0
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsMockMember(memberKey, entry) then
            local blockKeys = self:GetMemberProfessionBlockKeys(memberKey)
            self.db.global.members[memberKey] = nil
            removed = removed + 1
            if self.MarkSyncIndexDirty then
                if #blockKeys > 0 then
                    for index = 1, #blockKeys do
                        self:MarkSyncIndexDirty("mock-cleanup", blockKeys[index])
                    end
                else
                    self:MarkSyncIndexDirty("mock-cleanup")
                end
            end
        end
    end
    if removed > 0 then
        self:InvalidateRecipeCaches("presence")
        if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
            Addon.Tooltip:InvalidateIndex()
        end
    end
    return removed
end

function Data:RebuildOnlineCache()
    local previousOnline = self._onlineCache or {}
    local previousMeta = self._guildMetaCache or {}
    local nextOnline = {}
    local nextMeta = {}
    local delta = {
        presenceChanged = false,
        membershipChanged = false,
        guildStatusChanged = false,
        knownMembersChanged = false,
        onlineCountChanged = false,
        onlineCount = 0,
        previousOnlineCount = countKeys(previousOnline),
    }
    for i = 1, GetNumGuildMembers() do
        local fullName, rankName, rankIndex, level, classDisplayName, zone, publicNote, officerNote, online, status, classFileName = GetGuildRosterInfo(i)
        if fullName then
            local name, realm = fullName:match("^([^%-]+)%-(.+)$")
            if not name then
                name = fullName
                realm = GetRealmName() or "UnknownRealm"
            end
            realm = (realm or "UnknownRealm"):gsub("[%s%-]", "")
            local memberKey = name .. "-" .. realm
            if online then
                nextOnline[memberKey] = true
                delta.onlineCount = delta.onlineCount + 1
            end
            nextMeta[memberKey] = {
                name = fullName,
                rankName = rankName,
                rankIndex = rankIndex,
                level = level,
                className = classDisplayName,
                classFile = classFileName,
                zone = zone,
                online = online and true or false,
                status = status,
            }
        end
    end
    for memberKey, meta in pairs(nextMeta) do
        local previous = previousMeta[memberKey]
        if not previous then
            delta.membershipChanged = true
            delta.knownMembersChanged = true
        else
            if (previous.online and true or false) ~= (meta.online and true or false) then
                delta.presenceChanged = true
            end
            if previous.status ~= meta.status then
                delta.guildStatusChanged = true
                delta.knownMembersChanged = true
            end
            if previous.rankIndex ~= meta.rankIndex
                or previous.level ~= meta.level
                or previous.classFile ~= meta.classFile
                or previous.zone ~= meta.zone then
                delta.knownMembersChanged = true
            end
        end
    end
    for memberKey in pairs(previousMeta) do
        if not nextMeta[memberKey] then
            delta.membershipChanged = true
            delta.knownMembersChanged = true
            if previousOnline[memberKey] then
                delta.presenceChanged = true
            end
        end
    end
    if delta.previousOnlineCount ~= delta.onlineCount then
        delta.onlineCountChanged = true
    end
    self._onlineCache = nextOnline
    self._guildMetaCache = nextMeta
    self._guildRosterBuiltAt = time()
    return delta
end

function Data:IsMemberOnline(memberKey)
    return self._onlineCache[memberKey] == true
end

function Data:GetGuildMemberMeta(memberKey)
    return self._guildMetaCache and self._guildMetaCache[memberKey] or nil
end

function Data:GetGuildRosterAge()
    local builtAt = self._guildRosterBuiltAt or 0
    if builtAt <= 0 then
        return math.huge
    end
    local age = time() - builtAt
    if age < 0 then return 0 end
    return age
end

function Data:NeedsGuildRosterRefresh(maxAge)
    local threshold = tonumber(maxAge or 0) or 0
    return self:GetGuildRosterAge() > threshold
end

function Data:RequestGuildRosterRefresh(_reason, opts)
    opts = opts or {}
    local now = time()
    local cooldown = tonumber(opts.cooldown or 0) or 0
    if not opts.force and cooldown > 0 and (now - (self._guildRosterRefreshRequestedAt or 0)) < cooldown then
        return false
    end
    self._guildRosterRefreshRequestedAt = now
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
        return true
    end
    if GuildRoster then
        GuildRoster()
        return true
    end
    return false
end
