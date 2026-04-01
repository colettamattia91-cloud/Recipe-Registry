local Addon = _G.RecipeRegistry
local MinimapButton = Addon:NewModule("MinimapButton", "AceEvent-3.0")
Addon.MinimapButton = MinimapButton

local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Book_11"
local BUTTON_SIZE  = 31
local DRAG_RADIUS  = 80

local function getSettings()
    if not Addon.db or not Addon.db.profile then return nil end
    local settings = Addon.db.profile.minimap
    if type(settings) ~= "table" then
        Addon.db.profile.minimap = { hide = false, angle = 0.785 }
        settings = Addon.db.profile.minimap
    end
    if settings.hide == nil then settings.hide = false end
    if type(settings.angle) ~= "number" then settings.angle = 0.785 end
    return settings
end

local function isMinimapRound()
    if Minimap.GetMaskTexture then
        local mask = Minimap:GetMaskTexture()
        if mask and not mask:lower():find("minimapmask") then
            return false
        end
    end
    return true
end

local function updatePosition(btn, angle)
    if not btn then return end
    local x = math.cos(angle)
    local y = math.sin(angle)

    if not isMinimapRound() then
        local q = math.max(math.abs(x), math.abs(y))
        if q > 0 then
            x = x / q
            y = y / q
        end
    end

    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x * DRAG_RADIUS, y * DRAG_RADIUS)
end

local function angleFromCursor()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    return math.atan2(cy - my, cx - mx)
end

local function createButton()
    local btn = CreateFrame("Button", "RecipeRegistryMinimapButton", Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    btn.overlay = overlay

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture(ICON_TEXTURE)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 1)
    btn.icon = icon

    local hl = btn:GetHighlightTexture()
    if hl then
        hl:ClearAllPoints()
        hl:SetPoint("CENTER", btn, "CENTER", 0, 0)
        hl:SetSize(46, 46)
        hl:SetBlendMode("ADD")
    end

    return btn
end

function MinimapButton:OnEnable()
    if self.button then
        self:Refresh()
        return
    end

    local btn = createButton()
    local settings = getSettings()
    updatePosition(btn, settings and settings.angle or 0.785)

    btn:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            if Addon.UI then Addon.UI:Toggle() end
        else
            if Addon.Sync then Addon.Sync:DumpStatus() end
        end
    end)

    btn:SetScript("OnEnter", function(frame)
        GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
        GameTooltip:AddLine("Recipe Registry")
        GameTooltip:AddLine("|cffffffffLeft-click|r to toggle window", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffffffffRight-click|r to show sync status", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffffffffDrag|r to reposition", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetScript("OnDragStart", function(frame)
        frame.isDragging = true
        frame:SetScript("OnUpdate", function(self)
            local angle = angleFromCursor()
            local settings = getSettings()
            if settings then settings.angle = angle end
            updatePosition(self, angle)
        end)
    end)
    btn:SetScript("OnDragStop", function(frame)
        frame.isDragging = false
        frame:SetScript("OnUpdate", nil)
    end)

    self.button = btn
    self:Refresh()
end

function MinimapButton:Refresh()
    if not self.button then return end
    local settings = getSettings()
    if not settings then return end

    if settings.hide then
        self.button:Hide()
    else
        self.button:Show()
        updatePosition(self.button, settings.angle or 0.785)
    end
end

function MinimapButton:ToggleHidden()
    local settings = getSettings()
    if not settings then return end
    settings.hide = not settings.hide
    self:Refresh()
    Addon:Print("Minimap button " .. (settings.hide and "hidden" or "shown"))
end
