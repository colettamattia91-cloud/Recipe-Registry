local Addon = _G.RecipeRegistry
local UI = Addon:NewModule("UI")
Addon.UI = UI

local SEARCH_DEBOUNCE = 0.15

local PROF_ORDER = {
    "All", "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering",
    "Herbalism", "Jewelcrafting", "Leatherworking", "Mining", "Skinning", "Tailoring"
}

local PROFESSION_SPELL_IDS = {
    ["Alchemy"] = 2259,
    ["Blacksmithing"] = 2018,
    ["Cooking"] = 2550,
    ["Enchanting"] = 7411,
    ["Engineering"] = 4036,
    ["Herbalism"] = 2366,
    ["Jewelcrafting"] = 25229,
    ["Leatherworking"] = 2108,
    ["Mining"] = 2575,
    ["Skinning"] = 8613,
    ["Tailoring"] = 3908,
}

local GOLD = {1, 0.82, 0}
local OFFWHITE = {0.94, 0.92, 0.88}
local MUTED = {0.72, 0.72, 0.72}
local COLOR_BG = {0.05, 0.05, 0.05, 0.92}
local COLOR_TITLE_BG = {0.12, 0.12, 0.12, 1}
local COLOR_BORDER = {0.30, 0.30, 0.30, 0.85}
local COLOR_PANEL = {0.065, 0.065, 0.065, 0.96}
local COLOR_ROW = {0.08, 0.08, 0.08, 0.96}
local COLOR_ROW_SELECTED = {0.13, 0.11, 0.08, 0.98}
local COLOR_BUTTON = {0.075, 0.075, 0.075, 0.98}
local COLOR_BUTTON_ACTIVE = {0.13, 0.11, 0.08, 0.98}

local function unpackColor(t)
    return t[1], t[2], t[3]
end

local function colorText(text, r, g, b)
    if not text then return "-" end
    r = math.max(0, math.min(1, r or 1))
    g = math.max(0, math.min(1, g or 1))
    b = math.max(0, math.min(1, b or 1))
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, tostring(text))
end

local function getQualityColor(quality)
    if quality == nil then return 0.82, 0.82, 0.82 end
    if type(GetItemQualityColor) == "function" then
        local r, g, b = GetItemQualityColor(quality)
        if r then return r, g, b end
    end
    if C_Item and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(quality)
        if r then return r, g, b end
    end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if c then return c.r, c.g, c.b end
    return 0.82, 0.82, 0.82
end

local function getItemData(itemID)
    if not itemID then return nil, nil, nil end
    local name, _, quality, _, _, _, _, _, _, icon = GetItemInfo(itemID)
    if not icon and GetItemInfoInstant then
        local _, _, _, _, instantIcon = GetItemInfoInstant(itemID)
        icon = instantIcon
    end
    return name, quality, icon
end

local function getItemQuality(itemID)
    local _, quality = getItemData(itemID)
    return quality
end

local function getItemColorizedName(itemID, fallback)
    local _, quality = getItemData(itemID)
    if quality == nil then return fallback or tostring(itemID or "-") end
    return colorText(fallback or tostring(itemID), getQualityColor(quality))
end

local function getItemIcon(itemID)
    local _, _, icon = getItemData(itemID)
    return icon
end

local function getSpellIcon(spellID)
    return spellID and GetSpellTexture and GetSpellTexture(spellID) or nil
end

local function textureTag(texture, size)
    if not texture then return "" end
    size = size or 16
    return string.format("|T%s:%d:%d:0:0:64:64:4:60:4:60|t", texture, size, size)
end

local function materialTextureTag(texture)
    if not texture then return "" end
    return string.format("|T%s:18:18:0:0|t", texture)
end

local function statusTag(online)
    if online then
        return "|TInterface\\COMMON\\Indicator-Green:12:12:0:0|t"
    end
    return "|TInterface\\COMMON\\Indicator-Red:12:12:0:0|t"
end

local function getProfessionIcon(profName)
    local spellID = PROFESSION_SPELL_IDS[profName]
    return getSpellIcon(spellID)
end

local function getClassColor(memberKey)
    local meta = Addon.Data and Addon.Data.GetGuildMemberMeta and Addon.Data:GetGuildMemberMeta(memberKey)
    local classFile = meta and meta.classFile
    local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if color then return color.r, color.g, color.b end
    return unpackColor(OFFWHITE)
end

local function getClassColorizedName(memberKey)
    return colorText(memberKey, getClassColor(memberKey))
end

local function getRarityLabel(itemID)
    local quality = getItemQuality(itemID)
    if quality == nil then return nil end
    local label = _G["ITEM_QUALITY" .. quality .. "_DESC"] or _G["ITEM_QUALITY" .. tostring(quality) .. "_DESC"] or tostring(quality)
    return colorText(label, getQualityColor(quality))
end

local function createBackdrop(frame, bgR, bgG, bgB, bgA, borderR, borderG, borderB, borderA)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(bgR or COLOR_BG[1], bgG or COLOR_BG[2], bgB or COLOR_BG[3], bgA or COLOR_BG[4])
    frame:SetBackdropBorderColor(borderR or COLOR_BORDER[1], borderG or COLOR_BORDER[2], borderB or COLOR_BORDER[3], borderA or COLOR_BORDER[4])
