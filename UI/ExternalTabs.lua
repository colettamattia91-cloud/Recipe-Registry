-- External tab registry for RecipeRegistry's main frame.
--
-- A strictly-additive public API that lets sibling addons (notably
-- RecipeRegistry_Orders) plug their own top-level tab into the main
-- frame's navigation row without touching internals. Tabs registered
-- here behave like the "Guild Addons" view: full-width centre panel,
-- left/right side panels hidden.
--
-- The contract is documented in docs/recipe-registry-public-api.md.

local Addon = _G.RecipeRegistry
local UI = Addon and Addon.UI
if not UI then
    -- MainFrame.lua creates the UI module. If load order regresses we
    -- want a loud failure here rather than a silent dead registry.
    error("UI/ExternalTabs.lua loaded before UI module was created (check TOC order)")
end

local EXTERNAL_VIEW_PREFIX = "ext:"
UI.EXTERNAL_VIEW_PREFIX = EXTERNAL_VIEW_PREFIX

local function ensureRegistry()
    UI.__externalTabs       = UI.__externalTabs       or {}
    UI.__externalTabOrder   = UI.__externalTabOrder   or {}
    UI.__externalTabPanels  = UI.__externalTabPanels  or {}
    UI.__externalTabButtons = UI.__externalTabButtons or {}
    return UI.__externalTabs
end

local function validateSpec(spec)
    if type(spec) ~= "table" then return "invalid-spec" end
    if type(spec.id) ~= "string" or spec.id == "" then return "missing-id" end
    if spec.id:find(EXTERNAL_VIEW_PREFIX, 1, true) == 1 then return "reserved-prefix" end
    if type(spec.label) ~= "string" or spec.label == "" then return "missing-label" end
    if spec.build ~= nil and type(spec.build) ~= "function" then return "invalid-build" end
    if spec.onSelect ~= nil and type(spec.onSelect) ~= "function" then return "invalid-onselect" end
    if spec.onDeselect ~= nil and type(spec.onDeselect) ~= "function" then return "invalid-ondeselect" end
    return nil
end

