local Addon = _G.RecipeRegistry
local Tooltip = Addon:NewModule("Tooltip", "AceEvent-3.0", "AceTimer-3.0")
Addon.Tooltip = Tooltip

local MAX_TOOLTIP_CRAFTERS = 5

local ipairs = ipairs
local pairs = pairs
local sort = table.sort
local tostring = tostring
local tonumber = tonumber

local function extractItemID(link)
    if not link then return nil end
    local itemID = link:match("item:(%d+)")
    return itemID and tonumber(itemID) or nil
end

local function makeItemKey(itemID)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    return "item:" .. tostring(itemID)
end

local function makeSpellKey(spellID)
    spellID = tonumber(spellID)
    if not spellID then return nil end
    return "spell:" .. tostring(spellID)
end

local function addRow(index, key, recipeKey, crafter)
    if not key or not crafter then return end
    local bucket = index[key]
    if not bucket then
        bucket = { rows = {}, seen = {} }
        index[key] = bucket
    end

    local seenKey = table.concat({
        tostring(recipeKey or ""),
        tostring(crafter.memberKey or ""),
        tostring(crafter.profession or ""),
    }, "\031")
    if bucket.seen[seenKey] then return end
    bucket.seen[seenKey] = true
    bucket.rows[#bucket.rows + 1] = {
        recipeKey = recipeKey,
        memberKey = crafter.memberKey,
        profession = crafter.profession,
        online = crafter.online and true or false,
        skillRank = crafter.skillRank or 0,
        updatedAt = crafter.updatedAt or 0,
    }
end

local function sortRows(rows)
    sort(rows, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.skillRank ~= b.skillRank then return a.skillRank > b.skillRank end
        if a.memberKey ~= b.memberKey then return tostring(a.memberKey) < tostring(b.memberKey) end
        if a.profession ~= b.profession then return tostring(a.profession) < tostring(b.profession) end
        return tostring(a.recipeKey) < tostring(b.recipeKey)
    end)
end

function Tooltip:OnEnable()
    self.indexDirty = true
    self.index = {}
    self.indexVersion = 0
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", "InvalidateIndex")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "InvalidateIndex")
    self:HookTooltip(GameTooltip)
    if ItemRefTooltip then
        self:HookTooltip(ItemRefTooltip)
    end
    self:InvalidateIndex()
end

function Tooltip:HookTooltip(tooltip)
    if not tooltip then return end
    self.hookedTooltips = self.hookedTooltips or {}
    if self.hookedTooltips[tooltip] then return end
    self.hookedTooltips[tooltip] = true

    tooltip:HookScript("OnTooltipSetItem", function(tt)
        self:OnTooltipSetItem(tt)
    end)
    if not tooltip.HasScript or tooltip:HasScript("OnTooltipSetSpell") then
        tooltip:HookScript("OnTooltipSetSpell", function(tt)
            self:OnTooltipSetSpell(tt)
        end)
    end
    if not tooltip.HasScript or tooltip:HasScript("OnTooltipCleared") then
        tooltip:HookScript("OnTooltipCleared", function(tt)
            tt._rrCraftRenderedKey = nil
        end)
    end
end

function Tooltip:InvalidateIndex()
    self.indexDirty = true
    if self._timer then
        self:CancelTimer(self._timer, true)
        self._timer = nil
    end
end

function Tooltip:RebuildIndex()
    self.indexDirty = false
    self.indexVersion = (self.indexVersion or 0) + 1
    self.index = {}
    if not (Addon.Data and Addon.Data.GetRecipeIndex) then
        return
    end

    local recipeIndex = Addon.Data:GetRecipeIndex()
    for recipeKey, indexed in pairs(recipeIndex or {}) do
        local numericKey = tonumber(recipeKey)
        local crafters = indexed and indexed.crafterRows
        local key
        if numericKey and numericKey > 0 then
            key = makeItemKey(numericKey)
        elseif numericKey and numericKey < 0 then
            key = makeSpellKey(-numericKey)
        end
        if key and crafters then
            for _, crafter in ipairs(crafters) do
                addRow(self.index, key, recipeKey, crafter)
            end
        end
    end

    for _, bucket in pairs(self.index) do
        sortRows(bucket.rows)
        bucket.seen = nil
    end
end