end

local function createButton(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, height)
    b:SetText(text)
    return b
end

local function createCardStyleButton(parent, width, height)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, height)
    createBackdrop(b, COLOR_BUTTON[1], COLOR_BUTTON[2], COLOR_BUTTON[3], COLOR_BUTTON[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], 0.9)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", 12, 0)
    b.label:SetPoint("RIGHT", -8, 0)
    b.label:SetJustifyH("LEFT")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(14, 14)
    b.icon:SetPoint("LEFT", 10, 0)
    b.highlight = b:CreateTexture(nil, "HIGHLIGHT")
    b.highlight:SetAllPoints()
    b.highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    b.highlight:SetVertexColor(1, 1, 1, 0.04)
    b:SetScript("OnMouseDown", function(self) self:SetBackdropColor(0.10, 0.10, 0.10, 1) end)
    b:SetScript("OnMouseUp", function(self) end)
    function b:SetSelected(selected)
        if selected then
            self:SetBackdropColor(COLOR_BUTTON_ACTIVE[1], COLOR_BUTTON_ACTIVE[2], COLOR_BUTTON_ACTIVE[3], COLOR_BUTTON_ACTIVE[4])
            self:SetBackdropBorderColor(1, 0.82, 0, 0.95)
            self.label:SetTextColor(1.0, 0.92, 0.75)
        else
            self:SetBackdropColor(COLOR_BUTTON[1], COLOR_BUTTON[2], COLOR_BUTTON[3], COLOR_BUTTON[4])
            self:SetBackdropBorderColor(COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], 0.9)
            self.label:SetTextColor(0.94, 0.92, 0.88)
        end
    end
    function b:SetLabel(text, iconTexture)
        if iconTexture then
            self.icon:SetTexture(iconTexture)
            self.icon:Show()
            self.label:ClearAllPoints()
            self.label:SetPoint("LEFT", self.icon, "RIGHT", 8, 0)
            self.label:SetPoint("RIGHT", -8, 0)
        else
            self.icon:Hide()
            self.label:ClearAllPoints()
            self.label:SetPoint("LEFT", 12, 0)
            self.label:SetPoint("RIGHT", -8, 0)
        end
        self.label:SetText(text or "")
    end
    b:SetSelected(false)
    return b
end

local function ageText(ts)
    if not ts or ts <= 0 then return "never" end
    local delta = math.max(0, time() - ts)
    if delta < 120 then return "just now" end
    if delta < 3600 then return math.floor(delta / 60) .. "m ago" end
    if delta < 86400 then return math.floor(delta / 3600) .. "h ago" end
    return math.floor(delta / 86400) .. "d ago"
end

local function safeText(v)
    if v == nil then return "-" end
    return tostring(v)
end

