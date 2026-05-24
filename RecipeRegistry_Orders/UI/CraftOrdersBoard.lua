local ADDON_NAME = ...
local Addon = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

local Board = {}
Addon.Board = Board

-- Local helpers used across the board. Declared up front so every
-- method below can rely on them being in scope (Lua locals are only
-- visible from their declaration point onwards).
local function getRR()
    return _G.RecipeRegistry
end

local function getRecipeDisplayInfo(recipeKey)
    local rr = getRR()
    if not (rr and rr.Data and type(rr.Data.GetRecipeDisplayInfo) == "function") then
        return nil
    end
    local ok, info = pcall(rr.Data.GetRecipeDisplayInfo, rr.Data, recipeKey)
    if ok and type(info) == "table" then return info end
    return nil
end

local function shortenOrderId(id)
    if type(id) ~= "string" or #id <= 16 then return id end
    return id:sub(1, 8) .. "..." .. id:sub(-4)
end

local function formatPlayerKey(key)
    if type(key) ~= "string" or key == "" then return "?" end
    local hyphen = key:find("-", 1, true)
    if not hyphen then return key end
    return key:sub(1, hyphen - 1)
end

-- Panel-style colours mirror RecipeRegistry's main frame defaults so
-- the board feels native inside the host UI. Defined locally because
-- the public API surface does not (and should not) expose RR's
-- internal colour constants.
local COLOR_PANEL          = { 0.065, 0.065, 0.065, 0.96 }
local COLOR_BORDER         = { 0.30,  0.30,  0.30,  0.85 }
local COLOR_ROW_NORMAL     = { 0.10,  0.10,  0.10,  0.85 }
local COLOR_ROW_BORDER     = { 0.20,  0.20,  0.20,  0.60 }
local COLOR_ROW_SELECTED   = { 0.20,  0.16,  0.05,  0.95 }
local COLOR_ROW_SEL_BORDER = { 1.00,  0.82,  0.00,  0.95 }

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

local function applyRowBackdrop(frame, selected)
    if not (frame and frame.SetBackdrop) then return end
    frame:SetBackdrop(PANEL_BACKDROP)
    if selected then
        frame:SetBackdropColor(COLOR_ROW_SELECTED[1], COLOR_ROW_SELECTED[2], COLOR_ROW_SELECTED[3], COLOR_ROW_SELECTED[4])
        frame:SetBackdropBorderColor(COLOR_ROW_SEL_BORDER[1], COLOR_ROW_SEL_BORDER[2], COLOR_ROW_SEL_BORDER[3], COLOR_ROW_SEL_BORDER[4])
    else
        frame:SetBackdropColor(COLOR_ROW_NORMAL[1], COLOR_ROW_NORMAL[2], COLOR_ROW_NORMAL[3], COLOR_ROW_NORMAL[4])
        frame:SetBackdropBorderColor(COLOR_ROW_BORDER[1], COLOR_ROW_BORDER[2], COLOR_ROW_BORDER[3], COLOR_ROW_BORDER[4])
    end
end

-- Status -> RGB triple for the row's status column. Buckets the 13
-- lifecycle states into a small palette so the UI conveys "active",
-- "needs attention", "done" at a glance. Returned as 3 numbers so the
-- caller can splat into SetTextColor.
local STATUS_COLOURS = {
    Draft              = { 0.55, 0.55, 0.55 },
    MaterialsPartial   = { 1.00, 0.82, 0.10 },
    MaterialsSent      = { 1.00, 0.82, 0.10 },
    MaterialsReceived  = { 0.85, 0.85, 0.45 },
    MaterialsAssumed   = { 0.85, 0.75, 0.45 },
    MaterialsMissing   = { 1.00, 0.55, 0.20 },
    Accepted           = { 0.40, 0.80, 1.00 },
    DeliverySent       = { 0.40, 1.00, 0.60 },
    Completed          = { 0.40, 0.95, 0.40 },
    ReturnPending      = { 1.00, 0.60, 0.30 },
    Cancelled          = { 0.95, 0.40, 0.40 },
    Expired            = { 0.75, 0.60, 0.40 },
    Failed             = { 1.00, 0.30, 0.30 },
}

