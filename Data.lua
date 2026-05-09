local _, _ns = ...
local Addon = _G.RecipeRegistry
local Data = Addon:NewModule("Data")
Addon.Data = Data

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
local GetItemInfo = GetItemInfo
local GetSpellInfo = GetSpellInfo
local time = time
local pairs = pairs
local ipairs = ipairs
local sort = table.sort
local concat = table.concat
local tostring = tostring

local DB_DEFAULTS = {
    global = {
        meta = {
            schemaVersion = 2,
            lastWeeklyCleanupAt = 0,
            bootstrapCompletedAt = 0,
        },
        members = {},
    },
    profile = {
        selectedProfession = nil,
        sortMode = "alpha",
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
    },
}

local MANIFEST_BUILD_BLOCKS_PER_STEP = 32

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

local function cloneManifestBlock(block)
    return cloneTableShallow(block)
end

local function cloneManifestForUpdate(manifest)
    local copy = {
        builtAt = manifest and manifest.builtAt or time(),
        memberKey = manifest and manifest.memberKey,
        manifestSerial = manifest and manifest.manifestSerial or 0,
        blocks = {},
        totals = {
            blocks = manifest and manifest.totals and manifest.totals.blocks or 0,
            recipes = manifest and manifest.totals and manifest.totals.recipes or 0,
        },
    }
    for blockKey, block in pairs(manifest and manifest.blocks or {}) do
        copy.blocks[blockKey] = cloneManifestBlock(block)
    end
    return copy
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

local function newManifestTelemetry()
    return {
        buildsStarted = 0,
        buildsCompleted = 0,
        fullBuilds = 0,
        deltaBuilds = 0,
        buildSteps = 0,
        blocksProcessed = 0,
        dirtyBlocksMarked = 0,
        fullInvalidations = 0,
        schedules = 0,
        cacheHits = 0,
        syncFallbackBuilds = 0,
        deferredRequests = 0,
        totalBuildCostMs = 0,
        maxBuildCostMs = 0,
        lastBuildCostMs = 0,
    }
end

local function newManifestCache()
    return {
        manifest = nil,
        dirtyAll = true,
        dirtyBlocks = {},
        building = false,
        scheduled = false,
        dirtyDuringBuild = false,
        serial = 0,
        lastReason = "init",
        telemetry = newManifestTelemetry(),
    }
end

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

local function stableRecipeSignature(recipeKeys)
    local keys = {}
    for recipeKey in pairs(recipeKeys or {}) do
        keys[#keys + 1] = tonumber(recipeKey) or recipeKey
    end
    sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return concat(keys, ":")
end

local function buildManifestFingerprint(profession)
    local recipeSignature = profession and profession.signature or stableRecipeSignature(profession and profession.recipes)
    local specialization = profession and profession.specialization or ""
    return string.format("%s|spec:%s", tostring(recipeSignature or ""), tostring(specialization or ""))
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
    }
end

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
    self._manifestCache = newManifestCache()
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
    self._onlineCache = {}
    self._currentProfs = {}
    self:MigrateDatabase()
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

function Data:GetGlobalMeta()
    self.db.global.meta = self.db.global.meta or {}
    if type(self.db.global.meta.schemaVersion) ~= "number" then
        self.db.global.meta.schemaVersion = 1
    end
    if type(self.db.global.meta.lastWeeklyCleanupAt) ~= "number" then
        self.db.global.meta.lastWeeklyCleanupAt = 0
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
            rev = 0,
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
    prof.count = type(prof.count) == "number" and prof.count or countRecipeKeys(prof.recipes)
    prof.signature = prof.signature or stableRecipeSignature(prof.recipes)
    prof.skillRank = prof.skillRank or 0
    prof.skillMaxRank = prof.skillMaxRank or 0
    prof.specialization = prof.specialization or nil
    prof.blockRevision = type(prof.blockRevision) == "number" and prof.blockRevision or (entry.rev or 0)
    prof.lastUpdatedAt = type(prof.lastUpdatedAt) == "number" and prof.lastUpdatedAt or (entry.updatedAt or 0)
    prof.sourceType = prof.sourceType or entry.sourceType or self:GetMemberSourceType(entry.owner)
    prof.guildStatus = prof.guildStatus or entry.guildStatus or "active"
    prof.lastSeenInGuildAt = type(prof.lastSeenInGuildAt) == "number" and prof.lastSeenInGuildAt or (entry.lastSeenInGuildAt or entry.updatedAt or 0)
    return prof
end

function Data:NormalizeMemberEntry(entry, memberKey)
    if type(entry) ~= "table" then return nil end
    entry.owner = entry.owner or memberKey
    entry.rev = entry.rev or 0
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
                prof.blockRevision = prof.blockRevision or entry.rev or 0
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

function Data:InvalidateRecipeCaches(scope)
    if scope == "list" then
        self._recipeListCache = nil
        return
    end
    if scope == "presence" then
        self._recipeListCache = nil
        self._recipeCraftersCache = nil
        self._recipeIndex = nil
        if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
            Addon.Tooltip:InvalidateIndex()
        end
        return
    end

    self._recipeListCache = nil
    self._recipeDetailCache = nil
    self._recipeCraftersCache = nil
    self._recipeIndex = nil
    if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
        Addon.Tooltip:InvalidateIndex()
    end
end

function Data:BuildSyncBlockKey(ownerCharacter, professionKey)
    if not ownerCharacter or not professionKey then return nil end
    if not self:IsValidMemberKey(ownerCharacter) then return nil end
    return string.format("%s::%s", tostring(ownerCharacter), tostring(professionKey))
end

function Data:ParseSyncBlockKey(blockKey)
    if type(blockKey) ~= "string" then return nil, nil end
    local ownerCharacter, professionKey = blockKey:match("^(.-)::(.+)$")
    if not ownerCharacter or not professionKey then
        return nil, nil
    end
    return ownerCharacter, professionKey
end

function Data:IsValidSyncBlockKey(blockKey)
    local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
    if not self:IsValidMemberKey(ownerCharacter) then return false end
    if type(professionKey) ~= "string" or professionKey == "" then return false end
    return true
end

function Data:GetSyncBlock(memberKey, professionKey)
    if not self:IsValidMemberKey(memberKey) then return nil end
    local entry = self:GetMember(memberKey)
    local profession = entry and entry.professions and entry.professions[professionKey]
    if not entry or not profession then return nil end
    local blockKey = self:BuildSyncBlockKey(memberKey, professionKey)
    if not blockKey then return nil end

    local recipeCount = profession.count
    if type(recipeCount) ~= "number" then
        recipeCount = countRecipeKeys(profession.recipes)
    end

    return {
        blockKey = blockKey,
        ownerCharacter = memberKey,
        professionKey = professionKey,
        revision = profession.blockRevision or entry.rev or 0,
        lastUpdatedAt = profession.lastUpdatedAt or entry.updatedAt or 0,
        sourceType = profession.sourceType or entry.sourceType or self:GetMemberSourceType(memberKey),
        guildStatus = profession.guildStatus or entry.guildStatus or "active",
        lastSeenInGuildAt = profession.lastSeenInGuildAt or entry.lastSeenInGuildAt or entry.updatedAt or 0,
        count = recipeCount,
        fingerprint = buildManifestFingerprint(profession),
        skillRank = profession.skillRank or 0,
        skillMaxRank = profession.skillMaxRank or 0,
    }
end

local function manifestRowFromSyncBlock(block)
    if not block then return nil end
    return {
        ownerCharacter = block.ownerCharacter,
        professionKey = block.professionKey,
        revision = block.revision,
        lastUpdatedAt = block.lastUpdatedAt,
        sourceType = block.sourceType,
        guildStatus = block.guildStatus,
        lastSeenInGuildAt = block.lastSeenInGuildAt,
        count = block.count,
        fingerprint = block.fingerprint,
    }
end

function Data:EnsureManifestCache()
    if type(self._manifestCache) ~= "table" then
        self._manifestCache = newManifestCache()
    end
    local cache = self._manifestCache
    cache.dirtyBlocks = cache.dirtyBlocks or {}
    cache.telemetry = cache.telemetry or newManifestTelemetry()
    return cache
end

function Data:GetManifestSerial()
    local cache = self:EnsureManifestCache()
    return cache.serial or 0
end

function Data:GetManifestBlockRow(blockKey)
    local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
    if not self:IsValidMemberKey(ownerCharacter) or not professionKey then return nil end
    local entry = self:GetMember(ownerCharacter)
    if not entry or self:IsMockMember(ownerCharacter, entry) then return nil end
    if (entry.guildStatus or "active") ~= "active" then return nil end
    local block = self:GetSyncBlock(ownerCharacter, professionKey)
    if not block or (block.guildStatus or "active") ~= "active" then return nil end
    return manifestRowFromSyncBlock(block)
end

function Data:MarkManifestDirty(blockKey, reason)
    local cache = self:EnsureManifestCache()
    cache.lastReason = reason or cache.lastReason or "dirty"
    if cache.building then
        cache.dirtyDuringBuild = true
    end
    if not blockKey then
        cache.dirtyAll = true
        cache.dirtyBlocks = {}
        cache.telemetry.fullInvalidations = (cache.telemetry.fullInvalidations or 0) + 1
    elseif not cache.dirtyAll then
        if not cache.dirtyBlocks[blockKey] then
            cache.telemetry.dirtyBlocksMarked = (cache.telemetry.dirtyBlocksMarked or 0) + 1
        end
        cache.dirtyBlocks[blockKey] = true
    end
    self:ScheduleManifestBuild(reason or "dirty")