local function formatMoney(copper)
    if type(copper) ~= "number" then return "n/a" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local goldIcon = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:0:-5|t"
    local silverIcon = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:0:-5|t"
    local copperIcon = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:0:-5|t"
    local parts = {}
    if g > 0 then parts[#parts + 1] = string.format("%d %s", g, goldIcon) end
    if s > 0 then parts[#parts + 1] = string.format("%d %s", s, silverIcon) end
    if c > 0 then parts[#parts + 1] = string.format("%d %s", c, copperIcon) end
    if #parts == 0 then return "0" end
    return table.concat(parts, " ")
end

local function channelForInput(input)
    local c = tostring(input or "guild"):lower()
    if c == "g" or c == "guild" then return "GUILD" end
    if c == "p" or c == "party" then return "PARTY" end
    if c == "r" or c == "raid" then return "RAID" end
    if c == "s" or c == "say" then return "SAY" end
    return nil
end

local function getItemLinkByID(itemID)
    if not itemID or type(GetItemInfo) ~= "function" then return nil end
    local _, link = GetItemInfo(itemID)
    return link
end

local function whisperTargetFromMemberKey(memberKey)
    if not memberKey then return nil end
    local short = tostring(memberKey):match("^([^%-]+)")
    return short or memberKey
end

local function openWhisperWindow(target)
    if not target then return end
    if type(ChatFrame_SendTell) == "function" then
        ChatFrame_SendTell(target)
        return
    end
    if type(ChatFrame_OpenChat) == "function" then
        ChatFrame_OpenChat("/w " .. tostring(target) .. " ")
    end
end

local function insertLinkInChat(link)
    if not link then return false end
    if type(ChatEdit_InsertLink) ~= "function" then return false end
    local ok = ChatEdit_InsertLink(link)
    return ok and true or false
end

local function createStatCard(parent, label, width)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetSize(width, 44)
    createBackdrop(card, 0.075, 0.075, 0.075, 0.96, COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], 0.9)

    local value = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    value:SetPoint("TOPLEFT", 10, -8)
    value:SetJustifyH("LEFT")
    value:SetText("0")
    card.value = value

    local text = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    text:SetPoint("BOTTOMLEFT", 10, 8)
    text:SetJustifyH("LEFT")
    text:SetText(label)
    card.text = text

    return card
end

function UI:OnInitialize()
    self.selectedProfession = (Addon.db and Addon.db.profile and Addon.db.profile.selectedProfession) or "All"
    self.sortMode = (Addon.db and Addon.db.profile and Addon.db.profile.sortMode) or "alpha"
    self.selectedRecipeKey = nil
    self.searchText = ""
end

function UI:OnEnable()
    self:CreateMainFrame()
end

function UI:CreateMainFrame()
    if self.frame then return end

    local f = CreateFrame("Frame", "RecipeRegistryFrame", UIParent, "BackdropTemplate")
    f:SetSize(1200, 750)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(1000, 620)
    elseif f.SetMinResize then
        f:SetMinResize(1000, 620)
    end
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    createBackdrop(f, COLOR_BG[1], COLOR_BG[2], COLOR_BG[3], COLOR_BG[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])
    f:Hide()
    table.insert(UISpecialFrames, "RecipeRegistryFrame")

    local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    titleBar:SetPoint("TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", -1, -1)
    titleBar:SetHeight(46)
    createBackdrop(titleBar, COLOR_TITLE_BG[1], COLOR_TITLE_BG[2], COLOR_TITLE_BG[3], COLOR_TITLE_BG[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], 1)

    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -7)
    title:SetText("Recipe Registry")
    title:SetTextColor(unpackColor(GOLD))

    local subtitle = titleBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    subtitle:SetText("Guild crafting directory")
    subtitle:SetTextColor(0.80, 0.80, 0.80)
    subtitle:SetJustifyH("LEFT")
    f.subtitle = subtitle

    local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    close:SetPoint("RIGHT", -2, 0)
    close:SetScript("OnClick", function()
        if HideUIPanel then
            HideUIPanel(f)
        else
            f:Hide()
        end
    end)

    local rescan = createButton(titleBar, "Rescan", 72, 22)
    rescan:SetPoint("RIGHT", close, "LEFT", -12, 0)
    rescan:SetScript("OnClick", function() Addon:SlashHandler("rescan") end)
    f.rescanButton = rescan

    local syncDot = titleBar:CreateTexture(nil, "OVERLAY")
    syncDot:SetSize(10, 10)
    syncDot:SetPoint("RIGHT", rescan, "LEFT", -10, 0)
    syncDot:SetTexture("Interface\\Buttons\\WHITE8x8")
    syncDot:SetVertexColor(0.2, 0.9, 0.2, 1)
    f.syncDot = syncDot

    local autoLabel = titleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    autoLabel:SetPoint("RIGHT", syncDot, "LEFT", -8, 0)
    autoLabel:SetText("Sync")
    autoLabel:SetTextColor(0.7, 0.9, 0.7)
    f.autoLabel = autoLabel

    local topBand = CreateFrame("Frame", nil, f)
    topBand:SetPoint("TOPLEFT", 10, -58)
    topBand:SetPoint("TOPRIGHT", -10, -58)
    topBand:SetHeight(52)
    f.topBand = topBand

    local card1 = createStatCard(topBand, "Known members", 190)
    card1:SetPoint("LEFT", 0, 0)
    local card2 = createStatCard(topBand, "Recipes shown", 190)
    card2:SetPoint("LEFT", card1, "RIGHT", 10, 0)
    local card3 = createStatCard(topBand, "Network nodes", 190)
    card3:SetPoint("LEFT", card2, "RIGHT", 10, 0)
    local card4 = createStatCard(topBand, "Last local update", 230)
    card4:SetPoint("LEFT", card3, "RIGHT", 10, 0)
    f.cards = {members = card1, recipes = card2, network = card3, updated = card4}

    local left = CreateFrame("Frame", nil, f, "BackdropTemplate")
    left:SetPoint("TOPLEFT", 10, -118)
    left:SetPoint("BOTTOMLEFT", 10, 34)
    left:SetWidth(240)
    createBackdrop(left, COLOR_PANEL[1], COLOR_PANEL[2], COLOR_PANEL[3], COLOR_PANEL[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])
    f.left = left

    local searchLabel = left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", 12, -12)
    searchLabel:SetText("Search")

    local searchBox = CreateFrame("EditBox", nil, left, "InputBoxTemplate")
    searchBox:SetPoint("TOPLEFT", 10, -30)
    searchBox:SetPoint("TOPRIGHT", -10, -30)
    searchBox:SetHeight(24)
    searchBox:SetAutoFocus(false)
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetScript("OnEscapePressed", searchBox.ClearFocus)
    searchBox:SetScript("OnTextChanged", function(box)
        UI.searchText = box:GetText() or ""
        UI.selectedRecipeKey = nil
        if UI._searchTimer then
            Addon:CancelTimer(UI._searchTimer, true)
        end
        UI._searchTimer = Addon:ScheduleTimer(function()
            UI._searchTimer = nil
            if not UI.frame or not UI.frame:IsShown() then return end
            UI:RefreshRecipeList()
            UI:RefreshDetailPanel()
            UI:RefreshSummaryCards()
        end, SEARCH_DEBOUNCE)
    end)
    f.searchBox = searchBox

    local profLabel = left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profLabel:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 2, -12)
    profLabel:SetText("Profession filter")

    f.profButtons = {}
    local lastProf
    for i, profName in ipairs(PROF_ORDER) do
        local b = createCardStyleButton(left, 216, 24)
        if i == 1 then
            b:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -30)
        else
            b:SetPoint("TOPLEFT", lastProf, "BOTTOMLEFT", 0, -6)
        end
        b:SetScript("OnClick", function()
            UI.selectedProfession = profName
            if Addon.db and Addon.db.profile then Addon.db.profile.selectedProfession = profName end
            UI.selectedRecipeKey = nil
            UI:Refresh()
        end)
        f.profButtons[profName] = b
        lastProf = b
    end

    local hint = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 12, 12)
    hint:SetPoint("BOTTOMRIGHT", -12, 12)
    hint:SetJustifyH("LEFT")
    hint:SetSpacing(2)
    hint:SetText("Open your profession windows after learning new recipes. Sync runs automatically in the background.")
    hint:SetTextColor(0.70, 0.70, 0.70)
    f.sidebarHint = hint

    local center = CreateFrame("Frame", nil, f, "BackdropTemplate")
    center:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, 0)
    center:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT", 10, 0)
    center:SetWidth(360)
    createBackdrop(center, COLOR_PANEL[1], COLOR_PANEL[2], COLOR_PANEL[3], COLOR_PANEL[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])
    f.center = center

    local recipeHeader = center:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    recipeHeader:SetPoint("TOPLEFT", 12, -12)
    recipeHeader:SetText("Recipes")
    f.recipeHeader = recipeHeader

    local sortAlpha = createCardStyleButton(center, 96, 24)
    sortAlpha:SetPoint("TOPRIGHT", -112, -8)
    sortAlpha:SetLabel("Alphabetical")
    sortAlpha:SetScript("OnClick", function()
        UI.sortMode = "alpha"
        if Addon.db and Addon.db.profile then Addon.db.profile.sortMode = UI.sortMode end
        UI:Refresh()
    end)
    f.sortAlpha = sortAlpha

    local sortRarity = createCardStyleButton(center, 86, 24)
    sortRarity:SetPoint("LEFT", sortAlpha, "RIGHT", 6, 0)
    sortRarity:SetLabel("Rarity")
    sortRarity:SetScript("OnClick", function()
        UI.sortMode = "rarity"
        if Addon.db and Addon.db.profile then Addon.db.profile.sortMode = UI.sortMode end
        UI:Refresh()
    end)
    f.sortRarity = sortRarity


    local recipeScroll = CreateFrame("ScrollFrame", nil, center, "UIPanelScrollFrameTemplate")
    recipeScroll:SetPoint("TOPLEFT", 8, -40)
    recipeScroll:SetPoint("BOTTOMRIGHT", -28, 10)
    local recipeContent = CreateFrame("Frame", nil, recipeScroll)
    recipeContent:SetSize(320, 1)
    recipeScroll:SetScrollChild(recipeContent)
    f.recipeScroll = recipeScroll
    f.recipeContent = recipeContent
    f.recipeRows = {}

    local right = CreateFrame("Frame", nil, f, "BackdropTemplate")
    right:SetPoint("TOPLEFT", center, "TOPRIGHT", 10, 0)
    right:SetPoint("TOPRIGHT", -10, -118)
    right:SetPoint("BOTTOMRIGHT", -10, 34)
    createBackdrop(right, COLOR_PANEL[1], COLOR_PANEL[2], COLOR_PANEL[3], COLOR_PANEL[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])
    f.right = right

    local detailTitle = right:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    detailTitle:SetPoint("TOPLEFT", 12, -12)
    detailTitle:SetPoint("TOPRIGHT", -12, -12)
    detailTitle:SetJustifyH("LEFT")
    detailTitle:SetText("Recipe details")
    f.detailTitle = detailTitle

    local detailTitleButton = CreateFrame("Button", nil, right)
    detailTitleButton:SetPoint("TOPLEFT", 10, -10)
    detailTitleButton:SetPoint("TOPRIGHT", -32, -10)
    detailTitleButton:SetHeight(18)
    detailTitleButton:SetScript("OnClick", function(_, button)
        if button ~= "LeftButton" or not IsShiftKeyDown() then return end
        local detail = UI.currentDetail
        if not detail then return end
        local link = (detail.spellID and GetSpellLink and GetSpellLink(detail.spellID))
            or getItemLinkByID(detail.recipeItemID)
            or getItemLinkByID(detail.createdItemID)
        insertLinkInChat(link)
    end)
    detailTitleButton:SetScript("OnEnter", function(self)
        local detail = UI.currentDetail
        if not detail then return end
        local hasLink = false
        if detail.createdItemID then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT", 0, 0)
            GameTooltip:SetHyperlink("item:" .. detail.createdItemID)
            hasLink = true
        elseif detail.spellID then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT", 0, 0)
            GameTooltip:SetHyperlink("spell:" .. detail.spellID)
            hasLink = true
        end
        if hasLink then GameTooltip:Show() end
    end)
    detailTitleButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    f.detailTitleButton = detailTitleButton

    local detailSub = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    detailSub:SetPoint("TOPLEFT", detailTitle, "BOTTOMLEFT", 0, -4)
    detailSub:SetText("Select a recipe to see materials, output and available crafters.")
    detailSub:SetJustifyH("LEFT")
    f.detailSub = detailSub

    local detailScroll = CreateFrame("ScrollFrame", nil, right, "UIPanelScrollFrameTemplate")
    detailScroll:SetPoint("TOPLEFT", 8, -54)
    detailScroll:SetPoint("BOTTOMRIGHT", -28, 10)
    local detailContent = CreateFrame("Frame", nil, detailScroll)
    detailContent:SetSize(420, 1)
    detailScroll:SetScrollChild(detailContent)
    f.detailScroll = detailScroll
    f.detailContent = detailContent
    f.detailLines = {}

    local footer = CreateFrame("Frame", nil, f, "BackdropTemplate")
    footer:SetPoint("BOTTOMLEFT", 1, 1)
    footer:SetPoint("BOTTOMRIGHT", -1, 1)
    footer:SetHeight(24)
    createBackdrop(footer, COLOR_TITLE_BG[1], COLOR_TITLE_BG[2], COLOR_TITLE_BG[3], 1, 0.16, 0.16, 0.16, 1)

    local footerText = footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footerText:SetPoint("LEFT", 12, 0)
    footerText:SetText("Left-click the minimap button to open the directory.")
    footerText:SetTextColor(0.70, 0.70, 0.70)
    footerText:SetJustifyH("LEFT")
    f.footerText = footerText

    self.frame = f
