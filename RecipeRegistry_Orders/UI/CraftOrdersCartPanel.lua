local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local CartPanel = {}
Addon.CartPanel = CartPanel

-- ---------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------

local function getRR()
    return _G.RecipeRegistry
end

local function shortName(memberKey)
    if type(memberKey) ~= "string" or memberKey == "" then return "?" end
    local hyphen = memberKey:find("-", 1, true)
    if not hyphen then return memberKey end
    return memberKey:sub(1, hyphen - 1)
end

local function classColor(memberKey)
    local rr = getRR()
    if not (rr and rr.Data and type(rr.Data.GetGuildMemberMeta) == "function") then
        return nil
    end
    local ok, meta = pcall(rr.Data.GetGuildMemberMeta, rr.Data, memberKey)
    if not ok or type(meta) ~= "table" then return nil end
    local classFile = meta.classFile or meta.class
    if type(classFile) ~= "string" or classFile == "" then return nil end
    local palette = _G.RAID_CLASS_COLORS or _G.CUSTOM_CLASS_COLORS
    local c = palette and palette[classFile]
    if not c then return nil end
    return c.r, c.g, c.b
end

local function recipeDisplayInfo(recipeKey)
    local rr = getRR()
    if not (rr and rr.Data and type(rr.Data.GetRecipeDisplayInfo) == "function") then
        return nil
    end
    local ok, info = pcall(rr.Data.GetRecipeDisplayInfo, rr.Data, recipeKey)
    if ok and type(info) == "table" then return info end
    return nil
end

local function liveItemIcon(itemID, fallback)
    if type(fallback) == "string" and fallback ~= "" then return fallback end
    if type(itemID) ~= "number" then return nil end
    if type(_G.GetItemInfo) ~= "function" then return nil end
    local _, _, _, _, _, _, _, _, _, icon = _G.GetItemInfo(itemID)
    return icon
end

-- ---------------------------------------------------------------------
-- Data view (testable without CreateFrame)
-- ---------------------------------------------------------------------

