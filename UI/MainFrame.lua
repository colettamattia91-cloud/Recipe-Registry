local Addon = _G.RecipeRegistry
local UI = Addon:NewModule("UI")
Addon.UI = UI

local SEARCH_DEBOUNCE = 0.15
local GLOBAL_SEARCH_DEBOUNCE = 0.35
local GLOBAL_SEARCH_MIN_CHARS = 3
local ADDON_STATUS_VIEW = "Guild Addons"
local FAVORITES_VIEW = "Favorites"
local ADDON_STATUS_LEGACY_VIEWS = {
    ["Addon Status"] = true,
    ["Guild Addon Adoption"] = true,
}
local ADDON_STATUS_DEFAULT_SORT = "name"
local ADDON_STATUS_FILTER_CYCLES = {
    status = {"all", "online_with_addon", "online_addon_not_seen", "seen_before", "not_seen_recently", "never_seen"},
    roster = {"all", "online", "offline"},
    version = {"all", "current", "old", "unknown"},
}
local ADDON_STATUS_FILTER_LABELS = {
    online_with_addon = "Active",
    online_addon_not_seen = "Online no addon",
    seen_before = "Seen before",
    not_seen_recently = "Stale",
    never_seen = "Never seen",
    online = "Online",
    offline = "Offline",
    current = "Current",
    old = "Old",
    unknown = "Unknown",
}
local ADDON_STATUS_FILTER_MARKER = "|cffffd100[F]|r"