-- Public: register (or re-register) an external tab. Returns true on
-- success, or nil + error code on validation failure. Re-registration
-- with the same id is idempotent: it replaces the previous spec but
-- preserves the existing panel and button (the plugin can call
-- `build` again itself if it needs to redraw).
function UI:RegisterExternalTab(spec)
    local err = validateSpec(spec)
    if err then return nil, err end
    local tabs = ensureRegistry()

    local previous = tabs[spec.id]
    tabs[spec.id] = {
        id         = spec.id,
        label      = spec.label,
        icon       = spec.icon,
        build      = spec.build,
        onSelect   = spec.onSelect,
        onDeselect = spec.onDeselect,
    }
    if not previous then
        UI.__externalTabOrder[#UI.__externalTabOrder + 1] = spec.id
    end

    if self.frame and self.frame.mainNav then
        self:RealizeExternalTab(spec.id)
        self:RefreshMainTabs()
    end
    return true
end

function UI:GetExternalTabSpec(id)
    ensureRegistry()
    return UI.__externalTabs[id]
end

-- Public: rewrite the label of an already-registered tab. Used by
-- sibling plugins to keep a live counter or status in the tab button
-- (e.g. "Craft Orders (3)" when there are 3 orders awaiting action).
-- Idempotent and cheap: if the label is unchanged, returns true
-- without touching the button. Returns nil + reason for unknown tab
-- or invalid label so callers can branch on it.
function UI:SetExternalTabLabel(id, label)
    ensureRegistry()
    if type(id) ~= "string" or id == "" then return nil, "missing-id" end
    if type(label) ~= "string" or label == "" then return nil, "missing-label" end
    local spec = UI.__externalTabs[id]
    if not spec then return nil, "unknown-tab" end
    if spec.label == label then return true end
    spec.label = label
    local button = UI.__externalTabButtons[id]
    if button and button.SetLabel then
        button:SetLabel(label)
    end
    return true
end

function UI:HasExternalTab(id)
    ensureRegistry()
    return UI.__externalTabs[id] ~= nil
end

function UI:ListExternalTabs()
    ensureRegistry()
    local out = {}
    for index = 1, #UI.__externalTabOrder do
        out[index] = UI.__externalTabOrder[index]
    end
    return out
end

-- View-model helpers. External view ids are stored in selectedProfession
-- with the `ext:` prefix so they don't collide with profession names or
-- the addon-status view sentinel.

function UI:IsExternalView()
    local view = self.selectedProfession
    return type(view) == "string" and view:sub(1, #EXTERNAL_VIEW_PREFIX) == EXTERNAL_VIEW_PREFIX
end

function UI:GetExternalTabId()
    if not self:IsExternalView() then return nil end
    return self.selectedProfession:sub(#EXTERNAL_VIEW_PREFIX + 1)
end

function UI:SelectExternalTab(id)
    if not self:HasExternalTab(id) then return false, "unknown-tab" end

    local previousId = self:GetExternalTabId()
    if previousId == id then
        return true
    end

    if previousId then
        local previous = self:GetExternalTabSpec(previousId)
        local panel = UI.__externalTabPanels[previousId]
        if previous and previous.onDeselect and panel then
            pcall(previous.onDeselect, panel)
        end
    end

    self.selectedProfession = EXTERNAL_VIEW_PREFIX .. id
    if Addon.db and Addon.db.profile then
        Addon.db.profile.selectedProfession = self.selectedProfession
    end
    self.selectedRecipeKey = nil
    self.selectedAddonStatusKey = nil
    self.selectedCategory = nil

    if self.frame then
        self:RealizeExternalTab(id)
        self:ApplyMainLayout()

        local spec = self:GetExternalTabSpec(id)
        local panel = UI.__externalTabPanels[id]
        if spec and spec.onSelect and panel then
            pcall(spec.onSelect, panel)
        end
        if self.Refresh then
            self:Refresh()
        end
    end

    return true
end

function UI:GetExternalTabPanel(id)
    ensureRegistry()
    return UI.__externalTabPanels[id]
end

function UI:GetExternalTabButton(id)
    ensureRegistry()
    return UI.__externalTabButtons[id]
end

-- Called from CreateMainFrame after the addon-status tab is built, with
-- the nav row frame and an anchor button to position the first external
-- tab to the right of. Subsequent tabs anchor to the previous external
-- tab. Idempotent: an already-realized tab is a no-op.
function UI:RealizeExternalTabs(navParent, anchorButton)
    ensureRegistry()
    if not navParent then return end
    self.__externalTabNav = navParent
    self.__externalTabAnchor = anchorButton
    for _, id in ipairs(UI.__externalTabOrder) do
        self:RealizeExternalTab(id)
    end
end

function UI:RealizeExternalTab(id)
    ensureRegistry()
    local spec = UI.__externalTabs[id]
    if not spec then return end
    local parent = self.__externalTabNav
    local frame = self.frame
    if not (parent and frame) then return end
    if UI.__externalTabButtons[id] then
        -- Already realized; nothing to do beyond label refresh in case
        -- re-registration changed it.
        if UI.__externalTabButtons[id].SetLabel then
            UI.__externalTabButtons[id]:SetLabel(spec.label)
        end
        return
    end

    -- Locate the rightmost existing tab/external-tab button as anchor.
    local anchor = self.__externalTabAnchor
    for _, otherId in ipairs(UI.__externalTabOrder) do
        if otherId == id then break end
        local otherButton = UI.__externalTabButtons[otherId]
        if otherButton then
            anchor = otherButton
        end
    end

    local createButton = self._CreateMainNavButton
    if not createButton then
        -- MainFrame.lua exposes the constructor as a private factory at
        -- the bottom of CreateMainFrame. If it's missing, the host UI
        -- isn't ready yet — defer realization until the next call.
        return
    end

    local button = createButton(self, parent, spec.label)
    if anchor then
        button:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
    else
        button:SetPoint("LEFT", 0, 0)
    end
    if button.SetScript then
        button:SetScript("OnClick", function()
            UI:SelectExternalTab(id)
        end)
    end
    UI.__externalTabButtons[id] = button

    if frame.mainTabs then
        frame.mainTabs[EXTERNAL_VIEW_PREFIX .. id] = button
    end

    -- Build the panel lazily — only when the tab is selected for the
    -- first time. RealizeExternalTabPanel is the entry point.
    self:RealizeExternalTabPanel(id)
end

function UI:RealizeExternalTabPanel(id)
    ensureRegistry()
    local spec = UI.__externalTabs[id]
    local frame = self.frame
    if not (spec and frame) then return end
    if UI.__externalTabPanels[id] then return UI.__externalTabPanels[id] end

    if not CreateFrame then return end
    local panel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    panel:SetPoint("TOPLEFT",     10, -94)
    panel:SetPoint("BOTTOMRIGHT", -10, 34)
    panel:Hide()
    UI.__externalTabPanels[id] = panel

    if spec.build then
        local ok, err = pcall(spec.build, panel)
        if not ok and Addon.Trace then
            Addon:Tracef("ui", "external tab '%s' build failed: %s", id, tostring(err))
        end
    end
    return panel
end

-- Called from ApplyMainLayout when an external view is selected so the
-- correct panel is the only one visible.
function UI:ApplyExternalTabLayout()
    if not self.frame then return end
    local current = self:GetExternalTabId()
    for id, panel in pairs(UI.__externalTabPanels) do
        if panel and panel.SetShown then
            panel:SetShown(id == current)
        end
    end
end

-- Called from RefreshMainTabs to reflect the current selection on
-- external tab buttons.
function UI:RefreshExternalTabButtons()
    if not self.frame then return end
    local current = self:GetExternalTabId()
    for id, button in pairs(UI.__externalTabButtons) do
        if button and button.SetSelected then
            button:SetSelected(id == current)
        end
    end
end