-- Returns a presentation-ready view of the current cart, grouped by
-- crafter and enriched with display fields. Shape:
--   {
--     groups = { { crafter, displayName, colorR, colorG, colorB, lines = [...] }, ... },
--     totalLines, totalCrafters,
--   }
-- Each line: { lineIndex (1-based into Cart:GetLines()), recipeKey, recipeLabel,
--              quantity, outputItemID, icon, quality }
function CartPanel:BuildView()
    local view = { groups = {}, totalLines = 0, totalCrafters = 0 }
    local cart = Addon.Cart
    if not cart then return view end

    local lines = cart:GetLines()
    view.totalLines = #lines

    local groupByCrafter = {}
    local orderedCrafters = {}
    for cartIndex = 1, #lines do
        local cartLine = lines[cartIndex]
        local crafterKey = cartLine.crafter
        local group = groupByCrafter[crafterKey]
        if not group then
            local r, g, b = classColor(crafterKey)
            group = {
                crafter     = crafterKey,
                displayName = shortName(crafterKey),
                colorR      = r,
                colorG      = g,
                colorB      = b,
                lines       = {},
            }
            groupByCrafter[crafterKey] = group
            orderedCrafters[#orderedCrafters + 1] = crafterKey
        end

        local info = recipeDisplayInfo(cartLine.recipeKey)
        local icon = liveItemIcon(
            cartLine.outputItemID or (info and info.createdItemID),
            info and (info.createdItemIcon or info.icon)
        )
        local quality = info and info.createdItemQuality
        group.lines[#group.lines + 1] = {
            lineIndex    = cartIndex,
            recipeKey    = cartLine.recipeKey,
            recipeLabel  = cartLine.recipeLabel
                or (info and info.label)
                or ("recipe:" .. tostring(cartLine.recipeKey)),
            quantity     = cartLine.quantity or 1,
            outputItemID = cartLine.outputItemID,
            icon         = icon,
            quality      = quality,
        }
    end

    table.sort(orderedCrafters)
    for _, crafterKey in ipairs(orderedCrafters) do
        view.groups[#view.groups + 1] = groupByCrafter[crafterKey]
    end
    view.totalCrafters = #view.groups
    return view
end

-- Quantity controls used both by the +/- buttons and by future slash
-- bridge commands. Returns true on success, falsy + reason otherwise.
function CartPanel:OnIncrement(lineIndex)
    local cart = Addon.Cart
    if not cart then return false, "cart-missing" end
    local lines = cart:GetLines()
    local line = lines[lineIndex]
    if not line then return false, "invalid-index" end
    return cart:UpdateLineAt(lineIndex, { quantity = (line.quantity or 0) + 1 })
end

function CartPanel:OnDecrement(lineIndex)
    local cart = Addon.Cart
    if not cart then return false, "cart-missing" end
    local lines = cart:GetLines()
    local line = lines[lineIndex]
    if not line then return false, "invalid-index" end
    local newQty = (line.quantity or 0) - 1
    if newQty <= 0 then
        return cart:RemoveLineAt(lineIndex)
    end
    return cart:UpdateLineAt(lineIndex, { quantity = newQty })
end

function CartPanel:OnRemove(lineIndex)
    local cart = Addon.Cart
    if not cart then return false, "cart-missing" end
    return cart:RemoveLineAt(lineIndex)
end

function CartPanel:OnClear()
    local cart = Addon.Cart
    if not cart then return false, "cart-missing" end
    cart:Clear()
    return true
end

function CartPanel:OnCheckout()
    local cart = Addon.Cart
    if not cart then return nil, "cart-missing" end
    return cart:Checkout()
end

-- Formats a checkout result into a single chat-friendly summary line
-- (or two: success line, then any error line). Returns an array of
-- strings, never throws.
function CartPanel:FormatCheckoutSummary(result)
    if not result then return { "Cart checkout failed." } end
    local lines = {}
    if #result.created > 0 then
        lines[#lines + 1] = string.format("Created %d order(s): %s",
            #result.created, table.concat(result.created, ", "))
    end
    if #result.errors > 0 then
        for index = 1, #result.errors do
            local err = result.errors[index]
            lines[#lines + 1] = string.format("|cffff5555Error for %s:|r %s",
                tostring(err.crafter), tostring(err.reason))
        end
    end
    if #lines == 0 then
        lines[#lines + 1] = "Nothing to check out."
    end
    return lines
end

-- ---------------------------------------------------------------------
-- UI side
-- ---------------------------------------------------------------------

local PANEL_WIDTH        = 360
local PANEL_HEIGHT       = 420
local ROW_HEIGHT         = 22
local ROW_SPACING        = 2
local GROUP_HEADER_HEIGHT = 22
local GROUP_SPACING      = 8

local COLOR_PANEL  = { 0.07, 0.07, 0.07, 0.95 }
local COLOR_BORDER = { 0.30, 0.30, 0.30, 0.85 }

local PANEL_BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
}

local function applyPanelBackdrop(frame)
    if not (frame and frame.SetBackdrop) then return end
    frame:SetBackdrop(PANEL_BACKDROP)
    frame:SetBackdropColor(COLOR_PANEL[1], COLOR_PANEL[2], COLOR_PANEL[3], COLOR_PANEL[4])
    frame:SetBackdropBorderColor(COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])
end

local function qualityColor(quality)
    if type(quality) ~= "number" then return nil end
    local palette = _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[quality]
    if not palette then return nil end
    return palette.r, palette.g, palette.b
end

-- ---------------------------------------------------------------------
-- Toggle button — small "Cart (N)" widget anchored to RR's main frame.

function CartPanel:BuildToggle()
    if self.toggle then return self.toggle end
    if not CreateFrame then return nil end
    local host = _G.RecipeRegistryFrame
    if not host then return nil end

    -- Anchored to the bottom-right of the main frame so it doesn't
    -- collide with the title-bar widgets (Sync indicator, Roster
    -- Cleanup button, close button). Sits just above the resize
    -- handle if present.
    local toggle = CreateFrame("Button", "RecipeRegistry_OrdersCartToggle", host, "BackdropTemplate")
    toggle:SetSize(96, 22)
    toggle:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -14, 10)
    toggle:SetFrameLevel((host:GetFrameLevel() or 0) + 5)
    applyPanelBackdrop(toggle)

    toggle.label = toggle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    toggle.label:SetPoint("CENTER")
    toggle.label:SetText("Cart (0)")

    toggle:SetScript("OnEnter", function(widget)
        widget:SetBackdropBorderColor(1.00, 0.82, 0.00, 0.95)
    end)
    toggle:SetScript("OnLeave", function(widget)
        widget:SetBackdropBorderColor(COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])
    end)
    toggle:SetScript("OnClick", function() CartPanel:Toggle() end)

    self.toggle = toggle
    return toggle
end

function CartPanel:RefreshToggle()
    if not self.toggle then return end
    local count = Addon.Cart and Addon.Cart:CountLines() or 0
    if self.toggle.label and self.toggle.label.SetText then
        self.toggle.label:SetText(string.format("Cart (%d)", count))
    end
end

-- ---------------------------------------------------------------------
-- Floating panel.