end

function UI:EnsureRecipeRow(index)
    local row = self.frame.recipeRows[index]
    if row then return row end

    row = CreateFrame("Button", nil, self.frame.recipeContent, "BackdropTemplate")
    row:SetSize(314, 56)
    createBackdrop(row, COLOR_ROW[1], COLOR_ROW[2], COLOR_ROW[3], COLOR_ROW[4], 0.22, 0.22, 0.22, 1)

    local stripe = row:CreateTexture(nil, "ARTWORK")
    stripe:SetPoint("TOPLEFT", 0, 0)
    stripe:SetPoint("BOTTOMLEFT", 0, 0)
    stripe:SetWidth(4)
    stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
    stripe:SetVertexColor(0.35, 0.35, 0.35, 1)
    row.stripe = stripe

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(30, 30)
    icon:SetPoint("LEFT", 14, 0)
    row.icon = icon

    local title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -1)
    title:SetPoint("TOPRIGHT", -10, -8)
    title:SetJustifyH("LEFT")
    row.title = title

    local meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    meta:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 12, 7)
    meta:SetPoint("BOTTOMRIGHT", -10, 7)
    meta:SetJustifyH("LEFT")
    row.meta = meta

    row:SetScript("OnClick", function(self)
        UI.selectedRecipeKey = self.recipeKey
        UI:RefreshRecipeList()
        UI:RefreshDetailPanel()
    end)

    self.frame.recipeRows[index] = row
    return row