local PROF_ORDER = {
    FAVORITES_VIEW, "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering",
    "Jewelcrafting", "Leatherworking", "Mining", "Tailoring"
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
local FAVORITE_ICON = "Interface\\AddOns\\RecipeRegistry\\UI\\Assets\\favorite-star"
local VALID_FRAME_POINTS = {
    TOPLEFT = true,
    TOP = true,
    TOPRIGHT = true,
    LEFT = true,
    CENTER = true,
    RIGHT = true,
    BOTTOMLEFT = true,
    BOTTOM = true,
    BOTTOMRIGHT = true,
}

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

local function lowerSafe(v)
    if v == nil then return "" end
    return tostring(v):lower()
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
    return string.format("|T%s:18:18:0:0:64:64:5:59:5:59|t", texture)
end

local function statusTag(online)
    if online then
        return "|TInterface\\COMMON\\Indicator-Green:12:12:0:0|t"
    end
    return "|TInterface\\COMMON\\Indicator-Red:12:12:0:0|t"
end

local function addonStatusColor(statusKey)
    if statusKey == "online_with_addon" then
        return 0.35, 0.95, 0.45
    end
    if statusKey == "online_addon_not_seen" then
        return 1.0, 0.82, 0.25
    end
    if statusKey == "seen_before" then
        return 0.55, 0.72, 1.0
    end
    if statusKey == "not_seen_recently" then
        return 1.0, 0.48, 0.28
    end
    return 0.55, 0.55, 0.55
end

local function addonStatusLabelColor(row)
    local r, g, b = addonStatusColor(row and row.addonStatusKey)
    return colorText(row and row.addonStatusLabel or "Never seen", r, g, b)
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

local function releaseSearchFocus()
    local ui = Addon.UI
    if ui and ui.ClearSearchFocus then
        ui:ClearSearchFocus()
        return
    end
    local frame = ui and ui.frame
    local searchBox = frame and frame.searchBox
    if searchBox and searchBox.HasFocus and searchBox:HasFocus() then
        searchBox:ClearFocus()
    end
    searchBox = frame and frame.addonStatusSearchBox
    if searchBox and searchBox.HasFocus and searchBox:HasFocus() then
        searchBox:ClearFocus()
    end
end

local function createButton(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, height)
    b:SetText(text)
    b:SetScript("OnMouseDown", function()
        releaseSearchFocus()
    end)
    return b
end

-- Dark fill + gold edge button matching the addon's chrome. Same look
-- as the inline "Ask" button in the crafter list. Use this for any
-- top-bar or chrome-level button so it doesn't read as the default
-- vanilla-WoW blue UIPanelButton.
local function createAddonStyleButton(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, height)
    if b.SetBackdrop then
        b:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        b:SetBackdropColor(0.13, 0.11, 0.08, 0.95)
        b:SetBackdropBorderColor(1, 0.82, 0, 0.75)
    end
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", 2, 0)
    b.label:SetPoint("RIGHT", -2, 0)
    b.label:SetJustifyH("CENTER")
    b.label:SetText(text or "")
    b.label:SetTextColor(1.0, 0.92, 0.75)
    b:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    local hi = b:GetHighlightTexture()
    if hi and hi.SetVertexColor then hi:SetVertexColor(1, 0.82, 0, 0.18) end
    b:SetScript("OnMouseDown", function() releaseSearchFocus() end)
    -- Override SetText so existing call sites (cleanupButton:SetText
    -- when the background job toggles state) update the label rather
    -- than hitting the base Button's no-op SetText.
    function b:SetText(value)
        if self.label and self.label.SetText then
            self.label:SetText(value or "")
        end
    end
    return b
end

local function setButtonEnabledIfChanged(button, enabled)
    if not button then return end
    enabled = enabled and true or false
    if button._rrEnabled == enabled then return end
    button._rrEnabled = enabled
    if enabled then
        if button.Enable then button:Enable() end
        if button.SetAlpha then button:SetAlpha(1) end
    else
        if button.Disable then button:Disable() end
        if button.SetAlpha then button:SetAlpha(0.45) end
    end
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
    b:SetScript("OnMouseDown", function(self)
        releaseSearchFocus()
        self:SetBackdropColor(0.10, 0.10, 0.10, 1)
    end)
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

-- Exposed for UI/ExternalTabs.lua so sibling addons can spawn nav-row
-- tab buttons in the same visual style without duplicating the factory.
function UI:_CreateMainNavButton(parent, label, width, height)
    local button = createCardStyleButton(parent, width or 132, height or 24)
    button:SetLabel(label or "")
    return button
end

local function ageText(ts)
    if not ts or ts <= 0 then return "never" end
    local delta = math.max(0, time() - ts)
    if delta < 120 then return "just now" end
    if delta < 3600 then return math.floor(delta / 60) .. "m ago" end
    if delta < 86400 then return math.floor(delta / 3600) .. "h ago" end
    return math.floor(delta / 86400) .. "d ago"
end

local function timestampText(ts)
    if not ts or ts <= 0 then return "never" end
    local formatted = date and date("%Y-%m-%d %H:%M", ts) or tostring(ts)
    return string.format("%s (%s)", formatted, ageText(ts))
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

local function formatMoneyForChat(copper)
    if type(copper) ~= "number" then return "n/a" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = tostring(g) .. "g" end
    if s > 0 then parts[#parts + 1] = tostring(s) .. "s" end
    if c > 0 then parts[#parts + 1] = tostring(c) .. "c" end
    if #parts == 0 then return "0" end
    return table.concat(parts, " ")
end

local function escapeChatPlainText(value)
    if value == nil then return "" end
    return tostring(value):gsub("|", "||")
end

local function isChatLink(value)
    local text = tostring(value or "")
    return text:find("|H", 1, true) ~= nil and text:find("|h", 1, true) ~= nil
end

local function chatDisplayText(value)
    if value == nil then return "" end
    if isChatLink(value) then
        return tostring(value)
    end
    return escapeChatPlainText(value)
end

local SHARE_CHANNELS = {
    { input = "guild", label = "Guild", chatType = "GUILD", aliases = { "g", "guild" } },
    { input = "say", label = "Say", chatType = "SAY", aliases = { "s", "say" } },
    { input = "party", label = "Party", chatType = "PARTY", aliases = { "p", "party" } },
    { input = "raid", label = "Raid", chatType = "RAID", aliases = { "raid" } },
    { input = "reply", label = "Reply", chatType = "WHISPER", aliases = { "r", "reply", "re", "w", "whisper" } },
}

local function playerIsInRaid()
    if type(IsInRaid) == "function" then
        return IsInRaid() == true
    end
    if type(GetNumRaidMembers) == "function" then
        return (GetNumRaidMembers() or 0) > 0
    end
    return false
end

local function playerIsInParty()
    if playerIsInRaid() then
        return false
    end
    if type(IsInGroup) == "function" then
        return IsInGroup() == true
    end
    if type(GetNumPartyMembers) == "function" then
        return (GetNumPartyMembers() or 0) > 0
    end
    return false
end

local function shareChannelUnavailableReason(def)
    if def.chatType == "GUILD" and not (type(IsInGuild) == "function" and IsInGuild()) then
        return "You are not in a guild."
    end
    if def.chatType == "PARTY" and not playerIsInParty() then
        return "You are not in a party."
    end
    if def.chatType == "RAID" and not playerIsInRaid() then
        return "You are not in a raid."
    end
    if def.chatType == "WHISPER" and not def.target then
        return "No recent whisper target."
    end
    return nil
end

local function normalizeShareInput(input)
    local text = tostring(input or "guild"):lower()
    text = text:match("^%s*(.-)%s*$") or text
    if text == "" then return "guild" end
    return text
end

local function findShareChannelByAlias(input)
    local c = normalizeShareInput(input)
    for _, def in ipairs(SHARE_CHANNELS) do
        for _, alias in ipairs(def.aliases or {}) do
            if c == alias then
                return def
            end
        end
    end
    return nil
end

local function readFrameAttribute(frame, key)
    if not frame then return nil end
    if type(frame.GetAttribute) == "function" then
        local ok, value = pcall(frame.GetAttribute, frame, key)
        if ok and value ~= nil and value ~= "" then
            return value
        end
    end
    return frame[key]
end

local function getWhisperTargetFromEditBox(editBox)
    if not editBox then return nil end
    local chatType = readFrameAttribute(editBox, "chatType")
    if chatType ~= "WHISPER" then
        return nil
    end
    local target = readFrameAttribute(editBox, "tellTarget")
        or readFrameAttribute(editBox, "target")
        or readFrameAttribute(editBox, "tellTargetName")
    if target and target ~= "" then
        return target
    end
    return nil
end

local function getActiveWhisperTarget()
    if type(ChatEdit_GetActiveWindow) == "function" then
        local ok, editBox = pcall(ChatEdit_GetActiveWindow)
        if ok then
            local target = getWhisperTargetFromEditBox(editBox)
            if target then
                return target
            end
        end
    end
    return nil
end

local function getLastTellTarget()
    local activeTarget = getActiveWhisperTarget()
    if activeTarget then
        return activeTarget
    end
    if type(ChatEdit_GetLastTellTarget) == "function" then
        local ok, target = pcall(ChatEdit_GetLastTellTarget)
        if ok and target and target ~= "" then
            return target
        end
    end
    local globalTarget = _G.LAST_TELL_TARGET
    if globalTarget and globalTarget ~= "" then
        return globalTarget
    end
    return nil
end

local function shareChannelLabel(def, target)
    if def.chatType == "WHISPER" and target and target ~= "" then
        return string.format("%s: %s", tostring(def.label or "Reply"), tostring(target))
    end
    return def.label
end

local function resolveShareChannelTarget(def)
    if def.chatType == "WHISPER" then
        return getLastTellTarget()
    end
    return def.target
end

local function resolveShareChannel(input)
    local text = normalizeShareInput(input)
    local def = findShareChannelByAlias(text)
    if def then
        local target = resolveShareChannelTarget(def)
        local channelDef = {
            input = def.input,
            label = shareChannelLabel(def, target),
            chatType = def.chatType,
            target = target,
        }
        local reason = shareChannelUnavailableReason(channelDef)
        if reason then return nil, reason end
        return channelDef
    end

    return nil, "Usage: /rr share [guild|party|raid|say|reply]"
end

local function buildAvailableShareChannels()
    local options = {}
    for _, def in ipairs(SHARE_CHANNELS) do
        local target = resolveShareChannelTarget(def)
        local channelDef = {
            input = def.input,
            label = shareChannelLabel(def, target),
            chatType = def.chatType,
            target = target,
        }
        if not shareChannelUnavailableReason(channelDef) then
            options[#options + 1] = {
                input = channelDef.input,
                label = channelDef.label,
                chatType = channelDef.chatType,
                target = channelDef.target,
            }
        end
    end
    return options
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

-- Shift-click routing for an item link. HandleModifiedItemClick is WoW's
-- canonical entry point that dispatches the link to whatever currently
-- has focus: chat edit boxes, the auction house search field, dressing
-- room, profession windows, etc. Falls back to ChatEdit_InsertLink only
-- if the routing helper is unavailable (very old clients).
local function insertLinkInChat(link)
    if not link then return false end
    if type(HandleModifiedItemClick) == "function" then
        local ok = HandleModifiedItemClick(link)
        if ok then return true end
    end
    if type(ChatEdit_InsertLink) == "function" then
        local ok = ChatEdit_InsertLink(link)
        return ok and true or false
    end
    return false
end

local function createStatCard(parent, label, width)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetSize(width, 44)
    -- Subtle backdrop with a barely-there border so the cards read as
    -- passive info panels rather than clickable buttons. The full
    -- COLOR_BORDER alpha gave them a button-y outline; dropping it to
    -- ~0.15 keeps the visual grouping without the affordance.
    createBackdrop(card, 0.075, 0.075, 0.075, 0.85, COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], 0.15)

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

local function setTextIfChanged(region, value)
    if not region then return end
    value = value or ""
    if region._rrText == value then return end
    region._rrText = value
    region:SetText(value)
end

local function setTextureIfChanged(region, value)
    if region._rrTexture == value then return end
    region._rrTexture = value
    region:SetTexture(value)
end

local function setVertexColorIfChanged(region, r, g, b, a)
    a = a == nil and 1 or a
    local key = string.format("%.4f|%.4f|%.4f|%.4f", r or 0, g or 0, b or 0, a)
    if region._rrVertexColor == key then return end
    region._rrVertexColor = key
    region:SetVertexColor(r or 0, g or 0, b or 0, a)
end

local function setShownIfChanged(frame, shouldShow)
    if not frame then return end
    shouldShow = shouldShow and true or false
    if frame._rrShown == shouldShow then return end
    frame._rrShown = shouldShow
    if shouldShow then
        frame:Show()
    else
        frame:Hide()
    end
end

local function setBackdropColorsIfChanged(frame, bgR, bgG, bgB, bgA, borderR, borderG, borderB, borderA)
    local bgKey = string.format("%.4f|%.4f|%.4f|%.4f", bgR or 0, bgG or 0, bgB or 0, bgA or 0)
    if frame._rrBackdropBg ~= bgKey then
        frame._rrBackdropBg = bgKey
        frame:SetBackdropColor(bgR, bgG, bgB, bgA)
    end
    local borderKey = string.format("%.4f|%.4f|%.4f|%.4f", borderR or 0, borderG or 0, borderB or 0, borderA or 0)
    if frame._rrBackdropBorder ~= borderKey then
        frame._rrBackdropBorder = borderKey
        frame:SetBackdropBorderColor(borderR, borderG, borderB, borderA)
    end
end

local function setFavoriteButtonState(button, isFavorite)
    if not button or not button.icon then return end
    setTextureIfChanged(button.icon, FAVORITE_ICON)
    button.icon:SetTexCoord(0, 1, 0, 1)
    if isFavorite then
        setVertexColorIfChanged(button.icon, 1.0, 1.0, 1.0, 1)
    else
        setVertexColorIfChanged(button.icon, 0.34, 0.40, 0.55, 0.95)
    end
end

function UI:OnInitialize()
    self.selectedProfession = Addon.db and Addon.db.profile and Addon.db.profile.selectedProfession or nil
    if ADDON_STATUS_LEGACY_VIEWS[self.selectedProfession] then
        self.selectedProfession = ADDON_STATUS_VIEW
    end
    self.addonStatusSortKey = ADDON_STATUS_DEFAULT_SORT
    self.addonStatusSortDir = "asc"
    self.addonStatusFilters = {
        status = "all",
        roster = "all",
        version = "all",
    }
    self.sortMode = (Addon.db and Addon.db.profile and Addon.db.profile.sortMode) or "alpha"
    self.searchMode = (Addon.db and Addon.db.profile and (Addon.db.profile.defaultSearchMode or Addon.db.profile.searchMode)) or "recipe"
    if self.searchMode ~= "materials" then
        self.searchMode = "recipe"
    end
    self.selectedRecipeKey = nil
    self.selectedCategory = nil
    self.expandedCategory = nil
    self.recipeSearchText = ""
    self.addonStatusSearchText = ""
    self.searchText = ""
end

function UI:IsAddonStatusView()
    return self.selectedProfession == ADDON_STATUS_VIEW
end

function UI:GetMainView()
    if self:IsAddonStatusView() then
        return "addon"
    end
    return "recipes"
end

function UI:SetMainView(view)
    if self.IsExternalView and self:IsExternalView() then
        -- Clear any external tab selection when the user explicitly
        -- switches back to a built-in view.
        local externalId = self:GetExternalTabId()
        local externalSpec = externalId and self:GetExternalTabSpec(externalId) or nil
        local panel = externalId and self:GetExternalTabPanel(externalId) or nil
        if externalSpec and externalSpec.onDeselect and panel then
            pcall(externalSpec.onDeselect, panel)
        end
        self.selectedProfession = nil
    end
    if view == "addon" then
        self.selectedProfession = ADDON_STATUS_VIEW
    else
        if self.selectedProfession == ADDON_STATUS_VIEW then
            self.selectedProfession = nil
        end
    end
    self:ActivateSearchForCurrentView()
    if Addon.db and Addon.db.profile then
        Addon.db.profile.selectedProfession = self.selectedProfession
    end
    self.selectedRecipeKey = nil
    self.selectedAddonStatusKey = nil
    self.selectedCategory = nil
    self.expandedCategory = nil
    self:ApplyMainLayout()
    self:Refresh()
end

function UI:GetAddonStatusFilter(columnKey)
    self.addonStatusFilters = self.addonStatusFilters or {}
    return self.addonStatusFilters[columnKey] or "all"
end

function UI:CycleAddonStatusFilter(columnKey)
    local cycle = ADDON_STATUS_FILTER_CYCLES[columnKey]
    if not cycle then
        self:SetAddonStatusSort(columnKey)
        return
    end
    self.addonStatusFilters = self.addonStatusFilters or {}
    local current = self.addonStatusFilters[columnKey] or "all"
    local nextIndex = 1
    for index, value in ipairs(cycle) do
        if value == current then
            nextIndex = index + 1
            break
        end
    end
    if nextIndex > #cycle then
        nextIndex = 1
    end
    self.addonStatusFilters[columnKey] = cycle[nextIndex]
    self.selectedAddonStatusKey = nil
    self:ResetRecipeScroll()
    self:RefreshRecipeList()
    self:RefreshSummaryCards()
end

function UI:SetAddonStatusSort(columnKey)
    columnKey = columnKey or ADDON_STATUS_DEFAULT_SORT
    if self.addonStatusSortKey == columnKey then
        self.addonStatusSortDir = self.addonStatusSortDir == "asc" and "desc" or "asc"
    else
        self.addonStatusSortKey = columnKey
        self.addonStatusSortDir = columnKey == "lastSeen" and "desc" or "asc"
    end
    self.selectedAddonStatusKey = nil
    self:ResetRecipeScroll()
    self:RefreshRecipeList()
    self:RefreshSummaryCards()
end

function UI:HandleAddonStatusHeaderClick(columnKey, mouseButton)
    if mouseButton == "RightButton" then
        self:CycleAddonStatusFilter(columnKey)
    else
        self:SetAddonStatusSort(columnKey)
    end
end

function UI:ResetRecipeScroll()
    local scroll = self.frame and self.frame.recipeScroll
    if scroll and scroll.SetVerticalScroll then
        scroll:SetVerticalScroll(0)
    end
    self:InvalidateRecipeWindowCache()
end

local function getMainFrameProfile()
    if not (Addon.db and Addon.db.profile) then return nil end
    local profile = Addon.db.profile
    if type(profile.mainFrame) ~= "table" then
        profile.mainFrame = {}
    end
    return profile.mainFrame
end

function UI:ClearSearchFocus()
    if not self.frame then return end
    local searchBox = self.frame.searchBox
    if searchBox and searchBox.HasFocus and searchBox:HasFocus() then
        searchBox:ClearFocus()
    end
    searchBox = self.frame.addonStatusSearchBox
    if searchBox and searchBox.HasFocus and searchBox:HasFocus() then
        searchBox:ClearFocus()
    end
end

function UI:CancelSearchTimer()
    if self._searchTimer then
        Addon:CancelTimer(self._searchTimer, true)
        self._searchTimer = nil
    end
end

function UI:ActivateSearchForCurrentView()
    if self:IsAddonStatusView() then
        self.searchText = self.addonStatusSearchText or ""
    else
        self.searchText = self.recipeSearchText or ""
    end
    return self.searchText
end

function UI:RefreshSearchClearButtons()
    if not self.frame then return end
    setShownIfChanged(self.frame.searchClearButton, (self.recipeSearchText or "") ~= "")
    setShownIfChanged(self.frame.addonStatusSearchClearButton, (self.addonStatusSearchText or "") ~= "")
end

function UI:SetSearchBoxValue(box, text)
    if not box then return end
    text = text or ""
    if box.GetText and box:GetText() == text then return end
    self._syncingSearchBoxes = true
    box:SetText(text)
    self._syncingSearchBoxes = nil
end

function UI:SyncSearchControls()
    if not self.frame then return end
    self:SetSearchBoxValue(self.frame.searchBox, self.recipeSearchText or "")
    self:SetSearchBoxValue(self.frame.addonStatusSearchBox, self.addonStatusSearchText or "")
    self:RefreshSearchClearButtons()
end

function UI:ScheduleSearchRefresh()
    self:CancelSearchTimer()
    local delay = SEARCH_DEBOUNCE
    if self.selectedProfession == nil and self.searchText ~= "" then
        delay = GLOBAL_SEARCH_DEBOUNCE
    end
    self._searchTimer = Addon:ScheduleTimer(function()
        UI._searchTimer = nil
        if not UI.frame or not UI.frame:IsShown() then return end
        UI:RefreshRecipeList()
        UI:RefreshDetailPanel()
        UI:RefreshSummaryCards()
    end, delay)
end

function UI:ApplySearchNow()
    self:CancelSearchTimer()
    if not (self.frame and self.frame:IsShown()) then return end
    self:RefreshRecipeList()
    self:RefreshDetailPanel()
    self:RefreshSummaryCards()
end

function UI:OpenChatAfterSearch()
    if ChatFrame_OpenChat then
        ChatFrame_OpenChat("")
    elseif DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox then
        DEFAULT_CHAT_FRAME.editBox:Show()
        DEFAULT_CHAT_FRAME.editBox:SetFocus()
    end
end

function UI:ClearSearch()
    if self:IsAddonStatusView() then
        self.addonStatusSearchText = ""
    else
        self.recipeSearchText = ""
    end
    self:ActivateSearchForCurrentView()
    self.selectedAddonStatusKey = nil
    self:CancelSearchTimer()
    self:ResetRecipeScroll()
    self:SyncSearchControls()
    self:ClearSearchFocus()
    self:CancelSearchTimer()
end

function UI:CloseShareMenus()
    local frame = self.frame
    if self._shareMenuOpen and type(CloseDropDownMenus) == "function" then
        CloseDropDownMenus()
    end
    if frame and frame.shareMenuFrame and frame.shareMenuFrame.Hide then
        frame.shareMenuFrame:Hide()
    end
    if frame and frame.fallbackShareMenu and frame.fallbackShareMenu.Hide then
        frame.fallbackShareMenu:Hide()
    end
    if frame and frame.shareMenuClickCatcher and frame.shareMenuClickCatcher.Hide then
        frame.shareMenuClickCatcher:Hide()
    end
    self._shareMenuOpen = false
end

function UI:ShowShareMenuClickCatcher()
    local catcher = self.frame and self.frame.shareMenuClickCatcher
    if catcher and catcher.Show then
        catcher:Show()
    end
end

function UI:HideShareMenuClickCatcher()
    local catcher = self.frame and self.frame.shareMenuClickCatcher
    if catcher and catcher.Hide then
        catcher:Hide()
    end
end

function UI:HandleFrameHidden()
    self:CloseShareMenus()
    self:ClearSearch()
end

function UI:SaveFramePlacement()
    local f = self.frame
    local settings = getMainFrameProfile()
    if not (f and settings) then return end

    local point, _, relativePoint, x, y = f:GetPoint(1)
    settings.point = point or "CENTER"
    settings.relativePoint = relativePoint or settings.point
    settings.x = x or 0
    settings.y = y or 0
    settings.width = f:GetWidth() or settings.width or 1200
    settings.height = f:GetHeight() or settings.height or 750
end

function UI:RestoreFramePlacement()
    local f = self.frame
    if not f then return end
    local settings = getMainFrameProfile()
    local width = settings and tonumber(settings.width) or 1200
    local height = settings and tonumber(settings.height) or 750
    f:SetSize(math.max(1000, width or 1200), math.max(620, height or 750))
    f:ClearAllPoints()
    local point = settings and settings.point
    local relativePoint = settings and settings.relativePoint
    if VALID_FRAME_POINTS[point] and VALID_FRAME_POINTS[relativePoint or point] then
        f:SetPoint(point, UIParent, relativePoint or point, settings.x or 0, settings.y or 0)
    else
        f:SetPoint("CENTER")
    end
end

function UI:Close(reason)
    self:CloseShareMenus()
    self:ClearSearchFocus()
    self:CancelSearchTimer()
    if self.frame and self.frame:IsShown() then
        self.frame:Hide()
    end
end

local function buildRefreshPlan(reasons)
    local plan = {
        status = false,
        professions = false,
        list = false,
        detail = false,
        visibleRows = false,
    }

    if not reasons or next(reasons) == nil then
        plan.status = true
        plan.professions = true
        plan.list = true
        plan.detail = true
        plan.visibleRows = true
        return plan
    end

    for reason in pairs(reasons) do
        if reason == "queue" then
            plan.status = true
        elseif reason == "addon-status" then
            plan.status = true
            plan.list = true
            plan.detail = true
        elseif reason == "roster" then
            plan.status = true
            plan.list = true
            plan.detail = true
        elseif reason == "item-cache" then
            plan.visibleRows = true
            plan.detail = true
        elseif reason == "detect-professions" then
            plan.professions = true
            plan.status = true
        else
            plan.status = true
            plan.professions = true
            plan.list = true
            plan.detail = true
            plan.visibleRows = true
        end
    end

    if plan.list then
        plan.detail = true
    end

    return plan
end

function UI:GetDegradedModeReason()
    if not Addon.Data then
        return "data-unavailable"
    end
    local hasCachedData = false
    for memberKey, entry in pairs(Addon.Data:GetMembersDB() or {}) do
        if Addon.Data:IsUserVisibleMember(memberKey, entry, true) and next(entry.professions or {}) ~= nil then
            hasCachedData = true
            break
        end
    end
    if Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseHeavyUI() then
        if not hasCachedData then
            return "sensitive-context"
        end
    end
    if Addon.Sync and Addon.Sync.IsInWarmup and Addon.Sync:IsInWarmup() then
        if not hasCachedData then
            return "warmup"
        end
    end
    if Addon.Sync and Addon.Sync.IsInWorldTransition and Addon.Sync:IsInWorldTransition() then
        return "world-transition"
    end
    if not (self.frame and self.frame.recipeRows and self.frame.detailLines) then
        return "frame-not-ready"
    end
    return nil
end

function UI:IsHeavyRefreshAllowed()
    return self:GetDegradedModeReason() == nil
end

function UI:MarkFullRefreshPending(reason)
    self.fullRefreshPending = true
    self.fullRefreshPendingReason = reason or self.fullRefreshPendingReason or "pending"
    if Addon.Sync and Addon.Sync.telemetry then
        Addon.Sync.telemetry.transitionDeferredUI = (Addon.Sync.telemetry.transitionDeferredUI or 0) + 1
    end
end

function UI:RefreshDegradedStatus(reason)
    if not self.frame then return end
    reason = tostring(reason or "sync-pending")
    self.currentRecipeRows = {}
    self.currentDetail = nil
    self.selectedRecipeKey = nil
    setTextIfChanged(self.frame.recipeHeader, "Status only while Recipe Registry stabilizes")
    for index = 1, #(self.frame.recipeRows or {}) do
        setShownIfChanged(self.frame.recipeRows[index], false)
    end
    if self.frame.recipeContent and self.frame.recipeContent.SetHeight then
        self.frame.recipeContent:SetHeight(1)
    end
    setTextIfChanged(self.frame.detailTitle, "Recipe details")
    setTextIfChanged(self.frame.detailSub, "Heavy UI refresh is deferred until sync becomes stable.")
    self:RenderDetailLines({
        string.format("Status-only mode active: %s.", reason:gsub("%-", " ")),
        "The full recipe list and detail panel will resume automatically.",
    }, {}, {})
    self:RefreshSummaryCards()
end

function UI:TryResumeFullRefresh()
    if not self.fullRefreshPending then
        return false
    end
    if not self:IsHeavyRefreshAllowed() then
        return false
    end
    self.fullRefreshPending = false
    self.fullRefreshPendingReason = nil
    Addon:RequestRefresh("resume-full-refresh")
    return true
end

function UI:RefreshMainTabs()
    if not (self.frame and self.frame.mainTabs) then return end
    local currentView = self:GetMainView()
    local externalView = self.IsExternalView and self:IsExternalView()
    for viewName, button in pairs(self.frame.mainTabs) do
        if type(viewName) == "string"
            and viewName:sub(1, #(self.EXTERNAL_VIEW_PREFIX or "ext:")) == (self.EXTERNAL_VIEW_PREFIX or "ext:") then
            -- External tab buttons are refreshed by RefreshExternalTabButtons.
        else
            button:SetSelected(not externalView and viewName == currentView)
        end
    end
    if self.RefreshExternalTabButtons then
        self:RefreshExternalTabButtons()
    end
end

function UI:RefreshAddonStatusControls()
    if not self.frame then return end
    local f = self.frame
    local addonStatusView = self:IsAddonStatusView()
    setShownIfChanged(f.addonStatusControls, addonStatusView)
    setShownIfChanged(f.addonStatusHelp, addonStatusView)
    setShownIfChanged(f.recipeHeader, not addonStatusView)
    setShownIfChanged(f.sortSwitch, not addonStatusView)
    self:SyncSearchControls()
end

function UI:ApplyMainLayout()
    if not self.frame then return end
    local f = self.frame
    if not (f.left and f.center and f.right) then return end

    f.left:ClearAllPoints()
    f.left:SetPoint("TOPLEFT", 10, -154)
    f.left:SetPoint("BOTTOMLEFT", 10, 34)
    f.left:SetWidth(240)

    f.center:ClearAllPoints()
    f.right:ClearAllPoints()
    local externalView = self.IsExternalView and self:IsExternalView()
    if externalView then
        setShownIfChanged(f.topBand, false)
        setShownIfChanged(f.left, false)
        setShownIfChanged(f.center, false)
        setShownIfChanged(f.right, false)
        if self.ApplyExternalTabLayout then
            self:ApplyExternalTabLayout()
        end
        self:RefreshAddonStatusControls()
        self:InvalidateRecipeWindowCache()
        return
    end
    -- Hide any external tab panel that might still be visible from a
    -- previous selection. Built-in views (recipes / addon) own the
    -- centre area themselves.
    if self.ApplyExternalTabLayout then
        self:ApplyExternalTabLayout()
    end
    setShownIfChanged(f.center, true)
    if self:IsAddonStatusView() then
        setShownIfChanged(f.topBand, false)
        setShownIfChanged(f.left, false)
        f.center:SetPoint("TOPLEFT", 10, -94)
        f.center:SetPoint("BOTTOMRIGHT", -10, 34)
        setShownIfChanged(f.right, false)
        if f.recipeScroll then
            f.recipeScroll:ClearAllPoints()
            f.recipeScroll:SetPoint("TOPLEFT", 8, -58)
            f.recipeScroll:SetPoint("BOTTOMRIGHT", -28, 10)
        end
    else
        setShownIfChanged(f.topBand, true)
        setShownIfChanged(f.left, true)
        f.center:SetPoint("TOPLEFT", f.left, "TOPRIGHT", 10, 0)
        f.center:SetPoint("BOTTOMLEFT", f.left, "BOTTOMRIGHT", 10, 0)
        f.center:SetWidth(360)
        f.right:SetPoint("TOPLEFT", f.center, "TOPRIGHT", 10, 0)
        f.right:SetPoint("TOPRIGHT", -10, -154)
        f.right:SetPoint("BOTTOMRIGHT", -10, 34)
        setShownIfChanged(f.right, true)
        if f.recipeScroll then
            -- Drop the cached anchor-mode so _SetRecipeScrollAnchor below
            -- actually re-applies the points (the cache short-circuits
            -- when mode already matches, but ApplyMainLayout's previous
            -- inline SetPoint had blown the anchor out from under it).
            f.recipeScroll._rrAnchorMode = nil
            local hint = f.hiddenExpansionHint
            self:_SetRecipeScrollAnchor(hint and hint:IsShown() == true)
        end
    end
    self:RefreshAddonStatusControls()
    self:InvalidateRecipeWindowCache()
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
    local function startMoving()
        UI:ClearSearchFocus()
        f:StartMoving()
    end
    local function stopMoving()
        f:StopMovingOrSizing()
        UI:SaveFramePlacement()
    end
    f:SetScript("OnDragStart", startMoving)
    f:SetScript("OnDragStop", stopMoving)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(1000, 620)
    elseif f.SetMinResize then
        f:SetMinResize(1000, 620)
    end
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    createBackdrop(f, COLOR_BG[1], COLOR_BG[2], COLOR_BG[3], COLOR_BG[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])

    local shareMenuClickCatcher = CreateFrame("Frame", nil, UIParent)
    shareMenuClickCatcher:SetAllPoints(UIParent)
    shareMenuClickCatcher:EnableMouse(true)
    if shareMenuClickCatcher.SetFrameStrata then
        shareMenuClickCatcher:SetFrameStrata("DIALOG")
    end
    if shareMenuClickCatcher.SetFrameLevel then
        shareMenuClickCatcher:SetFrameLevel(0)
    end
    shareMenuClickCatcher:SetScript("OnMouseDown", function()
        UI:CloseShareMenus()
    end)
    shareMenuClickCatcher:Hide()
    f.shareMenuClickCatcher = shareMenuClickCatcher

    self.frame = f
    self:RestoreFramePlacement()
    f:Hide()
    f:SetScript("OnHide", function()
        UI:HandleFrameHidden()
    end)
    table.insert(UISpecialFrames, "RecipeRegistryFrame")

    local function clearSearchFocus()
        if f.searchBox and f.searchBox.HasFocus and f.searchBox:HasFocus() then
            f.searchBox:ClearFocus()
        end
    end

    local function hookFocusRelease(frame)
        local previous = frame:GetScript("OnMouseDown")
        frame:SetScript("OnMouseDown", function(self, ...)
            clearSearchFocus()
            if previous then
                previous(self, ...)
            end
        end)
    end

    hookFocusRelease(f)

    local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    titleBar:SetPoint("TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", -1, -1)
    titleBar:SetHeight(46)
    createBackdrop(titleBar, COLOR_TITLE_BG[1], COLOR_TITLE_BG[2], COLOR_TITLE_BG[3], COLOR_TITLE_BG[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", startMoving)
    titleBar:SetScript("OnDragStop", stopMoving)
    hookFocusRelease(titleBar)

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
        UI:Close("button")
    end)

    local cleanup = createAddonStyleButton(titleBar, "Roster Cleanup", 112, 22)
    cleanup:SetPoint("RIGHT", close, "LEFT", -12, 0)
    cleanup:SetScript("OnClick", function()
        if not (Addon.GuildLifecycleMaintenance and Addon.GuildLifecycleMaintenance.StartManualCleanup) then
            Addon:Print("Guild cleanup is not available.")
            return
        end
        local started, reason = Addon.GuildLifecycleMaintenance:StartManualCleanup()
        if started then
            Addon:Print("Guild roster cleanup started in background.")
        elseif reason == "already-running" then
            Addon:Print("Guild roster cleanup is already running.")
        elseif reason == "roster-empty" or reason == "roster-too-small" then
            Addon:Print("Guild roster cleanup skipped: roster data looks incomplete. Try again after the guild roster updates.")
        else
            Addon:Print("Guild roster cleanup could not start.")
        end
    end)
    f.cleanupButton = cleanup

    local syncDot = titleBar:CreateTexture(nil, "OVERLAY")
    syncDot:SetSize(10, 10)
    syncDot:SetPoint("RIGHT", cleanup, "LEFT", -10, 0)
    syncDot:SetTexture("Interface\\Buttons\\WHITE8x8")
    syncDot:SetVertexColor(0.2, 0.9, 0.2, 1)
    f.syncDot = syncDot

    local autoLabel = titleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    autoLabel:SetPoint("RIGHT", syncDot, "LEFT", -8, 0)
    autoLabel:SetText("Sync")
    autoLabel:SetTextColor(0.7, 0.9, 0.7)
    f.autoLabel = autoLabel

    local mainNav = CreateFrame("Frame", nil, f)
    mainNav:SetPoint("TOPLEFT", 10, -58)
    mainNav:SetPoint("TOPRIGHT", -10, -58)
    mainNav:SetHeight(28)
    f.mainNav = mainNav
    hookFocusRelease(mainNav)

    local recipesTab = createCardStyleButton(mainNav, 112, 24)
    recipesTab:SetPoint("LEFT", 0, 0)
    recipesTab:SetLabel("Recipes")
    recipesTab:SetScript("OnClick", function()
        UI:SetMainView("recipes")
    end)

    local addonStatusTab = createCardStyleButton(mainNav, 132, 24)
    addonStatusTab:SetPoint("LEFT", recipesTab, "RIGHT", 8, 0)
    addonStatusTab:SetLabel(ADDON_STATUS_VIEW)
    addonStatusTab:SetScript("OnClick", function()
        UI:SetMainView("addon")
    end)
    f.mainTabs = {
        recipes = recipesTab,
        addon = addonStatusTab,
    }

    if self.RealizeExternalTabs then
        self:RealizeExternalTabs(mainNav, addonStatusTab)
    end

    local topBand = CreateFrame("Frame", nil, f)
    topBand:SetPoint("TOPLEFT", 10, -94)
    topBand:SetPoint("TOPRIGHT", -10, -94)
    topBand:SetHeight(52)
    f.topBand = topBand
    hookFocusRelease(topBand)

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
    left:SetPoint("TOPLEFT", 10, -154)
    left:SetPoint("BOTTOMLEFT", 10, 34)
    left:SetWidth(240)
    createBackdrop(left, COLOR_PANEL[1], COLOR_PANEL[2], COLOR_PANEL[3], COLOR_PANEL[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])
    f.left = left
    hookFocusRelease(left)

    local searchLabel = left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", 12, -12)
    searchLabel:SetText("Search")

    local searchBox = CreateFrame("EditBox", nil, left, "InputBoxTemplate")
    searchBox:SetPoint("TOPLEFT", 10, -30)
    searchBox:SetPoint("TOPRIGHT", -10, -30)
    searchBox:SetHeight(24)
    searchBox:SetAutoFocus(false)
    -- Right inset reserves space for the clear-button overlay below.
    searchBox:SetTextInsets(6, 22, 0, 0)
    searchBox:SetScript("OnEscapePressed", function()
        UI:ClearSearchFocus()
    end)
    searchBox:SetScript("OnEnterPressed", function()
        UI:ApplySearchNow()
        UI:ClearSearchFocus()
        UI:OpenChatAfterSearch()
    end)
    f.searchBox = searchBox

    -- Small ✕ clear button overlaid on the right edge of the search box.
    -- Only visible when there's text to clear.
    local clearButton = CreateFrame("Button", nil, searchBox)
    clearButton:SetSize(14, 14)
    clearButton:SetPoint("RIGHT", -4, 0)
    clearButton:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    if clearButton.GetNormalTexture then
        local tex = clearButton:GetNormalTexture()
        if tex and tex.SetVertexColor then
            tex:SetVertexColor(0.85, 0.85, 0.85, 0.85)
        end
    end
    clearButton:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    clearButton:Hide()
    clearButton:SetScript("OnClick", function()
        UI:ClearSearch()
        UI:RefreshRecipeList()
        UI:RefreshDetailPanel()
        UI:RefreshSummaryCards()
    end)
    f.searchClearButton = clearButton

    searchBox:SetScript("OnTextChanged", function(box)
        if UI._syncingSearchBoxes then return end
        UI.recipeSearchText = box:GetText() or ""
        UI.searchText = UI.recipeSearchText
        UI.selectedRecipeKey = nil
        UI.selectedAddonStatusKey = nil
        UI:ResetRecipeScroll()
        UI:SyncSearchControls()
        UI:ScheduleSearchRefresh()
    end)

    local searchFocusWatcher = CreateFrame("Frame", nil, f)
    searchFocusWatcher:Hide()
    -- Polled at ~5 Hz: just needs to catch "user clicked outside the frame
    -- to defocus the search box". 20 Hz was overkill — no perceptible UX
    -- difference at 200ms but 4x less work while the box is focused.
    searchFocusWatcher:SetScript("OnUpdate", function(self, elapsed)
        self._elapsed = (self._elapsed or 0) + (elapsed or 0)
        if self._elapsed < 0.2 then return end
        self._elapsed = 0
        if not (f.searchBox and f.searchBox.HasFocus and f.searchBox:HasFocus()) then
            self._mouseDown = nil
            self:Hide()
            return
        end
        local mouseDown = IsMouseButtonDown and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton"))
        if mouseDown and not self._mouseDown and MouseIsOver and not MouseIsOver(f) then
            UI:ClearSearchFocus()
            self:Hide()
        end
        self._mouseDown = mouseDown and true or false
    end)
    searchBox:SetScript("OnEditFocusGained", function()
        searchFocusWatcher._mouseDown = nil
        searchFocusWatcher._elapsed = 0
        searchFocusWatcher:Show()
    end)
    searchBox:SetScript("OnEditFocusLost", function()
        searchFocusWatcher._mouseDown = nil
        searchFocusWatcher._elapsed = 0
        searchFocusWatcher:Hide()
    end)
    f.searchFocusWatcher = searchFocusWatcher

    local searchScopeLabel = left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchScopeLabel:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 2, -12)
    searchScopeLabel:SetText("Search scope")
    f.searchScopeLabel = searchScopeLabel

    local searchRecipes, searchMaterials
    searchRecipes = createCardStyleButton(left, 103, 24)
    searchRecipes:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -30)
    searchRecipes:SetLabel("Recipes")
    searchRecipes:SetScript("OnClick", function()
        UI.searchMode = "recipe"
        UI.selectedRecipeKey = nil
        searchRecipes:SetSelected(true)
        searchMaterials:SetSelected(false)
        UI:ApplySearchNow()
    end)
    f.searchRecipes = searchRecipes

    searchMaterials = createCardStyleButton(left, 107, 24)
    searchMaterials:SetPoint("LEFT", searchRecipes, "RIGHT", 6, 0)
    searchMaterials:SetLabel("+ Materials")
    searchMaterials:SetScript("OnClick", function()
        UI.searchMode = "materials"
        UI.selectedRecipeKey = nil
        searchRecipes:SetSelected(false)
        searchMaterials:SetSelected(true)
        UI:ApplySearchNow()
    end)
    f.searchMaterials = searchMaterials

    local profLabel = left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profLabel:SetPoint("TOPLEFT", searchRecipes, "BOTTOMLEFT", 2, -14)
    profLabel:SetText("Profession filter")
    f.profLabel = profLabel

    local profScroll = CreateFrame("ScrollFrame", nil, left, "UIPanelScrollFrameTemplate")
    profScroll:SetPoint("TOPLEFT", profLabel, "BOTTOMLEFT", -2, -8)
    profScroll:SetPoint("BOTTOMRIGHT", -28, 58)
    -- profScroll uses UIPanelScrollFrameTemplate which renders a ~16-20px
    -- scrollbar inside its right edge. Sizing profContent at 196 leaves the
    -- scrollbar an unobstructed lane and avoids clipping button right edges.
    local profContent = CreateFrame("Frame", nil, profScroll)
    profContent:SetSize(196, 1)
    profScroll:SetScrollChild(profContent)
    f.profScroll = profScroll
    f.profContent = profContent

    f.profButtons = {}
    f.categoryButtons = {}
    for i, profName in ipairs(PROF_ORDER) do
        local b = createCardStyleButton(profContent, 192, 24)
        b:SetPoint("TOPLEFT", 0, -((i - 1) * 30))
        b:SetScript("OnClick", function()
            if UI.selectedProfession == profName then
                UI.selectedProfession = nil
            else
                UI.selectedProfession = profName
            end
            if Addon.db and Addon.db.profile then Addon.db.profile.selectedProfession = UI.selectedProfession end
            UI.selectedRecipeKey = nil
            UI.selectedAddonStatusKey = nil
            UI.selectedCategory = nil
            UI.expandedCategory = nil
            UI:Refresh()
        end)
        f.profButtons[profName] = b
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
    hookFocusRelease(center)

    -- Single segmented switch replaces the two side-by-side sort buttons.
    -- The original layout let the header text overlap the buttons whenever
    -- the header string grew (e.g., "Status only while Recipe Registry
    -- stabilizes"). The switch is narrower and the header is now bounded
    -- on its right edge so the two never collide.
    local sortSwitch = createCardStyleButton(center, 130, 24)
    sortSwitch:SetPoint("TOPRIGHT", -8, -8)
    sortSwitch:SetLabel("Sort: Alphabetical")
    sortSwitch:SetScript("OnClick", function()
        UI.sortMode = (UI.sortMode == "alpha") and "rarity" or "alpha"
        if Addon.db and Addon.db.profile then Addon.db.profile.sortMode = UI.sortMode end
        UI:Refresh()
    end)
    f.sortSwitch = sortSwitch

    local recipeHeader = center:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    recipeHeader:SetPoint("TOPLEFT", 12, -12)
    recipeHeader:SetPoint("TOPRIGHT", sortSwitch, "TOPLEFT", -10, -4)
    recipeHeader:SetJustifyH("LEFT")
    if recipeHeader.SetWordWrap then
        recipeHeader:SetWordWrap(false)
    end
    if recipeHeader.SetMaxLines then
        recipeHeader:SetMaxLines(1)
    end
    recipeHeader:SetText("Recipes")
    f.recipeHeader = recipeHeader

    local addonStatusControls = CreateFrame("Frame", nil, center)
    addonStatusControls:SetPoint("TOPLEFT", 8, -8)
    addonStatusControls:SetPoint("TOPRIGHT", -8, -8)
    addonStatusControls:SetHeight(26)
    f.addonStatusControls = addonStatusControls

    local addonStatusTitle = addonStatusControls:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    addonStatusTitle:SetPoint("LEFT", 4, 0)
    addonStatusTitle:SetText(ADDON_STATUS_VIEW)
    addonStatusTitle:SetTextColor(1.0, 0.82, 0)
    f.addonStatusTitle = addonStatusTitle

    local addonStatusHelp = center:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    addonStatusHelp:SetPoint("TOPLEFT", addonStatusControls, "BOTTOMLEFT", 4, -6)
    addonStatusHelp:SetPoint("TOPRIGHT", addonStatusControls, "BOTTOMRIGHT", -4, -6)
    addonStatusHelp:SetJustifyH("LEFT")
    addonStatusHelp:SetText("Left-click column headers to sort; right-click headers marked [F] to filter.")
    addonStatusHelp:SetTextColor(0.66, 0.66, 0.66)
    f.addonStatusHelp = addonStatusHelp

    local addonStatusSearchBox = CreateFrame("EditBox", nil, addonStatusControls, "InputBoxTemplate")
    addonStatusSearchBox:SetPoint("RIGHT", 0, 0)
    addonStatusSearchBox:SetSize(230, 24)
    addonStatusSearchBox:SetAutoFocus(false)
    addonStatusSearchBox:SetTextInsets(6, 22, 0, 0)
    addonStatusSearchBox:SetScript("OnEscapePressed", function()
        UI:ClearSearchFocus()
    end)
    addonStatusSearchBox:SetScript("OnEnterPressed", function()
        UI:ApplySearchNow()
        UI:ClearSearchFocus()
        UI:OpenChatAfterSearch()
    end)
    addonStatusSearchBox:SetScript("OnTextChanged", function(box)
        if UI._syncingSearchBoxes then return end
        UI.addonStatusSearchText = box:GetText() or ""
        UI.searchText = UI.addonStatusSearchText
        UI.selectedRecipeKey = nil
        UI.selectedAddonStatusKey = nil
        UI:ResetRecipeScroll()
        UI:SyncSearchControls()
        UI:ScheduleSearchRefresh()
    end)
    f.addonStatusSearchBox = addonStatusSearchBox

    local addonStatusSearchLabel = addonStatusControls:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    addonStatusSearchLabel:SetPoint("RIGHT", addonStatusSearchBox, "LEFT", -8, 0)
    addonStatusSearchLabel:SetText("Search")
    addonStatusSearchLabel:SetTextColor(0.72, 0.72, 0.72)
    f.addonStatusSearchLabel = addonStatusSearchLabel

    local addonStatusSearchClearButton = CreateFrame("Button", nil, addonStatusSearchBox)
    addonStatusSearchClearButton:SetSize(14, 14)
    addonStatusSearchClearButton:SetPoint("RIGHT", -4, 0)
    addonStatusSearchClearButton:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    if addonStatusSearchClearButton.GetNormalTexture then
        local tex = addonStatusSearchClearButton:GetNormalTexture()
        if tex and tex.SetVertexColor then
            tex:SetVertexColor(0.85, 0.85, 0.85, 0.85)
        end
    end
    addonStatusSearchClearButton:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    addonStatusSearchClearButton:Hide()
    addonStatusSearchClearButton:SetScript("OnClick", function()
        UI:ClearSearch()
        UI:RefreshRecipeList()
        UI:RefreshSummaryCards()
    end)
    f.addonStatusSearchClearButton = addonStatusSearchClearButton

    -- Discoverability hint: when a profession's view is restricted by the
    -- expansion filter, surface a one-click "N <expansion> recipes hidden"
    -- button so the user doesn't have to dive into the options panel to
    -- realise material is being filtered. Sits in the strip between the
    -- header and the recipe list; hidden when not applicable.
    local hiddenExpansionHint = CreateFrame("Button", nil, center)
    -- y=-42 leaves ~12px of breathing room below the Sort button row
    -- (sortSwitch bottoms out around y=-30); the scroll's hint-shown
    -- anchor below puts another ~10px between the hint and the first
    -- recipe row.
    hiddenExpansionHint:SetPoint("TOPLEFT", 12, -42)
    hiddenExpansionHint:SetPoint("TOPRIGHT", -28, -42)
    hiddenExpansionHint:SetHeight(20)
    -- Sibling recipeScroll (created right after) inherits a higher frame
    -- level by default, so its row children render in FRONT of the hint
    -- when their y range overlaps. Bump the hint a few levels above the
    -- centre frame so it stays on top within the same strata (changing
    -- strata on a non-toplevel child can detach it from the parent).
    hiddenExpansionHint:SetFrameLevel((center.GetFrameLevel and center:GetFrameLevel() or 1) + 10)
    hiddenExpansionHint:Hide()
    -- Faint background panel so the hint reads as an actionable strip
    -- rather than blending into the centre frame backdrop.
    local hintBg = hiddenExpansionHint:CreateTexture(nil, "BACKGROUND")
    hintBg:SetAllPoints(true)
    hintBg:SetColorTexture(0.95, 0.75, 0.20, 0.12)
    hiddenExpansionHint.bg = hintBg
    local hintHighlight = hiddenExpansionHint:CreateTexture(nil, "HIGHLIGHT")
    hintHighlight:SetAllPoints(true)
    hintHighlight:SetColorTexture(0.95, 0.75, 0.20, 0.22)
    local hiddenExpansionHintText = hiddenExpansionHint:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hiddenExpansionHintText:SetPoint("LEFT", 6, 0)
    hiddenExpansionHintText:SetPoint("RIGHT", -6, 0)
    hiddenExpansionHintText:SetJustifyH("LEFT")
    hiddenExpansionHintText:SetTextColor(1.0, 0.82, 0.0)
    hiddenExpansionHint.text = hiddenExpansionHintText
    hiddenExpansionHint:SetScript("OnClick", function()
        UI:UnhideCurrentProfessionExpansion()
    end)
    f.hiddenExpansionHint = hiddenExpansionHint

    local recipeScroll = CreateFrame("ScrollFrame", nil, center, "UIPanelScrollFrameTemplate")
    recipeScroll:SetPoint("TOPLEFT", 8, -60)
    recipeScroll:SetPoint("BOTTOMRIGHT", -28, 10)
    -- WoW Classic's UIPanelScrollFrameTemplate doesn't clip children to
    -- the scroll's visible bounds. Without this, scrolling the list
    -- pushes row frames above the scroll's TOPLEFT (into the hint
    -- band) where they paint over the discoverability hint and any
    -- other UI above. Force clipping so rows disappear cleanly at
    -- the top edge of the scroll viewport.
    if recipeScroll.SetClipsChildren then
        recipeScroll:SetClipsChildren(true)
    end
    local recipeContent = CreateFrame("Frame", nil, recipeScroll)
    recipeContent:SetSize(320, 1)
    recipeScroll:SetScrollChild(recipeContent)
    f.recipeScroll = recipeScroll
    f.recipeContent = recipeContent
    -- Pool of recycled row frames. Index = pool slot, not recipe-list index.
    -- The pool grows on demand to (visible rows + buffer); rebinding happens
    -- per scroll tick via UI:RenderVisibleRecipeRows.
    f.recipeRows = {}
    recipeScroll:HookScript("OnVerticalScroll", function()
        UI:RenderVisibleRecipeRows()
    end)
    recipeScroll:HookScript("OnSizeChanged", function()
        UI:RenderVisibleRecipeRows()
    end)

    local right = CreateFrame("Frame", nil, f, "BackdropTemplate")
    right:SetPoint("TOPLEFT", center, "TOPRIGHT", 10, 0)
    right:SetPoint("TOPRIGHT", -10, -154)
    right:SetPoint("BOTTOMRIGHT", -10, 34)
    createBackdrop(right, COLOR_PANEL[1], COLOR_PANEL[2], COLOR_PANEL[3], COLOR_PANEL[4], COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4])
    f.right = right
    hookFocusRelease(right)

    local detailTitle = right:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    detailTitle:SetPoint("TOPLEFT", 12, -12)
    detailTitle:SetPoint("TOPRIGHT", -132, -12)
    detailTitle:SetJustifyH("LEFT")
    if detailTitle.SetWordWrap then
        detailTitle:SetWordWrap(false)
    end
    if detailTitle.SetMaxLines then
        detailTitle:SetMaxLines(1)
    end
    detailTitle:SetText("Recipe details")
    f.detailTitle = detailTitle

    local detailFavoriteButton = CreateFrame("Button", nil, right)
    detailFavoriteButton:SetSize(18, 18)
    detailFavoriteButton:SetPoint("TOPRIGHT", -14, -12)
    detailFavoriteButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    detailFavoriteButton.icon = detailFavoriteButton:CreateTexture(nil, "ARTWORK")
    detailFavoriteButton.icon:SetAllPoints()
    detailFavoriteButton:SetScript("OnClick", function(self, button)
        if button ~= "LeftButton" then return end
        if not self.recipeKey then return end
        UI.selectedRecipeKey = self.recipeKey
        UI:ToggleFavorite(self.recipeKey)
    end)
    detailFavoriteButton:SetScript("OnEnter", function(self)
        if not self.recipeKey then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:AddLine(self.isFavorite and "Remove from favorites" or "Add to favorites")
        GameTooltip:Show()
    end)
    detailFavoriteButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    f.detailFavoriteButton = detailFavoriteButton

    local detailShareButton = CreateFrame("Button", nil, right, "BackdropTemplate")
    detailShareButton:SetSize(68, 18)
    detailShareButton:SetPoint("TOPRIGHT", detailFavoriteButton, "TOPLEFT", -8, 0)
    if detailShareButton.SetBackdrop then
        detailShareButton:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        detailShareButton:SetBackdropColor(0.13, 0.11, 0.08, 0.95)
        detailShareButton:SetBackdropBorderColor(1, 0.82, 0, 0.75)
    end
    detailShareButton.label = detailShareButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detailShareButton.label:SetPoint("LEFT", 6, 0)
    detailShareButton.label:SetPoint("RIGHT", -18, 0)
    detailShareButton.label:SetJustifyH("CENTER")
    detailShareButton.label:SetText("Share")
    detailShareButton.label:SetTextColor(1.0, 0.92, 0.75)
    detailShareButton.menuArrow = detailShareButton:CreateTexture(nil, "ARTWORK")
    detailShareButton.menuArrow:SetSize(12, 12)
    detailShareButton.menuArrow:SetPoint("RIGHT", -6, 0)
    detailShareButton.menuArrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    if detailShareButton.menuArrow.SetVertexColor then
        detailShareButton.menuArrow:SetVertexColor(1.0, 0.82, 0, 1)
    end
    detailShareButton:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    local shareHi = detailShareButton:GetHighlightTexture()
    if shareHi and shareHi.SetVertexColor then
        shareHi:SetVertexColor(1, 0.82, 0, 0.18)
    end
    detailShareButton:SetScript("OnMouseDown", function(self)
        releaseSearchFocus()
        if self.SetBackdropColor then
            self:SetBackdropColor(0.10, 0.09, 0.07, 1)
        end
    end)
    detailShareButton:SetScript("OnMouseUp", function(self)
        if self.SetBackdropColor then
            self:SetBackdropColor(0.13, 0.11, 0.08, 0.95)
        end
    end)
    detailShareButton:SetScript("OnClick", function(self, button)
        if button ~= "LeftButton" then return end
        UI:OpenShareMenu(self)
    end)
    detailShareButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        if UI.selectedRecipeKey then
            GameTooltip:AddLine("Share recipe")
            GameTooltip:AddLine("Choose a chat channel.", 0.8, 0.8, 0.8)
        else
            GameTooltip:AddLine("No recipe selected")
        end
        GameTooltip:Show()
    end)
    detailShareButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    f.detailShareButton = detailShareButton

    local shareMenuFrame = CreateFrame("Frame", "RecipeRegistryShareMenu", right, "UIDropDownMenuTemplate")
    shareMenuFrame:Hide()
    f.shareMenuFrame = shareMenuFrame

    local detailTitleButton = CreateFrame("Button", nil, right)
    detailTitleButton:SetPoint("TOPLEFT", 10, -10)
    detailTitleButton:SetPoint("TOPRIGHT", detailShareButton, "TOPLEFT", -10, 0)
    detailTitleButton:SetHeight(18)
    detailTitleButton:SetScript("OnClick", function(_, button)
        if button ~= "LeftButton" or not IsShiftKeyDown() then return end
        local detail = UI.currentDetail
        if not detail then return end
        local link = getItemLinkByID(detail.createdItemID)
            or getItemLinkByID(detail.recipeItemID)
            or (detail.spellID and GetSpellLink and GetSpellLink(detail.spellID))
        insertLinkInChat(link)
    end)
    detailTitleButton:SetScript("OnEnter", function(self)
        local detail = UI.currentDetail
        if not detail then return end
        local hasLink = false
        if detail.createdItemID then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetHyperlink("item:" .. detail.createdItemID)
            hasLink = true
        elseif detail.spellID then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
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
    hookFocusRelease(footer)

    local footerText = footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footerText:SetPoint("LEFT", 12, 0)
    footerText:SetText("Left-click the minimap button to open the directory.")
    footerText:SetTextColor(0.70, 0.70, 0.70)
    footerText:SetJustifyH("LEFT")
    f.footerText = footerText

    local debugPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
    debugPanel:SetPoint("TOPRIGHT", -10, -118)
    debugPanel:SetSize(290, 120)
    createBackdrop(debugPanel, 0.03, 0.03, 0.03, 0.95, 0.65, 0.55, 0.18, 0.95)
    debugPanel:Hide()
    f.debugPanel = debugPanel

    local debugTitle = debugPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    debugTitle:SetPoint("TOPLEFT", 10, -10)
    debugTitle:SetText("Performance Debug")
    f.debugTitle = debugTitle

    local debugText = debugPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    debugText:SetPoint("TOPLEFT", debugTitle, "BOTTOMLEFT", 0, -8)
    debugText:SetPoint("TOPRIGHT", -10, -10)
    debugText:SetJustifyH("LEFT")
    debugText:SetJustifyV("TOP")
    debugText:SetSpacing(2)
    if debugText.SetWordWrap then
        debugText:SetWordWrap(true)
    end
    debugText:SetText("")
    f.debugText = debugText

    local debugReset = createButton(debugPanel, "Reset", 64, 18)
    debugReset:SetPoint("BOTTOMRIGHT", -10, 8)
    debugReset:SetScript("OnClick", function()
        Addon:SlashHandler("perf reset")
    end)
    f.debugReset = debugReset

    local debugDump = createButton(debugPanel, "Dump", 64, 18)
    debugDump:SetPoint("RIGHT", debugReset, "LEFT", -6, 0)
    debugDump:SetScript("OnClick", function()
        Addon:SlashHandler("perf dump")
    end)
    f.debugDump = debugDump

    self.frame = f
    self:ApplyMainLayout()
    self:RefreshDebugVisibility()
end

function UI:EnsureCategoryButton(index)
    local button = self.frame.categoryButtons[index]
    if button then return button end

    button = createCardStyleButton(self.frame.profContent, 198, 20)
    button:SetScript("OnClick", function(self)
        -- In accordion view a top-level category button also toggles its
        -- subcategory group. `toggleExpandKey` is set per-render only for
        -- those buttons; it's nil for "All", flat categories, and subcategories.
        if self.toggleExpandKey then
            if UI.expandedCategory == self.toggleExpandKey then
                UI.expandedCategory = nil
            else
                UI.expandedCategory = self.toggleExpandKey
            end
        end
        UI.selectedCategory = self.categoryToken
        UI.selectedRecipeKey = nil
        UI:Refresh()
    end)
    self.frame.categoryButtons[index] = button
    return button
end

function UI:EnsureRecipeRow(index)
    local row = self.frame.recipeRows[index]
    if row then return row end

    row = CreateFrame("Button", nil, self.frame.recipeContent, "BackdropTemplate")
    row:SetSize(314, 70)
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
    title:SetPoint("TOPRIGHT", -40, -1)
    title:SetJustifyH("LEFT")
    if title.SetWordWrap then
        title:SetWordWrap(false)
    end
    if title.SetMaxLines then
        title:SetMaxLines(1)
    end
    row.title = title

    local stats = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    stats:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    stats:SetPoint("TOPRIGHT", -40, -22)
    stats:SetJustifyH("LEFT")
    stats:SetTextColor(0.82, 0.82, 0.82)
    row.stats = stats

    local meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    meta:SetPoint("TOPLEFT", stats, "BOTTOMLEFT", 0, -4)
    meta:SetPoint("TOPRIGHT", -40, -42)
    meta:SetJustifyH("LEFT")
    if meta.SetWordWrap then
        meta:SetWordWrap(false)
    end
    if meta.SetMaxLines then
        meta:SetMaxLines(1)
    end
    row.meta = meta

    local favoriteButton = CreateFrame("Button", nil, row)
    favoriteButton:SetSize(20, 20)
    favoriteButton:SetPoint("RIGHT", -10, 0)
    favoriteButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    favoriteButton.icon = favoriteButton:CreateTexture(nil, "ARTWORK")
    favoriteButton.icon:SetAllPoints()
    favoriteButton:SetScript("OnClick", function(self, button)
        if button ~= "LeftButton" then return end
        if not UI.selectedRecipeKey or UI.selectedRecipeKey ~= self.recipeKey then
            UI.selectedRecipeKey = self.recipeKey
        end
        UI:ToggleFavorite(self.recipeKey)
    end)
    favoriteButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:AddLine(self.isFavorite and "Remove from favorites" or "Add to favorites")
        GameTooltip:Show()
    end)
    favoriteButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row.favoriteButton = favoriteButton
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row:SetScript("OnClick", function(self, button)
        if self.addonStatusHeaderRow then
            return
        end
        if self.addonStatusGroupKey then
            return
        end
        if self.addonStatusMemberKey then
            return
        end
        if not self.recipeKey then
            return
        end
        if button == "RightButton" then
            UI:ToggleFavorite(self.recipeKey)
        else
            UI.selectedRecipeKey = self.recipeKey
            UI:RefreshRecipeList()
            UI:RefreshDetailPanel()
        end
    end)
    row:SetScript("OnEnter", function(self)
        if self.addonStatusMemberKey then return end
        if not self.tooltipLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(self.tooltipLink)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    self.frame.recipeRows[index] = row
    return row
end

function UI:EnsureDetailLine(index)
    local line = self.frame.detailLines[index]
    if line then return line end
    line = CreateFrame("Button", nil, self.frame.detailContent)
    line:SetSize(420, 22)
    line.text = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    line.text:SetPoint("TOPLEFT", 0, 0)
    line.text:SetPoint("TOPRIGHT", -4, 0)
    line.text:SetJustifyH("LEFT")
    line.text:SetSpacing(2)
    if line.text.SetWordWrap then
        line.text:SetWordWrap(true)
    end

    -- Compact text button matching the addon's gold/dark theme. The
    -- previous icon-only square (a 16x16 tinted FriendsList chat sprite)
    -- read as visual noise rather than an obvious action affordance —
    -- the user reported it as "proprio brutto". This version reads as
    -- a real button: dark fill, gold edge, "Ask" label, hover lift.
    line.actionButton = CreateFrame("Button", nil, line, "BackdropTemplate")
    line.actionButton:SetSize(36, 16)
    line.actionButton:SetPoint("RIGHT", -2, 0)
    if line.actionButton.SetBackdrop then
        line.actionButton:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        line.actionButton:SetBackdropColor(0.13, 0.11, 0.08, 0.95)
        line.actionButton:SetBackdropBorderColor(1, 0.82, 0, 0.75)
    end
    line.actionButton.label = line.actionButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.actionButton.label:SetPoint("LEFT", 2, 0)
    line.actionButton.label:SetPoint("RIGHT", -2, 0)
    line.actionButton.label:SetJustifyH("CENTER")
    line.actionButton.label:SetText("Ask")
    line.actionButton.label:SetTextColor(1.0, 0.92, 0.75)
    line.actionButton:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    local hi = line.actionButton:GetHighlightTexture()
    if hi and hi.SetVertexColor then
        hi:SetVertexColor(1, 0.82, 0, 0.18)
    end
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

function UI:IsFavorite(recipeKey)
    if not Addon.charDB or not Addon.charDB.favorites then
        return false
    end
    return Addon.charDB.favorites[tostring(recipeKey)] or false
end

function UI:ToggleFavorite(recipeKey)
    if not Addon.charDB then return end
    if not Addon.charDB.favorites then
        Addon.charDB.favorites = {}
    end
    local key = tostring(recipeKey)
    if Addon.charDB.favorites[key] then
        Addon.charDB.favorites[key] = nil
    else
        Addon.charDB.favorites[key] = true
    end
    UI:RefreshRecipeList()
    UI:RefreshDetailPanel()
end

function UI:GetAvailableShareChannels()
    return buildAvailableShareChannels()
end

function UI:OpenFallbackShareMenu(anchor, menu)
    if type(CreateFrame) ~= "function" then
        return false
    end
    local frame = self.frame
    local parent = (frame and frame.right) or UIParent
    if not parent then
        return false
    end

    local popup = frame and frame.fallbackShareMenu
    if not popup then
        popup = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        createBackdrop(popup, 0.04, 0.04, 0.04, 0.98, 0.42, 0.34, 0.16, 0.95)
        popup.rows = {}
        if popup.SetFrameStrata then popup:SetFrameStrata("DIALOG") end
        if popup.SetFrameLevel then
            local catcher = frame and frame.shareMenuClickCatcher
            local level = catcher and catcher.GetFrameLevel and catcher:GetFrameLevel() or 0
            popup:SetFrameLevel(level + 1)
        end
        if popup.SetClampedToScreen then popup:SetClampedToScreen(true) end
        if frame then
            frame.fallbackShareMenu = popup
        end
    end

    local width = 150
    local rowHeight = 20
    for index, item in ipairs(menu) do
        local row = popup.rows[index]
        if not row then
            row = createButton(popup, "", width - 8, rowHeight)
            popup.rows[index] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 4, -4 - ((index - 1) * (rowHeight + 2)))
        row:SetPoint("TOPRIGHT", -4, -4 - ((index - 1) * (rowHeight + 2)))
        row:SetHeight(rowHeight)
        row:SetText(item.text)
        local func = item.func
        row:SetScript("OnClick", function()
            popup:Hide()
            if func then func() end
        end)
        row:Show()
    end
    for index = #menu + 1, #(popup.rows or {}) do
        popup.rows[index]:Hide()
    end

    popup:SetSize(width, (#menu * (rowHeight + 2)) + 6)
    popup:ClearAllPoints()
    if anchor then
        popup:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
    else
        popup:SetPoint("CENTER", parent, "CENTER", 0, 0)
    end
    popup:Show()
    return true
end

function UI:OpenShareMenu(anchor)
    self:CloseShareMenus()
    if not self.selectedRecipeKey then
        Addon:Print("No recipe selected.")
        return
    end
    local channels = self:GetAvailableShareChannels()
    if #channels == 0 then
        Addon:Print("No available chat channels.")
        return
    end

    local menu = {}
    for _, channel in ipairs(channels) do
        local input = channel.input
        local label = channel.label
        menu[#menu + 1] = {
            text = label,
            notCheckable = true,
            func = function()
                UI:CloseShareMenus()
                UI:ShareSelectedRecipe(input)
            end,
        }
    end

    local menuFrame = self.frame and self.frame.shareMenuFrame
    if menuFrame
        and type(UIDropDownMenu_Initialize) == "function"
        and type(UIDropDownMenu_CreateInfo) == "function"
        and type(UIDropDownMenu_AddButton) == "function"
        and type(ToggleDropDownMenu) == "function" then
        self:ShowShareMenuClickCatcher()
        UIDropDownMenu_Initialize(menuFrame, function(_, level)
            if level and level > 1 then return end
            for _, item in ipairs(menu) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = item.text
                info.notCheckable = true
                info.func = item.func
                UIDropDownMenu_AddButton(info, level or 1)
            end
        end, "MENU")
        ToggleDropDownMenu(1, nil, menuFrame, anchor, 0, 0)
        self._shareMenuOpen = true
        return
    end

    if type(EasyMenu) == "function" then
        self:ShowShareMenuClickCatcher()
        EasyMenu(menu, menuFrame or anchor, anchor, 0, 0, "MENU", 2)
        self._shareMenuOpen = true
        return
    end

    self:ShowShareMenuClickCatcher()
    if self:OpenFallbackShareMenu(anchor, menu) then
        self._shareMenuOpen = true
        return
    end
    self:HideShareMenuClickCatcher()

    Addon:Print("Share menu is not available.")
end

function UI:RefreshStatusBar()
    local sync = Addon.Sync
    local state = sync and sync.GetUiState and sync:GetUiState() or nil
    local statusSnapshot = Addon.Data and Addon.Data.GetUiStatusSnapshot and Addon.Data:GetUiStatusSnapshot(false) or {
        members = 0,
        updatedAt = 0,
    }
    local degradedReason = self:GetDegradedModeReason()
    local cleanupRunning = Addon.GuildLifecycleMaintenance and Addon.GuildLifecycleMaintenance.IsCleanupRunning
        and Addon.GuildLifecycleMaintenance:IsCleanupRunning() or false

    local members = statusSnapshot.members or 0

    local onlineNodes = state and state.onlineNodes or 0
    local queued = state and state.queued or 0
    local inFlight = state and state.inFlight
    local paused = state and state.paused or false
    local subtitle
    if self:IsAddonStatusView() then
        local summary = self.currentAddonStatusSummary
        if not summary and Addon.Data and Addon.Data.GetGuildAddonStatusRows then
            local _, fetchedSummary = Addon.Data:GetGuildAddonStatusRows({
                searchText = self.searchText,
                staleAfterDays = 30,
            })
            summary = fetchedSummary
        end
        summary = summary or {}
        local counts = summary.statusCounts or {}
        subtitle = string.format(
            "%s • %d roster member(s) • %d using Recipe Registry now • refreshed %s",
            ADDON_STATUS_VIEW,
            summary.rosterTotal or 0,
            counts.online_with_addon or 0,
            ageText(summary.lastRosterRefreshAt)
        )
    else
        subtitle = string.format(
            "Automatic sync • %d guild addon node(s) • %d known crafter(s)",
            onlineNodes,
            members
        )
    end
    if inFlight then
        subtitle = subtitle .. string.format(" • syncing %s", tostring(inFlight))
    elseif queued and queued > 0 then
        subtitle = subtitle .. string.format(" • %d update(s) queued", queued)
    end
    if paused then
        subtitle = subtitle .. " | paused"
    end
    if cleanupRunning then
        subtitle = subtitle .. " | roster cleanup running"
    end
    if degradedReason then
        subtitle = subtitle .. " | status only: " .. degradedReason:gsub("%-", " ")
    end
    setTextIfChanged(self.frame.subtitle, subtitle)

    -- Until local sync state stabilizes (warmup / world transition / sensitive
    -- context) we deliberately don't go green even when peers are online —
    -- green should mean "we're ready and have peers", not just "peers exist".
    if degradedReason then
        setVertexColorIfChanged(self.frame.syncDot, 1.0, 0.82, 0.0, 1)
        self.frame.autoLabel:SetTextColor(1.0, 0.9, 0.45)
    elseif onlineNodes > 1 then
        setVertexColorIfChanged(self.frame.syncDot, 0.2, 0.9, 0.2, 1)
        self.frame.autoLabel:SetTextColor(0.7, 0.95, 0.7)
    elseif onlineNodes == 1 then
        setVertexColorIfChanged(self.frame.syncDot, 1.0, 0.82, 0.0, 1)
        self.frame.autoLabel:SetTextColor(1.0, 0.9, 0.45)
    else
        setVertexColorIfChanged(self.frame.syncDot, 0.75, 0.2, 0.2, 1)
        self.frame.autoLabel:SetTextColor(1.0, 0.75, 0.75)
    end

    if paused then
        setVertexColorIfChanged(self.frame.syncDot, 0.75, 0.2, 0.2, 1)
        self.frame.autoLabel:SetTextColor(1.0, 0.75, 0.75)
    end

    setTextIfChanged(self.frame.cards.members.value, tostring(members))
    setTextIfChanged(self.frame.cards.members.text, "Known crafters")
    setTextIfChanged(self.frame.cards.network.value, string.format("%d / %d", onlineNodes, state and state.registry or 0))
    setTextIfChanged(self.frame.cards.network.text, "Guild addon nodes")
    setTextIfChanged(self.frame.cards.updated.value, ageText(statusSnapshot.updatedAt))
    setTextIfChanged(self.frame.cards.updated.text, "Last recipe update")
    if self.frame.cleanupButton then
        self.frame.cleanupButton:SetText(cleanupRunning and "Cleaning..." or "Roster Cleanup")
        if cleanupRunning then
            self.frame.cleanupButton:Disable()
        else
            self.frame.cleanupButton:Enable()
        end
    end
    self:RefreshMainTabs()
    self:RefreshDebugPanel()
end

function UI:RefreshDebugVisibility()
    if not (self.frame and self.frame.debugPanel) then return end
    if Addon.perfDebugMode then
        self.frame.debugPanel:Show()
        self:RefreshDebugPanel()
    else
        self.frame.debugPanel:Hide()
    end
end

function UI:RefreshDebugPanel()
    if not (self.frame and self.frame.debugPanel and Addon.perfDebugMode) then return end

    local perf = Addon.Performance and Addon.Performance.GetDebugSnapshot and Addon.Performance:GetDebugSnapshot() or nil
    local sync = Addon.Sync and Addon.Sync.GetDebugSnapshot and Addon.Sync:GetDebugSnapshot() or nil
    local bootstrap = Addon.BootstrapSync and Addon.BootstrapSync.GetUiState and Addon.BootstrapSync:GetUiState() or nil
    local mock = Addon.MockSync and Addon.MockSync.GetDebugSnapshot and Addon.MockSync:GetDebugSnapshot() or nil

    local perfTelemetry = perf and perf.telemetry or {}
    local syncTelemetry = sync and sync.telemetry or {}
    local mockTelemetry = mock and mock.telemetry or {}
    local queueLengths = perf and perf.queueLengths or {}
    local queueParts = {}
    for category, size in pairs(queueLengths or {}) do
        if size and size > 0 then
            queueParts[#queueParts + 1] = string.format("%s:%d", tostring(category), tonumber(size) or 0)
        end
    end
    table.sort(queueParts)

    local lines = {
        string.format("Scheduler avg/max: %.2f / %.2f ms", perfTelemetry.averageStepCostMs or 0, perfTelemetry.maxStepCostMs or 0),
        string.format("Steps: %d  Over budget: %d", perfTelemetry.jobSteps or 0, perfTelemetry.overBudgetSteps or 0),
        string.format("UI marks/flushes: %d / %d", perfTelemetry.uiRefreshMarks or 0, perfTelemetry.uiRefreshFlushes or 0),
        string.format("UI refresh last/max: %.2f / %.2f ms", perfTelemetry.uiRefreshLastMs or 0, perfTelemetry.uiRefreshMaxMs or 0),
        string.format("Outbound sent: %d  Inbound recv/applied: %d / %d", syncTelemetry.sentChunks or 0, syncTelemetry.receivedChunks or 0, syncTelemetry.appliedChunks or 0),
        string.format("Queues req/out/in/final: %d / %d / %d / %d", sync and sync.pendingRequests or 0, sync and sync.outboundChunks or 0, sync and sync.inboundChunks or 0, sync and sync.inboundFinalize or 0),
        string.format("Paused cycles: %d  Eq skips: %d", syncTelemetry.pausedSyncCycles or 0, syncTelemetry.skippedEquivalentMerges or 0),
        string.format("Bootstrap: %s", bootstrap and (bootstrap.inProgress and "running" or (bootstrap.canBootstrap and "available" or (bootstrap.completed and "done" or "not-needed"))) or "n/a"),
        string.format("Mock: %s iso=%s pending=%d delivered=%d", mock and (mock.active and (mock.scenarioName or "running") or "idle") or "n/a", tostring(mock and mock.hardIsolation or false), mock and mock.pendingPayloads or 0, mockTelemetry.payloadsDelivered or 0),
        string.format("Worker queues: %s", #queueParts > 0 and table.concat(queueParts, ", ") or "idle"),
    }
    setTextIfChanged(self.frame.debugText, table.concat(lines, "\n"))
end

function UI:RefreshSummaryCards()
    if self:IsAddonStatusView() then
        local summary = self.currentAddonStatusSummary
        if not summary and Addon.Data and Addon.Data.GetGuildAddonStatusRows then
            local _, fetchedSummary = Addon.Data:GetGuildAddonStatusRows({
                searchText = self.searchText,
                staleAfterDays = 30,
            })
            summary = fetchedSummary
        end
        summary = summary or {}
        local counts = summary.statusCounts or {}
        local seenWithAddon = (counts.online_with_addon or 0)
            + (counts.seen_before or 0)
            + (counts.not_seen_recently or 0)
        setTextIfChanged(self.frame.cards.members.value, tostring(summary.rosterTotal or 0))
        setTextIfChanged(self.frame.cards.members.text, "Roster members")
        if self.searchText and self.searchText ~= "" or (summary.filteredRows and summary.filteredRows ~= summary.shownRows) then
            setTextIfChanged(self.frame.cards.recipes.value, tostring(summary.filteredRows or summary.shownRows or 0))
            setTextIfChanged(self.frame.cards.recipes.text, "Matching members")
        else
            setTextIfChanged(self.frame.cards.recipes.value, tostring(seenWithAddon))
            setTextIfChanged(self.frame.cards.recipes.text, "Seen with addon")
        end
        setTextIfChanged(self.frame.cards.network.value, tostring(counts.online_with_addon or 0))
        setTextIfChanged(self.frame.cards.network.text, "Using addon now")
        setTextIfChanged(self.frame.cards.updated.value, ageText(summary.lastRosterRefreshAt))
        setTextIfChanged(self.frame.cards.updated.text, "Roster refresh")
        return
    end
    local shown = self.currentRecipeRows and #self.currentRecipeRows or 0
    setTextIfChanged(self.frame.cards.recipes.value, tostring(shown))
    local label
    if self.selectedProfession == "Favorites" then
        label = "Favorites shown"
    elseif self.selectedProfession then
        label = self.selectedProfession .. " shown"
    elseif self.searchText and self.searchText ~= "" then
        label = "Search results"
    else
        label = "Recipes shown"
    end
    setTextIfChanged(self.frame.cards.recipes.text, label)
end

function UI:RefreshProfessionButtons(opts)
    -- `skipCategories` lets the degraded-mode renderer populate the
    -- profession sidebar without touching category providers during warmup.
    -- After warmup, the normal Refresh path runs with skipCategories=false
    -- and the categories appear.
    local skipCategories = opts and opts.skipCategories or false
    local summary = Addon.Data:GetProfessionSummary()
    local useCategories = (not skipCategories) and Addon.db and Addon.db.profile and Addon.db.profile.useRecipeCategories ~= false
    local yOffset = 0
    local categoryButtonIndex = 0

    if self.frame.searchScopeLabel and self.frame.searchRecipes and self.frame.searchMaterials and self.frame.profLabel then
        setShownIfChanged(self.frame.searchScopeLabel, true)
        setShownIfChanged(self.frame.searchRecipes, true)
        setShownIfChanged(self.frame.searchMaterials, true)
        setShownIfChanged(self.frame.profScroll, true)
        setShownIfChanged(self.frame.sidebarHint, true)
        self.frame.profLabel:ClearAllPoints()
        self.frame.profLabel:SetPoint("TOPLEFT", self.frame.searchRecipes, "BOTTOMLEFT", 2, -14)
        self.frame.profLabel:SetText("Profession filter")
    end

    local function placeButton(button, indent, height, gap)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", indent or 0, -yOffset)
        setShownIfChanged(button, true)
        yOffset = yOffset + (height or 24) + (gap or 6)
    end

    for _, profName in ipairs(PROF_ORDER) do
        local button = self.frame.profButtons[profName]
        button:SetLabel(profName, profName ~= FAVORITES_VIEW and getProfessionIcon(profName) or nil)
        button:SetSelected(self.selectedProfession == profName)

        -- Hide professions whose only expansions are currently filtered away.
        -- Skipped when the filter is permissive (both Vanilla and TBC visible
        -- for the profession): in that case every supported profession stays
        -- in the sidebar. Only fires under a restrictive filter, e.g. JC has
        -- no Vanilla recipes so it disappears in a Vanilla-only view.
        local hideProfession = false
        if profName ~= FAVORITES_VIEW and Addon.RecipeUiFilters and Addon.Data then
            local visibility = Addon.RecipeUiFilters:GetEffectiveExpansionVisibility(profName)
            if visibility and (visibility.vanilla == false or visibility.tbc == false) then
                local expansions = Addon.Data.GetProfessionExpansions
                    and Addon.Data:GetProfessionExpansions(profName)
                    or nil
                if expansions and (expansions.vanilla or expansions.tbc) then
                    local vanillaMatch = visibility.vanilla and expansions.vanilla
                    local tbcMatch = visibility.tbc and expansions.tbc
                    if not vanillaMatch and not tbcMatch then
                        hideProfession = true
                    end
                end
            end
        end

        if hideProfession then
            setShownIfChanged(button, false)
        else
            placeButton(button, 0, 24, 6)
        end

        if not hideProfession and useCategories and self.selectedProfession == profName and profName ~= FAVORITES_VIEW then
            local viewMode = (Addon.db and Addon.db.profile and Addon.db.profile.recipeCategoryView) or "expanded"
            -- Sidebar categories follow the same projection as the recipe list:
            -- only categories with at least one recipe visible under the active
            -- filters are offered. The filter context here mirrors the list's
            -- but carries no categoryFilter (we want the full visible set).
            local sidebarFilterContext = {
                selectedProfession = profName,
                effectiveProfession = profName,
                globalSearch = false,
            }
            local categories = (Addon.Data.GetVisibleRecipeCategories
                    and Addon.Data:GetVisibleRecipeCategories(profName, sidebarFilterContext))
                or (Addon.Data.GetRecipeCategories and Addon.Data:GetRecipeCategories(profName, true))
                or {}

            local selectedCategoryExists = self.selectedCategory == nil
            for _, categoryRow in ipairs(categories) do
                local categoryToken = categoryRow.key or categoryRow
                if categoryToken == self.selectedCategory then
                    selectedCategoryExists = true
                    break
                end
                for _, subcategoryRow in ipairs(categoryRow.subcategories or {}) do
                    local subcategoryToken = "subcategory:" .. tostring(categoryToken) .. ":" .. tostring(subcategoryRow.key)
                    if subcategoryToken == self.selectedCategory then
                        selectedCategoryExists = true
                        break
                    end
                end
                if selectedCategoryExists then break end
            end
            if not selectedCategoryExists then
                self.selectedCategory = nil
            end

            -- Reconcile a subcategory selection with the active view mode so the
            -- user never ends up filtered to a subcategory whose button isn't
            -- rendered: categoriesOnly falls back to the parent category, while
            -- accordion expands the parent so the selection stays visible.
            local selectedSubParent = self.selectedCategory
                and tostring(self.selectedCategory):match("^subcategory:([^:]+):")
            if selectedSubParent then
                if viewMode == "categoriesOnly" then
                    self.selectedCategory = selectedSubParent
                elseif viewMode == "accordion" then
                    self.expandedCategory = selectedSubParent
                end
            end

            if #categories > 0 then
                -- profContent is 196 wide (sized to clear the sidebar's
                -- scrollbar); size each row to fit its indent so subcategory
                -- rows at the deeper indent don't bleed past it.
                local function widthFor(indent) return 196 - indent - 4 end
                categoryButtonIndex = categoryButtonIndex + 1
                local allButton = self:EnsureCategoryButton(categoryButtonIndex)
                allButton.categoryToken = nil
                allButton.toggleExpandKey = nil
                allButton.categoryLabel = "All"
                allButton:SetLabel("All")
                allButton:SetSelected(self.selectedCategory == nil)
                allButton:SetWidth(widthFor(14))
                placeButton(allButton, 14, 20, 4)

                for _, categoryRow in ipairs(categories) do
                    local categoryToken = categoryRow.key or categoryRow
                    local categoryLabel = categoryRow.label or categoryToken
                    local hasSubcategories = categoryRow.subcategories and #categoryRow.subcategories > 0
                    local expanded = viewMode == "accordion" and self.expandedCategory == categoryToken

                    categoryButtonIndex = categoryButtonIndex + 1
                    local categoryButton = self:EnsureCategoryButton(categoryButtonIndex)
                    categoryButton.categoryToken = categoryToken
                    categoryButton.categoryLabel = categoryLabel
                    if viewMode == "accordion" and hasSubcategories then
                        categoryButton.toggleExpandKey = categoryToken
                        local arrow = expanded and "|cff808080v|r " or "|cff808080>|r "
                        categoryButton:SetLabel(arrow .. categoryLabel)
                    else
                        categoryButton.toggleExpandKey = nil
                        categoryButton:SetLabel(categoryLabel)
                    end
                    categoryButton:SetSelected(self.selectedCategory == categoryToken)
                    categoryButton:SetWidth(widthFor(14))
                    placeButton(categoryButton, 14, 20, 4)

                    -- expanded: always show subcategories; accordion: only for the
                    -- expanded category; categoriesOnly: never.
                    local renderSubcategories = hasSubcategories
                        and (viewMode == "expanded" or (viewMode == "accordion" and expanded))
                    if renderSubcategories then
                        for _, subcategoryRow in ipairs(categoryRow.subcategories or {}) do
                            local subcategoryToken = "subcategory:" .. tostring(categoryToken) .. ":" .. tostring(subcategoryRow.key)
                            categoryButtonIndex = categoryButtonIndex + 1
                            local subcategoryButton = self:EnsureCategoryButton(categoryButtonIndex)
                            subcategoryButton.categoryToken = subcategoryToken
                            subcategoryButton.toggleExpandKey = nil
                            subcategoryButton.categoryLabel = subcategoryRow.label or subcategoryRow.key
                            subcategoryButton:SetLabel(subcategoryButton.categoryLabel)
                            subcategoryButton:SetSelected(self.selectedCategory == subcategoryToken)
                            subcategoryButton:SetWidth(widthFor(28))
                            placeButton(subcategoryButton, 28, 18, 3)
                        end
                    end
                end
                yOffset = yOffset + 2
            end
        elseif self.selectedProfession == profName then
            self.selectedCategory = nil
            self.expandedCategory = nil
        end
    end
    for i = categoryButtonIndex + 1, #(self.frame.categoryButtons or {}) do
        setShownIfChanged(self.frame.categoryButtons[i], false)
    end
    if self.frame.profContent then
        self.frame.profContent:SetHeight(math.max(1, yOffset + 4))
    end
    if self.frame.searchRecipes then
        self.frame.searchRecipes:SetSelected(self.searchMode ~= "materials")
    end
    if self.frame.searchMaterials then
        self.frame.searchMaterials:SetSelected(self.searchMode == "materials")
    end
end

function UI:GetCategoryFilterLabel(profession, categoryToken)
    if not categoryToken or not (Addon.Data and Addon.Data.GetRecipeCategories) then
        return nil
    end
    local subcategoryCategory, subcategoryKey = tostring(categoryToken):match("^subcategory:([^:]+):(.+)$")
    for _, categoryRow in ipairs(Addon.Data:GetRecipeCategories(profession, true) or {}) do
        local categoryKey = categoryRow.key or categoryRow
        if subcategoryCategory and categoryKey == subcategoryCategory then
            for _, subcategoryRow in ipairs(categoryRow.subcategories or {}) do
                if subcategoryRow.key == subcategoryKey then
                    return (categoryRow.label or categoryKey) .. " / " .. (subcategoryRow.label or subcategoryKey)
                end
            end
        elseif categoryKey == categoryToken then
            return categoryRow.label or categoryKey
        end
    end
    return tostring(categoryToken)
end

local RECIPE_ROW_HEIGHT = 70
local ADDON_STATUS_ROW_HEIGHT = 28
local RECIPE_ROW_BUFFER = 2

function UI:GetListRowHeight()
    return self:IsAddonStatusView() and ADDON_STATUS_ROW_HEIGHT or RECIPE_ROW_HEIGHT
end

function UI:GetListRowWidth()
    local scroll = self.frame and self.frame.recipeScroll
    local width = scroll and scroll.GetWidth and scroll:GetWidth() or nil
    if type(width) ~= "number" or width <= 0 then
        width = self:IsAddonStatusView() and 860 or 314
    end
    return math.max(300, width - 10)
end

local function getAddonStatusVersionState(row)
    local version = row and row.addonVersion
    if version == nil or version == "" or version == "unknown" or version == "-" then
        return "unknown"
    end
    local compare = Addon.BuildInfo and Addon.BuildInfo.CompareSemver
    local cmp = compare and compare(tostring(version), tostring(Addon.ADDON_VERSION or Addon.DISPLAY_VERSION or ""))
    if cmp == nil then
        return "unknown"
    end
    if cmp < 0 then
        return "old"
    end
    return "current"
end

local function compareAddonStatusRows(a, b, sortKey)
    if sortKey == "status" then
        local av, bv = a.addonStatusOrder or 99, b.addonStatusOrder or 99
        if av ~= bv then return av < bv end
    elseif sortKey == "roster" then
        if (a.online == true) ~= (b.online == true) then
            return a.online == true
        end
    elseif sortKey == "version" then
        local compare = Addon.BuildInfo and Addon.BuildInfo.CompareSemver
        local av, bv = tostring(a.addonVersion or ""), tostring(b.addonVersion or "")
        local cmp = compare and compare(av, bv)
        if cmp ~= nil and cmp ~= 0 then return cmp < 0 end
        if av ~= bv then return av < bv end
    elseif sortKey == "lastSeen" then
        local av, bv = tonumber(a.lastSeenAt or 0) or 0, tonumber(b.lastSeenAt or 0) or 0
        if av ~= bv then return av < bv end
    elseif sortKey == "rank" then
        local av, bv = tostring(a.rankName or ""), tostring(b.rankName or "")
        if av ~= bv then return av < bv end
    elseif sortKey == "zone" then
        local av, bv = tostring(a.zone or ""), tostring(b.zone or "")
        if av ~= bv then return av < bv end
    end
    return tostring(a.memberKey or "") < tostring(b.memberKey or "")
end

function UI:AddonStatusRowPassesHeaderFilters(row)
    local filters = self.addonStatusFilters or {}
    local statusFilter = filters.status or "all"
    if statusFilter ~= "all" and row.addonStatusKey ~= statusFilter then
        return false
    end

    local rosterFilter = filters.roster or "all"
    if rosterFilter == "online" and row.online ~= true then
        return false
    elseif rosterFilter == "offline" and row.online == true then
        return false
    end

    local versionFilter = filters.version or "all"
    if versionFilter ~= "all" and getAddonStatusVersionState(row) ~= versionFilter then
        return false
    end

    return true
end

function UI:GetFilteredSortedAddonStatusRows(rows)
    local out = {}
    for _, row in ipairs(rows or {}) do
        if self:AddonStatusRowPassesHeaderFilters(row) then
            out[#out + 1] = row
        end
    end

    local sortKey = self.addonStatusSortKey or ADDON_STATUS_DEFAULT_SORT
    local descending = self.addonStatusSortDir == "desc"
    table.sort(out, function(a, b)
        if descending then
            return compareAddonStatusRows(b, a, sortKey)
        end
        return compareAddonStatusRows(a, b, sortKey)
    end)
    return out
end

function UI:BuildAddonStatusDisplayRows(rows)
    local out = {
        {
            rowType = "addonStatusTableHeader",
        },
    }
    for _, row in ipairs(self:GetFilteredSortedAddonStatusRows(rows)) do
        out[#out + 1] = row
    end
    return out
end

local function getVisibleRecipeWindow(ui, total)
    if total <= 0 then
        return 1, 0
    end

    local frame = ui and ui.frame
    local scrollFrame = frame and frame.recipeScroll
    local offset = (scrollFrame and scrollFrame.GetVerticalScroll and scrollFrame:GetVerticalScroll()) or 0
    local viewHeight = (scrollFrame and scrollFrame:GetHeight()) or 0
    if viewHeight <= 0 then
        -- Frame hasn't been laid out yet (first paint). Fall back to a
        -- conservative initial window so we don't render nothing.
        viewHeight = 600
    end

    local rowHeight = ui and ui.GetListRowHeight and ui:GetListRowHeight() or RECIPE_ROW_HEIGHT
    local firstIdx = math.max(1, math.floor(offset / rowHeight) + 1 - RECIPE_ROW_BUFFER)
    local lastIdx = math.min(total, math.ceil((offset + viewHeight) / rowHeight) + RECIPE_ROW_BUFFER)
    return firstIdx, lastIdx
end

function UI:EnsureAddonStatusRowParts(row)
    if row.addonStatusPartsReady then return end

    row.addonSectionTitle = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.addonSectionTitle:SetPoint("LEFT", 10, 0)
    row.addonSectionTitle:SetPoint("RIGHT", -10, 0)
    row.addonSectionTitle:SetJustifyH("LEFT")

    row.addonName = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.addonName:SetPoint("LEFT", 12, 0)
    row.addonName:SetWidth(210)
    row.addonName:SetJustifyH("LEFT")

    row.addonStatus = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.addonStatus:SetPoint("LEFT", row.addonName, "RIGHT", 8, 0)
    row.addonStatus:SetWidth(160)
    row.addonStatus:SetJustifyH("LEFT")

    row.addonRoster = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.addonRoster:SetPoint("LEFT", row.addonStatus, "RIGHT", 8, 0)
    row.addonRoster:SetWidth(138)
    row.addonRoster:SetJustifyH("LEFT")

    row.addonVersion = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.addonVersion:SetPoint("LEFT", row.addonRoster, "RIGHT", 8, 0)
    row.addonVersion:SetWidth(94)
    row.addonVersion:SetJustifyH("LEFT")

    row.addonLastSeen = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.addonLastSeen:SetPoint("LEFT", row.addonVersion, "RIGHT", 8, 0)
    row.addonLastSeen:SetWidth(110)
    row.addonLastSeen:SetJustifyH("LEFT")

    row.addonRank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.addonRank:SetPoint("LEFT", row.addonLastSeen, "RIGHT", 8, 0)
    row.addonRank:SetWidth(130)
    row.addonRank:SetJustifyH("LEFT")

    row.addonZone = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.addonZone:SetPoint("LEFT", row.addonRank, "RIGHT", 8, 0)
    row.addonZone:SetWidth(150)
    row.addonZone:SetJustifyH("LEFT")

    row.addonHeaderButtons = {}
    local headerColumns = {
        { key = "name", region = row.addonName },
        { key = "status", region = row.addonStatus },
        { key = "roster", region = row.addonRoster },
        { key = "version", region = row.addonVersion },
        { key = "lastSeen", region = row.addonLastSeen },
        { key = "rank", region = row.addonRank },
        { key = "zone", region = row.addonZone },
    }
    for _, column in ipairs(headerColumns) do
        local button = CreateFrame("Button", nil, row)
        button.addonStatusColumnKey = column.key
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetPoint("TOPLEFT", column.region, "TOPLEFT", -4, 0)
        button:SetPoint("BOTTOMRIGHT", column.region, "BOTTOMRIGHT", 4, 0)
        button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
        button.highlight:SetAllPoints()
        button.highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
        button.highlight:SetVertexColor(1, 1, 1, 0.06)
        button:SetScript("OnClick", function(self, mouseButton)
            UI:HandleAddonStatusHeaderClick(self.addonStatusColumnKey, mouseButton)
        end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:AddLine("Left-click to sort")
            if ADDON_STATUS_FILTER_CYCLES[self.addonStatusColumnKey] then
                GameTooltip:AddLine("Right-click to filter", 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        button:Hide()
        row.addonHeaderButtons[column.key] = button
    end

    row.addonStatusPartsReady = true
end

function UI:SetAddonStatusHeaderButtonsVisible(row, visible)
    self:EnsureAddonStatusRowParts(row)
    for _, button in pairs(row.addonHeaderButtons or {}) do
        setShownIfChanged(button, visible)
    end
end

function UI:SetAddonStatusPartsVisible(row, visible)
    self:EnsureAddonStatusRowParts(row)
    setShownIfChanged(row.addonSectionTitle, visible)
    setShownIfChanged(row.addonName, visible)
    setShownIfChanged(row.addonStatus, visible)
    setShownIfChanged(row.addonRoster, visible)
    setShownIfChanged(row.addonVersion, visible)
    setShownIfChanged(row.addonLastSeen, visible)
    setShownIfChanged(row.addonRank, visible)
    setShownIfChanged(row.addonZone, visible)
end

function UI:HideRecipeRowParts(row)
    setShownIfChanged(row.icon, false)
    setShownIfChanged(row.favoriteButton, false)
    setShownIfChanged(row.title, false)
    setShownIfChanged(row.stats, false)
    setShownIfChanged(row.meta, false)
end

function UI:BindAddonStatusGroupRow(row, rowIdx, rowData)
    local rowHeight = self:GetListRowHeight()
    row:SetPoint("TOPLEFT", 0, -((rowIdx - 1) * rowHeight))
    row:SetSize(self:GetListRowWidth(), rowHeight - 2)
    row.recipeKey = nil
    row.addonStatusMemberKey = nil
    row.addonStatusGroupKey = rowData.groupKey
    row.addonStatusHeaderRow = false
    row.tooltipLink = nil
    self:HideRecipeRowParts(row)
    self:SetAddonStatusPartsVisible(row, false)
    self:SetAddonStatusHeaderButtonsVisible(row, false)
    setShownIfChanged(row.addonSectionTitle, true)

    local arrow = rowData.collapsed and "|cff9fa6b2\226\150\184|r" or "|cff9fa6b2\226\150\190|r"
    setTextIfChanged(row.addonSectionTitle, string.format("%s %s (%d)", arrow, rowData.groupLabel or "Group", rowData.count or 0))
    row.addonSectionTitle:SetTextColor(1.0, 0.82, 0.0)
    setVertexColorIfChanged(row.stripe, 1, 0.82, 0, 1)
    setBackdropColorsIfChanged(row, 0.10, 0.09, 0.07, 0.98, 0.28, 0.24, 0.12, 0.95)
    setShownIfChanged(row, true)
end

function UI:GetAddonStatusHeaderText(columnKey, baseLabel)
    local text = baseLabel
    local filter = self:GetAddonStatusFilter(columnKey)
    if filter ~= "all" then
        text = string.format("%s: %s", baseLabel, ADDON_STATUS_FILTER_LABELS[filter] or filter)
    end
    if (self.addonStatusSortKey or ADDON_STATUS_DEFAULT_SORT) == columnKey then
        text = text .. (self.addonStatusSortDir == "desc" and " v" or " ^")
    end
    if ADDON_STATUS_FILTER_CYCLES[columnKey] then
        text = text .. " " .. ADDON_STATUS_FILTER_MARKER
    end
    return text
end

function UI:BindAddonStatusHeaderRow(row, rowIdx)
    local rowHeight = self:GetListRowHeight()
    row:SetPoint("TOPLEFT", 0, -((rowIdx - 1) * rowHeight))
    row:SetSize(self:GetListRowWidth(), rowHeight - 2)
    row.recipeKey = nil
    row.addonStatusMemberKey = nil
    row.addonStatusGroupKey = nil
    row.addonStatusHeaderRow = true
    row.tooltipLink = nil
    self:HideRecipeRowParts(row)
    self:SetAddonStatusPartsVisible(row, true)
    self:SetAddonStatusHeaderButtonsVisible(row, true)
    setShownIfChanged(row.addonSectionTitle, false)

    setTextIfChanged(row.addonName, self:GetAddonStatusHeaderText("name", "Name"))
    setTextIfChanged(row.addonStatus, self:GetAddonStatusHeaderText("status", "Addon"))
    setTextIfChanged(row.addonRoster, self:GetAddonStatusHeaderText("roster", "Presence"))
    setTextIfChanged(row.addonVersion, self:GetAddonStatusHeaderText("version", "Version"))
    setTextIfChanged(row.addonLastSeen, self:GetAddonStatusHeaderText("lastSeen", "Last seen"))
    setTextIfChanged(row.addonRank, self:GetAddonStatusHeaderText("rank", "Rank"))
    setTextIfChanged(row.addonZone, self:GetAddonStatusHeaderText("zone", "Zone"))
    row.addonName:SetTextColor(0.72, 0.72, 0.72)
    row.addonStatus:SetTextColor(0.72, 0.72, 0.72)
    row.addonRoster:SetTextColor(0.72, 0.72, 0.72)
    row.addonVersion:SetTextColor(0.72, 0.72, 0.72)
    row.addonLastSeen:SetTextColor(0.72, 0.72, 0.72)
    row.addonRank:SetTextColor(0.72, 0.72, 0.72)
    row.addonZone:SetTextColor(0.72, 0.72, 0.72)
    setVertexColorIfChanged(row.stripe, 0.35, 0.35, 0.35, 1)
    setBackdropColorsIfChanged(row, 0.06, 0.06, 0.06, 0.98, 0.20, 0.20, 0.20, 0.95)
    setShownIfChanged(row, true)
end

function UI:BindAddonStatusRow(row, rowIdx, rowData)
    if rowData.rowType == "addonStatusGroup" then
        self:BindAddonStatusGroupRow(row, rowIdx, rowData)
        return
    end
    if rowData.rowType == "addonStatusTableHeader" then
        self:BindAddonStatusHeaderRow(row, rowIdx)
        return
    end
    local rowHeight = self:GetListRowHeight()
    row:SetPoint("TOPLEFT", 0, -((rowIdx - 1) * rowHeight))
    row:SetSize(self:GetListRowWidth(), rowHeight - 2)
    row.recipeKey = nil
    row.addonStatusMemberKey = rowData.memberKey
    row.addonStatusGroupKey = nil
    row.addonStatusHeaderRow = false
    row.tooltipLink = nil
    self:HideRecipeRowParts(row)
    self:SetAddonStatusPartsVisible(row, true)
    self:SetAddonStatusHeaderButtonsVisible(row, false)
    setShownIfChanged(row.addonSectionTitle, false)

    local sr, sg, sb = addonStatusColor(rowData.addonStatusKey)
    setVertexColorIfChanged(row.stripe, sr, sg, sb, 1)

    local titleText = getClassColorizedName(rowData.memberKey)
    if rowData.isLocalPlayer then
        titleText = titleText .. " " .. colorText("(you)", unpackColor(MUTED))
    end
    setTextIfChanged(row.addonName, titleText)
    setTextIfChanged(row.addonStatus, addonStatusLabelColor(rowData))
    setTextIfChanged(row.addonRoster, rowData.online and colorText("Online", 0.35, 0.95, 0.45) or colorText("Offline", 0.85, 0.45, 0.45))
    setTextIfChanged(row.addonVersion, safeText(rowData.addonVersion))
    setTextIfChanged(row.addonLastSeen, rowData.lastSeenAt and rowData.lastSeenAt > 0 and tostring(rowData.lastSeenAgeText or ageText(rowData.lastSeenAt)) or "never")
    setTextIfChanged(row.addonRank, safeText(rowData.rankName))
    setTextIfChanged(row.addonZone, safeText(rowData.zone))
    row.addonName:SetTextColor(getClassColor(rowData.memberKey))
    row.addonStatus:SetTextColor(0.92, 0.92, 0.88)
    row.addonRoster:SetTextColor(0.92, 0.92, 0.88)
    row.addonVersion:SetTextColor(0.82, 0.82, 0.82)
    row.addonLastSeen:SetTextColor(0.82, 0.82, 0.82)
    row.addonRank:SetTextColor(0.82, 0.82, 0.82)
    row.addonZone:SetTextColor(0.82, 0.82, 0.82)
    setBackdropColorsIfChanged(row, COLOR_ROW[1], COLOR_ROW[2], COLOR_ROW[3], COLOR_ROW[4], 0.22, 0.22, 0.22, 1)
    setShownIfChanged(row, true)
end

function UI:RefreshRecipeRowAssets(rowData)
    if not (rowData and rowData.recipeKey and Addon.Data and Addon.Data.GetRecipeDisplayInfo) then
        return rowData
    end
    local detail = Addon.Data:GetRecipeDisplayInfo(rowData.recipeKey) or rowData.detail or {}
    rowData.detail = detail
    rowData.label = (detail and detail.label) or rowData.label or tostring(rowData.recipeKey)
    return rowData
end

function UI:BindRecipeRow(row, recipeIdx, rowData)
    if rowData and (rowData.rowType == "addonStatus"
        or rowData.rowType == "addonStatusGroup"
        or rowData.rowType == "addonStatusTableHeader") then
        self:BindAddonStatusRow(row, recipeIdx, rowData)
        return
    end
    rowData = self:RefreshRecipeRowAssets(rowData) or rowData
    local rowHeight = self:GetListRowHeight()
    row:SetPoint("TOPLEFT", 0, -((recipeIdx - 1) * rowHeight))
    row:SetSize(314, rowHeight)
    row.recipeKey = rowData.recipeKey
    row.addonStatusMemberKey = nil
    row.addonStatusGroupKey = nil
    row.addonStatusHeaderRow = false
    if row.addonStatusPartsReady then
        self:SetAddonStatusPartsVisible(row, false)
        self:SetAddonStatusHeaderButtonsVisible(row, false)
    end
    setShownIfChanged(row.icon, true)
    setShownIfChanged(row.title, true)
    setShownIfChanged(row.stats, true)
    setShownIfChanged(row.meta, true)
    setShownIfChanged(row.favoriteButton, true)

    local isFav = self:IsFavorite(rowData.recipeKey)
    row.favoriteButton.isFavorite = isFav
    row.favoriteButton.recipeKey = rowData.recipeKey
    setFavoriteButtonState(row.favoriteButton, isFav)

    local detail = rowData.detail or {}
    local colorItemID = detail.createdItemID or detail.recipeItemID
    local tooltipLink = (detail.createdItemID and ("item:" .. detail.createdItemID))
        or (detail.recipeItemID and ("item:" .. detail.recipeItemID))
        or (detail.spellID and ("spell:" .. detail.spellID))
        or nil
    row.tooltipLink = tooltipLink
    local titleText = rowData.label
    local rowIcon = detail.createdItemIcon or detail.recipeItemIcon or detail.spellIcon or getItemIcon(colorItemID)
    if rowIcon then
        setTextureIfChanged(row.icon, rowIcon)
        if row.icon.SetTexCoord then row.icon:SetTexCoord(0, 1, 0, 1) end
        setVertexColorIfChanged(row.icon, 1, 1, 1, 1)
        setShownIfChanged(row.icon, true)
    else
        setTextureIfChanged(row.icon, "Interface\\Icons\\INV_Misc_QuestionMark")
        if row.icon.SetTexCoord then row.icon:SetTexCoord(0, 1, 0, 1) end
        setVertexColorIfChanged(row.icon, 1, 1, 1, 1)
        setShownIfChanged(row.icon, true)
    end
    if colorItemID then
        titleText = getItemColorizedName(colorItemID, rowData.label)
        local sr, sg, sb = getQualityColor(getItemQuality(colorItemID) or 1)
        setVertexColorIfChanged(row.stripe, sr, sg, sb, 1)
    else
        setVertexColorIfChanged(row.stripe, 0.42, 0.42, 0.42, 1)
    end
    setTextIfChanged(row.title, titleText)

    local statsParts = {
        string.format("%d crafter(s)", rowData.crafterCount or 0),
    }
    if (rowData.onlineCount or 0) > 0 then
        statsParts[#statsParts + 1] = string.format("|cff55d66b%d online|r", rowData.onlineCount or 0)
    end
    setTextIfChanged(row.stats, table.concat(statsParts, "\n"))

    local metaParts = {}
    if self.selectedProfession == nil and rowData.professionList and #rowData.professionList > 0 then
        metaParts[#metaParts + 1] = table.concat(rowData.professionList, ", ")
    end
    setTextIfChanged(row.meta, table.concat(metaParts, " - "))

    if self.selectedRecipeKey == rowData.recipeKey then
        setBackdropColorsIfChanged(row, COLOR_ROW_SELECTED[1], COLOR_ROW_SELECTED[2], COLOR_ROW_SELECTED[3], COLOR_ROW_SELECTED[4], 1, 0.82, 0, 0.95)
    else
        setBackdropColorsIfChanged(row, COLOR_ROW[1], COLOR_ROW[2], COLOR_ROW[3], COLOR_ROW[4], 0.22, 0.22, 0.22, 1)
    end
    setShownIfChanged(row, true)
end

-- Virtualized rendering: only the rows that fall in the visible scroll
-- window (plus a small buffer above/below) are bound to recipe data. The
-- pool grows on demand and never shrinks below the largest window ever
-- needed, so swapping a 5-row Favorites filter for a 2000-row global search
-- keeps the pool size at ~ visibleRows + buffer (typically 10-15).
--
-- OnVerticalScroll fires per pixel during a scroll gesture but the actual
-- visible window only changes every RECIPE_ROW_HEIGHT pixels. We cache the
-- last bound window and skip rebind when neither bound has moved. The
-- cache is cleared by RefreshRecipeList/RefreshVisibleRecipeRowAssets,
-- which are the entry points where the underlying data (or selection)
-- can change while the window stays the same.
function UI:InvalidateRecipeWindowCache()
    self._lastRenderedFirstIdx = nil
    self._lastRenderedLastIdx = nil
end

function UI:RenderVisibleRecipeRows()
    if not self.frame or not self.currentRecipeRows then return end
    local rows = self.currentRecipeRows
    local total = #rows
    local pool = self.frame.recipeRows
    if total == 0 then
        for i = 1, #pool do
            setShownIfChanged(pool[i], false)
        end
        self:InvalidateRecipeWindowCache()
        return
    end

    local firstIdx, lastIdx = getVisibleRecipeWindow(self, total)

    if self._lastRenderedFirstIdx == firstIdx and self._lastRenderedLastIdx == lastIdx then
        return
    end

    local visibleCount = math.max(0, lastIdx - firstIdx + 1)

    local poolSlot = 0
    for recipeIdx = firstIdx, lastIdx do
        poolSlot = poolSlot + 1
        local row = self:EnsureRecipeRow(poolSlot)
        self:BindRecipeRow(row, recipeIdx, rows[recipeIdx])
    end
    for i = visibleCount + 1, #pool do
        setShownIfChanged(pool[i], false)
    end

    self._lastRenderedFirstIdx = firstIdx
    self._lastRenderedLastIdx = lastIdx
end

-- Kicks off a chunked recipe-list build through Data:BuildRecipeListAsync.
-- The build path:
--   * cache hit  → onComplete fires inline; finalize runs synchronously
--                  inside this call (no perceptible delay).
--   * cache miss → job processes ~60 recipes per scheduler step; the panel
--                  shows a "Loading..." header until the callback fires.
--
-- The generation token discards stale callbacks: if the filter changes
-- (profession switch, search debounce fires, favorites toggle) before the
-- previous build finishes, the in-flight callback notices the mismatch and
-- returns without touching the UI. A `nil` rows payload from the callback
-- means the data cache was invalidated mid-build — we drop it for the same
-- reason; the originating event will have queued its own RefreshRecipeList.
function UI:RefreshRecipeList()
    if not self.frame then return end
    if self:IsAddonStatusView() then
        self:RefreshAddonStatusList()
        return
    end
    self.searchText = self.recipeSearchText or ""
    self.currentAddonStatusSummary = nil
    self.selectedAddonStatusKey = nil
    local effectiveProfession = self.selectedProfession
    if effectiveProfession == "Favorites" then
        effectiveProfession = nil
    end
    local categoryFilter
    if Addon.db and Addon.db.profile and Addon.db.profile.useRecipeCategories ~= false
        and self.selectedProfession and self.selectedProfession ~= "Favorites" then
        categoryFilter = self.selectedCategory
    end
    local categoryLabel = self:GetCategoryFilterLabel(self.selectedProfession, categoryFilter)
    local globalSearch = (self.selectedProfession == nil and self.searchText and self.searchText ~= "")
    local canRunGlobalSearch = globalSearch and string.len(self.searchText or "") >= GLOBAL_SEARCH_MIN_CHARS

    local context = {
        selectedProfession = self.selectedProfession,
        categoryFilter = categoryFilter,
        globalSearch = globalSearch,
        canRunGlobalSearch = canRunGlobalSearch,
        sortMode = self.sortMode,
        categoryLabel = categoryLabel,
    }
    context.filterContext = {
        selectedProfession = self.selectedProfession,
        effectiveProfession = effectiveProfession,
        categoryFilter = categoryFilter,
        globalSearch = globalSearch,
    }
    -- Thread the per-session expansion reveal so RecipePasses /
    -- BuildVisibleSpellIdHash treat the hidden expansion as visible
    -- for THIS view only. Profile prefilters stay untouched, so other
    -- professions still respect the saved Vanilla=off preference.
    if self._sessionRevealedExpansions and effectiveProfession then
        local filtersModule = Addon.RecipeUiFilters
        local profKey = effectiveProfession
        if filtersModule and filtersModule.NormalizeProfessionKey then
            profKey = filtersModule:NormalizeProfessionKey(effectiveProfession) or effectiveProfession
        end
        local reveal = profKey and self._sessionRevealedExpansions[profKey]
        if reveal then
            context.filterContext.sessionRevealedExpansions = reveal
        end
    end
    if Addon.RecipeUiFilters and Addon.RecipeUiFilters.BuildFilterCacheKey then
        context.filterCacheKey = Addon.RecipeUiFilters:BuildFilterCacheKey(context.filterContext)
    end

    self._recipeListGeneration = (self._recipeListGeneration or 0) + 1
    local generation = self._recipeListGeneration

    -- Refresh the hint + scroll anchor before the build runs, so the
    -- previously-rendered rows from the prior profession don't briefly
    -- overlap the hint while the new build is in flight. _FinalizeRecipeList
    -- re-runs the same refresh at the end (cheap no-op when nothing
    -- changed) to catch edge cases where the hint state depends on
    -- per-recipe data only available after the build.
    self:RefreshHiddenExpansionHint(self.selectedProfession)

    if not (self.selectedProfession == "Favorites" or self.selectedProfession ~= nil or canRunGlobalSearch) then
        self:_FinalizeRecipeList({}, context, generation)
        return
    end

    if self.selectedProfession == FAVORITES_VIEW then
        self:_FinalizeRecipeList(self:BuildFavoriteRecipeRows(context.filterContext), context, generation)
        return
    end

    local callbackFiredInline = false
    Addon.Data:BuildRecipeListAsync(
        effectiveProfession,
        self.searchText,
        self.sortMode,
        self.searchMode,
        categoryFilter,
        context.filterContext,
        function(rows, _wasCached)
            callbackFiredInline = true
            if self._recipeListGeneration ~= generation then return end
            if not rows then
                -- The recipe index was invalidated mid-build (warmup
                -- traffic, scan completion, sync merge…). The original
                -- callsite is supposed to follow up with a RequestRefresh
                -- but some warmup paths don't, leaving the UI stuck on
                -- "Loading…" forever. Defer a refresh ourselves; the
                -- generation check above keeps us from racing a manual
                -- profession change.
                if Addon.ScheduleTimer then
                    Addon:ScheduleTimer(function()
                        if self._recipeListGeneration ~= generation then return end
                        Addon:RequestRefresh("list-stale-retry")
                    end, 0.25)
                end
                return
            end
            self:_FinalizeRecipeList(rows, context, generation)
        end
    )

    if not callbackFiredInline then
        self:_ShowRecipeListLoadingState(context, generation)
    end
end

-- The build is async and the panel is empty (or showing prior rows we don't
-- want to leave stale-looking). Update header + selection so the user sees
-- a clear "we're working on it" state instead of a frozen-looking frame.
function UI:_ShowRecipeListLoadingState(context, generation)
    if self._recipeListGeneration ~= generation then return end
    local headerText
    if context.selectedProfession == "Favorites" then
        headerText = "Favorites - loading..."
    elseif context.selectedProfession and context.categoryFilter then
        headerText = context.selectedProfession .. ": " .. tostring(context.categoryLabel or context.categoryFilter) .. " - loading..."
    elseif context.selectedProfession then
        headerText = context.selectedProfession .. " - loading..."
    elseif context.globalSearch and not context.canRunGlobalSearch then
        headerText = string.format("Type at least %d characters to search all recipes", GLOBAL_SEARCH_MIN_CHARS)
    else
        headerText = "Loading recipes..."
    end
    setTextIfChanged(self.frame.recipeHeader, headerText)
    if self.frame.sortSwitch then
        setShownIfChanged(self.frame.sortSwitch, true)
        if self.frame.sortSwitch.Enable then
            self.frame.sortSwitch:Enable()
        end
        local sortLabel = context.sortMode == "rarity" and "Sort: Rarity" or "Sort: Alphabetical"
        self.frame.sortSwitch:SetLabel(sortLabel)
    end
end

function UI:RejectStaleRecipeSelection(rows)
    if not self.selectedRecipeKey then
        return false
    end

    local selected = tostring(self.selectedRecipeKey)
    for _, rowData in ipairs(rows or {}) do
        if tostring(rowData.recipeKey) == selected then
            return false
        end
    end

    self.selectedRecipeKey = nil
    self.currentDetail = nil
    self._lastDetailSignature = nil
    self._lastDetailRecipeKey = nil
    self:CloseShareMenus()
    return true
end

function UI:_FinalizeRecipeList(rows, context, generation)
    if not self.frame then return end
    if self._recipeListGeneration ~= generation then return end
    if context and context.filterCacheKey and Addon.RecipeUiFilters and Addon.RecipeUiFilters.BuildFilterCacheKey then
        local currentFilterKey = Addon.RecipeUiFilters:BuildFilterCacheKey(context.filterContext)
        if currentFilterKey ~= context.filterCacheKey then
            -- The filter key shifted between RefreshRecipeList kick-off and
            -- the build completing — most commonly an ownership-index
            -- generation bump from an incoming sync block-merge. Dropping
            -- the result silently leaves the centre panel stuck on
            -- "Loading…" until something else nudges a refresh. Schedule
            -- a short retry on the next frame so the user actually sees
            -- rows; the generation gate above keeps us from clobbering a
            -- profession the user navigated away from in the meantime.
            if Addon.ScheduleTimer then
                Addon:ScheduleTimer(function()
                    if self._recipeListGeneration ~= generation then return end
                    Addon:RequestRefresh("list-filter-key-shift")
                end, 0.1)
            end
            return
        end
    end

    if context.selectedProfession == "Favorites" then
        local filteredRows = {}
        for _, row in ipairs(rows) do
            if self:IsFavorite(row.recipeKey) then
                filteredRows[#filteredRows + 1] = row
            end
        end
        rows = filteredRows
    end

    self.currentRecipeRows = rows
    local headerText
    if context.selectedProfession == "Favorites" then
        headerText = "Favorite recipes"
    elseif context.selectedProfession and context.categoryFilter then
        headerText = context.selectedProfession .. ": " .. tostring(context.categoryLabel or context.categoryFilter)
    elseif context.selectedProfession then
        headerText = context.selectedProfession .. " recipes"
    elseif context.globalSearch and not context.canRunGlobalSearch then
        headerText = string.format("Type at least %d characters to search all recipes", GLOBAL_SEARCH_MIN_CHARS)
    elseif context.globalSearch then
        headerText = "Search results"
    else
        headerText = "Select a profession or search"
    end
    setTextIfChanged(self.frame.recipeHeader, headerText)
    if self.frame.sortSwitch then
        setShownIfChanged(self.frame.sortSwitch, true)
        if self.frame.sortSwitch.Enable then
            self.frame.sortSwitch:Enable()
        end
        local sortLabel = context.sortMode == "rarity" and "Sort: Rarity" or "Sort: Alphabetical"
        self.frame.sortSwitch:SetLabel(sortLabel)
    end

    local selectedExists = self.selectedRecipeKey ~= nil
    if selectedExists then
        selectedExists = not self:RejectStaleRecipeSelection(rows)
    end

    if (not self.selectedRecipeKey or not selectedExists) and #rows > 0 then
        self.selectedRecipeKey = rows[1].recipeKey
    elseif #rows == 0 then
        self.selectedRecipeKey = nil
    end

    local contentHeight = math.max(1, #rows * self:GetListRowHeight() + 10)
    if self.frame.recipeContent._rrHeight ~= contentHeight then
        self.frame.recipeContent._rrHeight = contentHeight
        self.frame.recipeContent:SetHeight(contentHeight)
    end

    -- Data and/or selection just changed: force a re-bind even if the
    -- visible window indices match the previous render.
    self:InvalidateRecipeWindowCache()
    self:RenderVisibleRecipeRows()
    self:RefreshSummaryCards()
    self:RefreshHiddenExpansionHint(context.selectedProfession)
    -- Async path: the selection may have changed after the list arrived,
    -- so refresh the detail panel to keep it in sync with the new rows.
    self:RefreshDetailPanel()
end

-- Discoverability hint shown between the recipe header and the list. When
-- the user has hidden an expansion globally (or via per-profession
-- override) and that expansion has catalogued recipes for the current
-- profession, expose a one-click affordance to surface them. Falls
-- through to hidden state for "All", Favorites, or fully-on visibility.
function UI:RefreshHiddenExpansionHint(profession)
    local hint = self.frame and self.frame.hiddenExpansionHint
    if not hint then return end
    if not profession or profession == "All" or profession == "Favorites" then
        self:_SetRecipeScrollAnchor(false)
        if hint.IsShown and hint:IsShown() then hint:Hide() end
        return
    end
    local filters = Addon.RecipeUiFilters
    local metadata = Addon.RecipeMetadata
    if not (filters and metadata) then
        if hint.IsShown and hint:IsShown() then hint:Hide() end
        return
    end
    local profKey = filters.NormalizeProfessionKey and filters:NormalizeProfessionKey(profession) or profession
    -- Mining is intentionally expansion-agnostic at the predicate level;
    -- the hint would never fire usefully there.
    if profKey == "mining" then
        if hint.IsShown and hint:IsShown() then hint:Hide() end
        return
    end
    local visibility = filters:GetEffectiveExpansionVisibility(profKey)
    -- Honour the per-session reveal so the hint disappears after click
    -- without forcing the user to refresh / re-navigate to clear it.
    local sessionReveal = self._sessionRevealedExpansions
        and self._sessionRevealedExpansions[profKey]
        or nil
    if sessionReveal then
        visibility = {
            vanilla = visibility.vanilla ~= false or sessionReveal.vanilla == true,
            tbc = visibility.tbc ~= false or sessionReveal.tbc == true,
        }
    end
    local hiddenExpansion, hiddenCount
    local getCount = metadata.GetExpansionRecipeCount
        and function(exp) return metadata:GetExpansionRecipeCount(profKey, exp) end
        or function() return 0 end
    if visibility.vanilla == false then
        local n = getCount("vanilla")
        if n > 0 then
            hiddenExpansion = "vanilla"
            hiddenCount = n
        end
    end
    if not hiddenExpansion and visibility.tbc == false then
        local n = getCount("tbc")
        if n > 0 then
            hiddenExpansion = "tbc"
            hiddenCount = n
        end
    end
    if not hiddenExpansion then
        self:_SetRecipeScrollAnchor(false)
        if hint.IsShown and hint:IsShown() then hint:Hide() end
        return
    end
    hint._pendingProfession = profKey
    hint._pendingExpansion = hiddenExpansion
    local label = hiddenExpansion == "vanilla" and "Vanilla" or "TBC"
    if hint.text then
        hint.text:SetText(string.format(
            "%d %s recipe%s hidden by filter — click to show",
            hiddenCount,
            label,
            hiddenCount == 1 and "" or "s"
        ))
    end
    self:_SetRecipeScrollAnchor(true)
    hint:Show()
end

-- Toggle the recipeScroll's top anchor so the hint never overlaps the
-- first recipe row. Use absolute offsets relative to the centre frame
-- (not frame-to-frame anchors) — anchoring to the hint while it was
-- hidden produced a measurable mismatch (the hint's BOTTOMLEFT wasn't
-- being honoured) that put the scroll INSIDE the hint band by ~14px.
-- The hint sits at y=-34 with height 20, so y=-72 leaves an 18px gap
-- below the hint's bottom edge.
function UI:_SetRecipeScrollAnchor(hintShown)
    local frame = self.frame
    local scroll = frame and frame.recipeScroll
    if not scroll then return end
    local mode = hintShown and "below-hint" or "below-header"
    if scroll._rrAnchorMode == mode then return end
    scroll._rrAnchorMode = mode
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", 8, hintShown and -72 or -40)
    scroll:SetPoint("BOTTOMRIGHT", -28, 10)
end

-- Click handler: per-session reveal of the hidden expansion for the
-- currently-viewed profession. The user's saved profile is NOT
-- mutated, so navigating to another profession (or /reload) shows the
-- hint again at the original preference. Stored on the UI module so
-- subsequent navigations back to the same profession keep the reveal.
function UI:UnhideCurrentProfessionExpansion()
    local hint = self.frame and self.frame.hiddenExpansionHint
    if not hint or not hint._pendingExpansion then return end
    local profKey = hint._pendingProfession
    if not profKey then return end
    self._sessionRevealedExpansions = self._sessionRevealedExpansions or {}
    local profReveal = self._sessionRevealedExpansions[profKey]
    if type(profReveal) ~= "table" then
        profReveal = {}
        self._sessionRevealedExpansions[profKey] = profReveal
    end
    profReveal[hint._pendingExpansion] = true
    -- Invalidate the list-cache slice for this profession only — the
    -- session reveal changes the predicate outcome for the current view
    -- but leaves every other cached list (other professions, profile-
    -- side filters) intact.
    if Addon.Data and Addon.Data.InvalidateRecipeCaches then
        Addon.Data:InvalidateRecipeCaches("list")
    end
    hint:Hide()
    Addon:RequestRefresh("unhide-expansion-session")
end

function UI:GetCrafterRequestability(recipeKey, crafter, selfKey)
    if not crafter or not crafter.memberKey then
        return false, "missing-crafter"
    end
    if selfKey and crafter.memberKey == selfKey then
        return false, "current-player"
    end
    if Addon.Data and Addon.Data.GetRecipeRequestability then
        return Addon.Data:GetRecipeRequestability(recipeKey, crafter.memberKey)
    end
    return true, "requestable"
end

function UI:GetCrafterRequestMeta(recipeKey, crafter, selfKey)
    local requestable, reason = self:GetCrafterRequestability(recipeKey, crafter, selfKey)
    if reason == "current-player" then
        return nil, requestable, reason
    end

    local canRequest = false
    if requestable then
        canRequest = not (Addon.SyncPausePolicy and Addon.SyncPausePolicy:ShouldPauseProtocolTraffic("BLOCK_PULL_REQUEST"))
    end

    return {
        canRequest = canRequest,
        canWhisper = true,
        memberKey = crafter and crafter.memberKey or nil,
        requestable = requestable,
        requestabilityReason = reason,
    }, requestable, reason
end

function UI:BuildDetailRequestabilitySignature(detail)
    local crafters = detail and detail.crafters or nil
    if not crafters or #crafters == 0 then
        return ""
    end

    local selfKey = Addon.Data and Addon.Data.GetPlayerKey and Addon.Data:GetPlayerKey() or nil
    local parts = {}
    for _, crafter in ipairs(crafters) do
        local requestable, reason = self:GetCrafterRequestability(detail.recipeKey, crafter, selfKey)
        parts[#parts + 1] = table.concat({
            tostring(crafter.memberKey or ""),
            requestable and "1" or "0",
            tostring(reason or ""),
        }, ":")
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- Reuse the pooled render: when item info arrives or assets change, the
-- visible-window walk in BindRecipeRow already picks up the new icons,
-- colors, and labels via the same code path.
function UI:RefreshVisibleRecipeRowAssets()
    if not self.frame or not self.currentRecipeRows then
        return
    end

    -- Item-cache events can arrive in bursts; only re-bind the current
    -- virtualized window and let off-screen rows refresh lazily on scroll.
    self:InvalidateRecipeWindowCache()
    self:RenderVisibleRecipeRows()
end

function UI:BuildFavoriteRecipeRows(filterContext)
    local favorites = Addon.charDB and Addon.charDB.favorites or {}
    local favoriteKeys = {}
    local favoriteSet = {}
    for recipeKey, enabled in pairs(favorites) do
        if enabled then
            local key = tostring(recipeKey)
            favoriteSet[key] = true
            favoriteKeys[#favoriteKeys + 1] = key
        end
    end
    if #favoriteKeys == 0 or not Addon.Data then
        return {}
    end

    local data = Addon.Data
    local rowsByKey = {}

    local function passesFilters(recipeKey)
        if Addon.RecipeUiFilters and Addon.RecipeUiFilters.RecipePasses then
            local passed = Addon.RecipeUiFilters:RecipePasses(recipeKey, nil, filterContext)
            return passed == true
        end
        return true
    end

    local function ensureRow(recipeKey)
        local key = tostring(recipeKey)
        local row = rowsByKey[key]
        if row then return row end

        local detail = data.GetRecipeDisplayInfo and data:GetRecipeDisplayInfo(recipeKey) or nil
        row = {
            recipeKey = recipeKey,
            detail = detail,
            label = (detail and detail.label)
                or (data.ResolveRecipeLabel and data:ResolveRecipeLabel(recipeKey))
                or tostring(recipeKey),
            crafterCount = 0,
            onlineCount = 0,
            professionList = {},
            _profNames = {},
            _seenMembers = {},
        }
        rowsByKey[key] = row
        return row
    end

    local function addIndexedRecipe(recipeKey, indexed)
        if not indexed then return end
        if not passesFilters(recipeKey) then return end
        local row = ensureRow(recipeKey)
        row.crafterCount = indexed.crafterCount or 0
        row.onlineCount = 0
        for _, crafter in ipairs(indexed.crafterRows or {}) do
            if data.IsMemberOnline and data:IsMemberOnline(crafter.memberKey) then
                row.onlineCount = row.onlineCount + 1
            end
        end
        for profName in pairs(indexed.profNames or {}) do
            row._profNames[profName] = true
        end
    end

    if data._recipeIndex then
        for _, favoriteKey in ipairs(favoriteKeys) do
            addIndexedRecipe(favoriteKey, data._recipeIndex[favoriteKey] or data._recipeIndex[tonumber(favoriteKey)])
        end
    else
        for memberKey, entry in pairs(data.GetMembersDB and data:GetMembersDB() or {}) do
            if data.IsUserVisibleMember and data:IsUserVisibleMember(memberKey, entry) then
                for profName, prof in pairs(entry.professions or {}) do
                    for recipeKey in pairs(prof.recipes or {}) do
                        local key = tostring(recipeKey)
                        if favoriteSet[key] and passesFilters(recipeKey) then
                            local row = ensureRow(recipeKey)
                            row._profNames[profName] = true
                            if not row._seenMembers[memberKey] then
                                row._seenMembers[memberKey] = true
                                row.crafterCount = row.crafterCount + 1
                                if data.IsMemberOnline and data:IsMemberOnline(memberKey) then
                                    row.onlineCount = row.onlineCount + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local q = lowerSafe(self.searchText)
    local out = {}
    for _, row in pairs(rowsByKey) do
        for profName in pairs(row._profNames or {}) do
            row.professionList[#row.professionList + 1] = profName
        end
        table.sort(row.professionList)
        row._profNames = nil
        row._seenMembers = nil

        local searchText
        if self.searchMode == "materials" then
            searchText = row.detail and row.detail.searchText or lowerSafe(row.label)
        else
            searchText = row.detail and row.detail.recipeSearchText or lowerSafe(row.label)
        end
        if q == "" or searchText:find(q, 1, true) then
            out[#out + 1] = row
        end
    end

    table.sort(out, function(a, b)
        if self.sortMode == "rarity" then
            local aq = a.detail and (a.detail.createdItemQuality or a.detail.recipeItemQuality)
            local bq = b.detail and (b.detail.createdItemQuality or b.detail.recipeItemQuality)
            aq = aq == nil and -1 or aq
            bq = bq == nil and -1 or bq
            if aq ~= bq then return aq > bq end
        end
        local al = lowerSafe(a.label)
        local bl = lowerSafe(b.label)
        if al ~= bl then return al < bl end
        if (a.onlineCount or 0) ~= (b.onlineCount or 0) then return (a.onlineCount or 0) > (b.onlineCount or 0) end
        if (a.crafterCount or 0) ~= (b.crafterCount or 0) then return (a.crafterCount or 0) > (b.crafterCount or 0) end
        return tostring(a.recipeKey) < tostring(b.recipeKey)
    end)

    return out
end

function UI:RefreshAddonStatusList()
    self.searchText = self.addonStatusSearchText or ""
    self._recipeListGeneration = (self._recipeListGeneration or 0) + 1
    self.selectedRecipeKey = nil
    local rows, summary = {}, {
        rosterReady = false,
        reason = "data-unavailable",
        rosterTotal = 0,
        shownRows = 0,
        addonPeersActive = 0,
        lastRosterRefreshAt = 0,
    }
    if Addon.Data and Addon.Data.GetGuildAddonStatusRows then
        rows, summary = Addon.Data:GetGuildAddonStatusRows({
            searchText = self.searchText,
            staleAfterDays = 30,
        })
    end
    self:_FinalizeAddonStatusList(rows or {}, summary or {})
end

function UI:_FinalizeAddonStatusList(rows, summary)
    if not self.frame then return end
    self.currentAddonStatusRows = rows or {}
    self.currentAddonStatusSummary = summary or {}
    self.currentRecipeRows = self:BuildAddonStatusDisplayRows(self.currentAddonStatusRows)
    self.currentAddonStatusSummary.filteredRows = math.max(0, #self.currentRecipeRows - 1)

    local headerText
    if self.currentAddonStatusSummary.rosterReady ~= true then
        headerText = ADDON_STATUS_VIEW .. " - waiting for guild roster"
    elseif self.searchText and self.searchText ~= "" then
        headerText = ADDON_STATUS_VIEW .. " search results"
    else
        headerText = ADDON_STATUS_VIEW
    end
    setTextIfChanged(self.frame.recipeHeader, headerText)
    if self.frame.sortSwitch then
        setShownIfChanged(self.frame.sortSwitch, false)
    end
    self:RefreshAddonStatusControls()

    self.selectedAddonStatusKey = nil

    local contentHeight = math.max(1, #self.currentRecipeRows * self:GetListRowHeight() + 10)
    if self.frame.recipeContent._rrHeight ~= contentHeight then
        self.frame.recipeContent._rrHeight = contentHeight
        self.frame.recipeContent:SetHeight(contentHeight)
    end

    self:InvalidateRecipeWindowCache()
    self:RenderVisibleRecipeRows()
    self:RefreshSummaryCards()
    self:RefreshDetailPanel()
end

function UI:RenderDetailLines(lines, lineLinks, lineMeta)
    local yOffset = 0
    for i, text in ipairs(lines) do
        local line = self:EnsureDetailLine(i)
        setTextIfChanged(line.text, text)
        line.link = lineLinks and lineLinks[i] or nil
        line.tooltipLink = nil
        line.requestTarget = nil
        local meta = lineMeta and lineMeta[i] or nil
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", 0, -yOffset)
        line:SetWidth(420)
        -- requestTarget drives the left-click whisper-open (always
        -- available for non-self crafters). actionButton is the "request
        -- this craft" affordance which sends a whisper from the addon —
        -- gated by canRequest so it stays hidden while the sync pause
        -- policy is active (raid/instance/combat).
        if meta and meta.memberKey and (meta.canWhisper or meta.canRequest) then
            line.requestTarget = whisperTargetFromMemberKey(meta.memberKey)
            local showActionButton = meta.canRequest == true
            setShownIfChanged(line.actionButton, showActionButton)
            line.text:ClearAllPoints()
            line.text:SetPoint("TOPLEFT", 0, 0)
            -- Reserve room for the 36px-wide Ask button + 4px breathing
            -- room. -4 still applies when the button is hidden.
            line.text:SetPoint("TOPRIGHT", showActionButton and -44 or -4, 0)
        else
            setShownIfChanged(line.actionButton, false)
            line.text:ClearAllPoints()
            line.text:SetPoint("TOPLEFT", 0, 0)
            line.text:SetPoint("TOPRIGHT", -4, 0)
        end
        if meta and meta.tooltipLink then
            line.tooltipLink = meta.tooltipLink
        end
        line.isOfflineToggle = meta and meta.isOfflineToggle or false
        local textHeight = math.max(16, math.ceil(line.text:GetStringHeight() or 0))
        local lineHeight = math.max(20, textHeight + 6)
        line:SetHeight(lineHeight)
        line.actionButton:ClearAllPoints()
        line.actionButton:SetPoint("RIGHT", -2, 0)
        setShownIfChanged(line, true)
        yOffset = yOffset + lineHeight + 4
    end
    for i = #lines + 1, #self.frame.detailLines do
        setShownIfChanged(self.frame.detailLines[i], false)
    end
    local detailHeight = math.max(1, yOffset + 10)
    if self.frame.detailContent._rrHeight ~= detailHeight then
        self.frame.detailContent._rrHeight = detailHeight
        self.frame.detailContent:SetHeight(detailHeight)
    end
end

function UI:GetSelectedAddonStatusRow()
    if not self.selectedAddonStatusKey then
        return nil
    end
    for _, rowData in ipairs(self.currentRecipeRows or {}) do
        if rowData.rowType == "addonStatus" and rowData.memberKey == self.selectedAddonStatusKey then
            return rowData
        end
    end
    return nil
end

function UI:RefreshAddonStatusDetailPanel()
    if not self.frame then return end
    self.currentDetail = nil
    self._lastDetailSignature = nil
    self.frame.detailFavoriteButton.recipeKey = nil
    self.frame.detailFavoriteButton.isFavorite = false
    setShownIfChanged(self.frame.detailFavoriteButton, false)
    self.frame.detailScroll:SetPoint("TOPLEFT", 8, -54)

    local lines = {}
    local summary = self.currentAddonStatusSummary or {}
    if summary.rosterReady ~= true then
        setTextIfChanged(self.frame.detailTitle, ADDON_STATUS_VIEW)
        setTextIfChanged(self.frame.detailSub, "Waiting for the guild roster refresh.")
        lines[#lines + 1] = "Guild roster data is not loaded yet."
        lines[#lines + 1] = "Recipe Registry has requested a roster refresh and will update this view automatically."
        self:RenderDetailLines(lines, {}, {})
        return
    end

    local row = self:GetSelectedAddonStatusRow()
    if not row then
        setTextIfChanged(self.frame.detailTitle, ADDON_STATUS_VIEW)
        setTextIfChanged(self.frame.detailSub, "No guild member selected.")
        if self.searchText and self.searchText ~= "" then
            lines[#lines + 1] = "No guild roster rows match this search."
        else
            lines[#lines + 1] = "No guild roster rows are available."
        end
        self:RenderDetailLines(lines, {}, {})
        return
    end

    local sr, sg, sb = addonStatusColor(row.addonStatusKey)
    setTextIfChanged(self.frame.detailTitle, getClassColorizedName(row.memberKey))
    setTextIfChanged(self.frame.detailSub, colorText(row.addonStatusLabel, sr, sg, sb))

    lines[#lines + 1] = "|cffffd100Addon|r"
    lines[#lines + 1] = "Status: " .. addonStatusLabelColor(row)
    lines[#lines + 1] = "Version: " .. safeText(row.addonVersion)
    lines[#lines + 1] = "Wire: " .. safeText(row.wireVersion)
    lines[#lines + 1] = "Build channel: " .. safeText(row.buildChannel)
    lines[#lines + 1] = "Build ID: " .. safeText(row.buildId)
    lines[#lines + 1] = "First seen addon: " .. timestampText(row.firstSeenAt)
    lines[#lines + 1] = "Last seen addon: " .. timestampText(row.lastSeenAt)

    lines[#lines + 1] = " "
    lines[#lines + 1] = "|cffffd100Roster|r"
    lines[#lines + 1] = "Online status: " .. (row.online and colorText("Online", 0.35, 0.95, 0.45) or colorText("Offline", 0.85, 0.45, 0.45))
    lines[#lines + 1] = "Rank: " .. safeText(row.rankName)
    lines[#lines + 1] = "Level: " .. safeText(row.level)
    lines[#lines + 1] = "Zone: " .. safeText(row.zone)
    if row.status and row.status ~= "" then
        lines[#lines + 1] = "Roster status: " .. safeText(row.status)
    end

    self:RenderDetailLines(lines, {}, {})
end

function UI:RefreshDetailPanel()
    if not self.frame then return end
    if self:IsAddonStatusView() then
        self.currentDetail = nil
        self._lastDetailSignature = nil
        self:CloseShareMenus()
        setShownIfChanged(self.frame.detailFavoriteButton, false)
        setShownIfChanged(self.frame.detailShareButton, false)
        return
    end
    local lines = {}
    local lineLinks = {}
    local lineMeta = {}
    setShownIfChanged(self.frame.detailFavoriteButton, true)
    setShownIfChanged(self.frame.detailShareButton, true)
    if not self.selectedRecipeKey then
        self.currentDetail = nil
        self._lastDetailSignature = nil
        self:CloseShareMenus()
        setTextIfChanged(self.frame.detailTitle, "Recipe details")
        setTextIfChanged(self.frame.detailSub, "Select a recipe to see materials and available crafters.")
        self.frame.detailFavoriteButton.recipeKey = nil
        self.frame.detailFavoriteButton.isFavorite = false
        setFavoriteButtonState(self.frame.detailFavoriteButton, false)
        setButtonEnabledIfChanged(self.frame.detailShareButton, false)
        -- Hide any plugin-registered recipe-action buttons too.
        if self.RealizeRecipeActions then
            self:RealizeRecipeActions(self.frame.right or self.frame, self.frame.detailFavoriteButton)
        end
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
    local isFavorite = self:IsFavorite(self.selectedRecipeKey)

    -- Cheap visibility-only signature: if nothing visible has changed since
    -- the last render, skip the full rebuild. Catches the common "roster
    -- update fired but the open recipe is unaffected" case where we'd
    -- otherwise rebuild the entire crafters+materials+cost block from
    -- scratch on every periodic refresh.
    local onlineCount = 0
    if detail.crafters then
        for _, c in ipairs(detail.crafters) do
            if c.online then onlineCount = onlineCount + 1 end
        end
    end
    local requestabilitySignature = self:BuildDetailRequestabilitySignature(detail)
    local signature = string.format(
        "%s|%s|%d|%d|%s|%s|%s|%s|%s",
        tostring(self.selectedRecipeKey),
        isFavorite and "1" or "0",
        tonumber(detail.crafterCount) or 0,
        onlineCount,
        tostring(detail.cost and detail.cost.total or ""),
        tostring(detail.cost and detail.cost.missingCount or 0),
        tostring(detail.cost and detail.cost.source or ""),
        tostring(self._offlineCraftersExpanded),
        requestabilitySignature
    )
    if self._lastDetailSignature == signature then
        return
    end
    self._lastDetailSignature = signature

    local iconTagText = textureTag(detail.createdItemIcon or detail.recipeItemIcon or detail.spellIcon, 18)
    local titleItemID = detail.createdItemID or detail.recipeItemID
    local titleText = detail.label or tostring(self.selectedRecipeKey)
    if titleItemID then
        titleText = getItemColorizedName(titleItemID, titleText)
    end
    setTextIfChanged(self.frame.detailTitle, iconTagText .. " " .. titleText)
    self.frame.detailFavoriteButton.recipeKey = self.selectedRecipeKey
    self.frame.detailFavoriteButton.isFavorite = isFavorite
    setFavoriteButtonState(self.frame.detailFavoriteButton, isFavorite)
    setButtonEnabledIfChanged(self.frame.detailShareButton, true)

    -- Render any sibling-addon-provided per-recipe action buttons,
    -- anchored to the LEFT of the favorite button. Implemented in
    -- UI/RecipeActions.lua as a strictly-additive hook.
    if self.RealizeRecipeActions then
        self:RealizeRecipeActions(self.frame.right or self.frame, self.frame.detailFavoriteButton)
    end

    local subtitleParts = {}
    if detail.professionName then subtitleParts[#subtitleParts + 1] = detail.professionName end
    if detail.directEnchant then subtitleParts[#subtitleParts + 1] = "Direct enchant" end
    subtitleParts[#subtitleParts + 1] = string.format("%d crafter(s)", detail.crafterCount or 0)
    setTextIfChanged(self.frame.detailSub, table.concat(subtitleParts, "  •  "))

    -- Reset scroll position (no embedded tooltip anymore)
    self.frame.detailScroll:SetPoint("TOPLEFT", 8, -54)

    -- Reset offline accordion state when recipe changes
    if self._lastDetailRecipeKey ~= self.selectedRecipeKey then
        self:CloseShareMenus()
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
            local nameText = getClassColorizedName(crafter.memberKey)
            if crafter.specialization then
                nameText = nameText .. " " .. colorText("[" .. crafter.specialization .. "]", unpackColor(MUTED))
            end
            local requestMeta, requestable = self:GetCrafterRequestMeta(self.selectedRecipeKey, crafter, selfKey)
            if requestable == false and (not selfKey or crafter.memberKey ~= selfKey) then
                nameText = nameText .. " " .. colorText("[Not requestable]", unpackColor(MUTED))
            end
            lines[#lines + 1] = string.format("%s %s", state, nameText)
            if requestMeta then
                -- canWhisper is a local UI action (opens a chat window) and
                -- has no sync implications, so it stays enabled even when
                -- SyncPausePolicy pauses protocol traffic (raids,
                -- instances, combat). canRequest also stays false for
                -- BoP and self-only recipes that remote crafters cannot
                -- deliver.
                lineMeta[#lines] = requestMeta
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
                    local nameText = getClassColorizedName(crafter.memberKey)
                    if crafter.specialization then
                        nameText = nameText .. " " .. colorText("[" .. crafter.specialization .. "]", unpackColor(MUTED))
                    end
                    local requestable = self:GetCrafterRequestability(self.selectedRecipeKey, crafter, selfKey)
                    if requestable == false and (not selfKey or crafter.memberKey ~= selfKey) then
                        nameText = nameText .. " " .. colorText("[Not requestable]", unpackColor(MUTED))
                    end
                    lines[#lines + 1] = string.format("%s %s", state, nameText)
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
            lines[#lines + 1] = string.format("%s  %s x%d", materialTextureTag(icon), name, reagent.count or 1)
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
        self:Close("toggle")
    else
        self:RestoreFramePlacement()
        self.frame:Show()
        self:RefreshDebugVisibility()
        local degradedReason = self:GetDegradedModeReason()
        if degradedReason and not self:IsAddonStatusView() then
            self:RefreshStatusBar()
            self:RefreshProfessionButtons({ skipCategories = true })
            self:RefreshDegradedStatus(degradedReason)
            self:MarkFullRefreshPending(degradedReason)
        else
            self:Refresh(nil)
        end
        self:SyncSearchControls()
    end
end

function UI:Refresh(reasons)
    if not self.frame or not self.frame:IsShown() then return end
    self:ApplyMainLayout()
    local degradedReason = self:GetDegradedModeReason()
    if degradedReason and not self:IsAddonStatusView() then
        self:RefreshStatusBar()
        -- Profession buttons are static labels — populating them while sync
        -- is still warming up gives the user a non-empty sidebar instead
        -- of a row of unlabelled rectangles. skipCategories=true keeps us
        -- off category providers during the degraded warmup render.
        self:RefreshProfessionButtons({ skipCategories = true })
        self:RefreshDegradedStatus(degradedReason)
        self:MarkFullRefreshPending(degradedReason)
        return
    end
    self.fullRefreshPending = false
    self.fullRefreshPendingReason = nil
    local plan = buildRefreshPlan(reasons)
    if plan.status then
        self:RefreshStatusBar()
    end
    if plan.professions then
        self:RefreshProfessionButtons()
    end
    if plan.list then
        self:RefreshRecipeList()
    elseif plan.visibleRows then
        self:RefreshVisibleRecipeRowAssets()
    end
    if plan.detail then
        self:RefreshDetailPanel()
    end
end

function UI:ShareSelectedRecipe(channelInput)
    local channel, channelError = resolveShareChannel(channelInput)
    if not channel then
        Addon:Print(channelError or "Usage: /rr share [guild|party|raid|say|reply]")
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

    local totalText = (detail.cost and detail.cost.total and formatMoneyForChat(detail.cost.total)) or "n/a"
    local sourceText = (detail.cost and detail.cost.source) or "N/A"
    SendChatMessage(string.format("[RR] %s - Mats total: %s - Source: %s",
        chatDisplayText(recipeLink),
        escapeChatPlainText(totalText),
        escapeChatPlainText(sourceText)), channel.chatType, nil, channel.target)

    if detail.reagents and #detail.reagents > 0 then
        local chunk = "[RR] Mats:"
        for _, reagent in ipairs(detail.reagents) do
            local link = getItemLinkByID(reagent.itemID) or reagent.name or ("item:" .. tostring(reagent.itemID or "?"))
            local seg = string.format(" %s x%d", chatDisplayText(link), reagent.count or 1)
            if #chunk + #seg > 240 then
                SendChatMessage(chunk, channel.chatType, nil, channel.target)
                chunk = "[RR] Mats:" .. seg
            else
                chunk = chunk .. seg
            end
        end
        if chunk ~= "[RR] Mats:" then
            SendChatMessage(chunk, channel.chatType, nil, channel.target)
        end
    end
end