function CartPanel:Build()
    if self.frame then return self.frame end
    if not CreateFrame then return nil end

    local f = CreateFrame("Frame", "RecipeRegistry_OrdersCartPanel", UIParent, "BackdropTemplate")
    f:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    f:SetPoint("CENTER", 320, 0)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    applyPanelBackdrop(f)
    f:Hide()
    self.frame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Order cart")
    f.title = title

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", 14, -34)
    subtitle:SetPoint("TOPRIGHT", -14, -34)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Pending lines, grouped by crafter.")
    f.subtitle = subtitle

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() CartPanel:Hide() end)

    local listFrame = CreateFrame("Frame", nil, f, "BackdropTemplate")
    listFrame:SetPoint("TOPLEFT", 14, -58)
    listFrame:SetPoint("BOTTOMRIGHT", -14, 50)
    applyPanelBackdrop(listFrame)
    f.listFrame = listFrame

    local scroll = CreateFrame("ScrollFrame", nil, listFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -28, 8)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(PANEL_WIDTH - 60, 1)
    scroll:SetScrollChild(content)
    f.scroll  = scroll
    f.content = content
    self._rowPool   = self._rowPool or {}
    self._headerPool = self._headerPool or {}

    local checkout = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    checkout:SetSize(120, 24)
    checkout:SetPoint("BOTTOMLEFT", 16, 14)
    checkout:SetText("Checkout")
    checkout:SetScript("OnClick", function() CartPanel:OnCheckoutClicked() end)
    f.checkout = checkout

    local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clear:SetSize(120, 24)
    clear:SetPoint("BOTTOMRIGHT", -16, 14)
    clear:SetText("Clear cart")
    clear:SetScript("OnClick", function() CartPanel:OnClearClicked() end)
    f.clear = clear

    return f
end

-- Row widget for a single cart line. Layout:
--   [icon] Recipe label                       [- N +] [x]
function CartPanel:_AcquireRow(index)
    self._rowPool = self._rowPool or {}
    local row = self._rowPool[index]
    if row then return row end
    if not (self.frame and self.frame.content and CreateFrame) then return nil end

    row = CreateFrame("Frame", nil, self.frame.content)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", 0, 0)
    row:SetPoint("RIGHT", 0, 0)

    row.iconTexture = row:CreateTexture(nil, "ARTWORK")
    row.iconTexture:SetSize(16, 16)
    row.iconTexture:SetPoint("LEFT", 4, 0)

    row.labelText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.labelText:SetPoint("LEFT", row.iconTexture, "RIGHT", 6, 0)
    row.labelText:SetJustifyH("LEFT")
    if row.labelText.SetWordWrap then row.labelText:SetWordWrap(false) end
    if row.labelText.SetMaxLines then row.labelText:SetMaxLines(1) end

    row.removeButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.removeButton:SetSize(18, 18)
    row.removeButton:SetPoint("RIGHT", -4, 0)
    row.removeButton:SetText("x")
    row.removeButton:SetScript("OnClick", function(widget)
        CartPanel:OnRemove(widget.boundIndex)
    end)

    row.plusButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.plusButton:SetSize(18, 18)
    row.plusButton:SetPoint("RIGHT", row.removeButton, "LEFT", -2, 0)
    row.plusButton:SetText("+")
    row.plusButton:SetScript("OnClick", function(widget)
        CartPanel:OnIncrement(widget.boundIndex)
    end)

    row.qtyText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.qtyText:SetWidth(32)
    row.qtyText:SetPoint("RIGHT", row.plusButton, "LEFT", -4, 0)
    row.qtyText:SetJustifyH("CENTER")

    row.minusButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.minusButton:SetSize(18, 18)
    row.minusButton:SetPoint("RIGHT", row.qtyText, "LEFT", -2, 0)
    row.minusButton:SetText("-")
    row.minusButton:SetScript("OnClick", function(widget)
        CartPanel:OnDecrement(widget.boundIndex)
    end)

    -- We're going to set the labelText's RIGHT anchor to the minus
    -- button's LEFT so long names don't overlap controls.
    row.labelText:SetPoint("RIGHT", row.minusButton, "LEFT", -6, 0)

    self._rowPool[index] = row
    return row
end

function CartPanel:_AcquireHeader(index)
    self._headerPool = self._headerPool or {}
    local header = self._headerPool[index]
    if header then return header end
    if not (self.frame and self.frame.content and CreateFrame) then return nil end

    header = CreateFrame("Frame", nil, self.frame.content)
    header:SetHeight(GROUP_HEADER_HEIGHT)
    header:SetPoint("LEFT", 0, 0)
    header:SetPoint("RIGHT", 0, 0)

    header.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header.label:SetPoint("LEFT", 4, 0)
    header.label:SetJustifyH("LEFT")

    self._headerPool[index] = header
    return header
end