end

function UI:EnsureDetailLine(index)
    local line = self.frame.detailLines[index]
    if line then return line end
    line = CreateFrame("Button", nil, self.frame.detailContent)
    line:SetSize(420, 22)
    line:SetPoint("TOPLEFT", 0, -((index - 1) * 22))
    line.text = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    line.text:SetPoint("TOPLEFT", 0, 0)
    line.text:SetPoint("BOTTOMRIGHT", -24, 0)
    line.text:SetJustifyH("LEFT")
    line.text:SetSpacing(4)
    if line.text.SetWordWrap then
        line.text:SetWordWrap(false)
    end
    if line.text.SetMaxLines then
        line.text:SetMaxLines(1)
    end

    line.actionButton = CreateFrame("Button", nil, line)
    line.actionButton:SetSize(16, 16)
    line.actionButton:SetPoint("RIGHT", -2, 0)
    line.actionButton.icon = line.actionButton:CreateTexture(nil, "ARTWORK")
    line.actionButton.icon:SetAllPoints()
    line.actionButton.icon:SetTexture("Interface\\FriendsFrame\\UI-FriendsList-Small-Up")
    line.actionButton.icon:SetVertexColor(0.8, 1.0, 0.8, 1)
    line.actionButton:SetScript("OnClick", function(self, button)
        if button ~= "LeftButton" then return end
        local parent = self:GetParent()
        local target = parent.requestTarget
        if not target then return end
        local detail = UI.currentDetail
        if not detail then return end
        local recipeLink = (detail.spellID and GetSpellLink and GetSpellLink(detail.spellID))
            or getItemLinkByID(detail.recipeItemID)
            or getItemLinkByID(detail.createdItemID)
            or (detail.label or "this craft")
        local msg = string.format("Hi! Could you craft %s for me when you have time? Thanks!", tostring(recipeLink))
        SendChatMessage(msg, "WHISPER", nil, target)
    end)
    line.actionButton:SetScript("OnEnter", function(self)
        if not self:GetParent().requestTarget then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Request craft")
        GameTooltip:AddLine("Click to whisper this crafter.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    line.actionButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    line.actionButton:Hide()

    line:SetScript("OnClick", function(self, button)
        if button ~= "LeftButton" then return end
        if self.isOfflineToggle then
            UI._offlineCraftersExpanded = not UI._offlineCraftersExpanded
            UI:RefreshDetailPanel()
            return
        end
        if IsShiftKeyDown() then
            insertLinkInChat(self.link)
            return
        end
        if self.requestTarget then
            openWhisperWindow(self.requestTarget)
        end
    end)
    line:SetScript("OnEnter", function(self)
        if not self.tooltipLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(self.tooltipLink)
        GameTooltip:Show()
    end)
    line:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    self.frame.detailLines[index] = line
    return line
end

function UI:RefreshStatusBar()
    local sync = Addon.Sync
    local state = sync and sync.GetUiState and sync:GetUiState() or nil
    local summary = Addon.Data:GetLocalSummary()

    local members = 0
    for _ in pairs(Addon.Data:GetMembersDB()) do
        members = members + 1
    end

    local onlineNodes = state and state.onlineNodes or 0
    local queued = state and state.queued or 0
    local inFlight = state and state.inFlight
    local role = state and state.role or "Client"

    local subtitle = string.format(
        "Automatic sync • %s • %d guild node(s) • %d known member(s)",
        role,
        onlineNodes,
        members
    )
    if inFlight then
        subtitle = subtitle .. string.format(" • syncing %s", tostring(inFlight))
    elseif queued and queued > 0 then
        subtitle = subtitle .. string.format(" • %d update(s) queued", queued)
    end
    self.frame.subtitle:SetText(subtitle)

    if onlineNodes > 1 then
        self.frame.syncDot:SetVertexColor(0.2, 0.9, 0.2, 1)
        self.frame.autoLabel:SetTextColor(0.7, 0.95, 0.7)
    elseif onlineNodes == 1 then
        self.frame.syncDot:SetVertexColor(1.0, 0.82, 0.0, 1)
        self.frame.autoLabel:SetTextColor(1.0, 0.9, 0.45)
    else
        self.frame.syncDot:SetVertexColor(0.75, 0.2, 0.2, 1)
        self.frame.autoLabel:SetTextColor(1.0, 0.75, 0.75)
    end

    self.frame.cards.members.value:SetText(tostring(members))
    self.frame.cards.network.value:SetText(string.format("%d / %d", onlineNodes, state and state.registry or 0))
    self.frame.cards.updated.value:SetText(ageText(summary.updatedAt))
    self.frame.cards.updated.text:SetText("Last local update")
end

function UI:RefreshSummaryCards()
    local shown = self.currentRecipeRows and #self.currentRecipeRows or 0
    self.frame.cards.recipes.value:SetText(tostring(shown))
    self.frame.cards.recipes.text:SetText(self.selectedProfession == "All" and "Recipes shown" or (self.selectedProfession .. " shown"))
end

function UI:RefreshProfessionButtons()
    local summary = Addon.Data:GetProfessionSummary()
    for _, profName in ipairs(PROF_ORDER) do
        local button = self.frame.profButtons[profName]
        if profName == "All" then
            button:SetLabel("All")
        else
            button:SetLabel(profName, getProfessionIcon(profName))
        end
        button:SetSelected(self.selectedProfession == profName)
    end
end

function UI:RefreshRecipeList()
    if not self.frame then return end
    local rows = Addon.Data:GetRecipeList(self.selectedProfession, self.searchText, self.sortMode)
    self.currentRecipeRows = rows
    self.frame.recipeHeader:SetText(self.selectedProfession == "All" and "Recipes" or (self.selectedProfession .. " recipes"))
    self.frame.sortAlpha:SetSelected(self.sortMode == "alpha")
    self.frame.sortRarity:SetSelected(self.sortMode == "rarity")

    if not self.selectedRecipeKey and #rows > 0 then
        self.selectedRecipeKey = rows[1].recipeKey
    elseif #rows == 0 then
        self.selectedRecipeKey = nil
    end

    for i, rowData in ipairs(rows) do
        local row = self:EnsureRecipeRow(i)
        row:SetPoint("TOPLEFT", 0, -((i - 1) * 56))
        row.recipeKey = rowData.recipeKey
        local detail = rowData.detail or {}
        local colorItemID = detail.createdItemID or detail.recipeItemID
        local titleText = rowData.label
        local rowIcon = detail.createdItemIcon or detail.recipeItemIcon or detail.spellIcon or getItemIcon(colorItemID)
        if rowIcon then
            row.icon:SetTexture(rowIcon)
            row.icon:Show()
        else
            row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            row.icon:Show()
        end
        if colorItemID then
            titleText = getItemColorizedName(colorItemID, rowData.label)
            local sr, sg, sb = getQualityColor(getItemQuality(colorItemID) or 1)
            row.stripe:SetVertexColor(sr, sg, sb, 1)
        else
            row.stripe:SetVertexColor(0.42, 0.42, 0.42, 1)
        end
        row.title:SetText(titleText)
        local metaParts = {}
        if self.selectedProfession == "All" and rowData.professionList and #rowData.professionList > 0 then
            metaParts[#metaParts + 1] = table.concat(rowData.professionList, ", ")
        end
        metaParts[#metaParts + 1] = string.format("%d crafter(s)", rowData.crafterCount or 0)
        if (rowData.onlineCount or 0) > 0 then
            metaParts[#metaParts + 1] = string.format("%d online", rowData.onlineCount or 0)
        end
        row.meta:SetText(table.concat(metaParts, "  •  "))
        if self.selectedRecipeKey == rowData.recipeKey then
            row:SetBackdropColor(COLOR_ROW_SELECTED[1], COLOR_ROW_SELECTED[2], COLOR_ROW_SELECTED[3], COLOR_ROW_SELECTED[4])
            row:SetBackdropBorderColor(1, 0.82, 0, 0.95)
        else
            row:SetBackdropColor(COLOR_ROW[1], COLOR_ROW[2], COLOR_ROW[3], COLOR_ROW[4])
            row:SetBackdropBorderColor(0.22, 0.22, 0.22, 1)
        end
        row:Show()
    end
    for i = #rows + 1, #self.frame.recipeRows do
        self.frame.recipeRows[i]:Hide()
    end
    self.frame.recipeContent:SetHeight(math.max(1, #rows * 56 + 10))
    self:RefreshSummaryCards()
end

function UI:RenderDetailLines(lines, lineLinks, lineMeta)
    for i, text in ipairs(lines) do
        local line = self:EnsureDetailLine(i)
        line.text:SetText(text)
        line.link = lineLinks and lineLinks[i] or nil
        line.tooltipLink = nil
        line.requestTarget = nil
        local meta = lineMeta and lineMeta[i] or nil
        if meta and meta.canRequest and meta.memberKey then
            line.requestTarget = whisperTargetFromMemberKey(meta.memberKey)
            line.actionButton:Show()
            if line._lastActionText ~= text then
                local textWidth = line.text:GetStringWidth() or 0
                local desiredX = math.min(392, math.max(24, textWidth + 14))
                line._lastActionText = text
                line._lastActionX = desiredX
                line.actionButton:ClearAllPoints()
                line.actionButton:SetPoint("LEFT", line, "LEFT", desiredX, 0)
            elseif line._lastActionX then
                line.actionButton:ClearAllPoints()
                line.actionButton:SetPoint("LEFT", line, "LEFT", line._lastActionX, 0)
            end
        else
            line.actionButton:Hide()
            line._lastActionText = nil
            line._lastActionX = nil
        end
        if meta and meta.tooltipLink then
            line.tooltipLink = meta.tooltipLink
        end
        line.isOfflineToggle = meta and meta.isOfflineToggle or false
        line:Show()
    end
    for i = #lines + 1, #self.frame.detailLines do
        self.frame.detailLines[i]:Hide()
    end
    self.frame.detailContent:SetHeight(math.max(1, #lines * 22 + 18))
end

function UI:RefreshDetailPanel()
    if not self.frame then return end
    local lines = {}
    local lineLinks = {}
    local lineMeta = {}
    if not self.selectedRecipeKey then
        self.currentDetail = nil
        self.frame.detailTitle:SetText("Recipe details")
        self.frame.detailSub:SetText("Select a recipe to see materials and available crafters.")
        if self.frame.detailTooltip then
            self.frame.detailTooltip:Hide()
        end
        self.frame.detailScroll:SetPoint("TOPLEFT", 8, -54)
        lines[#lines + 1] = "No recipe selected."
        self:RenderDetailLines(lines, lineLinks, lineMeta)
        return
    end

    local detail = Addon.Data:GetRecipeDetail(self.selectedRecipeKey)
    self.currentDetail = detail
    local iconTagText = textureTag(detail.createdItemIcon or detail.recipeItemIcon or detail.spellIcon, 18)
    local titleItemID = detail.createdItemID or detail.recipeItemID
    local titleText = detail.label or tostring(self.selectedRecipeKey)
    if titleItemID then
        titleText = getItemColorizedName(titleItemID, titleText)
    end
    self.frame.detailTitle:SetText(iconTagText .. titleText)

    local subtitleParts = {}
    if detail.professionName then subtitleParts[#subtitleParts + 1] = detail.professionName end
    if detail.directEnchant then subtitleParts[#subtitleParts + 1] = "Direct enchant" end
    subtitleParts[#subtitleParts + 1] = string.format("%d crafter(s)", detail.crafterCount or 0)
    self.frame.detailSub:SetText(table.concat(subtitleParts, "  •  "))

    -- Reset scroll position (no embedded tooltip anymore)
    self.frame.detailScroll:SetPoint("TOPLEFT", 8, -54)

    -- Reset offline accordion state when recipe changes
    if self._lastDetailRecipeKey ~= self.selectedRecipeKey then
        self._offlineCraftersExpanded = nil
        self._lastDetailRecipeKey = self.selectedRecipeKey
    end

    -- Split crafters into online / offline
    local onlineCrafters = {}
    local offlineCrafters = {}
    if detail.crafters then
        for _, crafter in ipairs(detail.crafters) do
            if crafter.online then
                onlineCrafters[#onlineCrafters + 1] = crafter
            else
                offlineCrafters[#offlineCrafters + 1] = crafter
            end
        end
    end

    lines[#lines + 1] = "|cffffd100Crafters|r"
    if #onlineCrafters == 0 and #offlineCrafters == 0 then
        lines[#lines + 1] = "No crafter known yet"
    else
        local selfKey = Addon.Data and Addon.Data.GetPlayerKey and Addon.Data:GetPlayerKey() or nil
        for _, crafter in ipairs(onlineCrafters) do
            local state = statusTag(true)
            lines[#lines + 1] = string.format("%s %s", state, getClassColorizedName(crafter.memberKey))
            if (not selfKey or crafter.memberKey ~= selfKey) then
                lineMeta[#lines] = {
                    canRequest = true,
                    memberKey = crafter.memberKey,
                }
            end
        end
        if #offlineCrafters > 0 then
            -- Default: collapsed if any online crafter, expanded if all offline
            if self._offlineCraftersExpanded == nil then
                self._offlineCraftersExpanded = (#onlineCrafters == 0)
            end
            local arrow = self._offlineCraftersExpanded and "|cff9fa6b2\226\150\190" or "|cff9fa6b2\226\150\184"
            lines[#lines + 1] = string.format("%s Offline (%d)|r", arrow, #offlineCrafters)
            lineMeta[#lines] = { isOfflineToggle = true }
            if self._offlineCraftersExpanded then
                for _, crafter in ipairs(offlineCrafters) do
                    local state = statusTag(false)
                    lines[#lines + 1] = string.format("%s %s", state, getClassColorizedName(crafter.memberKey))
                end
            end
        end
    end

    lines[#lines + 1] = " "
    lines[#lines + 1] = "|cffffd100Materials|r"
    if detail.reagents and #detail.reagents > 0 then
        for _, reagent in ipairs(detail.reagents) do
            local icon = reagent.icon or getItemIcon(reagent.itemID)
            local name = getItemColorizedName(reagent.itemID, safeText(reagent.name))
            local unitCost = formatMoney(reagent.unitCost)
            local lineCost = formatMoney(reagent.totalCost)
            lines[#lines + 1] = string.format("%s %s x%d", materialTextureTag(icon), name, reagent.count or 1)
            lineLinks[#lines] = getItemLinkByID(reagent.itemID)
            lineMeta[#lines] = {
                tooltipLink = getItemLinkByID(reagent.itemID),
            }
            lines[#lines + 1] = string.format("|cff9fa6b2   Unit: %s   Total: %s|r", unitCost, lineCost)
        end
    elseif detail.directEnchant then
        lines[#lines + 1] = "No material mapping available for this enchant."
    else
        lines[#lines + 1] = "No material mapping available."
    end

    if detail.cost and (detail.cost.pricedCount or 0) > 0 then
        lines[#lines + 1] = " "
        lines[#lines + 1] = "|cffffd100Cost estimate|r"
        lines[#lines + 1] = string.format("|cffffffffTotal: %s|r", formatMoney(detail.cost.total))
        lines[#lines + 1] = string.format("|cff8f949cSources: %s|r", tostring(detail.cost.source or "N/A"))
        if (detail.cost.missingCount or 0) > 0 then
            lines[#lines + 1] = string.format("|cff8f949cMissing prices: %d reagent(s)|r", detail.cost.missingCount)
        end
    end

    self:RenderDetailLines(lines, lineLinks, lineMeta)
end

function UI:Toggle()
    self:CreateMainFrame()
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
        self:Refresh()
        self.frame.searchBox:SetText(self.searchText or "")
    end
end

function UI:Refresh()
    if not self.frame or not self.frame:IsShown() then return end
    self:RefreshStatusBar()
    self:RefreshProfessionButtons()
    self:RefreshRecipeList()
    self:RefreshDetailPanel()
end

function UI:ShareSelectedRecipe(channelInput)
    local channel = channelForInput(channelInput)
    if not channel then
        Addon:Print("Usage: /rr share [guild|party|raid|say]")
        return
    end

    if channel == "GUILD" and not IsInGuild() then
        Addon:Print("You are not in a guild.")
        return
    end
    if channel == "PARTY" and not IsInGroup() then
        Addon:Print("You are not in a party.")
        return
    end
    if channel == "RAID" and not IsInRaid() then
        Addon:Print("You are not in a raid.")
        return
    end

    if not self.selectedRecipeKey then
        Addon:Print("No recipe selected.")
        return
    end

    local detail = Addon.Data:GetRecipeDetail(self.selectedRecipeKey)
    if not detail then
        Addon:Print("No recipe details available.")
        return
    end

    local recipeLink = (detail.spellID and GetSpellLink and GetSpellLink(detail.spellID))
        or getItemLinkByID(detail.recipeItemID)
        or getItemLinkByID(detail.createdItemID)
        or (detail.label or tostring(self.selectedRecipeKey))

    local totalText = (detail.cost and detail.cost.total and formatMoney(detail.cost.total)) or "n/a"
    local sourceText = (detail.cost and detail.cost.source) or "N/A"
    SendChatMessage(string.format("[RR] %s | Mats total: %s | Source: %s", tostring(recipeLink), totalText, tostring(sourceText)), channel)

    if detail.reagents and #detail.reagents > 0 then
        local chunk = "[RR] Mats:"
        for _, reagent in ipairs(detail.reagents) do
            local link = getItemLinkByID(reagent.itemID) or reagent.name or ("item:" .. tostring(reagent.itemID or "?"))
            local seg = string.format(" %s x%d", tostring(link), reagent.count or 1)
            if #chunk + #seg > 240 then
                SendChatMessage(chunk, channel)
                chunk = "[RR] Mats:" .. seg
            else
                chunk = chunk .. seg
            end
        end
        if chunk ~= "[RR] Mats:" then
            SendChatMessage(chunk, channel)
        end
    end
end
