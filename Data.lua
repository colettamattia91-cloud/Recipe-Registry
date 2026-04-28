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
        minimap = {
            hide = false,
            minimapPos = 220,
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

local function cloneTableShallow(src)
    local out = {}
    for key, value in pairs(src or {}) do
        out[key] = value
    end
    return out
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
-- Positive keys (item-based) are always valid.
-- Negative keys (spell-based) must have a known AtlasLoot profession mapping.
-- In TBC Classic AtlasLoot covers every learnable recipe, so a missing entry
-- means the spell is not a craft.
-- Fallback when AtlasLoot is absent: check spell subtext for profession rank
-- keywords (Apprentice/Journeyman/Expert/Artisan/Master) which only craft
-- spells have; class spells use "Rank N" or have no subtext.
local CRAFT_RANK_KEYWORDS = {
    ["Apprentice"] = true, ["Journeyman"] = true, ["Expert"] = true,
    ["Artisan"] = true, ["Master"] = true,
}
local function isValidRecipeKey(recipeKey)
    local n = tonumber(recipeKey)
    if not n then return false end
    if recipeValidityCache[n] ~= nil then
        return recipeValidityCache[n]
    end
    if n > 0 then
        recipeValidityCache[n] = true
        return true
    end  -- item-based: always valid
    local _, profession = getAtlasLootHandles()
    if profession and profession.GetProfessionData then
        local valid = profession.GetProfessionData(-n) ~= nil
        recipeValidityCache[n] = valid
        return valid
    end
    -- Fallback: no AtlasLoot — check spell subtext for craft rank keywords
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

local function lowerSafe(v)
    if v == nil then return "" end
    return tostring(v):lower()
end

local function extractItemID(link)
    if not link then return nil end
    local itemID = link:match("item:(%d+)")
    return itemID and tonumber(itemID) or nil
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
    -- When true, the next TRADE_SKILL_SHOW / CRAFT_SHOW will run a full scan
    -- even if recipe data already exists in the DB. Set by recipe-change events.
    -- Starts false: data loaded from DB is considered valid until a change fires.
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
        return
    end

    self._recipeListCache = nil
    self._recipeDetailCache = nil
    self._recipeCraftersCache = nil
    self._recipeIndex = nil
end

function Data:BuildSyncBlockKey(ownerCharacter, professionKey)
    if not ownerCharacter or not professionKey then return nil end
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

function Data:GetSyncBlock(memberKey, professionKey)
    local entry = self:GetMember(memberKey)
    local profession = entry and entry.professions and entry.professions[professionKey]
    if not entry or not profession then return nil end

    local recipeCount = profession.count
    if type(recipeCount) ~= "number" then
        recipeCount = countRecipeKeys(profession.recipes)
    end

    return {
        blockKey = self:BuildSyncBlockKey(memberKey, professionKey),
        ownerCharacter = memberKey,
        professionKey = professionKey,
        revision = profession.blockRevision or entry.rev or 0,
        lastUpdatedAt = profession.lastUpdatedAt or entry.updatedAt or 0,
        sourceType = profession.sourceType or entry.sourceType or self:GetMemberSourceType(memberKey),
        guildStatus = profession.guildStatus or entry.guildStatus or "active",
        lastSeenInGuildAt = profession.lastSeenInGuildAt or entry.lastSeenInGuildAt or entry.updatedAt or 0,
        count = recipeCount,
        fingerprint = profession.signature or stableRecipeSignature(profession.recipes),
        skillRank = profession.skillRank or 0,
        skillMaxRank = profession.skillMaxRank or 0,
    }
end

function Data:GetAllSyncBlocks(includeStale)
    local blocks = {}
    for memberKey, entry in pairs(self:GetMembersDB()) do
        if not self:IsMockMember(memberKey, entry) and (includeStale or (entry.guildStatus or "active") == "active") then
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
    local manifest = {
        builtAt = time(),
        memberKey = self:GetPlayerKey(),
        blocks = {},
        totals = {
            blocks = 0,
            recipes = 0,
        },
    }

    for _, block in ipairs(self:GetAllSyncBlocks(includeStale)) do
        manifest.blocks[block.blockKey] = {
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
        manifest.totals.blocks = manifest.totals.blocks + 1
        manifest.totals.recipes = manifest.totals.recipes + (block.count or 0)
    end

    return manifest
end

function Data:GetDatasetCompletenessEstimate()
    local manifest = self:BuildSyncManifest(false)
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
    self:InvalidateRecipeCaches("presence")
    return true
end

function Data:DeleteMember(memberKey)
    if not memberKey then return false end
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
        self:InvalidateRecipeCaches("presence")
        if Addon.Tooltip and Addon.Tooltip.InvalidateIndex then
            Addon.Tooltip:InvalidateIndex()
        end
    end
    return removed
end

function Data:CleanInvalidRecipes()
    local totalRemoved = 0
    for memberKey, entry in pairs(self:GetMembersDB()) do
        for profName, prof in pairs(entry.professions or {}) do
            local toRemove = {}
            for recipeKey in pairs(prof.recipes or {}) do
                if not isValidRecipeKey(recipeKey) then
                    toRemove[#toRemove + 1] = recipeKey
                end
            end
            for _, recipeKey in ipairs(toRemove) do
                prof.recipes[recipeKey] = nil
                totalRemoved = totalRemoved + 1
                Addon:Debug("Removed invalid recipe", recipeKey, "from", memberKey, profName)
            end
            if #toRemove > 0 then
                local count = 0
                for _ in pairs(prof.recipes) do count = count + 1 end
                prof.count = count
                prof.signature = stableRecipeSignature(prof.recipes)
            end
        end
    end
    if totalRemoved > 0 then
        self:InvalidateRecipeCaches()
        Addon:RequestRefresh("clean")
    end
    return totalRemoved
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

function Data:DetectProfessions()
    self._currentProfs = {}
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, skillRank, _, _, skillMaxRank = GetSkillLineInfo(i)
        if not isHeader and name then
            local canonical = self:GetCanonicalProfession(name)
            if TRACKED[canonical] then
                self._currentProfs[canonical] = {
                    skillRank = skillRank or 0,
                    skillMaxRank = skillMaxRank or 0,
                }
                local entry = self:GetOrCreateMember(self:GetPlayerKey())
                entry.professions[canonical] = entry.professions[canonical] or { recipes = {} }
                entry.professions[canonical].skillRank = skillRank or 0
                entry.professions[canonical].skillMaxRank = skillMaxRank or 0
                entry.professions[canonical] = self:NormalizeProfessionBlock(entry, canonical, entry.professions[canonical])
            end
        end
    end
    Addon:RequestRefresh("detect-professions")
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

function Data:ScanTradeSkill()
    local title = GetTradeSkillLine and GetTradeSkillLine()
    if not title then return false end
    local canonical = self:GetCanonicalProfession(title)
    if not TRACKED[canonical] then return false end

    -- Only touch the native UI when necessary:
    -- • first time this profession is seen (no data in DB yet), OR
    -- • a recipe-change signal explicitly requested a rescan (_scanNeeded).
    -- On routine open/close cycles the data in DB is current → skip entirely.
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[canonical]
    local hasData = prof and prof.count and prof.count > 0
    if hasData and not self._scanNeeded then
        return false
    end
    -- Consume the flag before scanning so a signal fired during the scan is
    -- not silently swallowed (it will re-set the flag for the next open).
    self._scanNeeded = false

    local filterState = snapshotTradeSkillFilters()
    clearTradeSkillFilters()

    local recipes = {}
    local collapsedHeaders = {}
    local ok, err = pcall(function()
        -- Record which headers were collapsed so we can re-collapse after scan.
        local numSkills = GetNumTradeSkills() or 0
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
                local itemID = extractItemID(GetTradeSkillItemLink(i))
                local recipeKey = itemID or -(extractSpellID(GetTradeSkillRecipeLink(i)) or i)
                recipes[recipeKey] = true
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
        Addon:Print("Trade skill scan failed: " .. tostring(err))
        return false
    end

    return self:ApplyScanResult(canonical, recipes)
end

function Data:ScanCraft()
    local title = GetCraftDisplaySkillLine and GetCraftDisplaySkillLine()
    local canonical = self:GetCanonicalProfession(title or "")
    if canonical ~= "Enchanting" then
        -- CraftFrame is open for a non-Enchanting skill (e.g. Beast Training).
        -- Skip the scan to avoid storing class spells as Enchanting recipes.
        Addon:Debug("ScanCraft skipped: CraftFrame shows", title or "nil", "->", canonical or "nil")
        return false
    end

    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[canonical]
    local hasData = prof and prof.count and prof.count > 0
    if hasData and not self._scanNeeded then
        return false
    end
    self._scanNeeded = false

    local filterState = snapshotCraftFilters()
    clearCraftFilters()

    local recipes = {}
    local ok, err = pcall(function()
        for i = 1, (GetNumCrafts() or 0) do
            local recipeName, recipeType = GetCraftInfo(i)
            if recipeName and recipeType ~= "header" and recipeType ~= "subheader" then
                local itemID = extractItemID(GetCraftItemLink(i))
                local recipeKey = itemID or -(extractSpellID(GetCraftRecipeLink(i)) or i)
                recipes[recipeKey] = true
            end
        end
    end)

    restoreCraftFilters(filterState)

    if not ok then
        Addon:Print("Craft scan failed: " .. tostring(err))
        return false
    end

    return self:ApplyScanResult(canonical, recipes)
end

function Data:ApplyScanResult(profession, recipeKeys)
    local entry = self:GetOrCreateMember(self:GetPlayerKey())
    local prof = entry.professions[profession] or { recipes = {} }
    local oldSignature = prof.signature or ""
    local newSignature = stableRecipeSignature(recipeKeys)
    local changed = (oldSignature ~= newSignature)

    prof.recipes = {}
    local count = 0
    for recipeKey in pairs(recipeKeys or {}) do
        prof.recipes[recipeKey] = true
        count = count + 1
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
    end

    entry.professions[profession] = prof

    if changed then
        self:TouchLocalRevision("scan:" .. profession)
        prof.blockRevision = entry.rev or prof.blockRevision
        Addon:Debug("Scan changed", profession, count, "recipe ids")
        Addon:Print(string.format("Scanned %s: %d recipe(s) found.", profession, count))
    else
        Addon:Print(string.format("Scanned %s: unchanged (%d recipe(s)).", profession, count))
    end

    self:InvalidateRecipeCaches()
    Addon:RequestRefresh("scan")
    return changed
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

function Data:BuildSnapshotChunks(memberKey)
    local entry = self:GetMember(memberKey)
    if not entry then return {} end

    local chunks = {}
    local chunkSize = 120
    local profNames = {}
    for profName in pairs(entry.professions or {}) do
        profNames[#profNames + 1] = profName
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
            recipeKeys = pending,
            partial = false,
        }
    end

    if #chunks == 0 then
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
            recipes = {},
            sourceType = chunk.sourceType or "replica",
        }
        for _, recipeKey in ipairs(chunk.recipeKeys or {}) do
            if isValidRecipeKey(recipeKey) then
                prof.recipes[recipeKey] = true
            else
                Addon:Debug("Blocked invalid recipe from sync:", recipeKey, "profession:", chunk.profession, "from:", chunk.memberKey)
            end
        end
        prof.skillRank = chunk.skillRank or prof.skillRank or 0
        prof.skillMaxRank = chunk.skillMaxRank or prof.skillMaxRank or 0
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
        if currentProf and currentProf.recipes and currentProf.count and currentProf.count > count and count > 0 then
            local incomingRank = prof.skillRank or 0
            local currentRank = currentProf.skillRank or 0
            if incomingRank >= currentRank and isSubsetOf(incomingRecipes, currentProf.recipes) then
                local merged = {}
                for recipeKey in pairs(currentProf.recipes) do merged[recipeKey] = true end
                for recipeKey in pairs(incomingRecipes) do merged[recipeKey] = true end
                incomingRecipes = merged
                count = 0
                for _ in pairs(incomingRecipes) do count = count + 1 end
                Addon:Print(string.format("Protected %s %s from a partial remote overwrite (%d -> %d kept).", memberKey, profName, count, currentProf.count or count))
            end
        end

        finalEntry.professions[profName] = {
            skillRank = prof.skillRank or 0,
            skillMaxRank = prof.skillMaxRank or 0,
            recipes = incomingRecipes,
            count = count,
            signature = stableRecipeSignature(incomingRecipes),
            lastScan = state.updatedAt or time(),
            blockRevision = rev,
            lastUpdatedAt = state.updatedAt or time(),
            sourceType = prof.sourceType or finalEntry.sourceType,
            guildStatus = "active",
            lastSeenInGuildAt = finalEntry.lastSeenInGuildAt,
        }
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
    Addon:Print(string.format("Members=%d Professions=%d Recipes=%d | Local rev=%d updated=%d", totalMembers, totalProfs, totalRecipes, s.rev, s.updatedAt))
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
    Addon:Print(string.format("AtlasLoot resolver: %s | Recipe=%s | Profession=%s", self:HasAtlasLootResolver() and "ready" or "missing", recipe and "yes" or "no", profession and "yes" or "no"))
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
        Addon:Print("No AtlasLoot recipe data for item " .. tostring(recipeItemID))
        return
    end
    local reagents = info.spellData and formatReagents(info.spellData[6], info.spellData[7]) or "none"
    Addon:Print(string.format("Recipe %d -> prof=%s rank=%d spell=%s(%d) output=%s reagents=[%s]",
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
        Addon:Print("No AtlasLoot profession data for spell " .. tostring(spellID))
        return
    end
    Addon:Print(string.format("Spell %s(%d) -> prof=%s min=%d low=%d high=%d output=%s recipe=%s(%s) num=%d reagents=[%s]",
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
        Addon:Print("No AtlasLoot craft mapping for created item " .. tostring(createdItemID) .. ". In TBC many enchanting formulas are direct enchants and do not create an item; use /rr r <recipeItemID> or /rr s <spellID> for those.")
        return
    end
    Addon:Print(string.format("Created item %s(%d) -> spell=%s(%d) recipe=%s(%s)",
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

    if Addon.Sync then
        Addon.Sync.registry = {}
        Addon.Sync.pendingRequests = {}
        Addon.Sync.partialReceive = {}
        Addon.Sync.outgoingSessions = {}
        Addon.Sync.inFlight = nil
        Addon.Sync.lastAdvertisedRev = nil
    end

    self:InvalidateRecipeCaches()
    self:DetectProfessions()
    Addon:Print("Database wiped. AtlasLoot lookups stay available; sync cache is clean.")
    Addon:RequestRefresh("wipe")
end
