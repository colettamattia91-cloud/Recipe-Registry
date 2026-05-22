local Addon = _G.RecipeRegistry
local MinimapButton = Addon:NewModule("MinimapButton", "AceEvent-3.0")
Addon.MinimapButton = MinimapButton

local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Book_11"
local LDB = LibStub("LibDataBroker-1.1")
local DBIcon = LibStub("LibDBIcon-1.0")
local OBJECT_NAME = "RecipeRegistry"

local function getSettings()
    if not Addon.db or not Addon.db.profile then return nil end
    local settings = Addon.db.profile.minimap
    if type(settings) ~= "table" then
        Addon.db.profile.minimap = { hide = false, minimapPos = 220 }
        settings = Addon.db.profile.minimap
    end
    if settings.hide == nil then settings.hide = false end
    if type(settings.minimapPos) ~= "number" then
        local legacyAngle = settings.angle
        if type(legacyAngle) == "number" then
            if math.abs(legacyAngle) <= (math.pi * 2 + 0.001) then
                settings.minimapPos = math.deg(legacyAngle) % 360
            else
                settings.minimapPos = legacyAngle % 360
            end
        else
            settings.minimapPos = 220
        end
    end
    return settings
end

local function handleClick(_, button)
    if button == "LeftButton" then
        if Addon.UI then Addon.UI:Toggle() end
    else
        if Addon.Sync then Addon.Sync:DumpStatus() end
    end
end

local function showTooltip(tooltip)
    tooltip:AddLine("Recipe Registry")
    tooltip:AddLine("|cffffffffLeft-click|r to toggle window", 0.8, 0.8, 0.8)
    tooltip:AddLine("|cffffffffRight-click|r to show sync status", 0.8, 0.8, 0.8)
    tooltip:AddLine("|cffffffffDrag|r to reposition", 0.8, 0.8, 0.8)
end

function MinimapButton:OnEnable()
    if not self.ldbObject then
        self.ldbObject = LDB:NewDataObject(OBJECT_NAME, {
            type = "launcher",
            text = "Recipe Registry",
            icon = ICON_TEXTURE,
            OnClick = handleClick,
            OnTooltipShow = showTooltip,
        })
    end

    local settings = getSettings()
    if not DBIcon:IsRegistered(OBJECT_NAME) then
        DBIcon:Register(OBJECT_NAME, self.ldbObject, settings)
    end
    self.button = DBIcon:GetMinimapButton(OBJECT_NAME)
    self:Refresh()
end

function MinimapButton:Refresh()
    local settings = getSettings()
    if not settings then return end
    if DBIcon:IsRegistered(OBJECT_NAME) then
        DBIcon:Refresh(OBJECT_NAME, settings)
    end
end

function MinimapButton:ToggleHidden()
    local settings = getSettings()
    if not settings then return end
    settings.hide = not settings.hide
    if DBIcon:IsRegistered(OBJECT_NAME) then
        if settings.hide then
            DBIcon:Hide(OBJECT_NAME)
        else
            DBIcon:Show(OBJECT_NAME)
            DBIcon:Refresh(OBJECT_NAME, settings)
        end
    end
    Addon:Print("Minimap button " .. (settings.hide and "hidden" or "shown"))
end