function Board:GetStatusColor(status)
    local row = STATUS_COLOURS[status]
    if row then return row[1], row[2], row[3] end
    return 0.70, 0.70, 0.70
end

-- Look up the WoW class colour for a guild member, via RR's public
-- Data:GetGuildMemberMeta accessor. Returns r, g, b or nil if the
-- player's class isn't known (offline newcomer, RR roster not yet
-- populated, missing global table in test harness).
function Board:GetClassColorForKey(playerKey)
    if type(playerKey) ~= "string" or playerKey == "" then return nil end
    local rr = getRR()
    if not (rr and rr.Data and type(rr.Data.GetGuildMemberMeta) == "function") then
        return nil
    end
    local ok, meta = pcall(rr.Data.GetGuildMemberMeta, rr.Data, playerKey)
    if not ok or type(meta) ~= "table" then return nil end
    local classFile = meta.classFile or meta.class
    if type(classFile) ~= "string" or classFile == "" then return nil end
    local classColors = _G.RAID_CLASS_COLORS or _G.CUSTOM_CLASS_COLORS
    local color = classColors and classColors[classFile]
    if not color then return nil end
    return color.r, color.g, color.b
end

local function rgbToHexCode(r, g, b)
    return string.format("|cff%02x%02x%02x",
        math.floor(math.max(0, math.min(1, r or 1)) * 255),
        math.floor(math.max(0, math.min(1, g or 1)) * 255),
        math.floor(math.max(0, math.min(1, b or 1)) * 255))
end

function Board:ColorizeByClass(playerKey, displayText)
    displayText = displayText or playerKey
    if type(displayText) ~= "string" or displayText == "" then return "?" end
    local r, g, b = self:GetClassColorForKey(playerKey)
    if not r then return displayText end
    return rgbToHexCode(r, g, b) .. displayText .. "|r"
end

local function qualityColorCode(quality)
    if type(quality) ~= "number" then return nil end
    local qc = _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[quality]
    if not qc then return nil end
    if qc.hex then return qc.hex end
    return rgbToHexCode(qc.r, qc.g, qc.b)
end

function Board:ColorizeByQuality(quality, displayText)
    if type(displayText) ~= "string" or displayText == "" then return "?" end
    local code = qualityColorCode(quality)
    if not code then return displayText end
    return code .. displayText .. "|r"
end

function Board:ColorizeByStatus(status, displayText)
    displayText = displayText or status
    if type(displayText) ~= "string" or displayText == "" then return "?" end
    local r, g, b = self:GetStatusColor(status)
    return rgbToHexCode(r, g, b) .. displayText .. "|r"
end

-- Provider tags are coloured so they're recognisable even on a row
-- where the material name is common-quality (default white). Pale
-- green = requester ships it, gold = crafter supplies it, split = both.
-- No "missing" colour yet — that's a Phase 7 concern.
local PROVIDER_REQ_COLOR = "|cff90d090"
local PROVIDER_CRA_COLOR = "|cffffd100"
local QTY_COLOR          = "|cffaaccff"

local function formatProviderTag(req, cra)
    req = req or 0
    cra = cra or 0
    if req > 0 and cra > 0 then
        return string.format("%srequester %d|r / %scrafter %d|r",
            PROVIDER_REQ_COLOR, req, PROVIDER_CRA_COLOR, cra)
    elseif cra > 0 then
        return PROVIDER_CRA_COLOR .. "crafter|r"
    else
        return PROVIDER_REQ_COLOR .. "requester|r"
    end
end

local function formatQuantity(count)
    return string.format("%sx%d|r", QTY_COLOR, count or 0)
end

-- Inline item-icon escape using WoW's |T...|t syntax. Empty string when
-- no texture path is available so the caller can just concatenate. The
-- 64:64:4:60:4:60 crop strips the standard item-border so the inline
-- icon aligns visually with the text — the exact format RR core uses
-- in UI/MainFrame.lua for the same purpose.
local ICON_SIZE = 16

