local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Window = {}
Addon.ShoppingWindow = Window

-- §9.1 floating window. Anchored to UIParent so it survives RR's main
-- frame closing — the user opens the window once, walks away to the
-- auction house and bank, and the materials breakdown stays visible
-- the whole time.

local PANEL_BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
}
local COLOR_PANEL  = { 0.07, 0.07, 0.07, 0.95 }
local COLOR_BORDER = { 0.30, 0.30, 0.30, 0.85 }
local COLOR_ROW    = { 0.10, 0.10, 0.10, 0.85 }

local WINDOW_WIDTH  = 360
local WINDOW_HEIGHT = 440
local ROW_HEIGHT    = 22
local ROW_SPACING   = 2

-- Column layout. The "still" column is rightmost because that's the
-- number the user actually wants to read at a glance ("what do I
-- still have to gather"); the rest is supporting context.
local COL_ICON_W   = 18
local COL_NEED_W   = 38
local COL_BAGS_W   = 38
local COL_BANK_W   = 38
local COL_STILL_W  = 40

local function applyPanelBackdrop(frame)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop(PANEL_BACKDROP)
    frame:SetBackdropColor(COLOR_PANEL[1], COLOR_PANEL[2], COLOR_PANEL[3], COLOR_PANEL[4])
    frame:SetBackdropBorderColor(COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])
end

local function applyRowBackdrop(frame)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop(PANEL_BACKDROP)
    frame:SetBackdropColor(COLOR_ROW[1], COLOR_ROW[2], COLOR_ROW[3], COLOR_ROW[4])
    frame:SetBackdropBorderColor(0.18, 0.18, 0.18, 0.55)
end

local function formatBankSnapshotAge(snapshot)
    if not (snapshot and snapshot.lastSeenAt) then return "bank not seen this session" end
    local delta = math.max(0, (time and time() or 0) - snapshot.lastSeenAt)
    if delta < 60 then return "bank seen just now" end
    if delta < 3600 then return string.format("bank seen %dm ago", math.floor(delta / 60)) end
    return string.format("bank seen %dh ago", math.floor(delta / 3600))
end

local function makeColumnHeader(parent, label, width, anchorLeft)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    if anchorLeft then
        fs:SetPoint("LEFT", anchorLeft, "RIGHT", 4, 0)
    else
        fs:SetPoint("LEFT", 8, 0)
    end
    fs:SetWidth(width)
    fs:SetJustifyH("RIGHT")
    fs:SetText(label or "")
    return fs
end

function Window:Build()
    if self.frame then return self.frame end
    if not CreateFrame then return nil end

    local frame = CreateFrame("Frame", "RecipeRegistry_OrdersShoppingWindow",
        UIParent, "BackdropTemplate")
    frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    frame:SetPoint("CENTER", -380, 0)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    applyPanelBackdrop(frame)
    frame:Hide()
    self.frame = frame

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Shopping list")
    frame.title = title

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", 14, -34)
    subtitle:SetPoint("TOPRIGHT", -14, -34)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("")
    frame.subtitle = subtitle

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() Window:Hide() end)

    -- Header strip with right-justified column titles.
    local headerStrip = CreateFrame("Frame", nil, frame)
    headerStrip:SetPoint("TOPLEFT", 14, -56)
    headerStrip:SetPoint("TOPRIGHT", -14, -56)
    headerStrip:SetHeight(16)
    frame.headerStrip = headerStrip

    local itemHeader = headerStrip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    itemHeader:SetPoint("LEFT", COL_ICON_W + 6, 0)
    itemHeader:SetText("Item")
    itemHeader:SetJustifyH("LEFT")

    local needCol  = makeColumnHeader(headerStrip, "Need",  COL_NEED_W,  nil)
    needCol:ClearAllPoints()
    needCol:SetPoint("RIGHT", -COL_STILL_W - COL_BANK_W - COL_BAGS_W - 16, 0)
    local bagsCol  = makeColumnHeader(headerStrip, "Bags",  COL_BAGS_W,  nil)
    bagsCol:ClearAllPoints()
    bagsCol:SetPoint("RIGHT", -COL_STILL_W - COL_BANK_W - 12, 0)
    local bankCol  = makeColumnHeader(headerStrip, "Bank",  COL_BANK_W,  nil)
    bankCol:ClearAllPoints()
    bankCol:SetPoint("RIGHT", -COL_STILL_W - 8, 0)
    local stillCol = makeColumnHeader(headerStrip, "Still", COL_STILL_W, nil)
    stillCol:ClearAllPoints()
    stillCol:SetPoint("RIGHT", -4, 0)
    stillCol:SetTextColor(1.0, 0.82, 0.0)

    -- Scrollable list body.
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -76)
    scroll:SetPoint("BOTTOMRIGHT", -36, 16)
    frame.scroll = scroll

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(WINDOW_WIDTH - 60, 1)
    scroll:SetScrollChild(scrollChild)
    frame.scrollChild = scrollChild

    self.rows = self.rows or {}
    return frame
