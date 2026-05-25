local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local OrderDialog = {}
Addon.OrderDialog = OrderDialog

-- ---------------------------------------------------------------------
-- Helpers
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

local function getLastChoices()
    if not Addon.charDB then return nil end
    Addon.charDB.lastChoices = Addon.charDB.lastChoices or {}
    return Addon.charDB.lastChoices
end

-- ---------------------------------------------------------------------
-- Data-side surface (testable without CreateFrame)
-- ---------------------------------------------------------------------

-- Returns a presentation-ready list of crafters for a recipe. Sorted
-- with online first, then by skill rank desc, then alphabetic — the
-- same ordering Data:GetRecipeCrafters already produces. Each entry
-- gets a `display` (short name) and class colour triple `r,g,b` (or
-- nil if unknown). `opts.includeOffline` decides whether offline
-- crafters appear at all.
function OrderDialog:GetSortedCrafters(info, opts)
    opts = opts or {}
    local out = {}
    if type(info) ~= "table" or type(info.crafters) ~= "table" then return out end
    for index = 1, #info.crafters do
        local source = info.crafters[index]
        if source.online or opts.includeOffline then
            local r, g, b = classColor(source.memberKey)
            out[#out + 1] = {
                memberKey      = source.memberKey,
                profession     = source.profession,
                skillRank      = source.skillRank,
                specialization = source.specialization,
                online         = source.online == true,
                display        = shortName(source.memberKey),
                colorR         = r,
                colorG         = g,
                colorB         = b,
            }
        end
    end
    return out
end

function OrderDialog:GetLastChoice(recipeKey)
    local choices = getLastChoices()
    if not choices then return nil end
    return choices[recipeKey]
end

function OrderDialog:RememberChoice(recipeKey, quantity, crafter)
    local choices = getLastChoices()
    if not choices then return end
    choices[recipeKey] = {
        crafter  = crafter,
        quantity = tonumber(quantity) or 1,
    }
end

-- Computes the initial dialog state from sticky preferences + crafter
-- availability. Returns:
--   { quantity, crafter, source = "sticky"|"auto-select"|"first-online"|nil }
-- The caller binds these to the form widgets on Open().
function OrderDialog:ComputeInitialSelection(recipeKey, info)
    local result = { quantity = 1, crafter = nil, source = nil }
    local sticky = self:GetLastChoice(recipeKey)
    if sticky then
        result.quantity = tonumber(sticky.quantity) or 1
    end

    local crafters = self:GetSortedCrafters(info, { includeOffline = false })
    if #crafters == 0 then return result end

    if sticky and sticky.crafter then
        for index = 1, #crafters do
            if crafters[index].memberKey == sticky.crafter then
                result.crafter = sticky.crafter
                result.source  = "sticky"
                return result
            end
        end
    end

    if #crafters == 1 then
        result.crafter = crafters[1].memberKey
        result.source  = "auto-select"
        return result
    end

    result.crafter = crafters[1].memberKey
    result.source  = "first-online"
    return result
end

-- Commit handler shared by the slash and the dialog button. Validates
-- + calls Cart:AddLine + saves sticky. Returns the cart line index
-- (or nil + reason).
function OrderDialog:ConfirmAddToCart(recipeKey, info, quantity, crafter)
    quantity = tonumber(quantity)
    if not quantity or quantity <= 0 then return nil, "invalid-line-quantity" end
    if type(crafter) ~= "string" or crafter == "" then return nil, "missing-crafter" end
    if not (Addon.Cart and Addon.Cart.AddLine) then return nil, "cart-missing" end

    local recipeLabel  = info and info.label
    local outputItemID = info and info.createdItemID

    local index, mergedFlag = Addon.Cart:AddLine({
        recipeKey    = recipeKey,
        quantity     = quantity,
        crafter      = crafter,
        recipeLabel  = recipeLabel,
        outputItemID = outputItemID,
    })
    if not index then
        return nil, mergedFlag  -- AddLine's 2nd return is the error code on failure
    end
    self:RememberChoice(recipeKey, quantity, crafter)
    return index, mergedFlag == true and "merged" or "added"
end

-- ---------------------------------------------------------------------
-- UI side
-- ---------------------------------------------------------------------

local DIALOG_WIDTH  = 360
local DIALOG_HEIGHT = 340

local COLOR_BG     = { 0.07, 0.07, 0.07, 0.95 }
local COLOR_BORDER = { 0.30, 0.30, 0.30, 0.85 }
local COLOR_ROW    = { 0.10, 0.10, 0.10, 0.85 }
local COLOR_ROW_SEL = { 0.20, 0.16, 0.05, 0.95 }
local COLOR_ROW_SEL_BORDER = { 1.00, 0.82, 0.00, 0.95 }

local PANEL_BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
}

local function applyPanelBackdrop(frame, bg, border)
    if not (frame and frame.SetBackdrop) then return end
    frame:SetBackdrop(PANEL_BACKDROP)
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
end