function CartPanel:Refresh()
    self:RefreshToggle()
    if not self.frame or not self.frame:IsShown() then return end

    local view = self:BuildView()
    if self.frame.subtitle and self.frame.subtitle.SetText then
        self.frame.subtitle:SetText(string.format(
            "%d line(s) across %d crafter(s).",
            view.totalLines, view.totalCrafters
        ))
    end

    local y = 0
    local headerIndex = 0
    local rowIndex = 0

    for _, group in ipairs(view.groups) do
        headerIndex = headerIndex + 1
        local header = self:_AcquireHeader(headerIndex)
        if header then
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT",  0, -y)
            header:SetPoint("TOPRIGHT", 0, -y)
            if header.label and header.label.SetText then
                if group.colorR then
                    header.label:SetTextColor(group.colorR, group.colorG, group.colorB)
                else
                    header.label:SetTextColor(1.00, 0.82, 0.00)
                end
                header.label:SetText(string.format("→ %s", group.displayName))
            end
            header:Show()
            y = y + GROUP_HEADER_HEIGHT
        end

        for _, lineView in ipairs(group.lines) do
            rowIndex = rowIndex + 1
            local row = self:_AcquireRow(rowIndex)
            if row then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT",  0, -y)
                row:SetPoint("TOPRIGHT", 0, -y)

                if lineView.icon and row.iconTexture and row.iconTexture.SetTexture then
                    row.iconTexture:SetTexture(lineView.icon)
                    row.iconTexture:Show()
                elseif row.iconTexture then
                    row.iconTexture:Hide()
                end

                local labelText = lineView.recipeLabel or "?"
                local r, g, b = qualityColor(lineView.quality)
                if r then
                    row.labelText:SetTextColor(r, g, b)
                else
                    row.labelText:SetTextColor(0.94, 0.92, 0.88)
                end
                row.labelText:SetText(labelText)
                row.qtyText:SetText(string.format("x%d", lineView.quantity or 0))

                row.minusButton.boundIndex  = lineView.lineIndex
                row.plusButton.boundIndex   = lineView.lineIndex
                row.removeButton.boundIndex = lineView.lineIndex

                row:Show()
                y = y + ROW_HEIGHT + ROW_SPACING
            end
        end

        y = y + GROUP_SPACING
    end

    -- Hide leftover widgets.
    for index = headerIndex + 1, #self._headerPool do
        local h = self._headerPool[index]
        if h and h.Hide then h:Hide() end
    end
    for index = rowIndex + 1, #self._rowPool do
        local r = self._rowPool[index]
        if r and r.Hide then r:Hide() end
    end

    if self.frame.content and self.frame.content.SetHeight then
        self.frame.content:SetHeight(math.max(1, y))
    end
end

function CartPanel:Show()
    self:Build()
    if self.frame and self.frame.Show then self.frame:Show() end
    self:Refresh()
end

function CartPanel:Hide()
    if self.frame and self.frame.Hide then self.frame:Hide() end
end

function CartPanel:Toggle()
    if self.frame and self.frame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function CartPanel:OnCheckoutClicked()
    local result, err = self:OnCheckout()
    local lines
    if not result then
        lines = { string.format("Checkout failed: %s", tostring(err)) }
    else
        lines = self:FormatCheckoutSummary(result)
    end
    if type(Addon.Print) == "function" then
        for index = 1, #lines do Addon:Print(lines[index]) end
    end
    self:Refresh()
end

function CartPanel:OnClearClicked()
    self:OnClear()
    self:Refresh()
end

-- ---------------------------------------------------------------------
-- Wiring

function CartPanel:Wire()
    if self._wired then return end
    self._wired = true

    if type(Addon.RegisterMessage) == "function" then
        Addon:RegisterMessage("CraftOrders:CartChanged", function()
            CartPanel:Refresh()
        end)
        -- Cart contents may change via Store mutations too (e.g. on
        -- checkout the cart is cleared, but the orders message fires
        -- before CartChanged). Hook both so the toggle badge stays
        -- accurate.
        Addon:RegisterMessage("CraftOrders:Changed", function()
            CartPanel:RefreshToggle()
        end)
    end

    -- The toggle button needs _G.RecipeRegistryFrame to anchor to. RR
    -- creates that frame in its UI:OnEnable; as long as the plugin's
    -- OnEnable runs after RR's the frame is there. If not (test
    -- harness, race), retry on a short timer until it appears or we
    -- give up after a few seconds.
    local function tryBuildToggle()
        if not _G.RecipeRegistryFrame then return false end
        CartPanel:BuildToggle()
        CartPanel:RefreshToggle()
        return true
    end
    if tryBuildToggle() then return end
    if type(Addon.ScheduleTimer) ~= "function" then return end
    local attempts = 0
    local function retry()
        attempts = attempts + 1
        if tryBuildToggle() then return end
        if attempts < 10 then
            Addon:ScheduleTimer(retry, 0.5)
        end
    end
    Addon:ScheduleTimer(retry, 0.5)
end
