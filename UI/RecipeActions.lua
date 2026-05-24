-- Per-recipe action registry for RecipeRegistry's detail panel.
--
-- A strictly-additive public API that lets sibling addons (notably
-- RecipeRegistry_Orders for "add to order cart") plug their own icon
-- button into the recipe detail panel without touching internals.
-- Actions are rendered as 18x18 icon buttons stacked to the LEFT of
-- the existing favorite button at the top-right of the detail panel.
--
-- The contract is documented in docs/recipe-registry-public-api.md.

local Addon = _G.RecipeRegistry
local UI = Addon and Addon.UI
if not UI then
    error("UI/RecipeActions.lua loaded before UI module was created (check TOC order)")
end

local function ensureRegistry()
    UI.__recipeActions      = UI.__recipeActions      or {}
    UI.__recipeActionOrder  = UI.__recipeActionOrder  or {}
    UI.__recipeActionButtons = UI.__recipeActionButtons or {}
    return UI.__recipeActions
end

local function validateSpec(spec)
    if type(spec) ~= "table" then return "invalid-spec" end
    if type(spec.id) ~= "string" or spec.id == "" then return "missing-id" end
    if type(spec.label) ~= "string" or spec.label == "" then return "missing-label" end
    if spec.icon ~= nil and type(spec.icon) ~= "string" then return "invalid-icon" end
    if spec.onClick ~= nil and type(spec.onClick) ~= "function" then return "invalid-onclick" end
    if spec.isVisible ~= nil and type(spec.isVisible) ~= "function" then return "invalid-isvisible" end
    if spec.isEnabled ~= nil and type(spec.isEnabled) ~= "function" then return "invalid-isenabled" end
    return nil
end

-- Public: register (or replace) a recipe-action icon. Returns true on
-- success, or nil + reason on validation failure. Re-registering the
-- same id replaces the spec while preserving the underlying button
-- widget (the plugin is responsible for triggering a re-render on
-- RR's side if it needs the new spec live — typically via Refresh).
function UI:RegisterRecipeAction(spec)
    local err = validateSpec(spec)
    if err then return nil, err end
    local registry = ensureRegistry()
    local previous = registry[spec.id]
    registry[spec.id] = {
        id        = spec.id,
        label     = spec.label,
        icon      = spec.icon,
        onClick   = spec.onClick,
        isVisible = spec.isVisible,
        isEnabled = spec.isEnabled,
    }
    if not previous then
        UI.__recipeActionOrder[#UI.__recipeActionOrder + 1] = spec.id
    end

    -- If the detail panel is currently rendered, kick a refresh so the
    -- new action shows up without waiting for the next select-recipe
    -- click. Cheap idempotent call.
    if self.RefreshDetailPanel then
        self:RefreshDetailPanel()
    end
    return true
end

function UI:UnregisterRecipeAction(id)
    local registry = ensureRegistry()
    if not registry[id] then return false end
    registry[id] = nil
    for index, value in ipairs(UI.__recipeActionOrder) do
        if value == id then
            table.remove(UI.__recipeActionOrder, index)
            break
        end
    end
    -- Hide the widget if it had been realized. We don't tear it down so
    -- a subsequent re-registration can reuse the same widget.
    local button = UI.__recipeActionButtons[id]
    if button and button.Hide then button:Hide() end
    UI.__recipeActionButtons[id] = nil
    if self.RefreshDetailPanel then
        self:RefreshDetailPanel()
    end
    return true
end

function UI:GetRecipeActionSpec(id)
    ensureRegistry()
    return UI.__recipeActions[id]
end

function UI:HasRecipeAction(id)
    ensureRegistry()
    return UI.__recipeActions[id] ~= nil
end

function UI:ListRecipeActions()
    ensureRegistry()
    local out = {}
    for index = 1, #UI.__recipeActionOrder do
        out[index] = UI.__recipeActionOrder[index]
    end
    return out
end

-- Realize the button for a given action, parented to the detail
-- panel's right-hand frame. Anchored to the LEFT of the previous
-- right-anchored element (favorite button or the previous action).
-- Idempotent: an already-realized button is reused.
function UI:_RealizeRecipeAction(id, parent, rightAnchor)
    local registry = ensureRegistry()
    local spec = registry[id]
    if not (spec and parent) then return nil end

    local button = UI.__recipeActionButtons[id]
    if not button then
        if not CreateFrame then return nil end
        button = CreateFrame("Button", nil, parent)
        button:SetSize(18, 18)
        button:RegisterForClicks("LeftButtonUp")
        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetAllPoints()
        button:SetScript("OnEnter", function(self_)
            if not self_.actionId then return end
            local activeSpec = UI:GetRecipeActionSpec(self_.actionId)
            if not activeSpec then return end
            if GameTooltip then
                GameTooltip:SetOwner(self_, "ANCHOR_CURSOR")
                GameTooltip:AddLine(activeSpec.label or self_.actionId)
                GameTooltip:Show()
            end
        end)
        button:SetScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)
        button:SetScript("OnClick", function(self_)
            local activeSpec = UI:GetRecipeActionSpec(self_.actionId)
            if not (activeSpec and type(activeSpec.onClick) == "function") then return end
            local recipeKey = UI.selectedRecipeKey
            local info = nil
            if recipeKey and Addon.Data and Addon.Data.GetRecipeDetail then
                local ok, detail = pcall(Addon.Data.GetRecipeDetail, Addon.Data, recipeKey)
                if ok then info = detail end
            end
            pcall(activeSpec.onClick, recipeKey, info)
        end)
        UI.__recipeActionButtons[id] = button
    end

    button.actionId = id
    if spec.icon and button.icon and button.icon.SetTexture then
        button.icon:SetTexture(spec.icon)
        button.icon:SetVertexColor(1, 1, 1, 1)
    end

    button:ClearAllPoints()
    if rightAnchor then
        button:SetPoint("RIGHT", rightAnchor, "LEFT", -6, 0)
    else
        button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, -12)
    end
    button:Show()
    return button
end

-- Called from RefreshDetailPanel each render so the visible / enabled
-- state stays in sync with the current recipe. Anchors actions in
-- registration order, growing left from the favorite button.
function UI:RealizeRecipeActions(parent, rightmostAnchor)
    ensureRegistry()
    if not parent then return end

    local recipeKey = self.selectedRecipeKey
    local info = nil
    if recipeKey and Addon.Data and Addon.Data.GetRecipeDetail then
        local ok, detail = pcall(Addon.Data.GetRecipeDetail, Addon.Data, recipeKey)
        if ok then info = detail end
    end

    local anchor = rightmostAnchor
    for _, id in ipairs(UI.__recipeActionOrder) do
        local spec = UI.__recipeActions[id]
        local visible = true
        if recipeKey == nil then
            visible = false
        elseif spec.isVisible then
            local ok, result = pcall(spec.isVisible, recipeKey, info)
            visible = ok and result == true
        end

        local button = UI.__recipeActionButtons[id]
        if visible then
            button = self:_RealizeRecipeAction(id, parent, anchor)
            if button then
                local enabled = true
                if spec.isEnabled then
                    local ok, result = pcall(spec.isEnabled, recipeKey, info)
                    enabled = ok and result == true
                end
                if button.SetEnabled then button:SetEnabled(enabled) end
                if button.icon and button.icon.SetVertexColor then
                    if enabled then
                        button.icon:SetVertexColor(1, 1, 1, 1)
                    else
                        button.icon:SetVertexColor(0.45, 0.45, 0.45, 0.85)
                    end
                end
                anchor = button
            end
        elseif button and button.Hide then
            button:Hide()
        end
    end
end
