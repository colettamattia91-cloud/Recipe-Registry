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

-- Scope axis is orthogonal to the status filter above and lets a user
-- narrow the board to "only orders I requested" or "only orders I need
-- to craft" without losing the active/done bucket.
local SCOPE_CYCLE  = { "all", "requester", "crafter" }
local SCOPE_LABELS = {
    all       = "Scope: Everyone",
    requester = "Scope: I requested",
    crafter   = "Scope: I craft",
}

-- User-facing labels for each state-machine target state. Keeps the
-- button text short and verb-led ("Mark received") instead of echoing
-- the raw enum value ("MaterialsReceived"). Any transition target not
-- in this table falls back to the raw state name.
local TRANSITION_LABELS = {
    MaterialsPartial  = "Materials partial",
    MaterialsSent     = "Mark materials sent",
    MaterialsReceived = "Mark received",
    MaterialsMissing  = "Mark missing",
    Accepted          = "Accept",
    DeliverySent      = "Mark delivery sent",
    Completed         = "Mark completed",
    ReturnPending     = "Request return",
    Cancelled         = "Cancel",
}

-- Transitions that should render with the destructive (red) ask-style
-- variant. The cancel/return path is the only one where the user is
-- closing an order against the happy path, so it visually stands apart.
local DESTRUCTIVE_TRANSITIONS = {
    Cancelled     = true,
    ReturnPending = true,
}

-- Target states that are now driven automatically by the mail flow
-- (MAIL_SEND_SUCCESS -> Mailbox:AutoAdvanceMaterialsState). The action
-- strip used to expose these as manual buttons but that was confusing:
-- the user had to click "Mark materials sent" *after* already clicking
-- Send in the in-game mail UI. Hidden here so the strip only surfaces
-- transitions the user actually drives themselves.
local SYSTEM_MANAGED_TRANSITIONS = {
    MaterialsPartial = true,
    MaterialsSent    = true,
}

-- Order states where offering the requester a "Compose mail" action
-- still makes sense. Once we're past MaterialsSent the materials
-- have either arrived or the crafter has taken over the conversation,
-- so cluttering the strip with a Compose button would be misleading.
local COMPOSER_ELIGIBLE_STATES = {
    Draft             = true,
    MaterialsPartial  = true,
    MaterialsSent     = true,  -- still relevant for sending a follow-up batch
}

-- Order states where the crafter can ship the finished outputs back
-- to the requester via a delivery mail. Accepted is when the crafter
-- has confirmed they'll fulfill; DeliverySent is included so a
-- multi-batch delivery can be continued after the first mail.
local DELIVERY_COMPOSER_ELIGIBLE_STATES = {
    Accepted     = true,
    DeliverySent = true,
}

-- Layout constants for the detail-panel action strip.
local ACTION_STRIP_HEIGHT = 28
local ACTION_BUTTON_HEIGHT = 22
local ACTION_BUTTON_SPACING = 6
local ACTION_BUTTON_MIN_WIDTH = 90

-- Mirrors UI/CraftOrdersCartPanel.lua's "Ask"-style button so the board's
-- action strip reads as part of the same visual family. Kept local to
-- the board file: the cart and the board are the only two callers and a
-- shared helper file is more weight than the duplication is worth.
local function buildActionButton(parent, width, height, label, tone)
    if not CreateFrame then return nil end
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width, height)
    button:SetBackdrop(PANEL_BACKDROP)

    local labelR, labelG, labelB = 1.0, 0.92, 0.75
    local borderR, borderG, borderB, borderA = 1, 0.82, 0, 0.75
    local hoverR, hoverG, hoverB, hoverA = 1, 0.82, 0, 0.18
    local bgR, bgG, bgB, bgA = 0.13, 0.11, 0.08, 0.95
    if tone == "red" then
        labelR, labelG, labelB = 1.0, 0.30, 0.30
        borderR, borderG, borderB, borderA = 1.0, 0.25, 0.25, 0.95
        hoverR, hoverG, hoverB, hoverA = 1.0, 0.20, 0.20, 0.28
        bgR, bgG, bgB, bgA = 0.13, 0.08, 0.08, 0.95
    end

    button:SetBackdropColor(bgR, bgG, bgB, bgA)
    button:SetBackdropBorderColor(borderR, borderG, borderB, borderA)

    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.label:SetPoint("LEFT", 2, 0)
    button.label:SetPoint("RIGHT", -2, 0)
    button.label:SetJustifyH("CENTER")
    button.label:SetText(label or "")
    button.label:SetTextColor(labelR, labelG, labelB)

    button:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    local hi = button:GetHighlightTexture()
    if hi and hi.SetVertexColor then hi:SetVertexColor(hoverR, hoverG, hoverB, hoverA) end
    return button