local function iconCode(texturePath)
    if type(texturePath) ~= "string" or texturePath == "" then return "" end
    return string.format("|T%s:%d:%d:0:0:64:64:4:60:4:60|t ",
        texturePath, ICON_SIZE, ICON_SIZE)
end

-- Live icon lookup. The planner caches reagent.icon at the time the
-- order is created; if WoW hadn't yet resolved the item then, the path
-- is nil in storage forever. Re-querying GetItemInfo at render time
-- picks up the icon as soon as the client caches it.
local function liveItemIcon(itemID, fallback)
    if type(fallback) == "string" and fallback ~= "" then return fallback end
    if type(itemID) ~= "number" then return nil end
    if type(_G.GetItemInfo) ~= "function" then return nil end
    local _, _, _, _, _, _, _, _, _, icon = _G.GetItemInfo(itemID)
    return icon
end

-- Section headers (Order, Lines, Materials) get a gold tint so the
-- eye lands on them when scanning the panel. Field labels (Status:,
-- Requester:, etc.) get a muted grey so labels read as "structure"
-- and values stand out with their semantic colour.
local SECTION_HEADER_COLOR = "|cffffd200"
local FIELD_LABEL_COLOR    = "|cff999999"

local INDENT_FIELD   = "  "
local INDENT_CONTENT = "  "

local function sectionHeader(text)
    return SECTION_HEADER_COLOR .. text .. "|r"
end

local function fieldLabel(text)
    return FIELD_LABEL_COLOR .. text .. "|r"
end

-- Data-side: a flat, presentation-ready list of orders for the board.
-- Sorted newest-first by updatedAt (falls back to createdAt). Each row
-- has the minimum fields the UI binds to.
local TERMINAL_STATES = {
    Completed = true,
    Cancelled = true,
    Expired   = true,
    Failed    = true,
}

local FILTER_CYCLE  = { "all", "active", "done" }
local FILTER_LABELS = {
    all    = "Filter: All",
    active = "Filter: Active",
    done   = "Filter: Done",
}

function Board:GetFilter()
    return self.filter or "all"
end

function Board:SetFilter(value)
    if not FILTER_LABELS[value] then return false, "unknown-filter" end
    if self.filter == value then return true end
    self.filter = value
    self.selectedOrderId = nil
    if self.panel and self.panel.filterButton and self.panel.filterButton.text then
        self.panel.filterButton.text:SetText(FILTER_LABELS[value])
    end
    self:Refresh()
    return true
end