function Tooltip:GetRowsForKey(key)
    if not key then return nil end
    if self.indexDirty then
        if InCombatLockdown and InCombatLockdown() then
            return nil
        end
        self:RebuildIndex()
    end
    local bucket = self.index and self.index[key]
    return bucket and bucket.rows or nil
end

function Tooltip:MergeRows(...)
    local out = {}
    local seen = {}
    for index = 1, select("#", ...) do
        local rows = select(index, ...)
        for _, row in ipairs(rows or {}) do
            local key = table.concat({
                tostring(row.recipeKey or ""),
                tostring(row.memberKey or ""),
                tostring(row.profession or ""),
            }, "\031")
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = row
            end
        end
    end
    sortRows(out)
    return out
end

function Tooltip:GetRowsForItemID(itemID)
    local directKey = makeItemKey(itemID)
    local directRows = self:GetRowsForKey(directKey)
    if directRows and #directRows > 0 then
        return directRows, directKey
    end

    local atlas = Addon.Data and Addon.Data.GetAtlasLootRecipeInfo and Addon.Data:GetAtlasLootRecipeInfo(itemID)
    if atlas then
        local rows = self:MergeRows(
            self:GetRowsForKey(makeSpellKey(atlas.spellID)),
            self:GetRowsForKey(makeItemKey(atlas.createdItemID))
        )
        if #rows > 0 then
            return rows, directKey
        end
    end

    return directRows, directKey
end

function Tooltip:GetRowsForSpellID(spellID)
    local directKey = makeSpellKey(spellID)
    local directRows = self:GetRowsForKey(directKey)
    if directRows and #directRows > 0 then
        return directRows, directKey
    end

    local atlas = Addon.Data and Addon.Data.GetAtlasLootSpellInfo and Addon.Data:GetAtlasLootSpellInfo(spellID)
    if atlas then
        local rows = self:MergeRows(
            self:GetRowsForKey(makeItemKey(atlas.createdItemID)),
            self:GetRowsForKey(makeItemKey(atlas.recipeItemID))
        )
        if #rows > 0 then
            return rows, directKey
        end
    end

    return directRows, directKey
end

function Tooltip:AddCraftLines(tooltip, rows, renderKey)
    if not rows or #rows == 0 then return end

    renderKey = tostring(renderKey or "craft") .. ":" .. tostring(self.indexVersion or 0)
    if tooltip._rrCraftRenderedKey == renderKey then return end
    tooltip._rrCraftRenderedKey = renderKey

    local onlineRows = {}
    for _, row in ipairs(rows) do
        if row.online then
            onlineRows[#onlineRows + 1] = row
        end
    end
    local displayRows = #onlineRows > 0 and onlineRows or rows
    local label = #onlineRows > 0 and string.format("%d online", #onlineRows)
        or string.format("%d offline known", #displayRows)

    tooltip:AddLine(" ")
    tooltip:AddLine("Recipe Registry", 1, 0.82, 0)
    tooltip:AddLine(label, 0.78, 0.78, 0.78)

    local maxRows = math.min(MAX_TOOLTIP_CRAFTERS, #displayRows)
    for i = 1, maxRows do
        local row = displayRows[i]
        local r, g, b = row.online and 0.4 or 0.65, row.online and 1 or 0.65, row.online and 0.4 or 0.65
        tooltip:AddLine(string.format("%s (%s)", tostring(row.memberKey), tostring(row.profession)), r, g, b)
    end
    if #displayRows > maxRows then
        tooltip:AddLine(string.format("+%d more", #displayRows - maxRows), 0.7, 0.7, 0.7)
    end
    tooltip:Show()
end

function Tooltip:OnTooltipSetItem(tooltip)
    local _, link = tooltip:GetItem()
    local itemID = extractItemID(link)
    if not itemID then return end
    local rows, key = self:GetRowsForItemID(itemID)
    self:AddCraftLines(tooltip, rows, key)
end

function Tooltip:OnTooltipSetSpell(tooltip)
    if not (tooltip and tooltip.GetSpell) then return end
    local ok, a, b, c = pcall(tooltip.GetSpell, tooltip)
    if not ok then return end
    local spellID = tonumber(c) or tonumber(b) or tonumber(a)
    if not spellID then return end
    local rows, key = self:GetRowsForSpellID(spellID)
    self:AddCraftLines(tooltip, rows, key)
end