end

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

function Board:GetScope()
    return self.scope or "all"
end

function Board:SetScope(value)
    if not SCOPE_LABELS[value] then return false, "unknown-scope" end
    if self.scope == value then return true end
    self.scope = value
    self.selectedOrderId = nil
    if self.panel and self.panel.scopeButton and self.panel.scopeButton.text then
        self.panel.scopeButton.text:SetText(SCOPE_LABELS[value])
    end
    self:Refresh()
    return true
end

function Board:CycleScope()
    local current = self:GetScope()
    local nextIdx = 1
    for index, value in ipairs(SCOPE_CYCLE) do
        if value == current then
            nextIdx = (index % #SCOPE_CYCLE) + 1
            break
        end
    end
    self:SetScope(SCOPE_CYCLE[nextIdx])
    return self:GetScope()
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

    -- Scope axis: resolve to a concrete requester/crafter key using the
    -- local player. Explicit filters.requester/filters.crafter passed by
    -- a caller always win — they're how tests pin queries to a known
    -- player without juggling the WoW mock's identity.
    local scope = filters.scope or self.scope or "all"
    if scope ~= "all" and not (storeFilters.requester or storeFilters.crafter) then
        local me
        if type(Addon.GetLocalPlayerKey) == "function" then
            local ok, key = pcall(Addon.GetLocalPlayerKey, Addon)
            if ok and type(key) == "string" and key ~= "" then me = key end
        end
        if me then
            if scope == "requester" then
                storeFilters.requester = me
            elseif scope == "crafter" then
                storeFilters.crafter = me
            end
        end
    end

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
-- Renders the materials-shipment progress as a single indented field
-- line ("Shipments: 2 of 3 batches sent") when at least one batch has
-- been sent. Returns nil when nothing has shipped yet so the detail
-- panel stays compact on fresh Draft orders. Total comes from a fresh
-- PlanBatches call; sent count is anything in order.batches[n] with a
-- sentAt stamp (a marker that RecordBatchSent writes on
-- MAIL_SEND_SUCCESS).
function Board:FormatShipmentProgressLine(order)
    if type(order) ~= "table" or type(order.batches) ~= "table" then return nil end

    local sentCount = 0
    for _, slot in pairs(order.batches) do
        if slot and slot.sentAt then sentCount = sentCount + 1 end
    end
    if sentCount == 0 then return nil end

    local totalLabel = "?"
    local assistant = Addon.MailAssistant
    if assistant and type(assistant.PlanBatches) == "function" then
        local batches = assistant:PlanBatches(order)
        if #batches > 0 then totalLabel = tostring(#batches) end
    end

    return string.format("%s%s %d of %s batch(es) sent",
        INDENT_FIELD, fieldLabel("Shipments:"), sentCount, totalLabel)
end

-- Walks the order's ledger and returns warning lines for every batch
-- slot that carries tamperFlags. Empty when the order has no ledger
-- entries or all entries are clean. Each flag is grouped by batch and
-- rendered in red so the warning is visually distinct from the rest
-- of the detail body. The block is pure-string; the renderer SetText
-- handles colour escapes via |cffrrggbb...|r the same way other
-- sections do.
function Board:FormatTamperWarning(order)
    if type(order) ~= "table" or type(order.batches) ~= "table" then return {} end

    -- Collect dirty slots in ascending batch order so the output is
    -- stable across refreshes.
    local dirtyBatches = {}
    for batchNumber, slot in pairs(order.batches) do
        if type(slot) == "table"
            and type(slot.tamperFlags) == "table"
            and #slot.tamperFlags > 0 then
            dirtyBatches[#dirtyBatches + 1] = batchNumber
        end
    end
    if #dirtyBatches == 0 then return {} end
    table.sort(dirtyBatches)

    local out = {}
    out[#out + 1] = ""
    out[#out + 1] = "|cffff5050[!] Tamper detected on this order|r"
    for index = 1, #dirtyBatches do
        local batchNumber = dirtyBatches[index]
        local slot = order.batches[batchNumber]
        out[#out + 1] = string.format(
            "%s|cffff5050batch %d:|r %s",
            INDENT_CONTENT,
            batchNumber,
            table.concat(slot.tamperFlags, ", ")
        )
        if slot.sender then
            out[#out + 1] = string.format(
                "%s%ssender: %s",
                INDENT_CONTENT, INDENT_FIELD,
                tostring(slot.sender)
            )
        end
    end
    return out
end

function Board:FormatDetailLines(order)
    if not order then return { "No order selected." } end
    local lines = {}

    -- Order header: gold "Order" tag + the raw id. Treated as a section
    -- header so it visually matches the Lines / Materials blocks below.
    lines[#lines + 1] = string.format("%s %s", sectionHeader("Order"), tostring(order.id))

    -- Tamper warning band: when any batch ledger entry carries
    -- tamperFlags, surface them at the top of the detail panel so the
    -- crafter sees the problem before deciding how to respond. The
    -- block lists the offending batch + the flag names; the user
    -- inspects /rrord events for the full payload.
    local tamperLines = self:FormatTamperWarning(order)
    for tIndex = 1, #tamperLines do
        lines[#lines + 1] = tamperLines[tIndex]
    end

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

    local shipmentLine = self:FormatShipmentProgressLine(order)
    if shipmentLine then
        lines[#lines + 1] = shipmentLine
    end

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

    local eventLines = self:FormatRecentEventLines(order, 5)
    if #eventLines > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = sectionHeader("Recent events:")
        for index = 1, #eventLines do
            lines[#lines + 1] = eventLines[index]
        end
    end

    return lines
end

-- Renders a single event log entry as a one-line summary. Kept as a
-- pure function (no self) so the spec can drive it with synthetic
-- payloads. The summary leads with the verb ("state Draft -> ...",
-- "line +Major Healing Potion") so a scanning reader sees the action
-- before the actor / seq metadata. Unknown kinds fall back to the raw
-- kind string rather than dropping the entry — visibility over
-- prettiness when something unexpected lands in the log.
local function summarizeEvent(event)
    if type(event) ~= "table" then return nil end
    local payload = event.payload or {}
    if event.kind == "OrderCreated" then
        local lineCount = tonumber(payload.lineCount) or 0
        return string.format("created (%d line%s)", lineCount, lineCount == 1 and "" or "s")
    end
    if event.kind == "OrderUpdated" then
        if payload.change == "state-transition" then
            return string.format("%s -> %s",
                tostring(payload.fromState or "?"),
                tostring(payload.toState or "?"))
        end
        if payload.change == "line-added" then
            local label = payload.recipeLabel or ("recipe:" .. tostring(payload.recipeKey or "?"))
            return string.format("line + %s x%s",
                tostring(label),
                tostring(payload.quantity or "?"))
        end
        if payload.change == "line-removed" then
            return string.format("line -#%s", tostring(payload.lineIndex or "?"))
        end
        if payload.change == "provider-set" then
            return string.format("provider item:%s = %s (qty %s)",
                tostring(payload.itemID or "?"),
                tostring(payload.provider or "?"),
                tostring(payload.quantity or "?"))
        end
        return tostring(payload.change or "updated")
    end
    if event.kind == "Pruned" then
        return "pruned"
    end
    return tostring(event.kind or "?")
end

-- Returns the most recent N events for the given order, formatted as
-- ready-to-render summary lines (indented with INDENT_CONTENT, with the
-- per-event seq and actor for traceability). Returns an empty table
-- when there's no order or no store. The Store's GetRecentEvents
-- returns a cross-order tail; we re-filter here so the section is
-- per-order rather than per-plugin.
function Board:FormatRecentEventLines(order, limit)
    if type(order) ~= "table" or type(order.id) ~= "string" then return {} end
    local store = Addon.Store
    if not store or type(store.GetRecentEvents) ~= "function" then return {} end

    limit = tonumber(limit) or 5
    -- Pull more than the display limit so we can filter out events from
    -- other orders before truncating. 4x is a coarse heuristic; we'll
    -- revisit if event volume grows enough to push relevant entries
    -- past this window.
    local recent = store:GetRecentEvents(limit * 4)
    local matching = {}
    for index = 1, #recent do
        local event = recent[index]
        if event and event.orderId == order.id then
            matching[#matching + 1] = event
        end
    end

    local start = math.max(1, #matching - limit + 1)
    local out = {}
    for index = start, #matching do
        local event = matching[index]
        local summary = summarizeEvent(event)
        if summary then
            out[#out + 1] = string.format("%s#%s  %s  by %s",
                INDENT_CONTENT,
                tostring(event.seq or "?"),
                summary,
                formatPlayerKey(event.actor or "?"))
        end
    end
    return out
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

-- Returns the state-machine actor role the local player has on the
-- given order: "requester", "crafter", or nil when the local player is
-- a third-party observer. System-only transitions (Expired,
-- MaterialsAssumed) are intentionally never offered through the UI —
-- those are driven by background timers, not user clicks.
local function resolveLocalPlayerKey()
    if type(Addon.GetLocalPlayerKey) ~= "function" then return nil end
    local ok, me = pcall(Addon.GetLocalPlayerKey, Addon)
    if not ok or type(me) ~= "string" or me == "" then return nil end
    return me
end

function Board:GetLocalActorForOrder(order, me)
    if type(order) ~= "table" then return nil end
    me = me or resolveLocalPlayerKey()
    if not me then return nil end
    if me == order.requester then return "requester" end
    if me == order.crafter   then return "crafter"   end
    return nil
end

-- Returns the ordered list of actionable transitions for the local
-- player on the given order:
--   { { toState = ..., label = ..., actor = ..., destructive = bool }, ... }
-- Empty when the order is nil, the local player has no role on it, or
-- the order is in a terminal state. The list is the source of truth
-- for both the renderer and the spec; the renderer never inspects
-- state-machine internals on its own.
function Board:ComputeActionsForOrder(order)
    local actor = self:GetLocalActorForOrder(order)
    if not actor then return {} end
    local SM = Addon.StateMachine
    if not SM or type(SM.GetValidTransitions) ~= "function" then return {} end
    local targets = SM:GetValidTransitions(order.status, actor)
    local out = {}
    for index = 1, #targets do
        local toState = targets[index]
        -- Skip materials phases the mail flow now drives automatically.
        -- Users still see the resulting state in the detail panel, but
        -- never need to click a button to advance into it.
        if not SYSTEM_MANAGED_TRANSITIONS[toState] then
            out[#out + 1] = {
                kind        = "transition",
                toState     = toState,
                label       = TRANSITION_LABELS[toState] or toState,
                actor       = actor,
                destructive = DESTRUCTIVE_TRANSITIONS[toState] == true,
            }
        end
    end

    -- "Compose mail" is a non-transition action: it doesn't drive
    -- the state machine, just stages the SendMail UI for the
    -- current outgoing batch. Surfaced for the requester on any
    -- pre-receipt state where shipping materials still makes
    -- sense; the production guard inside MailAssistant:OpenComposer
    -- catches edge cases (mailbox closed, nothing shippable).
    if actor == "requester" and COMPOSER_ELIGIBLE_STATES[order.status]
        and type(order.materials) == "table"
        and next(order.materials) ~= nil then
        out[#out + 1] = {
            kind  = "compose-mail",
            label = "Compose mail",
            actor = "requester",
        }
    end

    -- "Compose delivery" is the crafter-side equivalent: ship the
    -- finished outputs back to the requester. Eligible only on
    -- Accepted / DeliverySent so the strip doesn't bait the crafter
    -- into sending before they've taken the order.
    if actor == "crafter" and DELIVERY_COMPOSER_ELIGIBLE_STATES[order.status]
        and type(order.lines) == "table" and #order.lines > 0 then
        out[#out + 1] = {
            kind  = "compose-delivery",
            label = "Compose delivery",
            actor = "crafter",
        }
    end

    return out
end

-- Drives a single transition from the action strip. Routed through the
-- store so all the usual event-log and broadcast machinery fires, then
-- refreshes the board so the detail panel reflects the new state and
-- the new set of valid transitions. Returns true on success or
-- false + reason so the spec can drive it without a UI.
function Board:ApplyOrderAction(orderId, toState, actor)
    local store = Addon.Store
    if not store or type(store.Transition) ~= "function" then
        return false, "store-not-ready"
    end
    local ok, err = store:Transition(orderId, toState, actor)
    if not ok then return false, err end
    -- Refresh is a no-op when the panel isn't built (spec case).
    self:Refresh()
    return true
end

-- Dispatches a click on an action-strip entry to its handler. The
-- transition path stays on Store:Transition; compose-mail forwards to
-- MailAssistant:OpenComposer so the SendMail UI is pre-filled. Kept
-- as a separate method so the spec can exercise both branches without
-- a panel frame being built.
function Board:DispatchAction(orderId, entry)
    if type(entry) ~= "table" then return false, "invalid-entry" end
    if entry.kind == "compose-mail" or entry.kind == "compose-delivery" then
        local assistant = Addon.MailAssistant
        if not assistant then return false, "mail-assistant-missing" end
        local store = Addon.Store
        if not (store and type(store.GetOrder) == "function") then
            return false, "store-not-ready"
        end
        local order = store:GetOrder(orderId)
        if not order then return false, "unknown-order" end
        if entry.kind == "compose-delivery" then
            if type(assistant.OpenDeliveryComposer) ~= "function" then
                return false, "delivery-composer-missing"
            end
            return assistant:OpenDeliveryComposer(order)
        end
        if type(assistant.OpenComposer) ~= "function" then
            return false, "mail-assistant-missing"
        end
        return assistant:OpenComposer(order)
    end
    -- Default: state-machine transition.
    return self:ApplyOrderAction(orderId, entry.toState, entry.actor)
end

-- Counts the orders where the local player has at least one available
-- transition. Used both by the tab badge and by anyone wanting a
-- "needs your attention" measurement (e.g. future tooltip / minimap
-- decorations). Iterates every non-terminal order; that's fine because
-- the store typically holds tens of orders, not thousands.
function Board:CountActionRequired()
    local store = Addon.Store
    if not store or type(store.ListOrders) ~= "function" then return 0 end
    -- Resolve identity once so the per-order role check skips its own
    -- pcall + globals lookup. CraftOrders:Changed fires this on every
    -- store mutation, so the savings add up.
    local me = resolveLocalPlayerKey()
    if not me then return 0 end
    local orders = store:ListOrders()
    local count = 0
    for index = 1, #orders do
        local order = orders[index]
        local actor = self:GetLocalActorForOrder(order, me)
        if actor and #self:ComputeActionsForOrder(order) > 0 then
            count = count + 1
        end
    end
    return count
end

-- Builds the tab label that includes a (N) suffix when the local
-- player has action-required orders. Returns the bare base label when
-- the count is zero, so the tab reads plain ("Craft Orders") rather
-- than noisy ("Craft Orders (0)") in the common idle case.
local TAB_BASE_LABEL = "Craft Orders"
function Board:ComputeTabLabel()
    local count = self:CountActionRequired()
    if count <= 0 then return TAB_BASE_LABEL end
    return string.format("%s (%d)", TAB_BASE_LABEL, count)
end

-- Pushes the computed label to RR via the public API. No-ops when the
-- host hook isn't available so the plugin keeps working against older
-- RR builds. Returns true on success, nil + reason otherwise.
function Board:RefreshTabLabel()
    local rr = getRR()
    if not (rr and rr.UI and type(rr.UI.SetExternalTabLabel) == "function") then
        return nil, "hook-missing"
    end
    return rr.UI:SetExternalTabLabel("orders", self:ComputeTabLabel())
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
    -- Push an initial label so the badge reflects any orders that
    -- exist from a previous session even before the user interacts.
    self:RefreshTabLabel()
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
            -- Tab label refresh is cheap (one count + one comparison
            -- in the host) and runs without debounce so the badge
            -- updates instantly even from another tab. The panel
            -- itself debounces via _ScheduleRefresh.
            Board:RefreshTabLabel()
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

    -- Scope cycles independently of the status filter: a crafter can
    -- pin to "I craft" and still toggle between Active/Done.
    local scopeButton = CreateFrame("Button", nil, listFrame, "BackdropTemplate")
    scopeButton:SetSize(120, 18)
    scopeButton:SetPoint("RIGHT", filterButton, "LEFT", -6, 0)
    scopeButton:SetBackdrop(PANEL_BACKDROP)
    scopeButton:SetBackdropColor(0.12, 0.12, 0.12, 1)
    scopeButton:SetBackdropBorderColor(0.30, 0.30, 0.30, 0.85)
    scopeButton.text = scopeButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    scopeButton.text:SetPoint("CENTER")
    scopeButton.text:SetText(SCOPE_LABELS[self:GetScope()])
    scopeButton:SetScript("OnEnter", function(widget)
        widget:SetBackdropBorderColor(0.65, 0.55, 0.20, 0.95)
    end)
    scopeButton:SetScript("OnLeave", function(widget)
        widget:SetBackdropBorderColor(0.30, 0.30, 0.30, 0.85)
    end)
    scopeButton:SetScript("OnClick", function()
        Board:CycleScope()
    end)
    panel.scopeButton = scopeButton

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

    -- Action strip lives at the bottom of the detail panel and hosts
    -- buttons for each valid state transition the local actor can drive.
    -- We give it a fixed height up front so the detail text above can
    -- anchor to its top edge without re-layout.
    local actionStrip = CreateFrame("Frame", nil, detailFrame)
    actionStrip:SetHeight(ACTION_STRIP_HEIGHT)
    actionStrip:SetPoint("BOTTOMLEFT", 8, 8)
    actionStrip:SetPoint("BOTTOMRIGHT", -8, 8)
    panel.actionStrip = actionStrip

    local detailText = detailFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    detailText:SetPoint("TOPLEFT", 12, -12)
    detailText:SetPoint("BOTTOMRIGHT", actionStrip, "TOPRIGHT", 0, 4)
    detailText:SetJustifyH("LEFT")
    detailText:SetJustifyV("TOP")
    if detailText.SetSpacing then detailText:SetSpacing(3) end
    panel.detailText = detailText

    self.actionButtons = self.actionButtons or {}

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
        self:_RebindActionButtons(order)
    end
end

function Board:_AcquireActionButton(index)
    self.actionButtons = self.actionButtons or {}
    local button = self.actionButtons[index]
    if button then return button end
    if not (self.panel and self.panel.actionStrip and CreateFrame) then return nil end
    button = buildActionButton(self.panel.actionStrip, ACTION_BUTTON_MIN_WIDTH, ACTION_BUTTON_HEIGHT, "")
    if not button then return nil end
    button:SetScript("OnClick", function(widget)
        if not (widget._boundOrderId and widget._boundEntry) then return end
        Board:DispatchAction(widget._boundOrderId, widget._boundEntry)
    end)
    self.actionButtons[index] = button
    return button
end

-- Rebinds the action strip to the currently-selected order. Buttons are
-- pooled and re-styled in place rather than recreated, so toggling
-- between orders doesn't churn frames. Buttons beyond the current count
-- are hidden but kept around for the next refresh.
function Board:_RebindActionButtons(order)
    local actions = self:ComputeActionsForOrder(order)
    self.actionButtons = self.actionButtons or {}

    local anchor = self.panel.actionStrip
    if not anchor then return end

    local xOffset = 0
    for index = 1, #actions do
        local entry = actions[index]
        local button = self:_AcquireActionButton(index)
        if button then
            -- Width: glyph * approx-advance + padding, with a floor
            -- so short labels stay aligned with longer neighbours.
            local width = math.max(ACTION_BUTTON_MIN_WIDTH,
                #(entry.label or "") * 7 + 14)
            button:SetSize(width, ACTION_BUTTON_HEIGHT)
            -- Restyle in place: the same pooled button may toggle between
            -- the default and red variants as different orders are
            -- selected (e.g. Draft -> shows Cancel red; Accepted -> shows
            -- Mark delivery sent default).
            if entry.destructive then
                button:SetBackdropColor(0.13, 0.08, 0.08, 0.95)
                button:SetBackdropBorderColor(1.0, 0.25, 0.25, 0.95)
                button.label:SetTextColor(1.0, 0.30, 0.30)
                local hi = button:GetHighlightTexture()
                if hi and hi.SetVertexColor then hi:SetVertexColor(1.0, 0.20, 0.20, 0.28) end
            else
                button:SetBackdropColor(0.13, 0.11, 0.08, 0.95)
                button:SetBackdropBorderColor(1, 0.82, 0, 0.75)
                button.label:SetTextColor(1.0, 0.92, 0.75)
                local hi = button:GetHighlightTexture()
                if hi and hi.SetVertexColor then hi:SetVertexColor(1, 0.82, 0, 0.18) end
            end
            button.label:SetText(entry.label)
            button._boundOrderId = order and order.id or nil
            button._boundEntry   = entry

            button:ClearAllPoints()
            button:SetPoint("LEFT", anchor, "LEFT", xOffset, 0)
            button:Show()
            xOffset = xOffset + width + ACTION_BUTTON_SPACING
        end
    end

    for index = #actions + 1, #self.actionButtons do
        local extra = self.actionButtons[index]
        if extra and extra.Hide then extra:Hide() end
    end
end