function OrderDialog:Build()
    if self.frame then return self.frame end
    if not CreateFrame then return nil end

    local f = CreateFrame("Frame", "RecipeRegistry_OrdersOrderDialog", UIParent, "BackdropTemplate")
    f:SetSize(DIALOG_WIDTH, DIALOG_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    applyPanelBackdrop(f, COLOR_BG, COLOR_BORDER)
    f:Hide()
    self.frame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Order this recipe")
    f.title = title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() OrderDialog:Close() end)

    local recipeLine = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    recipeLine:SetPoint("TOPLEFT", 14, -40)
    recipeLine:SetPoint("TOPRIGHT", -14, -40)
    recipeLine:SetJustifyH("LEFT")
    f.recipeLine = recipeLine

    local qtyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    qtyLabel:SetPoint("TOPLEFT", 14, -72)
    qtyLabel:SetText("Quantity:")
    f.qtyLabel = qtyLabel

    local qtyBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    qtyBox:SetSize(60, 24)
    qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 16, 0)
    qtyBox:SetAutoFocus(false)
    qtyBox:SetNumeric(true)
    qtyBox:SetMaxLetters(4)
    qtyBox:SetText("1")
    f.qtyBox = qtyBox

    local crafterLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    crafterLabel:SetPoint("TOPLEFT", 14, -110)
    crafterLabel:SetText("Crafter:")
    f.crafterLabel = crafterLabel

    local crafterFrame = CreateFrame("Frame", nil, f, "BackdropTemplate")
    crafterFrame:SetPoint("TOPLEFT", 14, -130)
    crafterFrame:SetPoint("TOPRIGHT", -14, -130)
    crafterFrame:SetHeight(140)
    applyPanelBackdrop(crafterFrame, COLOR_ROW, COLOR_BORDER)
    f.crafterFrame = crafterFrame

    local scroll = CreateFrame("ScrollFrame", nil, crafterFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -24, 6)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(280, 1)
    scroll:SetScrollChild(content)
    f.scroll = scroll
    f.content = content
    self._crafterRows = self._crafterRows or {}

    local offlineToggle = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    offlineToggle:SetPoint("TOPLEFT", 14, -278)
    offlineToggle:SetSize(20, 20)
    offlineToggle:SetScript("OnClick", function(widget)
        self._includeOffline = widget:GetChecked() == true
        self:RefreshCrafterList()
    end)
    local offlineLabel = offlineToggle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    offlineLabel:SetPoint("LEFT", offlineToggle, "RIGHT", 4, 0)
    offlineLabel:SetText("Show offline crafters")
    f.offlineToggle = offlineToggle

    local addButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addButton:SetSize(120, 24)
    addButton:SetPoint("BOTTOMLEFT", 16, 14)
    addButton:SetText("Add to cart")
    addButton:SetScript("OnClick", function() OrderDialog:OnConfirm() end)
    f.addButton = addButton

    local cancelButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelButton:SetSize(90, 24)
    cancelButton:SetPoint("BOTTOMRIGHT", -16, 14)
    cancelButton:SetText("Cancel")
    cancelButton:SetScript("OnClick", function() OrderDialog:Close() end)
    f.cancelButton = cancelButton

    return f
end

local function setRowSelected(row, selected)
    if not (row and row.SetBackdrop) then return end
    if selected then
        row:SetBackdropColor(COLOR_ROW_SEL[1], COLOR_ROW_SEL[2], COLOR_ROW_SEL[3], COLOR_ROW_SEL[4])
        row:SetBackdropBorderColor(COLOR_ROW_SEL_BORDER[1], COLOR_ROW_SEL_BORDER[2], COLOR_ROW_SEL_BORDER[3], COLOR_ROW_SEL_BORDER[4])
    else
        row:SetBackdropColor(0, 0, 0, 0)
        row:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

function OrderDialog:_AcquireRow(index)
    self._crafterRows = self._crafterRows or {}
    local row = self._crafterRows[index]
    if row then return row end
    if not (self.frame and self.frame.content and CreateFrame) then return nil end

    row = CreateFrame("Button", nil, self.frame.content, "BackdropTemplate")
    row:SetHeight(20)
    row:SetPoint("LEFT", 0, 0)
    row:SetPoint("RIGHT", 0, 0)
    row:SetBackdrop(PANEL_BACKDROP)
    setRowSelected(row, false)

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameText:SetPoint("LEFT", 8, 0)
    row.nameText:SetJustifyH("LEFT")
    row.metaText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.metaText:SetPoint("RIGHT", -8, 0)
    row.metaText:SetJustifyH("RIGHT")

    row:SetScript("OnClick", function(widget)
        OrderDialog._selectedCrafter = widget.boundCrafter
        OrderDialog:RefreshSelectionHighlight()
    end)

    self._crafterRows[index] = row
    return row
end