function Board:CycleFilter()
    local current = self:GetFilter()
    local nextIdx = 1
    for index, value in ipairs(FILTER_CYCLE) do
        if value == current then
            nextIdx = (index % #FILTER_CYCLE) + 1
            break
        end
    end
    self:SetFilter(FILTER_CYCLE[nextIdx])
    return self:GetFilter()
end

local function passesBucket(bucket, status)
    if bucket == "active" then
        return not TERMINAL_STATES[status]
    elseif bucket == "done" then
        return TERMINAL_STATES[status] == true
    end
    return true
end

function Board:BuildRowList(filters)
    filters = filters or {}
    local store = Addon.Store
    if not store then return {} end

    -- Pass status through to the store (used by tests for narrow queries)
    -- but apply the board-level bucket filter ("all"/"active"/"done")
    -- here so it composes with anything else.
    local storeFilters = {}
    if filters.status then storeFilters.status = filters.status end
    if filters.requester then storeFilters.requester = filters.requester end
    if filters.crafter then storeFilters.crafter = filters.crafter end

    local bucket = filters.bucket or self.filter or "all"

    local orders = store:ListOrders(storeFilters)
    local rows = {}
    for index = 1, #orders do
        local order = orders[index]
        if passesBucket(bucket, order.status) then
            local firstLine = order.lines and order.lines[1] or nil
            local info = firstLine and getRecipeDisplayInfo(firstLine.recipeKey) or nil
            rows[#rows + 1] = {
                id              = order.id,
                displayId       = shortenOrderId(order.id),
                status          = order.status or "?",
                requester       = order.requester or "",
                crafter         = order.crafter or "",
                requesterShort  = formatPlayerKey(order.requester),
                crafterShort    = formatPlayerKey(order.crafter),
                firstLineLabel  = self:FormatFirstLineLabel(order),
                firstLineQuality = info and info.createdItemQuality or nil,
                lineCount       = #(order.lines or {}),
                updatedAt       = order.updatedAt or order.createdAt or 0,
            }
        end
    end
    -- ListOrders already sorts by createdAt desc; resort here by updatedAt
    -- so newly-mutated orders bubble to the top of the board.
    table.sort(rows, function(a, b)
        if a.updatedAt ~= b.updatedAt then
            return a.updatedAt > b.updatedAt
        end
        return a.id < b.id
    end)
    return rows
end

function Board:FormatFirstLineLabel(order)
    local lines = order and order.lines or nil
    if not lines or #lines == 0 then return "(empty)" end
    local first = lines[1]
    local label = first.recipeLabel or ("recipe:" .. tostring(first.recipeKey or "?"))
    local extra = (#lines > 1) and (" (+" .. (#lines - 1) .. " more)") or ""
    return string.format("%s x%d%s", label, first.quantity or 0, extra)
end

-- Detail-side: a string-only view of one order, for the right-hand
-- detail panel. Kept stable so future UI tweaks can reformat without
-- changing the test contract. Embeds WoW-style colour escape codes
-- (|cffXXXXXX...|r) inline for class-coloured player names, quality-
-- coloured material names, and the provider tag.
function Board:FormatDetailLines(order)
    if not order then return { "No order selected." } end
    local lines = {}

    -- Order header: gold "Order" tag + the raw id. Treated as a section
    -- header so it visually matches the Lines / Materials blocks below.
    lines[#lines + 1] = string.format("%s %s", sectionHeader("Order"), tostring(order.id))

    -- Metadata block: indented, grey labels, semantic-coloured values.
    lines[#lines + 1] = string.format("%s%s %s",
        INDENT_FIELD, fieldLabel("Status:"),
        self:ColorizeByStatus(order.status, tostring(order.status)))
    lines[#lines + 1] = string.format("%s%s %s",
        INDENT_FIELD, fieldLabel("Requester:"),
        self:ColorizeByClass(order.requester, formatPlayerKey(order.requester)))
    lines[#lines + 1] = string.format("%s%s %s",
        INDENT_FIELD, fieldLabel("Crafter:"),
        self:ColorizeByClass(order.crafter, formatPlayerKey(order.crafter)))
    lines[#lines + 1] = string.format("%s%s %s",
        INDENT_FIELD, fieldLabel("Delivery:"), tostring(order.deliveryMode))

    if order.lines and #order.lines > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = sectionHeader("Lines:")
        for index = 1, #order.lines do
            local line = order.lines[index]
            local info = getRecipeDisplayInfo(line.recipeKey)
            local quality = info and info.createdItemQuality
            local icon = liveItemIcon(
                line.outputItemID or (info and info.createdItemID),
                info and (info.createdItemIcon or info.icon)
            )
            local label = tostring(line.recipeLabel or ("recipe:" .. tostring(line.recipeKey)))
            lines[#lines + 1] = string.format(
                "%s#%d  %s%s %s",
                INDENT_CONTENT,
                index,
                iconCode(icon),
                self:ColorizeByQuality(quality, label),
                formatQuantity(line.quantity)
            )
        end
    end

    local materials = order.materials or {}
    local materialList = {}
    for _, bucket in pairs(materials) do
        materialList[#materialList + 1] = bucket
    end
    table.sort(materialList, function(a, b)
        local an = (a.name or ""):lower()
        local bn = (b.name or ""):lower()
        if an ~= bn then return an < bn end
        return (a.itemID or 0) < (b.itemID or 0)
    end)
    if #materialList > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = sectionHeader(string.format("Materials (%d distinct):", #materialList))
        for index = 1, #materialList do
            local m = materialList[index]
            local icon = liveItemIcon(m.itemID, m.icon)
            local namePart = self:ColorizeByQuality(m.quality, tostring(m.name or "?"))
            lines[#lines + 1] = string.format(
                "%s%s%s %s   %s",
                INDENT_CONTENT,
                iconCode(icon),
                namePart,
                formatQuantity(m.required),
                formatProviderTag(m.requesterProvided, m.crafterProvided)
            )
        end
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = sectionHeader("Materials:") .. " none computed"
    end

    return lines
end

-- Selection state. Plain table mutation so tests can drive it without
-- needing the panel frame to exist.
function Board:SetSelectedOrder(id)
    self.selectedOrderId = id
end

function Board:GetSelectedOrder()
    if not self.selectedOrderId then return nil end
    local store = Addon.Store
    if not store then return nil end
    return store:GetOrder(self.selectedOrderId)
end

-- Registers the board's tab on the host UI. Safe to call multiple times
-- (the host registry is idempotent). Returns true on success, or nil +
-- a short reason if RR's UI hook isn't present.
function Board:RegisterTab()
    local rr = getRR()
    if not rr then return nil, "rr-missing" end
    if not (rr.UI and type(rr.UI.RegisterExternalTab) == "function") then
        return nil, "hook-missing"
    end
    local ok, err = rr.UI:RegisterExternalTab({
        id    = "orders",
        label = "Craft Orders",
        build = function(panel)
            Board:Build(panel)
        end,
        onSelect = function(panel)
            Board:OnSelect(panel)
        end,
        onDeselect = function(panel)
            Board:OnDeselect(panel)
        end,
    })
    if not ok then return nil, err end
    self.tabRegistered = true
    self:_WireAutoRefresh()
    return true
end

-- Coalesces multiple refresh requests fired within REFRESH_DEBOUNCE
-- seconds into a single Refresh. GUILD_ROSTER_UPDATE in particular
-- can fire many times back-to-back as the roster paginates in; we
-- only need to re-render once at the end.
local REFRESH_DEBOUNCE = 0.3

function Board:_ScheduleRefresh()
    if self._refreshTimer then return end
    if type(Addon.ScheduleTimer) ~= "function" then
        -- No timer support (test harness lite mode); refresh immediately
        -- so behaviour is observable but skip the coalescing.
        self:Refresh()
        return
    end
    self._refreshTimer = Addon:ScheduleTimer(function()
        Board._refreshTimer = nil
        Board:Refresh()
    end, REFRESH_DEBOUNCE)
end

-- Subscribe to the store's "something changed" message so the board
-- re-renders on creation, mutation, transition, and deletion without
-- needing a /reload or a tab toggle. Also listen to GUILD_ROSTER_UPDATE
-- because class colour lookup depends on RR's roster cache, which
-- populates lazily after login (so the first paint can come up without
-- colour info). Both are idempotent — registered once per session.
function Board:_WireAutoRefresh()
    if self._autoRefreshWired then return end
    if type(Addon.RegisterMessage) == "function" then
        Addon:RegisterMessage("CraftOrders:Changed", function()
            Board:_ScheduleRefresh()
        end)
    end
    if type(Addon.RegisterEvent) == "function" then
        Addon:RegisterEvent("GUILD_ROSTER_UPDATE", function()
            Board:_ScheduleRefresh()
        end)
        -- Item info trickles in async after first reference; re-render
        -- so icons appear without needing a manual tab toggle.
        Addon:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
            Board:_ScheduleRefresh()
        end)
    end
    self._autoRefreshWired = true
end

-- UI construction. Called by the host once with the panel frame; the
-- panel is anchored full-width inside RR's main frame. The host shows
-- and hides this panel based on tab selection. Heavily guarded so that
-- when run under the test harness (no CreateFrame) the function exits
-- cleanly without producing partial state.
function Board:Build(panel)
    if not panel then return end
    if self.panelBuilt then return end
    self.panel = panel
    if not CreateFrame then return end

    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    header:SetPoint("TOPLEFT", 14, -10)
    header:SetText("Craft Orders")
    panel.header = header

    local subheader = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subheader:SetPoint("TOPLEFT", 14, -30)
    subheader:SetPoint("TOPRIGHT", -14, -30)
    subheader:SetJustifyH("LEFT")
    subheader:SetText("Local-only view; sync ships in a later phase.")
    panel.subheader = subheader

    local listFrame = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    listFrame:SetPoint("TOPLEFT", 14, -52)
    listFrame:SetPoint("BOTTOMLEFT", 14, 14)
    listFrame:SetWidth(440)
    applyPanelBackdrop(listFrame)
    panel.listFrame = listFrame

    local listHeader = listFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    listHeader:SetPoint("TOPLEFT", 10, -8)
    listHeader:SetText("Orders")
    panel.listHeader = listHeader

    local filterButton = CreateFrame("Button", nil, listFrame, "BackdropTemplate")
    filterButton:SetSize(110, 18)
    filterButton:SetPoint("TOPRIGHT", -8, -6)
    filterButton:SetBackdrop(PANEL_BACKDROP)
    filterButton:SetBackdropColor(0.12, 0.12, 0.12, 1)
    filterButton:SetBackdropBorderColor(0.30, 0.30, 0.30, 0.85)
    filterButton.text = filterButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    filterButton.text:SetPoint("CENTER")
    filterButton.text:SetText(FILTER_LABELS[self:GetFilter()])
    filterButton:SetScript("OnEnter", function(widget)
        widget:SetBackdropBorderColor(0.65, 0.55, 0.20, 0.95)
    end)
    filterButton:SetScript("OnLeave", function(widget)
        widget:SetBackdropBorderColor(0.30, 0.30, 0.30, 0.85)
    end)
    filterButton:SetScript("OnClick", function()
        Board:CycleFilter()
    end)
    panel.filterButton = filterButton

    local emptyHint = listFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyHint:SetPoint("TOPLEFT", 10, -28)
    emptyHint:SetPoint("TOPRIGHT", -10, -28)
    emptyHint:SetJustifyH("LEFT")
    emptyHint:SetText("No orders yet. /rrord new <recipeKey> <qty> <Char-Realm> to create one.")
    panel.emptyHint = emptyHint

    local scroll = CreateFrame("ScrollFrame", nil, listFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -28)
    scroll:SetPoint("BOTTOMRIGHT", -28, 8)
    panel.scroll = scroll

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(400, 1)
    scroll:SetScrollChild(scrollChild)
    panel.scrollChild = scrollChild

    self.rows = self.rows or {}

    local detailFrame = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    detailFrame:SetPoint("TOPLEFT", listFrame, "TOPRIGHT", 10, 0)
    detailFrame:SetPoint("BOTTOMRIGHT", -14, 14)
    applyPanelBackdrop(detailFrame)
    panel.detailFrame = detailFrame

    local detailText = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    detailText:SetPoint("TOPLEFT", 12, -12)
    detailText:SetPoint("BOTTOMRIGHT", -12, 12)
    detailText:SetJustifyH("LEFT")
    detailText:SetJustifyV("TOP")
    if detailText.SetSpacing then detailText:SetSpacing(3) end
    panel.detailText = detailText

    self.panelBuilt = true
    self:Refresh()
end

function Board:OnSelect(panel)
    self.panel = panel or self.panel
    self:Refresh()
end

function Board:OnDeselect()
    -- No teardown needed yet: the panel stays in memory and is reused
    -- on the next selection. If/when the board grows expensive (e.g.
    -- live sync subscriptions) this is the place to pause them.
end

local ROW_HEIGHT  = 22
local ROW_SPACING = 2
local ROW_PADDING = 6
local COL_ID_W    = 80
local COL_STATUS_W = 100
local COL_REQ_W   = 60

local function makeColumn(parent, width, anchorLeft)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", anchorLeft or parent, anchorLeft and "RIGHT" or "LEFT", ROW_PADDING, 0)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    if fs.SetMaxLines then fs:SetMaxLines(1) end
    return fs
end

function Board:_AcquireRow(index)
    self.rows = self.rows or {}
    local row = self.rows[index]
    if row then return row end
    if not (self.panel and self.panel.scrollChild and CreateFrame) then return nil end

    row = CreateFrame("Button", nil, self.panel.scrollChild, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", 0, 0)
    row:SetPoint("RIGHT", 0, 0)
    applyRowBackdrop(row, false)

    row.idText      = makeColumn(row, COL_ID_W,    nil)
    row.statusText  = makeColumn(row, COL_STATUS_W, row.idText)
    row.reqText     = makeColumn(row, COL_REQ_W,   row.statusText)
    row.labelText   = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.labelText:SetPoint("LEFT", row.reqText, "RIGHT", ROW_PADDING, 0)
    row.labelText:SetPoint("RIGHT", row, "RIGHT", -ROW_PADDING, 0)
    row.labelText:SetJustifyH("LEFT")
    if row.labelText.SetWordWrap then row.labelText:SetWordWrap(false) end
    if row.labelText.SetMaxLines then row.labelText:SetMaxLines(1) end

    row:SetScript("OnEnter", function(widget)
        if Board.selectedOrderId == widget.boundId then return end
        widget:SetBackdropBorderColor(0.55, 0.55, 0.55, 0.95)
    end)
    row:SetScript("OnLeave", function(widget)
        applyRowBackdrop(widget, Board.selectedOrderId == widget.boundId)
    end)
    row:SetScript("OnClick", function(widget)
        Board:OnRowClicked(widget.boundId)
    end)

    self.rows[index] = row
    return row
end

function Board:_BindRow(row, rowData, index)
    row.boundId = rowData.id
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT",  0, -((index - 1) * (ROW_HEIGHT + ROW_SPACING)))
    row:SetPoint("TOPRIGHT", 0, -((index - 1) * (ROW_HEIGHT + ROW_SPACING)))

    row.idText:SetText(rowData.displayId or "?")

    row.statusText:SetText(rowData.status or "?")
    row.statusText:SetTextColor(Board:GetStatusColor(rowData.status))

    row.reqText:SetText(rowData.requesterShort or "?")
    local rr, rg, rb = Board:GetClassColorForKey(rowData.requester)
    if rr then
        row.reqText:SetTextColor(rr, rg, rb)
    else
        row.reqText:SetTextColor(0.94, 0.92, 0.88)
    end

    -- Quality colour applied via inline escape so the label keeps its
    -- default font appearance when no quality is known.
    row.labelText:SetText(Board:ColorizeByQuality(rowData.firstLineQuality, rowData.firstLineLabel or ""))

    applyRowBackdrop(row, Board.selectedOrderId == rowData.id)
    row:Show()
end

function Board:OnRowClicked(id)
    self:SetSelectedOrder(id)
    self:Refresh()
end

function Board:Refresh()
    if not self.panelBuilt or not self.panel then return end

    local panel = self.panel
    local rows = self:BuildRowList()

    if panel.subheader and panel.subheader.SetText then
        panel.subheader:SetText(string.format(
            "Local-only view; sync ships in a later phase. %d order(s).",
            #rows
        ))
    end

    -- Show the empty-hint only when the list is empty; the scroll frame
    -- otherwise overlays it.
    if panel.emptyHint and panel.emptyHint.SetShown then
        panel.emptyHint:SetShown(#rows == 0)
    end

    -- Drop selection if the previously-selected order has disappeared.
    if self.selectedOrderId then
        local stillThere = false
        for index = 1, #rows do
            if rows[index].id == self.selectedOrderId then
                stillThere = true
                break
            end
        end
        if not stillThere then
            self.selectedOrderId = nil
        end
    end

    -- Auto-select the first row if nothing is selected and there is
    -- something to show. Keeps the detail panel populated by default.
    if not self.selectedOrderId and #rows > 0 then
        self.selectedOrderId = rows[1].id
    end

    self.rows = self.rows or {}
    for index = 1, #rows do
        local row = self:_AcquireRow(index)
        if row then
            self:_BindRow(row, rows[index], index)
        end
    end
    for index = #rows + 1, #self.rows do
        local row = self.rows[index]
        if row and row.Hide then row:Hide() end
    end

    if panel.scrollChild and panel.scrollChild.SetHeight then
        local contentHeight = math.max(1, #rows * (ROW_HEIGHT + ROW_SPACING))
        panel.scrollChild:SetHeight(contentHeight)
    end

    if panel.detailText and panel.detailText.SetText then
        local order = self:GetSelectedOrder()
        local lines = self:FormatDetailLines(order)
        panel.detailText:SetText(table.concat(lines, "\n"))
    end
end
