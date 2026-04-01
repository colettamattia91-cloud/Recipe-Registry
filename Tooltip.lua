local Addon = _G.RecipeRegistry
local Tooltip = Addon:NewModule("Tooltip", "AceEvent-3.0", "AceTimer-3.0")
Addon.Tooltip = Tooltip

function Tooltip:OnEnable()
    self.indexDirty = true
    self.index = {}
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", "InvalidateIndex")
    GameTooltip:HookScript("OnTooltipSetItem", function(tt)
        self:OnTooltipSetItem(tt)
    end)
end

function Tooltip:InvalidateIndex()
    self.indexDirty = true
    if self._timer then return end
    self._timer = self:ScheduleTimer(function()
        self._timer = nil
        self:RebuildIndex()
    end, 1.5)
end

function Tooltip:RebuildIndex()
    self.indexDirty = false
    self.index = {}
    local members = Addon.Data:GetMembersDB()
    for memberKey, entry in pairs(members) do
        for profName, prof in pairs(entry.professions or {}) do
            for recipeKey in pairs(prof.recipes or {}) do
                if tonumber(recipeKey) and tonumber(recipeKey) > 0 then
                    self.index[tonumber(recipeKey)] = self.index[tonumber(recipeKey)] or {}
                    local rows = self.index[tonumber(recipeKey)]
                    rows[#rows + 1] = { memberKey = memberKey, profession = profName, online = Addon.Data:IsMemberOnline(memberKey) }
                end
            end
        end
    end
end

function Tooltip:OnTooltipSetItem(tooltip)
    local _, link = tooltip:GetItem()
    if not link then return end
    local itemID = link:match("item:(%d+)")
    itemID = itemID and tonumber(itemID) or nil
    if not itemID then return end
    if self.indexDirty then
        -- Avoid rebuilding the full index in the tooltip render path.
        self:InvalidateIndex()
        return
    end
    local rows = self.index[itemID]
    if not rows or #rows == 0 then return end

    tooltip:AddLine(" ")
    tooltip:AddLine("Recipe Registry", 1, 0.82, 0)
    local shown = 0
    for _, row in ipairs(rows) do
        shown = shown + 1
        if shown > 5 then
            tooltip:AddLine(string.format("+%d more", #rows - 5), 0.7, 0.7, 0.7)
            break
        end
        local r, g, b = row.online and 0.4 or 0.65, row.online and 1 or 0.65, row.online and 0.4 or 0.65
        tooltip:AddLine(string.format("%s (%s)", row.memberKey, row.profession), r, g, b)
    end
    tooltip:Show()
end