-- Status colour pair matches RR core's existing convention for
-- online (soft green) vs offline (red). Encoded as inline |cff...
-- codes so the meta string can mix coloured fragments.
local STATUS_ONLINE_COLOR  = "|cff66dd66"
local STATUS_OFFLINE_COLOR = "|cffdd5555"

local function formatCrafterMeta(entry)
    local color  = entry.online and STATUS_ONLINE_COLOR or STATUS_OFFLINE_COLOR
    local status = entry.online and "online" or "offline"
    return color .. status .. "|r"
end

function OrderDialog:RefreshCrafterList()
    if not (self.frame and self._currentInfo) then return end
    local crafters = self:GetSortedCrafters(self._currentInfo, {
        includeOffline = self._includeOffline == true,
    })

    for index = 1, #crafters do
        local row = self:_AcquireRow(index)
        if row then
            local entry = crafters[index]
            row.boundCrafter = entry.memberKey
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -((index - 1) * 22))
            row:SetPoint("TOPRIGHT", 0, -((index - 1) * 22))
            row.nameText:SetText(entry.display)
            if entry.colorR then
                row.nameText:SetTextColor(entry.colorR, entry.colorG, entry.colorB)
            else
                row.nameText:SetTextColor(0.94, 0.92, 0.88)
            end
            row.metaText:SetText(formatCrafterMeta(entry))
            row:Show()
        end
    end
    for index = #crafters + 1, #self._crafterRows do
        local row = self._crafterRows[index]
        if row and row.Hide then row:Hide() end
    end
    if self.frame.content and self.frame.content.SetHeight then
        self.frame.content:SetHeight(math.max(1, #crafters * 22))
    end
    self:RefreshSelectionHighlight()
end

function OrderDialog:RefreshSelectionHighlight()
    for _, row in pairs(self._crafterRows or {}) do
        if row and row.boundCrafter then
            setRowSelected(row, row.boundCrafter == self._selectedCrafter)
        end
    end
end

function OrderDialog:OnConfirm()
    if not (self.frame and self._currentRecipeKey) then return end
    local qty = tonumber(self.frame.qtyBox:GetText()) or 1
    local index, outcome = self:ConfirmAddToCart(
        self._currentRecipeKey, self._currentInfo, qty, self._selectedCrafter
    )
    if not index then
        if type(Addon.Print) == "function" then
            Addon:Print("Couldn't add to cart: " .. tostring(outcome))
        end
        return
    end
    if type(Addon.Print) == "function" then
        Addon:Print(string.format(
            "Cart: %s %s x%d -> %s",
            outcome == "merged" and "updated" or "added",
            tostring(self._currentInfo and self._currentInfo.label or self._currentRecipeKey),
            qty,
            tostring(self._selectedCrafter)
        ))
    end
    self:Close()
end

-- Auto-decides whether the dialog should open with offline crafters
-- visible. Rule: if at least one crafter is online, default to
-- online-only (cleaner picker). If zero online but some exist
-- offline, default to "show offline" so the picker isn't empty.
function OrderDialog:ShouldDefaultToOffline(info)
    local online = self:GetSortedCrafters(info, { includeOffline = false })
    if #online > 0 then return false end
    local all = self:GetSortedCrafters(info, { includeOffline = true })
    return #all > 0
end

function OrderDialog:Open(recipeKey, info)
    if not recipeKey then return end
    local f = self:Build()
    if not f then return end

    self._currentRecipeKey = recipeKey
    self._currentInfo      = info
    self._includeOffline   = self:ShouldDefaultToOffline(info)
    if f.offlineToggle and f.offlineToggle.SetChecked then
        f.offlineToggle:SetChecked(self._includeOffline)
    end

    local label = (info and info.label) or tostring(recipeKey)
    if f.recipeLine and f.recipeLine.SetText then
        f.recipeLine:SetText(label)
    end

    local selection = self:ComputeInitialSelection(recipeKey, info)
    -- If we auto-fell-back to offline and the regular online-only
    -- selection didn't pick anyone, pick the first offline crafter
    -- so the dialog opens with something selected.
    if self._includeOffline and not selection.crafter then
        local all = self:GetSortedCrafters(info, { includeOffline = true })
        if #all > 0 then
            selection.crafter = all[1].memberKey
            selection.source  = "first-offline"
        end
    end
    if f.qtyBox and f.qtyBox.SetText then
        f.qtyBox:SetText(tostring(selection.quantity or 1))
    end
    self._selectedCrafter = selection.crafter

    self:RefreshCrafterList()
    if f.Show then f:Show() end
end

function OrderDialog:Close()
    if self.frame and self.frame.Hide then self.frame:Hide() end
    self._currentRecipeKey = nil
    self._currentInfo      = nil
    self._selectedCrafter  = nil
end

function OrderDialog:IsOpen()
    return self.frame and self.frame.IsShown and self.frame:IsShown() == true or false
end