end

function Data:MarkManifestMemberDirty(memberKey, entry, reason)
    entry = entry or self:GetMember(memberKey)
    if not memberKey or not entry then
        self:MarkManifestDirty(nil, reason or "member-unknown")
        return
    end
    local marked = false
    for professionKey in pairs(entry.professions or {}) do
        self:MarkManifestDirty(self:BuildSyncBlockKey(memberKey, professionKey), reason or "member")
        marked = true
    end
    if not marked then
        self:MarkManifestDirty(nil, reason or "member-empty")
    end
end

function Data:IsManifestDirty()
    local cache = self:EnsureManifestCache()
    return cache.dirtyAll == true or next(cache.dirtyBlocks) ~= nil or cache.building == true
end

function Data:MakeManifestShell()
    local cache = self:EnsureManifestCache()
    return {
        builtAt = time(),
        memberKey = self:GetPlayerKey(),
        manifestSerial = cache.serial or 0,
        blocks = {},
        totals = {
            blocks = 0,
            recipes = 0,
        },
    }
end

function Data:GetAllSyncBlocks(includeStale)
    local blocks = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if self:IsValidMemberKey(memberKey)
            and not self:IsMockMember(memberKey, entry)
            and (includeStale or (entry.guildStatus or "active") == "active") then
            for professionKey in pairs(entry.professions or {}) do
                local block = self:GetSyncBlock(memberKey, professionKey)
                if block then
                    blocks[#blocks + 1] = block
                end
            end
        end
    end
    sort(blocks, function(a, b)
        if a.ownerCharacter ~= b.ownerCharacter then
            return a.ownerCharacter < b.ownerCharacter
        end
        return a.professionKey < b.professionKey
    end)
    return blocks
end

function Data:BuildSyncManifest(includeStale)
    local manifest = self:MakeManifestShell()

    for _, block in ipairs(self:GetAllSyncBlocks(includeStale)) do
        manifest.blocks[block.blockKey] = manifestRowFromSyncBlock(block)
        manifest.totals.blocks = manifest.totals.blocks + 1
        manifest.totals.recipes = manifest.totals.recipes + (block.count or 0)
    end

    return manifest
end

function Data:ApplyManifestDirtyBlock(manifest, blockKey)
    if not manifest or not blockKey then return end
    local previous = manifest.blocks[blockKey]
    if previous then
        manifest.totals.blocks = math.max(0, (manifest.totals.blocks or 0) - 1)
        manifest.totals.recipes = math.max(0, (manifest.totals.recipes or 0) - (previous.count or 0))
        manifest.blocks[blockKey] = nil
    end

    local row = self:GetManifestBlockRow(blockKey)
    if row then
        manifest.blocks[blockKey] = row
        manifest.totals.blocks = (manifest.totals.blocks or 0) + 1
        manifest.totals.recipes = (manifest.totals.recipes or 0) + (row.count or 0)
    end
end

function Data:CommitManifestBuild(manifest, reason, mode, processed, startMs)
    local cache = self:EnsureManifestCache()
    cache.manifest = manifest
    cache.dirtyAll = cache.dirtyDuringBuild == true
    cache.dirtyBlocks = {}
    cache.building = false
    cache.scheduled = false
    cache.dirtyDuringBuild = false
    cache.lastReason = reason or cache.lastReason
    cache.telemetry.buildsCompleted = (cache.telemetry.buildsCompleted or 0) + 1
    cache.telemetry.blocksProcessed = (cache.telemetry.blocksProcessed or 0) + (processed or 0)
    if mode == "delta" then
        cache.telemetry.deltaBuilds = (cache.telemetry.deltaBuilds or 0) + 1
    else
        cache.telemetry.fullBuilds = (cache.telemetry.fullBuilds or 0) + 1
    end
    if startMs then
        local costMs = nowMs() - startMs
        cache.telemetry.totalBuildCostMs = (cache.telemetry.totalBuildCostMs or 0) + costMs
        cache.telemetry.lastBuildCostMs = costMs
        if costMs > (cache.telemetry.maxBuildCostMs or 0) then
            cache.telemetry.maxBuildCostMs = costMs
        end
    end
    if Addon.TrickleSync and Addon.TrickleSync.InvalidateManifestChunkCache then
        Addon.TrickleSync:InvalidateManifestChunkCache(reason or "commit")
    end
    if Addon.Sync and Addon.Sync.OnManifestCacheReady then
        Addon.Sync:OnManifestCacheReady(reason or "manifest-cache")
    end
    if cache.dirtyAll then
        self:ScheduleManifestBuild("dirty-during-build")
    end
end

function Data:BuildManifestCacheNow(reason)
    local cache = self:EnsureManifestCache()
    if cache.manifest and not self:IsManifestDirty() then
        cache.telemetry.cacheHits = (cache.telemetry.cacheHits or 0) + 1
        return cache.manifest
    end

    local startMs = nowMs()
    cache.serial = (cache.serial or 0) + 1
    cache.telemetry.buildsStarted = (cache.telemetry.buildsStarted or 0) + 1
    cache.telemetry.syncFallbackBuilds = (cache.telemetry.syncFallbackBuilds or 0) + (reason == "sync-fallback" and 1 or 0)

    local mode = "full"
    local manifest
    local processed = 0
    if cache.manifest and not cache.dirtyAll then
        mode = "delta"
        manifest = cloneManifestForUpdate(cache.manifest)
        manifest.builtAt = time()
        manifest.memberKey = self:GetPlayerKey()
        manifest.manifestSerial = cache.serial
        for blockKey in pairs(cache.dirtyBlocks or {}) do
            self:ApplyManifestDirtyBlock(manifest, blockKey)
            processed = processed + 1
        end
    else
        manifest = self:BuildSyncManifest(false)
        manifest.manifestSerial = cache.serial
        processed = manifest.totals.blocks or 0
    end

    self:CommitManifestBuild(manifest, reason or cache.lastReason or "sync", mode, processed, startMs)
    return manifest
end

function Data:PrepareManifestBuildState(state)
    local cache = self:EnsureManifestCache()
    state = state or {}
    state.reason = state.reason or cache.lastReason or "background"
    state.index = 1
    state.processed = 0
    state.startMs = nowMs()
    state.mode = (cache.manifest and not cache.dirtyAll) and "delta" or "full"
    cache.serial = (cache.serial or 0) + 1
    cache.telemetry.buildsStarted = (cache.telemetry.buildsStarted or 0) + 1
    cache.scheduled = false
    cache.building = true
    cache.dirtyDuringBuild = false

    if state.mode == "delta" then
        state.manifest = cloneManifestForUpdate(cache.manifest)
        state.manifest.builtAt = time()
        state.manifest.memberKey = self:GetPlayerKey()
        state.manifest.manifestSerial = cache.serial
        state.blockKeys = {}
        for blockKey in pairs(cache.dirtyBlocks or {}) do
            state.blockKeys[#state.blockKeys + 1] = blockKey
        end
        sort(state.blockKeys)
    else
        state.manifest = self:MakeManifestShell()
        state.manifest.manifestSerial = cache.serial
        state.blocks = self:GetAllSyncBlocks(false)
    end
    return state
end

function Data:RunManifestBuildStep(state)
    local cache = self:EnsureManifestCache()
    if cache.manifest and not self:IsManifestDirty() and not cache.building then
        cache.scheduled = false
        return false
    end

    if not state or not state.mode then
        state = self:PrepareManifestBuildState(state)
    end

    cache.telemetry.buildSteps = (cache.telemetry.buildSteps or 0) + 1
    local processedThisStep = 0
    while processedThisStep < MANIFEST_BUILD_BLOCKS_PER_STEP do
        if state.mode == "delta" then
            local blockKey = state.blockKeys[state.index]
            if not blockKey then break end
            self:ApplyManifestDirtyBlock(state.manifest, blockKey)
        else
            local block = state.blocks[state.index]
            if not block then break end
            state.manifest.blocks[block.blockKey] = manifestRowFromSyncBlock(block)
            state.manifest.totals.blocks = state.manifest.totals.blocks + 1
            state.manifest.totals.recipes = state.manifest.totals.recipes + (block.count or 0)
        end
        state.index = state.index + 1
        state.processed = (state.processed or 0) + 1
        processedThisStep = processedThisStep + 1
    end

    local done
    if state.mode == "delta" then
        done = state.index > #(state.blockKeys or {})
    else
        done = state.index > #(state.blocks or {})
    end
    if not done then return true, state end

    self:CommitManifestBuild(state.manifest, state.reason, state.mode, state.processed or 0, state.startMs)
    return false
end

function Data:ScheduleManifestBuild(reason)
    local cache = self:EnsureManifestCache()
    if cache.scheduled or cache.building then return end
    if not (Addon.Performance and Addon.Performance.ScheduleJob) then return end
    cache.scheduled = true
    cache.lastReason = reason or cache.lastReason or "scheduled"
    cache.telemetry.schedules = (cache.telemetry.schedules or 0) + 1
    Addon.Performance:ScheduleJob("manifest-cache-build", function(state)
        return self:RunManifestBuildStep(state)
    end, {
        category = "sync-manifest",
        label = "manifest-cache-build",
        budgetMs = 2,
        state = {
            reason = reason or "scheduled",
        },
    })
end

function Data:GetPreparedSyncManifest(opts)
    opts = opts or {}
    local cache = self:EnsureManifestCache()
    if cache.manifest and not self:IsManifestDirty() then
        cache.telemetry.cacheHits = (cache.telemetry.cacheHits or 0) + 1
        return cache.manifest, "ready"
    end
    if opts.allowStale and cache.manifest then
        cache.telemetry.cacheHits = (cache.telemetry.cacheHits or 0) + 1
        self:ScheduleManifestBuild(opts.reason or "stale-request")
        return cache.manifest, "stale"
    end
    if opts.syncFallback then
        return self:BuildManifestCacheNow("sync-fallback"), "built"
    end
    cache.telemetry.deferredRequests = (cache.telemetry.deferredRequests or 0) + 1
    self:ScheduleManifestBuild(opts.reason or "request")
    return nil, "building"
end

function Data:GetManifestDebugSnapshot()
    local cache = self:EnsureManifestCache()
    local manifest = cache.manifest
    local tel = cache.telemetry or newManifestTelemetry()
    local avgCostMs = 0
    if (tel.buildsCompleted or 0) > 0 then
        avgCostMs = (tel.totalBuildCostMs or 0) / tel.buildsCompleted
    end
    return {
        ready = manifest ~= nil and not self:IsManifestDirty(),
        hasManifest = manifest ~= nil,
        dirtyAll = cache.dirtyAll == true,
        dirtyBlocks = countKeys(cache.dirtyBlocks),
        building = cache.building == true,
        scheduled = cache.scheduled == true,
        serial = cache.serial or 0,
        blocks = manifest and manifest.totals and manifest.totals.blocks or 0,
        recipes = manifest and manifest.totals and manifest.totals.recipes or 0,
        lastReason = cache.lastReason or "none",
        avgBuildCostMs = avgCostMs,
        maxBuildCostMs = tel.maxBuildCostMs or 0,
        lastBuildCostMs = tel.lastBuildCostMs or 0,
        telemetry = tel,
    }
end

function Data:DumpManifestCacheStatus()
    local snapshot = self:GetManifestDebugSnapshot()
    local telemetry = snapshot.telemetry or {}
    local chunkTelemetry = Addon.TrickleSync and Addon.TrickleSync.GetManifestChunkTelemetry
        and Addon.TrickleSync:GetManifestChunkTelemetry()
        or {}
    local syncTelemetry = Addon.Sync and Addon.Sync.telemetry or {}
    local manifestQueueDepth = Addon.Sync and Addon.Sync.manifestChunkQueue and #Addon.Sync.manifestChunkQueue or 0
    Addon:SystemPrint(string.format(
        "Manifest cache ready=%s dirtyAll=%s dirtyBlocks=%d building=%s scheduled=%s serial=%d blocks=%d recipes=%d builds=%d full=%d delta=%d steps=%d processed=%d hits=%d deferred=%d chunkBuilds=%d chunkHits=%d chunkInvalidations=%d maniQueued=%d maniSent=%d maniQueue=%d avgCostMs=%.2f maxCostMs=%.2f lastCostMs=%.2f last=%s",
        tostring(snapshot.ready),
        tostring(snapshot.dirtyAll),
        snapshot.dirtyBlocks or 0,
        tostring(snapshot.building),
        tostring(snapshot.scheduled),
        snapshot.serial or 0,
        snapshot.blocks or 0,
        snapshot.recipes or 0,
        telemetry.buildsCompleted or 0,
        telemetry.fullBuilds or 0,
        telemetry.deltaBuilds or 0,
        telemetry.buildSteps or 0,
        telemetry.blocksProcessed or 0,
        telemetry.cacheHits or 0,
        telemetry.deferredRequests or 0,
        chunkTelemetry.chunkBuilds or 0,
        chunkTelemetry.chunkCacheHits or 0,
        chunkTelemetry.chunkInvalidations or 0,
        syncTelemetry.manifestChunksQueued or 0,
        syncTelemetry.manifestChunksSent or 0,
        manifestQueueDepth,
        snapshot.avgBuildCostMs or 0,
        snapshot.maxBuildCostMs or 0,
        snapshot.lastBuildCostMs or 0,
        tostring(snapshot.lastReason or "none")
    ))
end

function Data:ResetManifestTelemetry()
    local cache = self:EnsureManifestCache()
    cache.telemetry = newManifestTelemetry()
    if Addon.TrickleSync and Addon.TrickleSync.ResetManifestChunkTelemetry then
        Addon.TrickleSync:ResetManifestChunkTelemetry()
    end
end

function Data:GetDatasetCompletenessEstimate()
    local manifest = self:GetPreparedSyncManifest({ allowStale = true, syncFallback = true, reason = "completeness" })
    return manifest.totals.blocks, manifest.totals.recipes
end

function Data:IsBootstrapCandidate()
    local blockCount, recipeCount = self:GetDatasetCompletenessEstimate()
    return blockCount > 0 and recipeCount > 0
end

function Data:IsBootstrapNeeded()
    local blockCount, recipeCount = self:GetDatasetCompletenessEstimate()
    if blockCount == 0 then return true end
    return recipeCount == 0
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

function Data:MarkMemberActive(memberKey, seenAt)
    local entry = self:GetMember(memberKey)
    if not entry then return false end
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = seenAt or time()
    entry.staleAt = 0
    for professionKey, prof in pairs(entry.professions or {}) do
        prof.guildStatus = "active"
        prof.lastSeenInGuildAt = entry.lastSeenInGuildAt
        entry.professions[professionKey] = self:NormalizeProfessionBlock(entry, professionKey, prof)
    end
    self:MarkManifestMemberDirty(memberKey, entry, "member-active")
    return true
end

function Data:MarkMemberStale(memberKey, staleAt)
    local entry = self:GetMember(memberKey)
    if not entry or entry.owner == self:GetPlayerKey() then return false end
    if entry.guildStatus == "stale" then return false end
    entry.guildStatus = "stale"
    entry.staleAt = staleAt or time()
    for professionKey, prof in pairs(entry.professions or {}) do
        prof.guildStatus = "stale"
        entry.professions[professionKey] = self:NormalizeProfessionBlock(entry, professionKey, prof)
    end
    self:MarkManifestMemberDirty(memberKey, entry, "member-stale")
    self:InvalidateRecipeCaches("presence")
    return true
end

function Data:DeleteMember(memberKey)
    if not memberKey then return false end
    self:MarkManifestMemberDirty(memberKey, self:GetMember(memberKey), "member-delete")
    self.db.global.members[memberKey] = nil
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
            self.db.global.members[memberKey] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        self:MarkManifestDirty(nil, "mock-cleanup")
        self:InvalidateRecipeCaches("presence")
        if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
            Addon.Tooltip:InvalidateIndex()
        end
    end
    return removed
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

function Data:ShouldCleanRecipeFromProfession(profName, recipeKey, opts)
    opts = opts or {}
    if not isValidRecipeKey(recipeKey) then
        return true, "invalid-key"
    end

    if opts.checkProfessionMismatches == false then
        return false
    end

    local actualProfession = self:ResolveRecipeProfession(recipeKey)
    local expectedProfession = type(profName) == "string" and self:GetCanonicalProfession(profName) or nil
    if actualProfession and expectedProfession and actualProfession ~= expectedProfession then
        return true, "profession-mismatch", actualProfession
    end
    return false
end

local function newCorruptCleanStats()
    return {
        removedMembers = 0,
        removedProfessions = 0,
        removedRecipes = 0,
        invalidRecipes = 0,
        mismatchedRecipes = 0,
        repairedBlocks = 0,
        repairedCounts = 0,
        repairedSignatures = 0,
        lastRecipeKey = nil,
        lastMemberKey = nil,
        lastProfession = nil,
        lastReason = nil,
        lastActualProfession = nil,
    }
end

local function hasCorruptCleanChanges(stats)
    return (stats.removedMembers or 0) > 0
        or (stats.removedProfessions or 0) > 0
        or (stats.removedRecipes or 0) > 0
        or (stats.repairedBlocks or 0) > 0
end

local function cleanCorruptMember(data, memberKey, entry, opts, stats, dirtyBlocks)
    opts = opts or {}
    local dryRun = opts.dryRun == true
    local dirtyAll = false

    if not data:IsValidMemberKey(memberKey) or type(entry) ~= "table" then
        stats.removedMembers = stats.removedMembers + 1
        dirtyAll = true
        if not dryRun then
            data.db.global.members[memberKey] = nil
        end
        return dirtyAll
    end

    if type(entry.professions) ~= "table" then
        stats.repairedBlocks = stats.repairedBlocks + 1
        dirtyAll = true
        if not dryRun then
            entry.professions = {}
        end
    end

    for profName, prof in pairs(entry.professions or {}) do
        local removeProfession = type(profName) ~= "string"
            or profName == ""
            or profName:find(":", 1, true) ~= nil
            or type(prof) ~= "table"

        if removeProfession then
            stats.removedProfessions = stats.removedProfessions + 1
            dirtyAll = true
            if not dryRun then
                entry.professions[profName] = nil
            end
        else
            local blockDirty = false
            if type(prof.recipes) ~= "table" then
                blockDirty = true
                if not dryRun then
                    prof.recipes = {}
                end
            end

            local recipeTable = type(prof.recipes) == "table" and prof.recipes or {}
            local toRemove = {}
            for recipeKey in pairs(recipeTable) do
                local shouldRemove, reason, actualProfession = data:ShouldCleanRecipeFromProfession(profName, recipeKey, opts)
                if shouldRemove then
                    toRemove[#toRemove + 1] = {
                        key = recipeKey,
                        reason = reason,
                        actualProfession = actualProfession,
                    }
                    stats.removedRecipes = stats.removedRecipes + 1
                    if reason == "profession-mismatch" then
                        stats.mismatchedRecipes = stats.mismatchedRecipes + 1
                    else
                        stats.invalidRecipes = stats.invalidRecipes + 1
                    end
                    stats.lastRecipeKey = recipeKey
                    stats.lastMemberKey = memberKey
                    stats.lastProfession = profName
                    stats.lastReason = reason
                    stats.lastActualProfession = actualProfession
                end
            end

            for _, removal in ipairs(toRemove) do
                if not dryRun then
                    prof.recipes[removal.key] = nil
                    data:RecordInvalidRecipeKey(removal.key, "clean", memberKey, profName)
                end
                blockDirty = true
                Addon:Debug(
                    "Removed corrupt recipe",
                    tostring(removal.key),
                    "from",
                    memberKey,
                    profName,
                    removal.reason or "unknown",
                    removal.actualProfession or ""
                )
            end

            local recipesForStats = type(prof.recipes) == "table" and prof.recipes or {}
            if dryRun and #toRemove > 0 then
                recipesForStats = cloneTableShallow(recipesForStats)
                for _, removal in ipairs(toRemove) do
                    recipesForStats[removal.key] = nil
                end
            end
            local actualCount = countRecipeKeys(recipesForStats)
            if prof.count ~= actualCount then
                stats.repairedCounts = stats.repairedCounts + 1
                blockDirty = true
                if not dryRun then
                    prof.count = actualCount
                end
            end

            local actualSignature = stableRecipeSignature(recipesForStats)
            if prof.signature ~= actualSignature then
                stats.repairedSignatures = stats.repairedSignatures + 1
                blockDirty = true
                if not dryRun then
                    prof.signature = actualSignature
                end
            end

            if blockDirty then
                stats.repairedBlocks = stats.repairedBlocks + 1
                local blockKey = data:BuildSyncBlockKey(memberKey, profName)
                if blockKey then
                    dirtyBlocks[blockKey] = true
                else
                    dirtyAll = true
                end
            end
        end
    end

    return dirtyAll
end

local function commitCorruptClean(data, stats, dirtyAll, dirtyBlocks, reason)
    if not hasCorruptCleanChanges(stats) then return false end
    if dirtyAll then
        data:MarkManifestDirty(nil, reason or "clean-corrupt")
    else
        for blockKey in pairs(dirtyBlocks or {}) do
            data:MarkManifestDirty(blockKey, reason or "clean-corrupt")
        end
    end
    data:InvalidateRecipeCaches()
    Addon:RequestRefresh(reason or "clean")
    return true
end

function Data:CleanCorruptData(opts)
    opts = opts or {}
    local dryRun = opts.dryRun == true
    local stats = newCorruptCleanStats()
    local dirtyAll = false
    local dirtyBlocks = {}

    for memberKey, entry in pairs(self:GetMembersDB()) do
        dirtyAll = cleanCorruptMember(self, memberKey, entry, opts, stats, dirtyBlocks) or dirtyAll
    end

    if not dryRun then
        commitCorruptClean(self, stats, dirtyAll, dirtyBlocks, "clean-corrupt")
    end

    return stats
end

function Data:ScheduleSafeAutoClean(opts)
    if self._safeAutoCleanScheduled or self._safeAutoCleanCompleted then
        return false
    end
    if not (Addon.Performance and Addon.Performance.ScheduleJob) then
        return false
    end

    opts = opts or {}
    self._safeAutoCleanScheduled = true
    local memberKeys = {}
    for memberKey in pairs(self:GetMembersDB()) do
        memberKeys[#memberKeys + 1] = memberKey
    end
    sort(memberKeys)

    Addon.Performance:ScheduleJob("safe-auto-clean", function(state)
        state.index = state.index or 1
        state.memberKeys = state.memberKeys or memberKeys
        state.stats = state.stats or newCorruptCleanStats()
        state.dirtyBlocks = state.dirtyBlocks or {}
        state.dirtyAll = state.dirtyAll == true

        local processed = 0
        local maxMembersPerStep = opts.maxMembersPerStep or 8
        while processed < maxMembersPerStep do
            local memberKey = state.memberKeys[state.index]
            if not memberKey then
                self._safeAutoCleanCompleted = true
                self._safeAutoCleanScheduled = false
                local syncStats = Addon.Sync and Addon.Sync.CleanCorruptState
                    and Addon.Sync:CleanCorruptState({ dryRun = false })
                    or nil
                state.syncRemoved = syncStats and syncStats.removed or 0
                commitCorruptClean(self, state.stats, state.dirtyAll, state.dirtyBlocks, "auto-clean")
                if hasCorruptCleanChanges(state.stats) or (state.syncRemoved or 0) > 0 then
                    Addon:SystemPrint(string.format(
                        "Auto-clean repaired saved data: members=%d professions=%d recipes=%d repaired=%d sync=%d.",
                        state.stats.removedMembers or 0,
                        state.stats.removedProfessions or 0,
                        state.stats.removedRecipes or 0,
                        (state.stats.repairedBlocks or 0) + (state.stats.repairedCounts or 0) + (state.stats.repairedSignatures or 0),
                        state.syncRemoved or 0
                    ))
                end
                return false, state
            end

            state.dirtyAll = cleanCorruptMember(self, memberKey, self:GetMember(memberKey), {
                checkProfessionMismatches = false,
            }, state.stats, state.dirtyBlocks) or state.dirtyAll
            state.index = state.index + 1
            processed = processed + 1
        end
        return true, state
    end, {
        category = "maintenance",
        label = "safe-auto-clean",
        budgetMs = 1,
        maxStepsPerRun = 1,
        state = {
            memberKeys = memberKeys,
            index = 1,
            stats = newCorruptCleanStats(),
            dirtyBlocks = {},
            dirtyAll = false,
        },
    })

    return true
end

function Data:CleanInvalidRecipes()
    local stats = self:CleanCorruptData({ checkProfessionMismatches = false })
    return stats.removedRecipes or 0
end

function Data:TouchLocalRevision(reason)
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    entry.rev = (entry.rev or 0) + 1
    entry.updatedAt = time()
    entry.lastReason = reason
    entry.sourceType = "owner"
    entry.guildStatus = "active"
    entry.lastSeenInGuildAt = entry.updatedAt
    return entry.rev
end

function Data:ApplyLocalProfessionMetadata(profession, metadata)
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[profession] or { recipes = {} }
    local oldSpecialization = prof.specialization
    local newSpecialization = metadata and metadata.specialization or nil
    local specializationChanged = oldSpecialization ~= newSpecialization

    prof.skillRank = metadata and (metadata.skillRank or 0) or prof.skillRank or 0
    prof.skillMaxRank = metadata and (metadata.skillMaxRank or 0) or prof.skillMaxRank or 0
    prof.specialization = newSpecialization
    prof.sourceType = "owner"
    prof.guildStatus = "active"
    prof.lastSeenInGuildAt = time()
    entry.professions[profession] = self:NormalizeProfessionBlock(entry, profession, prof)

    if not specializationChanged then
        return false, oldSpecialization, newSpecialization
    end

    local newRev = self:TouchLocalRevision("specialization:" .. tostring(profession))
    prof = entry.professions[profession]
    prof.blockRevision = newRev or prof.blockRevision
    prof.lastUpdatedAt = entry.updatedAt or time()
    prof.lastSeenInGuildAt = entry.lastSeenInGuildAt or prof.lastUpdatedAt
    prof.sourceType = "owner"
    prof.guildStatus = "active"
    entry.professions[profession] = self:NormalizeProfessionBlock(entry, profession, prof)
    self:MarkManifestDirty(self:BuildSyncBlockKey(entry.owner or self:GetPlayerKey(), profession), "specialization")
    Addon:Debug(
        "Specialization changed",
        profession,
        tostring(oldSpecialization or "none"),
        "->",
        tostring(newSpecialization or "none")
    )
    return true, oldSpecialization, newSpecialization
end

function Data:DetectProfessions()
    self._currentProfs = {}
    local metadataChanged = false
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, skillRank, _, _, skillMaxRank = GetSkillLineInfo(i)
        if not isHeader and name then
            local canonical = self:GetCanonicalProfession(name)
            if TRACKED[canonical] then
                local specialization = detectSpecialization(canonical)
                self._currentProfs[canonical] = {
                    skillRank = skillRank or 0,
                    skillMaxRank = skillMaxRank or 0,
                    specialization = specialization,
                }
                local entry = self:GetOrCreateMember(self:GetPlayerKey())
                local wasNewProfession = entry.professions[canonical] == nil
                entry.professions[canonical] = entry.professions[canonical] or { recipes = {} }
                local changed = self:ApplyLocalProfessionMetadata(canonical, self._currentProfs[canonical])
                metadataChanged = changed or metadataChanged
                if wasNewProfession then
                    self:MarkManifestDirty(self:BuildSyncBlockKey(entry.owner or self:GetPlayerKey(), canonical), "detect-profession")
                end
            end
        end
    end
    Addon:RequestRefresh("detect-professions")
    return metadataChanged
end

function Data:RebuildOnlineCache()
    self._onlineCache = {}
    self._guildMetaCache = {}
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
                self._onlineCache[memberKey] = true
            end
            self._guildMetaCache[memberKey] = {
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
end

function Data:IsMemberOnline(memberKey)
    return self._onlineCache[memberKey] == true
end

function Data:GetGuildMemberMeta(memberKey)
    return self._guildMetaCache and self._guildMetaCache[memberKey] or nil
end

function Data:EnsureScanState()
    self._scanNeededByProfession = self._scanNeededByProfession or {}
    self._genericScanAttempts = self._genericScanAttempts or {}
    if type(self._scanTelemetry) ~= "table" then
        self._scanTelemetry = newScanTelemetry()
    end
end

function Data:RecordScanTelemetry(field, amount)
    self:EnsureScanState()
    self._scanTelemetry[field] = (self._scanTelemetry[field] or 0) + (amount or 1)
end

function Data:RecordInvalidRecipeKey(recipeKey, context, memberKey, profession)
    self:EnsureScanState()
    local t = self._scanTelemetry
    t.invalidRecipesBlocked = (t.invalidRecipesBlocked or 0) + 1
    if context == "snapshot" then
        t.invalidRecipesSnapshot = (t.invalidRecipesSnapshot or 0) + 1
    elseif context == "inbound" then
        t.invalidRecipesInbound = (t.invalidRecipesInbound or 0) + 1
    elseif context == "clean" then
        t.invalidRecipesCleaned = (t.invalidRecipesCleaned or 0) + 1
    elseif context == "scan" then
        t.invalidRecipesScan = (t.invalidRecipesScan or 0) + 1
    end
    t.lastInvalidRecipeKey = recipeKey
    t.lastInvalidRecipeContext = context
    t.lastInvalidRecipeMember = memberKey
    t.lastInvalidRecipeProfession = profession
end

function Data:MarkScanNeeded(profession, reason)
    self:EnsureScanState()
    local canonical = profession and self:GetCanonicalProfession(profession) or nil
    if canonical and TRACKED[canonical] then
        self._scanNeededByProfession[canonical] = reason or true
    else
        self._genericScanNeeded = reason or true
        self._genericScanAttempts = {}
    end
    self._scanNeeded = true
    self:RecordScanTelemetry("signals")
end

function Data:HasScanPending(profession)
    self:EnsureScanState()
    local canonical = profession and self:GetCanonicalProfession(profession) or nil
    if canonical and self._scanNeededByProfession[canonical] then
        return true
    end
    if self._genericScanNeeded ~= nil then
        return true
    end
    return self._scanNeeded == true and next(self._scanNeededByProfession) == nil
end

function Data:HasAnyScanPending()
    self:EnsureScanState()
    if self._genericScanNeeded ~= nil then
        return true
    end
    return next(self._scanNeededByProfession) ~= nil
end

function Data:SyncLegacyScanFlag()
    self._scanNeeded = self:HasAnyScanPending()
end

function Data:CompleteScanAttempt(result)
    if not result or not result.profession then return end
    self:EnsureScanState()
    if not result.valid or result.suspectedPartial then
        self:SyncLegacyScanFlag()
        return
    end

    local hadGenericPending = self._genericScanNeeded ~= nil
        or (self._scanNeeded == true and next(self._scanNeededByProfession) == nil)
    local genericReason = self._genericScanNeeded
    self._scanNeededByProfession[result.profession] = nil
    if hadGenericPending then
        if result.changed or genericReason == "manual-rescan" or genericReason == nil then
            self._genericScanNeeded = nil
            self._genericScanAttempts = {}
        else
            self._genericScanAttempts[result.profession] = true
        end
    end
    self:SyncLegacyScanFlag()
end

function Data:MakeScanResult(profession, opts)
    opts = opts or {}
    return {
        profession = profession,
        changed = opts.changed == true,
        valid = opts.valid == true,
        skipped = opts.skipped == true,
        skipReason = opts.skipReason,
        count = opts.count or 0,
        previousCount = opts.previousCount or 0,
        suspectedPartial = opts.suspectedPartial == true,
    }
end

function Data:SkipScan(profession, reason, previousCount)
    self:EnsureScanState()
    self:RecordScanTelemetry("scansSkipped")
    self._scanTelemetry.lastProfession = profession
    self._scanTelemetry.lastSkipReason = reason
    return self:MakeScanResult(profession, {
        skipped = true,
        skipReason = reason,
        previousCount = previousCount or 0,
    })
end

function Data:GetScanTelemetry()
    self:EnsureScanState()
    return self._scanTelemetry
end

function Data:ResetScanTelemetry()
    self._scanTelemetry = newScanTelemetry()
end

function Data:DumpScanStatus()
    local scan = self:GetScanTelemetry()
    Addon:SystemPrint(string.format(
        "Scan signals=%d started=%d changed=%d unchanged=%d skipped=%d failed=%d partial=%d invalid=%d pending=%s last=%s/%s",
        scan.signals or 0,
        scan.scansStarted or 0,
        scan.scansChanged or 0,
        scan.scansUnchanged or 0,
        scan.scansSkipped or 0,
        scan.scansFailed or 0,
        scan.suspectedPartial or 0,
        scan.invalidRecipesBlocked or 0,
        tostring(self:HasAnyScanPending()),
        tostring(scan.lastProfession or "none"),
        tostring(scan.lastSkipReason or "none")
    ))
    if (scan.invalidRecipesBlocked or 0) > 0 then
        Addon:SystemPrint(string.format(
            "Recipe validation snapshot=%d inbound=%d cleaned=%d last=%s/%s/%s/%s",
            scan.invalidRecipesSnapshot or 0,
            scan.invalidRecipesInbound or 0,
            scan.invalidRecipesCleaned or 0,
            tostring(scan.lastInvalidRecipeContext or "none"),
            tostring(scan.lastInvalidRecipeKey or "none"),
            tostring(scan.lastInvalidRecipeMember or "none"),
            tostring(scan.lastInvalidRecipeProfession or "none")
        ))
    end
end

function Data:GetActiveTradeSkillProfession()
    local title = GetTradeSkillLine and GetTradeSkillLine()
    if not title or title == "" or title == "UNKNOWN" then
        return nil, "trade-no-title"
    end
    local canonical = self:GetCanonicalProfession(title)
    if not TRACKED[canonical] then
        return canonical, "trade-untracked"
    end
    return canonical
end

function Data:CanScanTradeSkillData()
    local canonical, reason = self:GetActiveTradeSkillProfession()
    if not canonical then
        return false, reason or "trade-no-title", canonical
    end
    if reason then
        return false, reason, canonical
    end
    if type(GetNumTradeSkills) ~= "function" or type(GetTradeSkillInfo) ~= "function" then
        return false, "trade-api-missing", canonical
    end
    local numSkills = GetNumTradeSkills()
    if type(numSkills) ~= "number" or numSkills <= 0 then
        return false, "trade-data-not-ready", canonical
    end
    return true, nil, canonical, numSkills
end

function Data:GetActiveCraftProfession()
    local title = GetCraftSkillLine and GetCraftSkillLine(1)
    if not title or title == "" or title == "UNKNOWN" then
        title = GetCraftDisplaySkillLine and GetCraftDisplaySkillLine()
    end
    if not title or title == "" or title == "UNKNOWN" then
        return nil, "craft-no-title"
    end
    local canonical = self:GetCanonicalProfession(title)
    if canonical ~= "Enchanting" then
        return canonical, "craft-not-enchanting"
    end
    return canonical
end

function Data:CanScanCraftData()
    local canonical, reason = self:GetActiveCraftProfession()
    if not canonical then
        return false, reason or "craft-no-title", canonical
    end
    if reason then
        return false, reason, canonical
    end
    if type(GetNumCrafts) ~= "function" or type(GetCraftInfo) ~= "function" then
        return false, "craft-api-missing", canonical
    end
    local numCrafts = GetNumCrafts()
    if type(numCrafts) ~= "number" or numCrafts <= 0 then
        return false, "craft-data-not-ready", canonical
    end
    return true, nil, canonical, numCrafts
end

function Data:ScanTradeSkill()
    self:EnsureScanState()
    local canScan, reason, canonical, initialNumSkills = self:CanScanTradeSkillData()
    if not canScan then return self:SkipScan(canonical, reason or "trade-data-not-ready") end

    -- Routine opens reuse cached owner data; pending recipe signals and first
    -- scans still force a full read of the active profession.
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[canonical]
    local hasData = prof and prof.count and prof.count > 0
    if hasData and not self:HasScanPending(canonical) then
        return self:SkipScan(canonical, "cached", prof.count or 0)
    end

    self:RecordScanTelemetry("scansStarted")
    self._scanTelemetry.lastProfession = canonical
    self._scanTelemetry.lastSkipReason = nil
    local filterState = snapshotTradeSkillFilters()
    clearTradeSkillFilters()

    local recipes = {}
    local collapsedHeaders = {}
    local ok, err = pcall(function()
        -- Record which headers were collapsed so we can re-collapse after scan.
        local numSkills = initialNumSkills or GetNumTradeSkills() or 0
        for i = numSkills, 1, -1 do
            local headerName, recipeType, _, isExpanded = GetTradeSkillInfo(i)
            if recipeType == "header" and not isExpanded then
                collapsedHeaders[headerName or i] = true
                pcall(ExpandTradeSkillSubClass, i)
            end
        end

        numSkills = GetNumTradeSkills() or 0
        for i = 1, numSkills do
            local recipeName, recipeType = GetTradeSkillInfo(i)
            if recipeName and recipeType ~= "header" and recipeType ~= "subheader" then
                local itemID, invalidItemID = extractItemID(GetTradeSkillItemLink(i))
                local recipeKey = invalidItemID or itemID or -(extractSpellID(GetTradeSkillRecipeLink(i)) or i)
                if isValidRecipeKey(recipeKey) then
                    recipes[recipeKey] = true
                else
                    self:RecordInvalidRecipeKey(recipeKey, "scan", self:GetPlayerKey(), canonical)
                    Addon:Debug("Blocked invalid recipe from TradeSkill scan:", recipeKey, "profession:", canonical)
                end
            end
        end

        -- Re-collapse previously collapsed headers to restore visual state.
        if next(collapsedHeaders) then
            numSkills = GetNumTradeSkills() or 0
            local CollapseTradeSkillSubClass = CollapseTradeSkillSubClass
            if type(CollapseTradeSkillSubClass) == "function" then
                for i = 1, numSkills do
                    local headerName, recipeType, _, isExpanded = GetTradeSkillInfo(i)
                    if recipeType == "header" and isExpanded and collapsedHeaders[headerName or i] then
                        pcall(CollapseTradeSkillSubClass, i)
                    end
                end
            end
        end
    end)

    restoreTradeSkillFilters(filterState)

    if not ok then
        Addon:SystemPrint("Trade skill scan failed: " .. tostring(err))
        self:RecordScanTelemetry("scansFailed")
        return self:MakeScanResult(canonical, {
            valid = false,
            skipReason = "trade-scan-failed",
            previousCount = prof and prof.count or 0,
        })
    end

    return self:ApplyScanResult(canonical, recipes)
end

function Data:ScanCraft()
    self:EnsureScanState()
    local canScan, reason, canonical, initialNumCrafts = self:CanScanCraftData()
    if not canScan then
        if reason == "craft-not-enchanting" then
            -- CraftFrame is open for a non-Enchanting skill (e.g. Beast Training).
            -- Skip the scan to avoid storing class spells as Enchanting recipes.
            Addon:Debug("ScanCraft skipped: CraftFrame shows", canonical or "nil")
        end
        return self:SkipScan(canonical, reason or "craft-data-not-ready")
    end

    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[canonical]
    local hasData = prof and prof.count and prof.count > 0
    if hasData and not self:HasScanPending(canonical) then
        return self:SkipScan(canonical, "cached", prof.count or 0)
    end

    self:RecordScanTelemetry("scansStarted")
    self._scanTelemetry.lastProfession = canonical
    self._scanTelemetry.lastSkipReason = nil
    local filterState = snapshotCraftFilters()
    clearCraftFilters()

    local recipes = {}
    local ok, err = pcall(function()
        for i = 1, (initialNumCrafts or GetNumCrafts() or 0) do
            local recipeName, recipeType = GetCraftInfo(i)
            if recipeName and recipeType ~= "header" and recipeType ~= "subheader" then
                local itemID, invalidItemID = extractItemID(GetCraftItemLink(i))
                local recipeKey = invalidItemID or itemID or -(extractSpellID(GetCraftRecipeLink(i)) or i)
                if isValidRecipeKey(recipeKey) then
                    recipes[recipeKey] = true
                else
                    self:RecordInvalidRecipeKey(recipeKey, "scan", self:GetPlayerKey(), canonical)
                    Addon:Debug("Blocked invalid recipe from Craft scan:", recipeKey, "profession:", canonical)
                end
            end
        end
    end)

    restoreCraftFilters(filterState)

    if not ok then
        Addon:SystemPrint("Craft scan failed: " .. tostring(err))
        self:RecordScanTelemetry("scansFailed")
        return self:MakeScanResult(canonical, {
            valid = false,
            skipReason = "craft-scan-failed",
            previousCount = prof and prof.count or 0,
        })
    end

    return self:ApplyScanResult(canonical, recipes)
end

function Data:WarnSuspiciousScan(profession, previousCount, count)
    self._lastPartialScanWarning = self._lastPartialScanWarning or {}
    local now = time()
    local last = self._lastPartialScanWarning[profession] or 0
    if now - last >= 60 then
        self._lastPartialScanWarning[profession] = now
        Addon:SystemPrint(string.format(
            "Skipped %s scan: found %d recipe(s), keeping existing owner data with %d. Reopen the profession to retry.",
            tostring(profession),
            count or 0,
            previousCount or 0
        ))
    else
        Addon:Debug("Skipped suspicious partial scan", profession, "new", count or 0, "old", previousCount or 0)
    end
end

function Data:ApplyScanResult(profession, recipeKeys)
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[profession] or { recipes = {} }
    local oldSignature = prof.signature or ""
    local newSignature = stableRecipeSignature(recipeKeys)
    local recipeChanged = (oldSignature ~= newSignature)
    local previousCount = prof.count or countRecipeKeys(prof.recipes)
    local count = countRecipeKeys(recipeKeys)
    local oldSpecialization = prof.specialization

    if previousCount > 0 and count < previousCount then
        self:RecordScanTelemetry("suspectedPartial")
        prof.lastScanAttempt = time()
        prof.lastScanSkipReason = "suspected-partial"
        entry.professions[profession] = prof
        self:WarnSuspiciousScan(profession, previousCount, count)
        local result = self:MakeScanResult(profession, {
            valid = true,
            changed = false,
            count = count,
            previousCount = previousCount,
            suspectedPartial = true,
            skipReason = "suspected-partial",
        })
        self:CompleteScanAttempt(result)
        return result
    end

    prof.recipes = {}
    for recipeKey in pairs(recipeKeys or {}) do
        prof.recipes[recipeKey] = true
    end
    prof.signature = newSignature
    prof.count = count
    prof.lastScan = time()
    prof.blockRevision = (entry.rev or 0) + (changed and 1 or 0)
    prof.lastUpdatedAt = prof.lastScan
    prof.sourceType = "owner"
    prof.guildStatus = "active"
    prof.lastSeenInGuildAt = prof.lastScan

    if self._currentProfs[profession] then
        prof.skillRank = self._currentProfs[profession].skillRank or 0
        prof.skillMaxRank = self._currentProfs[profession].skillMaxRank or 0
        prof.specialization = self._currentProfs[profession].specialization
    end
    local specializationChanged = oldSpecialization ~= prof.specialization
    local changed = recipeChanged or specializationChanged

    entry.professions[profession] = prof

    if changed then
        self:RecordScanTelemetry("scansChanged")
        if specializationChanged and not recipeChanged then
            self:TouchLocalRevision("specialization-scan:" .. profession)
        else
            self:TouchLocalRevision("scan:" .. profession)
        end
        prof.blockRevision = entry.rev or prof.blockRevision
        self:MarkManifestDirty(
            self:BuildSyncBlockKey(entry.owner or self:GetPlayerKey(), profession),
            specializationChanged and not recipeChanged and "specialization-scan" or "scan"
        )
        if recipeChanged then
            Addon:Debug("Scan changed", profession, count, "recipe ids")
            Addon:SystemPrint(string.format("Scanned %s: %d recipe(s) found.", profession, count))
        else
            Addon:Debug(
                "Scan specialization changed",
                profession,
                tostring(oldSpecialization or "none"),
                "->",
                tostring(prof.specialization or "none")
            )
            Addon:SystemPrint(string.format(
                "Scanned %s: specialization updated to %s.",
                profession,
                tostring(prof.specialization or "none")
            ))
        end
    else
        self:RecordScanTelemetry("scansUnchanged")
        Addon:SystemPrint(string.format("Scanned %s: unchanged (%d recipe(s)).", profession, count))
    end

    self:InvalidateRecipeCaches()
    Addon:RequestRefresh("scan")
    local result = self:MakeScanResult(profession, {
        valid = true,
        changed = changed,
        count = count,
        previousCount = previousCount,
    })
    self:CompleteScanAttempt(result)
    return result
end

function Data:GetLocalSummary()
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local profCount, recipeCount = 0, 0
    for _, prof in pairs(entry.professions or {}) do
        profCount = profCount + 1
        recipeCount = recipeCount + (prof.count or 0)
    end
    return {
        memberKey = self:GetPlayerKey(),
        rev = entry.rev or 0,
        updatedAt = entry.updatedAt or 0,
        professions = profCount,
        recipes = recipeCount,
    }
end

function Data:BuildSnapshotChunks(memberKey, opts)
    local entry = self:GetMember(memberKey)
    if not entry then return {} end
    opts = opts or {}

    local requestedProfessions = nil
    if type(opts.requestedBlocks) == "table" and #opts.requestedBlocks > 0 then
        requestedProfessions = {}
        for _, blockKey in ipairs(opts.requestedBlocks) do
            local ownerCharacter, professionKey = self:ParseSyncBlockKey(blockKey)
            if ownerCharacter == memberKey and professionKey then
                requestedProfessions[professionKey] = true
            end
        end
    end

    local chunks = {}
    local chunkSize = 120
    local profNames = {}
    for profName in pairs(entry.professions or {}) do
        if not requestedProfessions or requestedProfessions[profName] then
            profNames[#profNames + 1] = profName
        end
    end
    sort(profNames)

    for _, profName in ipairs(profNames) do
        local prof = entry.professions[profName]
        local pending = {}
        local count = 0
        local recipeKeys = {}
        for recipeKey in pairs(prof.recipes or {}) do
            if isValidRecipeKey(recipeKey) then
                recipeKeys[#recipeKeys + 1] = recipeKey
            else
                self:RecordInvalidRecipeKey(recipeKey, "snapshot", memberKey, profName)
            end
        end
        sort(recipeKeys, function(a, b) return tostring(a) < tostring(b) end)

        for _, recipeKey in ipairs(recipeKeys) do
            pending[#pending + 1] = recipeKey
            count = count + 1
            if count >= chunkSize then
                chunks[#chunks + 1] = {
                    memberKey = memberKey,
                    rev = entry.rev or 0,
                    updatedAt = entry.updatedAt or 0,
                    sourceType = entry.sourceType or self:GetMemberSourceType(memberKey),
                    profession = profName,
                    skillRank = prof.skillRank or 0,
                    skillMaxRank = prof.skillMaxRank or 0,
                    specialization = prof.specialization or nil,
                    recipeKeys = pending,
                    partial = true,
                }
                pending = {}
                count = 0
            end
        end

        chunks[#chunks + 1] = {
            memberKey = memberKey,
            rev = entry.rev or 0,
            updatedAt = entry.updatedAt or 0,
            sourceType = entry.sourceType or self:GetMemberSourceType(memberKey),
            profession = profName,
            skillRank = prof.skillRank or 0,
            skillMaxRank = prof.skillMaxRank or 0,
            specialization = prof.specialization or nil,
            recipeKeys = pending,
            partial = false,
        }
    end

    if #chunks == 0 and not requestedProfessions then
        chunks[1] = {
            memberKey = memberKey,
            rev = entry.rev or 0,
            updatedAt = entry.updatedAt or 0,
            sourceType = entry.sourceType or self:GetMemberSourceType(memberKey),
            profession = nil,
            recipeKeys = {},
            partial = false,
        }
    end

    return chunks
end

function Data:BeginIncomingSnapshot(memberKey, rev, updatedAt)
    self._incoming = self._incoming or {}
    self._incoming[memberKey] = {
        memberKey = memberKey,
        rev = rev,
        updatedAt = updatedAt,
        professions = {},
    }
end

function Data:AppendIncomingChunk(chunk)
    if not chunk or not chunk.memberKey then return end
    self._incoming = self._incoming or {}
    local state = self._incoming[chunk.memberKey]
    if not state or state.rev ~= chunk.rev then
        self:BeginIncomingSnapshot(chunk.memberKey, chunk.rev, chunk.updatedAt)
        state = self._incoming[chunk.memberKey]
    end

    if chunk.profession then
        local prof = state.professions[chunk.profession] or {
            skillRank = chunk.skillRank or 0,
            skillMaxRank = chunk.skillMaxRank or 0,
            specialization = chunk.specialization or nil,
            recipes = {},
            sourceType = chunk.sourceType or "replica",
        }
        for _, recipeKey in ipairs(chunk.recipeKeys or {}) do
            if isValidRecipeKey(recipeKey) then
                prof.recipes[recipeKey] = true
            else
                self:RecordInvalidRecipeKey(recipeKey, "inbound", chunk.memberKey, chunk.profession)
                Addon:Debug("Blocked invalid recipe from sync:", recipeKey, "profession:", chunk.profession, "from:", chunk.memberKey)
            end
        end
        prof.skillRank = chunk.skillRank or prof.skillRank or 0
        prof.skillMaxRank = chunk.skillMaxRank or prof.skillMaxRank or 0
        if chunk.specialization ~= nil then
            prof.specialization = chunk.specialization
        end
        prof.lastUpdatedAt = chunk.updatedAt or state.updatedAt or time()
        prof.sourceType = chunk.sourceType or prof.sourceType or "replica"
        state.professions[chunk.profession] = prof
    end
end

function Data:FinalizeIncomingSnapshot(memberKey, rev, opts)
    if not self._incoming or not self._incoming[memberKey] then return false end
    local state = self._incoming[memberKey]
    if state.rev ~= rev then return false end
    opts = opts or {}

    local current = self:GetMember(memberKey)

    local finalEntry = {
        owner = memberKey,
        rev = rev,
        updatedAt = state.updatedAt or time(),
        sourceType = opts.sourceType or state.sourceType or "replica",
        guildStatus = "active",
        lastSeenInGuildAt = time(),
        isMock = opts.isMock == true,
        professions = {},
    }

    for profName, prof in pairs(state.professions or {}) do
        local incomingRecipes = prof.recipes or {}
        local count = 0
        for _ in pairs(incomingRecipes) do count = count + 1 end

        local currentProf = current and current.professions and current.professions[profName] or nil
        local currentCount = currentProf and (currentProf.count or countRecipeKeys(currentProf.recipes)) or 0
        local protectedPartial = false
        if currentProf and currentProf.recipes and currentCount > count then
            local incomingRank = prof.skillRank or 0
            local currentRank = currentProf.skillRank or 0
            if incomingRank >= currentRank and isSubsetOf(incomingRecipes, currentProf.recipes) then
                local incomingCount = count
                local merged = {}
                for recipeKey in pairs(currentProf.recipes) do merged[recipeKey] = true end
                for recipeKey in pairs(incomingRecipes) do merged[recipeKey] = true end
                incomingRecipes = merged
                count = 0
                for _ in pairs(incomingRecipes) do count = count + 1 end
                protectedPartial = true
                Addon:SystemPrint(string.format(
                    "Protected %s %s from a partial remote overwrite (%d -> %d kept, source=%s).",
                    memberKey,
                    profName,
                    incomingCount,
                    currentCount,
                    tostring(prof.sourceType or finalEntry.sourceType or "replica")
                ))
            end
        end

        local skillRank = prof.skillRank or 0
        local skillMaxRank = prof.skillMaxRank or 0
        local specialization = prof.specialization or nil
        local blockRevision = rev
        local lastUpdatedAt = state.updatedAt or time()
        local sourceType = prof.sourceType or finalEntry.sourceType
        if protectedPartial and currentProf then
            skillRank = math.max(currentProf.skillRank or 0, skillRank)
            skillMaxRank = math.max(currentProf.skillMaxRank or 0, skillMaxRank)
            specialization = specialization or currentProf.specialization
            blockRevision = currentProf.blockRevision or blockRevision
            lastUpdatedAt = currentProf.lastUpdatedAt or lastUpdatedAt
            sourceType = currentProf.sourceType or sourceType
        end

        finalEntry.professions[profName] = {
            skillRank = skillRank,
            skillMaxRank = skillMaxRank,
            specialization = specialization,
            recipes = incomingRecipes,
            count = count,
            signature = stableRecipeSignature(incomingRecipes),
            lastScan = state.updatedAt or time(),
            blockRevision = blockRevision,
            lastUpdatedAt = lastUpdatedAt,
            sourceType = sourceType,
            guildStatus = "active",
            lastSeenInGuildAt = finalEntry.lastSeenInGuildAt,
        }
    end

    if current and finalEntry.sourceType ~= "owner" then
        local preserved = 0
        for profName, currentProf in pairs(current.professions or {}) do
            if not finalEntry.professions[profName] then
                local clone = cloneTableShallow(currentProf)
                clone.recipes = {}
                for recipeKey in pairs(currentProf.recipes or {}) do
                    clone.recipes[recipeKey] = true
                end
                finalEntry.professions[profName] = clone
                preserved = preserved + 1
            end
        end
        if preserved > 0 then
            Addon:Debug("Preserved", preserved, "profession block(s) missing from incoming snapshot for", memberKey)
        end
    end

    local applied, reason, resolved = Addon.MergeEngine:ApplyIfNewer(current, finalEntry, {
        preserveOwner = memberKey == self:GetPlayerKey(),
    })
    self._incoming[memberKey] = nil

    if not applied then
        if Addon.Sync and Addon.Sync.RecordMergeSkip then
            Addon.Sync:RecordMergeSkip(reason)
        end
        return false
    end

    self.db.global.members[memberKey] = self:NormalizeMemberEntry(resolved, memberKey)
    self:MarkManifestMemberDirty(memberKey, self.db.global.members[memberKey], "snapshot-merge")
    self:InvalidateRecipeCaches()
    Addon:RequestRefresh("snapshot-merge")
    if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
        Addon.Tooltip:InvalidateIndex()
    end
    return true
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
                            crafters = {},
                            crafterRows = {},
                            crafterCount = 0,
                            onlineCount = 0,
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

                    if not row.crafters[memberKey] then
                        row.crafters[memberKey] = true
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

    self._recipeIndex = index
    return index
end

function Data:GetRecipeIndex()
    return self._recipeIndex or self:BuildRecipeIndex()
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

    -- Refresh label if it is still a placeholder
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
        -- AtlasLoot can miss some direct-enchant entries depending on dataset/version.
        -- Keep spell-based recipes usable by falling back to native spell data.
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
    self._recipeDetailCache[recipeKey] = info
    return info
end

function Data:GetRecipeList(profName, query, sortMode)
    sortMode = sortMode or "alpha"
    local cacheKey = tostring(profName or "") .. "	" .. lowerSafe(query) .. "	" .. tostring(sortMode)
    self._recipeListCache = self._recipeListCache or {}
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

    self._recipeListCache[cacheKey] = out
    return out
end

function Data:GetRecipeCrafters(recipeKey)
    self._recipeCraftersCache = self._recipeCraftersCache or {}
    local cached = self._recipeCraftersCache[recipeKey]
    if cached then
        return cached
    end

    local rows = {}
    local indexed = self:GetRecipeIndex()[recipeKey]
    if indexed and indexed.crafterRows then
        for i = 1, #indexed.crafterRows do
            rows[#rows + 1] = indexed.crafterRows[i]
        end
    end
    sort(rows, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.skillRank ~= b.skillRank then return a.skillRank > b.skillRank end
        return a.memberKey < b.memberKey
    end)
    self._recipeCraftersCache[recipeKey] = rows
    return rows
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
    Addon:SystemPrint(string.format("Members=%d Professions=%d Recipes=%d | Local rev=%d updated=%d", totalMembers, totalProfs, totalRecipes, s.rev, s.updatedAt))
    self:DumpScanStatus()
end

function Data:DumpLocalSyncStatus(professionFilter)
    local memberKey = self:GetPlayerKey()
    local entry = self:GetOrCreateMember(memberKey)
    local professionKeys = {}
    local totalRecipes = 0

    for profName, prof in pairs(entry.professions or {}) do
        professionKeys[#professionKeys + 1] = profName
        totalRecipes = totalRecipes + (prof.count or countRecipeKeys(prof.recipes))
    end
    sort(professionKeys)

    Addon:SystemPrint(string.format(
        "Local sync owner=%s rev=%d updated=%d professions=%d recipes=%d",
        tostring(memberKey),
        entry.rev or 0,
        entry.updatedAt or 0,
        #professionKeys,
        totalRecipes
    ))

    if #professionKeys == 0 then
        Addon:SystemPrint("Local sync professions: none")
        return
    end

    local requestedProfession = tostring(professionFilter or ""):match("^%s*(.-)%s*$") or ""
    if requestedProfession ~= "" then
        local canonical = self:GetCanonicalProfession(requestedProfession)
        local resolved = entry.professions[canonical] and canonical or nil
        if not resolved then
            for _, profName in ipairs(professionKeys) do
                if lowerSafe(profName) == lowerSafe(canonical) or lowerSafe(profName) == lowerSafe(requestedProfession) then
                    resolved = profName
                    break
                end
            end
        end
        if not resolved then
            Addon:SystemPrint("Local sync profession not found: " .. tostring(requestedProfession) .. ".")
            return
        end
        professionKeys = { resolved }
    end

    for _, profName in ipairs(professionKeys) do
        local prof = entry.professions[profName]
        Addon:SystemPrint(string.format(
            "  %s count=%d skill=%d/%d spec=%s blockRev=%d source=%s updated=%d",
            tostring(profName),
            prof and (prof.count or countRecipeKeys(prof.recipes)) or 0,
            prof and (prof.skillRank or 0) or 0,
            prof and (prof.skillMaxRank or 0) or 0,
            tostring(prof and prof.specialization or "none"),
            prof and (prof.blockRevision or 0) or 0,
            tostring(prof and prof.sourceType or "owner"),
            prof and (prof.lastUpdatedAt or 0) or 0
        ))
    end
end

function Data:DumpManifestSummary(opts)
    opts = opts or {}
    local verbose = opts.verbose == true
    local manifest = self:BuildSyncManifest(false)
    local localKey = self:GetPlayerKey()
    local totalBlocks = 0
    local totalRecipes = 0
    local ownerBlocks = 0
    local replicaBlocks = 0
    local replicaOwners = {}
    local staleMembers = 0
    local staleOwnerKeys = {}

    for memberKey, entry in pairs(self:GetMembersDB()) do
        if not self:IsMockMember(memberKey, entry) and (entry.guildStatus or "active") == "stale" then
            staleMembers = staleMembers + 1
            staleOwnerKeys[#staleOwnerKeys + 1] = memberKey
        end
    end

    for _, block in pairs(manifest.blocks or {}) do
        totalBlocks = totalBlocks + 1
        totalRecipes = totalRecipes + (block.count or 0)
        if block.ownerCharacter == localKey and (block.sourceType or "owner") == "owner" then
            ownerBlocks = ownerBlocks + 1
        else
            replicaBlocks = replicaBlocks + 1
            replicaOwners[block.ownerCharacter] = replicaOwners[block.ownerCharacter] or {
                blocks = 0,
                recipes = 0,
                sourceType = block.sourceType or "replica",
                professions = {},
            }
            replicaOwners[block.ownerCharacter].blocks = replicaOwners[block.ownerCharacter].blocks + 1
            replicaOwners[block.ownerCharacter].recipes = replicaOwners[block.ownerCharacter].recipes + (block.count or 0)
            replicaOwners[block.ownerCharacter].sourceType = block.sourceType or replicaOwners[block.ownerCharacter].sourceType
            replicaOwners[block.ownerCharacter].professions[#replicaOwners[block.ownerCharacter].professions + 1] = block.professionKey
        end
    end

    local replicaOwnerKeys = {}
    for ownerCharacter in pairs(replicaOwners) do
        replicaOwnerKeys[#replicaOwnerKeys + 1] = ownerCharacter
    end
    sort(replicaOwnerKeys)

    Addon:SystemPrint(string.format(
        "Manifest local=%s blocks=%d recipes=%d ownerBlocks=%d replicaBlocks=%d replicaOwners=%d staleMembers=%d",
        tostring(localKey),
        totalBlocks,
        totalRecipes,
        ownerBlocks,
        replicaBlocks,
        #replicaOwnerKeys,
        staleMembers
    ))

    if #replicaOwnerKeys == 0 then
        Addon:SystemPrint("Manifest replica owners: none")
    elseif not verbose then
        Addon:SystemPrint(string.format(
            "Manifest replica owners: %d (use /rr manifest verbose for details)",
            #replicaOwnerKeys
        ))
    else
        Addon:SystemPrint("Manifest replica owners:")
        local maxLines = math.min(#replicaOwnerKeys, 12)
        for index = 1, maxLines do
            local ownerCharacter = replicaOwnerKeys[index]
            local info = replicaOwners[ownerCharacter]
            sort(info.professions)
            Addon:SystemPrint(string.format(
                "  %s blocks=%d recipes=%d publish=replica authority=%s professions=%s",
                tostring(ownerCharacter),
                info.blocks or 0,
                info.recipes or 0,
                tostring(info.sourceType or "replica"),
                table.concat(info.professions or {}, ",")
            ))
        end
        if #replicaOwnerKeys > maxLines then
            Addon:SystemPrint(string.format("  ... and %d more", #replicaOwnerKeys - maxLines))
        end
    end
    if #staleOwnerKeys > 0 then
        sort(staleOwnerKeys)
        if not verbose then
            Addon:SystemPrint(string.format(
                "Manifest stale excluded: %d (use /rr manifest verbose for details)",
                #staleOwnerKeys
            ))
        else
            Addon:SystemPrint("Manifest stale excluded:")
            local maxStaleLines = math.min(#staleOwnerKeys, 8)
            for index = 1, maxStaleLines do
                local memberKey = staleOwnerKeys[index]
                local entry = self:GetMember(memberKey)
                local profCount = 0
                for _ in pairs(entry and entry.professions or {}) do
                    profCount = profCount + 1
                end
                Addon:SystemPrint(string.format("  %s professions=%d", tostring(memberKey), profCount))
            end
            if #staleOwnerKeys > maxStaleLines then
                Addon:SystemPrint(string.format("  ... and %d more", #staleOwnerKeys - maxStaleLines))
            end
        end
    end

    local snapshot = self:GetManifestDebugSnapshot()
    local syncTel = Addon.Sync and Addon.Sync.telemetry or {}
    Addon:SystemPrint(string.format(
        "Manifest builds=%d (full=%d delta=%d) avgCostMs=%.2f maxCostMs=%.2f requests=%d cooldownSkips=%d forceReplies=%d",
        snapshot.telemetry.buildsCompleted or 0,
        snapshot.telemetry.fullBuilds or 0,
        snapshot.telemetry.deltaBuilds or 0,
        snapshot.avgBuildCostMs or 0,
        snapshot.maxBuildCostMs or 0,
        syncTel.manifestBuildRequests or 0,
        syncTel.manifestCooldownSkips or 0,
        syncTel.manifestForceReplies or 0
    ))
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
    Addon:SystemPrint(string.format("AtlasLoot resolver: %s | Recipe=%s | Profession=%s", self:HasAtlasLootResolver() and "ready" or "missing", recipe and "yes" or "no", profession and "yes" or "no"))
end

local function formatOutputDesc(createdItemID, createdItemName, professionID)
    if createdItemID then
        return string.format("%s(%s)", tostring(createdItemName or "?"), tostring(createdItemID))
    end
    if professionID == 10 then
        return "direct enchant/no created item"
    end
    return "no created item"
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
    Addon:SystemPrint(string.format("Recipe %d -> prof=%s rank=%d spell=%s(%d) output=%s reagents=[%s]",
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
    Addon:SystemPrint(string.format("Spell %s(%d) -> prof=%s min=%d low=%d high=%d output=%s recipe=%s(%s) num=%d reagents=[%s]",
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
        Addon:SystemPrint("No AtlasLoot craft mapping for created item " .. tostring(createdItemID) .. ". In TBC many enchanting formulas are direct enchants and do not create an item; use /rr r <recipeItemID> or /rr s <spellID> for those.")
        return
    end
    Addon:SystemPrint(string.format("Created item %s(%d) -> spell=%s(%d) recipe=%s(%s)",
        tostring(info.createdItemName or "?"),
        tonumber(createdItemID or 0),
        tostring(info.spellName or "?"),
        tonumber(info.spellID or 0),
        tostring(info.recipeItemName or "nil"),
        tostring(info.recipeItemID or "nil")
    ))
end

function Data:WipeDatabase()
    local members = self:GetMembersDB()
    for key in pairs(members) do
        members[key] = nil
    end
    self._incoming = {}
    self._currentProfs = {}
    self:GetGlobalMeta().bootstrapCompletedAt = 0
    self:MarkManifestDirty(nil, "wipe")

    if Addon.Sync then
        Addon.Sync:ResetRuntimeStateForDatabaseWipe()
    end

    self:InvalidateRecipeCaches()
    self:DetectProfessions()
    if Addon.Sync then
        Addon.Sync:KickoffDatabaseResync()
    end
    Addon:Print("Database wiped. AtlasLoot lookups stay available; sync cache is clean and a fresh guild resync was requested.")
    Addon:RequestRefresh("wipe")
end