end

local function setRowColumn(fs, text, color)
    fs:SetText(text or "")
    if color then
        fs:SetTextColor(color[1], color[2], color[3])
    else
        fs:SetTextColor(0.94, 0.92, 0.88)
    end
end

function Window:_AcquireRow(index)
    self.rows = self.rows or {}
    local row = self.rows[index]
    if row then return row end
    if not (self.frame and self.frame.scrollChild and CreateFrame) then return nil end

    row = CreateFrame("Button", nil, self.frame.scrollChild, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", 0, 0)
    row:SetPoint("RIGHT", 0, 0)
    applyRowBackdrop(row)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(COL_ICON_W - 2, COL_ICON_W - 2)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

    -- The item-name fontstring uses a real hyperlink so shift-click
    -- pastes the item link into chat / Auctionator search per WoW's
    -- standard mechanic. The button-level OnHyperlinkClick handler
    -- routes the click into ChatEdit_InsertLink when shift is held.
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.nameText:SetPoint("RIGHT", row, "RIGHT", -COL_STILL_W - COL_BANK_W - COL_BAGS_W - COL_NEED_W - 24, 0)
    row.nameText:SetJustifyH("LEFT")
    if row.nameText.SetWordWrap then row.nameText:SetWordWrap(false) end

    row.needText  = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.needText:SetPoint("RIGHT", row, "RIGHT", -COL_STILL_W - COL_BANK_W - COL_BAGS_W - 16, 0)
    row.needText:SetWidth(COL_NEED_W)
    row.needText:SetJustifyH("RIGHT")

    row.bagsText  = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.bagsText:SetPoint("RIGHT", row, "RIGHT", -COL_STILL_W - COL_BANK_W - 12, 0)
    row.bagsText:SetWidth(COL_BAGS_W)
    row.bagsText:SetJustifyH("RIGHT")

    row.bankText  = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.bankText:SetPoint("RIGHT", row, "RIGHT", -COL_STILL_W - 8, 0)
    row.bankText:SetWidth(COL_BANK_W)
    row.bankText:SetJustifyH("RIGHT")

    row.stillText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.stillText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.stillText:SetWidth(COL_STILL_W)
    row.stillText:SetJustifyH("RIGHT")

    -- Standard shift-click-to-chat behaviour. ChatEdit_InsertLink is
    -- the same path the default UI uses when you shift-click an item
    -- from a bag, so it routes correctly to either the open chat box
    -- or an addon-provided receiver (Auctionator's search box, etc.).
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(widget, _button)
        if IsShiftKeyDown and IsShiftKeyDown() and widget._boundLink and ChatEdit_InsertLink then
            ChatEdit_InsertLink(widget._boundLink)
        end
    end)

    row:SetScript("OnEnter", function(widget)
        local tooltip = _G.GameTooltip
        if not (tooltip and widget._boundLink) then return end
        tooltip:SetOwner(widget, "ANCHOR_TOPLEFT")
        tooltip:SetHyperlink(widget._boundLink)
        -- Append per-order attribution lines after the standard
        -- item tooltip so the user can see which orders are
        -- responsible for this row.
        if widget._boundOrders and #widget._boundOrders > 0 then
            tooltip:AddLine(" ")
            tooltip:AddLine("Needed by:", 1.0, 0.82, 0.0)
            for _, entry in ipairs(widget._boundOrders) do
                tooltip:AddLine(string.format("  %s x%d",
                    tostring(entry.crafter or "?"), tonumber(entry.quantity) or 0),
                    0.85, 0.85, 0.85)
            end
        end
        tooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    self.rows[index] = row
    return row
end

function Window:_BindRow(row, entry, rowIndex)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT",  0, -((rowIndex - 1) * (ROW_HEIGHT + ROW_SPACING)))
    row:SetPoint("TOPRIGHT", 0, -((rowIndex - 1) * (ROW_HEIGHT + ROW_SPACING)))

    if entry.icon then
        row.icon:SetTexture(entry.icon)
    elseif type(_G.GetItemInfo) == "function" then
        local _, _, _, _, _, _, _, _, _, texture = _G.GetItemInfo(entry.itemID)
        if texture then row.icon:SetTexture(texture) end
    end

    setRowColumn(row.nameText, entry.link or entry.name or ("item:" .. tostring(entry.itemID)))
    setRowColumn(row.needText, tostring(entry.required or 0))
    setRowColumn(row.bagsText, tostring(entry.inBags  or 0))
    setRowColumn(row.bankText, tostring(entry.inBank  or 0))

    local stillCount = entry.stillToGather or 0
    local stillColor
    if stillCount == 0 then
        stillColor = { 0.55, 0.85, 0.45 } -- covered
    elseif (entry.inBags + entry.inBank) > 0 then
        stillColor = { 1.0, 0.82, 0.0 }   -- partially covered
    else
        stillColor = { 1.0, 0.45, 0.45 }  -- nothing on hand
    end
    setRowColumn(row.stillText, tostring(stillCount), stillColor)

    row._boundLink = entry.link
    row._boundOrders = entry.contributingOrders or {}
    row:Show()
end

function Window:Refresh()
    local shopping = Addon.Shopping
    if not (self.frame and shopping and shopping.ComputeAggregated) then return end
    local result = shopping:ComputeAggregated()

    if self.frame.subtitle then
        if result.orderCount == 0 then
            self.frame.subtitle:SetText("No outgoing orders yet.")
        else
            self.frame.subtitle:SetText(string.format(
                "%d distinct material(s) across %d order(s) — %s.",
                result.distinctItems, result.orderCount,
                formatBankSnapshotAge(result.bankSnapshot)))
        end
    end

    self.rows = self.rows or {}
    for index = 1, #result.materials do
        local row = self:_AcquireRow(index)
        if row then self:_BindRow(row, result.materials[index], index) end
    end
    for index = #result.materials + 1, #self.rows do
        local extra = self.rows[index]
        if extra and extra.Hide then extra:Hide() end
    end
    if self.frame.scrollChild and self.frame.scrollChild.SetHeight then
        local contentHeight = math.max(1, #result.materials * (ROW_HEIGHT + ROW_SPACING))
        self.frame.scrollChild:SetHeight(contentHeight)
    end
end

function Window:IsShown()
    return self.frame and self.frame.IsShown and self.frame:IsShown() or false
end

function Window:Show()
    self:Build()
    if not self.frame then return end
    self.frame:Show()
    self:Refresh()
end

function Window:Hide()
    if self.frame and self.frame.Hide then self.frame:Hide() end
end

function Window:Toggle()
    if self:IsShown() then self:Hide() else self:Show() end
end

-- Lifecycle: subscribe to CraftOrders:Changed so the rendered list
-- stays live when an order is added/removed or a batch is sent. The
-- backend's bank snapshot updates on BANKFRAME_OPENED separately
-- (Shopping:OnEnable); when that fires while the window is up, the
-- next Changed broadcast will pick up the new snapshot.
function Window:OnEnable()
    if self._wired then return end
    if type(Addon.RegisterMessage) ~= "function" then return end
    Addon:RegisterMessage("CraftOrders:Changed", function()
        if Window:IsShown() then Window:Refresh() end
    end)
    self._wired = true
end
