local Wow = {}

local unpack = unpack
local realDate = os.date
local realType = type

local state

local PROFESSION_SPELLS = {
    [2259] = "Alchemy",
    [2018] = "Blacksmithing",
    [2550] = "Cooking",
    [7411] = "Enchanting",
    [4036] = "Engineering",
    [2366] = "Herbalism",
    [25229] = "Jewelcrafting",
    [2108] = "Leatherworking",
    [2575] = "Mining",
    [8613] = "Skinning",
    [3908] = "Tailoring",
    [2656] = "Mining",
}

local function deepcopy(value, seen)
    if realType(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do
        out[deepcopy(key, seen)] = deepcopy(item, seen)
    end
    return out
end

local function applyDefaults(target, defaults)
    if realType(defaults) ~= "table" then return target end
    if realType(target) ~= "table" then target = {} end
    for key, value in pairs(defaults) do
        if realType(value) == "table" then
            target[key] = applyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

local function sortedTimerIndex()
    local bestIndex, bestTimer
    for index, timer in ipairs(state.timers) do
        if not timer.cancelled then
            if not bestTimer
                or timer.dueAt < bestTimer.dueAt
                or (timer.dueAt == bestTimer.dueAt and timer.id < bestTimer.id) then
                bestIndex = index
                bestTimer = timer
            end
        end
    end
    return bestIndex, bestTimer
end

local function callScheduled(owner, callback, ...)
    if realType(callback) == "function" then
        return callback(...)
    end
    if realType(callback) == "string" and owner and realType(owner[callback]) == "function" then
        return owner[callback](owner, ...)
    end
    error("invalid scheduled callback: " .. tostring(callback))
end

local function scheduleTimer(owner, callback, delay, repeating)
    state.nextTimerId = state.nextTimerId + 1
    local timer = {
        id = state.nextTimerId,
        owner = owner,
        callback = callback,
        delay = delay or 0,
        dueAt = state.now + (delay or 0),
        repeating = repeating == true,
        cancelled = false,
    }
    state.timers[#state.timers + 1] = timer
    return timer
end

local function normalizeBucketKey(event, ...)
    local first = select(1, ...)
    if first == nil then
        return event
    end
    return first
end

local sortedKeys

local function encodeLuaLiteral(value, seen)
    local valueType = realType(value)
    if valueType == "nil" then
        return "nil"
    end
    if valueType == "boolean" or valueType == "number" then
        return tostring(value)
    end
    if valueType == "string" then
        return string.format("%q", value)
    end
    if valueType ~= "table" then
        error("unsupported test serialization type: " .. tostring(valueType))
    end

    seen = seen or {}
    if seen[value] then
        error("cyclic table values are not supported by the test serializer")
    end
    seen[value] = true

    local parts = {}
    for _, key in ipairs(sortedKeys(value)) do
        parts[#parts + 1] = "[" .. encodeLuaLiteral(key, seen) .. "]=" .. encodeLuaLiteral(value[key], seen)
    end

    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function decodeLuaLiteral(text)
    if realType(text) ~= "string" then
        return false, nil
    end
    local chunk, err = loadstring("return " .. text)
    if not chunk then
        return false, err
    end
    local ok, value = pcall(chunk)
    if not ok then
        return false, value
    end
    return true, value
end

local function registerSerializedValue(prefix, value)
    _G.__RecipeRegistrySerializedValues = _G.__RecipeRegistrySerializedValues or {}
    _G.__RecipeRegistrySerializedNextId = (_G.__RecipeRegistrySerializedNextId or 0) + 1
    local token = string.format("%s:%d", prefix, _G.__RecipeRegistrySerializedNextId)
    _G.__RecipeRegistrySerializedValues[token] = deepcopy(value)
    return token
end

sortedKeys = function(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        local lt, rt = realType(left), realType(right)
        if lt == rt then
            if lt == "number" or lt == "string" then
                return left < right
            end
        end
        return tostring(left) < tostring(right)
    end)
    return keys
end

local function stableDescribe(value, seen)
    local valueType = realType(value)
    if valueType == "table" then
        seen = seen or {}
        if seen[value] then
            return "<cycle>"
        end
        seen[value] = true
        local parts = {}
        for _, key in ipairs(sortedKeys(value)) do
            parts[#parts + 1] = tostring(key) .. "=" .. stableDescribe(value[key], seen)
        end
        seen[value] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    if valueType == "string" then
        return value
    end
    return tostring(value)
end

local function flushBucket(owner, registration)
    local bucket = registration and registration.bucket
    registration.bucket = nil
    registration.timer = nil
    if not bucket then
        return
    end
    callScheduled(owner, registration.method, bucket)
end

local function deliverRegisteredEvent(owner, event, ...)
    if not owner then
        return
    end

    if owner.__events and owner.__events[event] then
        callScheduled(owner, owner.__events[event], event, ...)
    end

    local registration = owner.__bucketEvents and owner.__bucketEvents[event]
    if registration then
        local key = normalizeBucketKey(event, ...)
        registration.bucket = registration.bucket or {}
        registration.bucket[key] = (registration.bucket[key] or 0) + 1
        if not registration.timer then
            registration.timer = scheduleTimer(owner, function()
                flushBucket(owner, registration)
            end, registration.interval or 0, false)
        end
    end
end

local function embedBaseMethods(target)
    function target:Print(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        state.prints[#state.prints + 1] = table.concat(parts, " ")
    end

    function target:RegisterChatCommand(command, method)
        self.__chatCommands = self.__chatCommands or {}
        self.__chatCommands[command] = method
    end

    function target:RegisterEvent(event, method)
        self.__events = self.__events or {}
        self.__events[event] = method or event
    end

    function target:RegisterBucketEvent(event, interval, method)
        self.__bucketEvents = self.__bucketEvents or {}
        self.__bucketEvents[event] = {
            interval = interval or 0,
            method = method or event,
            bucket = nil,
            timer = nil,
        }
    end

    -- AceBucket-3.0 also exposes RegisterBucketMessage for AceEvent custom
    -- messages. Specs that rely on bucket flushes still use the event
    -- variant; this stub keeps Addon:OnEnable from crashing when it
    -- registers a message bucket, without actually scheduling deferred
    -- runs. SendMessage is mocked to a no-op below for the same reason.
    function target:RegisterBucketMessage(message, interval, method)
        self.__bucketMessages = self.__bucketMessages or {}
        self.__bucketMessages[message] = {
            interval = interval or 0,
            method = method or message,
        }
    end

    function target:SendMessage(_message, ...)
        -- no-op: the harness does not route AceEvent custom messages.
        -- Bucket message handlers registered via RegisterBucketMessage
        -- therefore never fire during tests; callers that depend on the
        -- side effect must drive it explicitly instead.
    end

    function target:RegisterMessage(_message, _method)
        -- no-op companion of SendMessage above.
    end

    function target:UnregisterEvent(event)
        if self.__events then self.__events[event] = nil end
    end

    function target:ScheduleTimer(callback, delay, ...)
        local extra = { ... }
        if #extra > 0 then
            local original = callback
            callback = function()
                return callScheduled(self, original, unpack(extra))
            end
        end
        return scheduleTimer(self, callback, delay, false)
    end

    function target:ScheduleRepeatingTimer(callback, delay, ...)
        local extra = { ... }
        if #extra > 0 then
            local original = callback
            callback = function()
                return callScheduled(self, original, unpack(extra))
            end
        end
        return scheduleTimer(self, callback, delay, true)
    end

    function target:CancelTimer(timer)
        if timer then timer.cancelled = true end
    end

    function target:RegisterComm(prefix, method)
        self.__commPrefix = prefix
        self.__commMethod = method or "OnCommReceived"
    end

    function target:SendCommMessage(prefix, message, distribution, targetName, priority)
        state.sentComm[#state.sentComm + 1] = {
            prefix = prefix,
            message = message,
            distribution = distribution,
            target = targetName,
            priority = priority,
            sender = state.playerName,
        }
    end

    return target
end

local function newAddon(name)
    local addon = embedBaseMethods({
        name = name,
        __modules = {},
        __moduleOrder = {},
    })

    function addon:NewModule(moduleName)
        local module = embedBaseMethods({
            name = moduleName,
            moduleName = moduleName,
            parent = self,
        })
        self.__modules[moduleName] = module
        self.__moduleOrder[#self.__moduleOrder + 1] = module
        return module
    end

    return addon
end

local function installLibStub()
    local libs = {}

    local AceAddon = { __addons = {} }
    function AceAddon:NewAddon(name, ...)
        -- Mixin names (e.g. "AceConsole-3.0", "AceEvent-3.0") are accepted
        -- and ignored: the harness already embeds Print/Register*/timer
        -- helpers on every addon via embedBaseMethods.
        local addon = newAddon(name)
        self.__addons[name] = addon
        return addon
    end
    function AceAddon:GetAddon(name, silent)
        local addon = self.__addons[name]
        if not addon and silent ~= true then
            error("AceAddon-3.0 has no addon registered as " .. tostring(name), 2)
        end
        return addon
    end
    libs["AceAddon-3.0"] = AceAddon

    libs["AceDB-3.0"] = {
        New = function(_, dbName, defaults)
            local db = _G[dbName]
            if realType(db) ~= "table" then
                db = {}
                _G[dbName] = db
            end
            applyDefaults(db, defaults or {})
            db.global = db.global or {}
            db.profile = db.profile or {}
            return db
        end,
    }

    libs["AceSerializer-3.0"] = {
        Serialize = function(_, payload)
            local mode = state and state.payloadMode or "table-fast"
            if mode == "table-fast" then
                return payload
            end
            if mode == "string-tokenized" then
                local shape = stableDescribe(payload)
                local token = registerSerializedValue("AS", payload)
                return token .. "|" .. shape
            end
            if mode == "realistic-string" or mode == "corruptible-string" then
                return "ASR|" .. encodeLuaLiteral(payload)
            end
            return payload
        end,
        Deserialize = function(_, payload)
            if realType(payload) == "table" then
                return true, payload
            end
            if realType(payload) ~= "string" then
                return false, nil
            end

            local token = payload:match("^(AS:%d+)|")
            if token then
                local value = _G.__RecipeRegistrySerializedValues and _G.__RecipeRegistrySerializedValues[token]
                if not value then
                    return false, nil
                end
                return true, deepcopy(value)
            end

            local literal = payload:match("^ASR|(.+)$")
            if literal then
                local ok, value = decodeLuaLiteral(literal)
                if not ok or realType(value) ~= "table" then
                    return false, nil
                end
                return true, value
            end

            return false, nil
        end,
    }

    libs["LibSerialize"] = {
        Serialize = function(_, payload)
            local shape = stableDescribe(payload)
            local token = registerSerializedValue("LS", payload)
            return token .. "|" .. shape
        end,
        Deserialize = function(_, payload)
            if realType(payload) ~= "string" then
                return false, nil
            end
            local token = payload:match("^(LS:%d+)|")
            local value = token and _G.__RecipeRegistrySerializedValues and _G.__RecipeRegistrySerializedValues[token]
            if not value then
                return false, nil
            end
            return true, deepcopy(value)
        end,
    }

    libs["LibDeflate"] = {
        CompressDeflate = function(_, payload)
            if realType(payload) ~= "string" then
                return nil
            end
            local token = registerSerializedValue("CD", payload)
            return token
        end,
        EncodeForWoWAddonChannel = function(_, payload)
            if realType(payload) ~= "string" then
                return nil
            end
            return "WA|" .. payload
        end,
        DecodeForWoWAddonChannel = function(_, payload)
            if realType(payload) ~= "string" then
                return nil
            end
            return payload:match("^WA|(.+)$")
        end,
        DecompressDeflate = function(_, payload)
            if realType(payload) ~= "string" then
                return nil
            end
            local value = _G.__RecipeRegistrySerializedValues and _G.__RecipeRegistrySerializedValues[payload]
            if realType(value) ~= "string" then
                return nil
            end
            return value
        end,
    }

    local function libstub(name, silent)
        local lib = libs[name]
        if not lib and silent == true then
            return nil
        end
        if not lib then error("missing test LibStub library: " .. tostring(name), 2) end
        return lib
    end

    _G.__RecipeRegistryTestLibs = libs
    _G.LibStub = libstub
end

local function makeFrame(shown)
    return {
        shown = shown == true,
        IsShown = function(self) return self.shown == true end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
    }
end

local function makeCheckButton()
    return {
        checked = false,
        GetChecked = function(self) return self.checked == true end,
        SetChecked = function(self, value) self.checked = value == true end,
    }
end

local function makeEditBox(initial)
    return {
        text = initial or "",
        GetText = function(self) return self.text or "" end,
        SetText = function(self, value)
            self.text = value or ""
            state.tradeSkill.nameFilter = self.text
        end,
    }
end

local function itemLink(itemID, name)
    if not itemID then return nil end
    return string.format("|Hitem:%d:0:0:0:0:0:0:0|h[%s]|h", itemID, name or ("Item " .. tostring(itemID)))
end

local function spellLink(spellID, name)
    if not spellID then return nil end
    return string.format("|Henchant:%d|h[%s]|h", spellID, name or ("Spell " .. tostring(spellID)))
end

local function normalizeRosterEntry(entry)
    if realType(entry) == "string" then
        return { name = entry, online = true }
    end
    return entry or {}
end

local function normalizeLastOnlineValue(row, key, legacyKey)
    local value = row[key]
    if value == nil and legacyKey then
        value = row[legacyKey]
    end
    if value == nil and realType(row.lastOnline) == "table" then
        value = row.lastOnline[key]
    end
    return value
end

local function installWowGlobals()
    _G.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, message)
            state.chat[#state.chat + 1] = tostring(message)
        end,
    }

    _G.UIParent = makeFrame(true)
    _G.TradeSkillFrame = makeFrame(false)
    _G.CraftFrame = makeFrame(false)
    _G.TradeSkillFilterBox = makeEditBox("")
    _G.TradeSkillFrameAvailableFilterCheckButton = makeCheckButton()
    _G.TradeSkillFrameFilterSkillUps = makeCheckButton()

    _G.time = function() return math.floor(state.now) end
    _G.GetTime = function() return state.now end
    _G.max = math.max
    _G.min = math.min
    _G.debugprofilestop = function()
        state.perfNowMs = (state.perfNowMs or (state.now * 1000)) + 0.1
        return state.perfNowMs
    end
    _G.date = function(format, value) return realDate(format, value or math.floor(state.now)) end

    _G.GetRealmName = function() return state.realm end
    _G.GetAddOnMetadata = function(addonName, field)
        if addonName ~= "RecipeRegistry" then
            return nil
        end
        local metadata = state.addonMetadata or {}
        return metadata[field]
    end
    _G.UnitFullName = function(unit)
        if unit == "player" then return state.playerName, state.realm end
        return nil
    end
    _G.IsInGuild = function() return state.inGuild == true end
    _G.IsInRaid = function() return state.inRaid == true end
    _G.GetNumRaidMembers = function() return state.inRaid and 1 or 0 end
    _G.InCombatLockdown = function() return state.inCombat == true end
    _G.IsInInstance = function() return state.inInstance == true, state.instanceType or "none" end

    _G.GuildRoster = function()
        state.guildRosterRequested = state.guildRosterRequested + 1
    end
    _G.C_GuildInfo = {
        GuildRoster = _G.GuildRoster,
    }
    _G.GetNumGuildMembers = function()
        return #state.guildRoster
    end
    _G.GetGuildRosterInfo = function(index)
        local row = normalizeRosterEntry(state.guildRoster[index])
        if not row then return nil end
        return row.name,
            row.rankName,
            row.rankIndex,
            row.level,
            row.classDisplayName,
            row.zone,
            row.publicNote,
            row.officerNote,
            row.online,
            row.status,
            row.classFileName
    end
    _G.GetGuildRosterLastOnline = function(index)
        if state.guildRosterLastOnlineAvailable == false then
            return nil
        end
        local row = normalizeRosterEntry(state.guildRoster[index])
        if not row then return nil end
        return normalizeLastOnlineValue(row, "yearsOffline", "years"),
            normalizeLastOnlineValue(row, "monthsOffline", "months"),
            normalizeLastOnlineValue(row, "daysOffline", "days"),
            normalizeLastOnlineValue(row, "hoursOffline", "hours")
    end

    _G.GetNumSkillLines = function()
        return #state.skillLines
    end
    _G.GetSkillLineInfo = function(index)
        local row = state.skillLines[index] or {}
        return row.name,
            row.isHeader == true,
            nil,
            row.skillRank or 0,
            nil,
            nil,
            row.skillMaxRank or 0
    end

    _G.GetSpellInfo = function(spellID)
        return state.spells[spellID] or PROFESSION_SPELLS[spellID] or ("Spell " .. tostring(spellID))
    end
    _G.IsSpellKnown = function(spellID)
        return state.knownSpells[spellID] == true
    end
    _G.GetSpellTexture = function(spellID)
        return "spell-icon-" .. tostring(spellID)
    end
    _G.GetItemInfo = function(itemID)
        itemID = tonumber(itemID)
        local item = state.items[itemID] or {}
        local name = item.name or ("Item " .. tostring(itemID))
        local link = item.link or itemLink(itemID, name)
        return name, link, item.quality or 1, nil, nil, nil, nil, nil, nil, item.icon or ("item-icon-" .. tostring(itemID)), nil, nil, nil, item.bindType
    end
    _G.GetItemInfoInstant = function(itemID)
        return tonumber(itemID), nil, nil, nil, "item-icon-" .. tostring(itemID)
    end

    _G.GetTradeSkillLine = function()
        return state.tradeSkill.title
    end
    _G.GetNumTradeSkills = function()
        return #state.tradeSkill.entries
    end
    _G.GetTradeSkillInfo = function(index)
        local row = state.tradeSkill.entries[index] or {}
        return row.name,
            row.type,
            nil,
            row.expanded ~= false
    end
    _G.GetTradeSkillItemLink = function(index)
        local row = state.tradeSkill.entries[index] or {}
        return row.itemLink or itemLink(row.itemID, row.name)
    end
    _G.GetTradeSkillRecipeLink = function(index)
        local row = state.tradeSkill.entries[index] or {}
        return row.recipeLink or spellLink(row.spellID, row.name)
    end
    _G.ExpandTradeSkillSubClass = function(index)
        if state.tradeSkill.entries[index] then state.tradeSkill.entries[index].expanded = true end
    end
    _G.CollapseTradeSkillSubClass = function(index)
        if state.tradeSkill.entries[index] then state.tradeSkill.entries[index].expanded = false end
    end
    _G.TradeSkillFrame_Update = function() end
    _G.GetTradeSkillSubClasses = function()
        return unpack(state.tradeSkill.subclasses)
    end
    _G.GetTradeSkillSubClassFilter = function(index)
        return state.tradeSkill.subclassFilter == 0 or state.tradeSkill.subclassFilter == index
    end
    _G.SetTradeSkillSubClassFilter = function(index)
        state.tradeSkill.subclassFilter = index or 0
    end
    _G.GetTradeSkillInvSlots = function()
        return unpack(state.tradeSkill.invSlots)
    end
    _G.GetTradeSkillInvSlotFilter = function(index)
        return state.tradeSkill.invSlotFilter == 0 or state.tradeSkill.invSlotFilter == index
    end
    _G.SetTradeSkillInvSlotFilter = function(index)
        state.tradeSkill.invSlotFilter = index or 0
    end
    _G.GetTradeSkillItemNameFilter = function()
        return state.tradeSkill.nameFilter or ""
    end
    _G.SetTradeSkillItemNameFilter = function(value)
        state.tradeSkill.nameFilter = value or ""
        _G.TradeSkillFilterBox.text = state.tradeSkill.nameFilter
    end
    _G.GetTradeSkillItemLevelFilter = function()
        return state.tradeSkill.itemLevelMin or 0, state.tradeSkill.itemLevelMax or 0
    end
    _G.SetTradeSkillItemLevelFilter = function(minLevel, maxLevel)
        state.tradeSkill.itemLevelMin = minLevel or 0
        state.tradeSkill.itemLevelMax = maxLevel or 0
    end
    _G.TradeSkillOnlyShowMakeable = function(value)
        state.tradeSkill.onlyMakeable = value == true
        _G.TradeSkillFrameAvailableFilterCheckButton:SetChecked(state.tradeSkill.onlyMakeable)
    end
    _G.TradeSkillOnlyShowSkillUps = function(value)
        state.tradeSkill.onlySkillUps = value == true
        _G.TradeSkillFrameFilterSkillUps:SetChecked(state.tradeSkill.onlySkillUps)
    end

    _G.GetCraftSkillLine = function(index)
        if index ~= nil and index <= 0 then return nil end
        return state.craftSkill.title
    end
    _G.GetCraftDisplaySkillLine = function()
        if state.craftSkill.title == "Beast Training" then return nil end
        return state.craftSkill.title
    end
    _G.GetNumCrafts = function()
        return #state.craftSkill.entries
    end
    _G.GetCraftInfo = function(index)
        local row = state.craftSkill.entries[index] or {}
        return row.name, row.subSpellName, row.type, row.numAvailable, row.isExpanded, row.trainingPointCost, row.requiredLevel
    end
    _G.GetCraftItemLink = function(index)
        local row = state.craftSkill.entries[index] or {}
        return row.itemLink or itemLink(row.itemID, row.name)
    end
    _G.GetCraftRecipeLink = function(index)
        local row = state.craftSkill.entries[index] or {}
        return row.recipeLink or spellLink(row.spellID, row.name)
    end
    _G.GetCraftItemNameFilter = function()
        return state.craftSkill.nameFilter or ""
    end
    _G.SetCraftItemNameFilter = function(value)
        state.craftSkill.nameFilter = value or ""
    end
    _G.CraftFrame_Update = function() end

    -- Mailbox API (TBC 2.5.x surface). The harness mailbox is a passive
    -- container: tests call Wow.OpenMailbox / Wow.AddInboxMail /
    -- Wow.GetSentMail to drive scenarios, and the production code
    -- reads/writes the same state via the WoW-compatible globals.
    local function mb() return state.mailbox end
    _G.HasNewMail        = function() return #mb().inbox > 0 end
    _G.GetInboxNumItems  = function() return #mb().inbox end
    _G.GetInboxHeaderInfo = function(index)
        local mail = mb().inbox[index]
        if not mail then return nil end
        -- Real signature: packageIcon, stationaryIcon, sender, subject,
        -- money, CODAmount, daysLeft, itemCount, wasRead, wasReturned,
        -- textCreated, canReply, isGM. We return only what the addon
        -- consumes; unused slots are nil.
        local itemCount = mail.items and #mail.items or 0
        return nil, nil, mail.sender, mail.subject,
            mail.money or 0, mail.codAmount or 0,
            mail.daysLeft or 30, itemCount,
            mail.wasRead == true, mail.wasReturned == true,
            true, mail.canReply ~= false, false
    end
    _G.GetInboxText = function(index)
        local mail = mb().inbox[index]
        if not mail then return "" end
        return mail.body or "", nil, nil, nil, nil
    end
    _G.GetInboxItem = function(index, attachIndex)
        local mail = mb().inbox[index]
        if not (mail and mail.items) then return nil end
        local item = mail.items[attachIndex]
        if not item then return nil end
        -- Real signature: name, itemID, texture, count, quality,
        -- canUse, isQuestItem, ...
        return item.name or ("item:" .. tostring(item.itemID)),
            item.itemID, item.texture, item.count or 1,
            item.quality or 1, true, false
    end
    _G.GetInboxItemLink = function(index, attachIndex)
        local mail = mb().inbox[index]
        if not (mail and mail.items) then return nil end
        local item = mail.items[attachIndex]
        if not item then return nil end
        return item.link or string.format("|Hitem:%d|h[%s]|h",
            item.itemID or 0, item.name or "item")
    end
    _G.TakeInboxItem = function(index, attachIndex)
        local mail = mb().inbox[index]
        if not (mail and mail.items) then return end
        mail.items[attachIndex] = nil
    end
    _G.TakeInboxMoney = function(index)
        local mail = mb().inbox[index]
        if not mail then return end
        mail.money = 0
    end
    _G.DeleteInboxItem = function(index)
        table.remove(mb().inbox, index)
    end

    _G.SendMail = function(recipient, subject, body)
        local out = mb().outgoing
        local attachments = {}
        for slotIndex = 1, #out.attachments do
            attachments[slotIndex] = out.attachments[slotIndex]
        end
        mb().sent[#mb().sent + 1] = {
            recipient   = recipient,
            subject     = subject,
            body        = body,
            attachments = attachments,
            sentAt      = state.now,
        }
        out.recipient = ""
        out.subject = ""
        out.body = ""
        out.attachments = {}
        -- WoW fires MAIL_SEND_SUCCESS on a successful send. Tests that
        -- exercise the addon's handler can dispatch it via
        -- Wow.DeliverEvent(plugin, "MAIL_SEND_SUCCESS") after the
        -- SendMail call so the wiring is explicit.
    end
    _G.ClickSendMailItemButton = function(slotIndex, ...)
        -- Production code sets state.cursorItem first; we mirror that
        -- by reading it. Tests can also call Wow.QueueOutgoingAttachment
        -- to skip the cursor dance.
        local cursor = state.cursorItem
        if not cursor then return end
        local slot = slotIndex or (#mb().outgoing.attachments + 1)
        mb().outgoing.attachments[slot] = {
            itemID = cursor.itemID,
            count  = cursor.count or 1,
            name   = cursor.name,
        }
        state.cursorItem = nil
    end
    _G.GetSendMailItem = function(slot)
        local item = mb().outgoing.attachments[slot]
        if not item then return nil end
        return item.name or ("item:" .. tostring(item.itemID)),
            item.itemID, nil, item.count or 1, 1
    end
    _G.GetSendMailItemLink = function(slot)
        local item = mb().outgoing.attachments[slot]
        if not item then return nil end
        return string.format("|Hitem:%d|h[%s]|h",
            item.itemID or 0, item.name or "item")
    end
    _G.SetSendMailCOD     = function(_amount) end
    _G.SetSendMailMoney   = function(_amount) end
    _G.GetSendMailMoney   = function() return 0 end
    _G.GetSendMailCOD     = function() return 0 end
end

function Wow.Reset(opts)
    opts = opts or {}
    state = {
        now = 1700000000,
        nextTimerId = 0,
        perfNowMs = 1700000000000,
        timers = {},
        prints = {},
        chat = {},
        sentComm = {},
        realm = "TestRealm",
        playerName = "Tester",
        inGuild = true,
        inCombat = false,
        inRaid = false,
        inInstance = false,
        instanceType = "none",
        guildRosterRequested = 0,
        guildRoster = {},
        guildRosterLastOnlineAvailable = true,
        skillLines = {},
        items = {},
        spells = {},
        knownSpells = {},
        tradeSkill = {
            title = nil,
            entries = {},
            subclasses = { "All" },
            invSlots = { "All" },
            subclassFilter = 0,
            invSlotFilter = 0,
            nameFilter = "",
            itemLevelMin = 0,
            itemLevelMax = 0,
            onlyMakeable = false,
            onlySkillUps = false,
        },
        craftSkill = {
            title = nil,
            entries = {},
            nameFilter = "",
        },
        mailbox = {
            isOpen   = false,
            inbox    = {},
            sent     = {},
            outgoing = { subject = "", body = "", recipient = "", attachments = {} },
        },
        payloadMode = opts.payloadMode or "table-fast",
        addonMetadata = deepcopy(opts.addonMetadata or {
            Version = "2.0.0",
            ["X-Build-Channel"] = "release",
            ["X-Build-ID"] = "test-build",
        }),
    }

    _G.RecipeRegistry = nil
    _G.RecipeRegistryDB = nil
    _G.RecipeRegistryCharDB = nil
    _G.RecipeRegistry_Orders = nil
    _G.RecipeRegistry_OrdersDB = nil
    _G.RecipeRegistry_OrdersCharDB = nil
    _G.RecipeRegistry_OrdersLogDB = nil
    _G.RecipeRegistryRecipeMetadata = nil
    _G.RecipeRegistryRecipeMetadataOverrides = nil
    _G.__RecipeRegistrySerializedValues = {}
    _G.__RecipeRegistrySerializedNextId = 0

    installLibStub()
    installWowGlobals()
    return state
end

function Wow.Configure(opts)
    opts = opts or {}
    if opts.payloadMode then
        state.payloadMode = opts.payloadMode
    end
    if opts.addonMetadata then
        state.addonMetadata = deepcopy(opts.addonMetadata)
    end
    return state
end

function Wow.GetState()
    return state
end

function Wow.GetPayloadMode()
    return state and state.payloadMode or "table-fast"
end

function Wow.UseState(nextState)
    if not nextState then
        error("Wow.UseState requires a state table", 2)
    end
    state = nextState
    return state
end

function Wow.WithState(nextState, fn, ...)
    if realType(fn) ~= "function" then
        error("Wow.WithState requires a callback", 2)
    end
    local previous = state
    Wow.UseState(nextState)
    local result = { pcall(fn, ...) }
    if previous then
        Wow.UseState(previous)
    end
    if not result[1] then
        error(result[2], 2)
    end
    return unpack(result, 2)
end

function Wow.SetPlayer(name, realm)
    state.playerName = name or state.playerName
    state.realm = realm or state.realm
end

function Wow.SetAddonMetadata(metadata)
    state.addonMetadata = deepcopy(metadata or {})
end

function Wow.SetGuildRoster(rows)
    state.guildRoster = deepcopy(rows or {})
end

function Wow.SetGuildRosterLastOnlineAvailable(value)
    state.guildRosterLastOnlineAvailable = value ~= false
end

function Wow.SetCombat(value)
    state.inCombat = value == true
end

function Wow.SetRaid(value)
    state.inRaid = value == true
end

function Wow.SetInstance(value, instanceType)
    state.inInstance = value == true
    state.instanceType = instanceType or (state.inInstance and "party" or "none")
end

function Wow.SetSkillLines(rows)
    state.skillLines = deepcopy(rows or {})
end

function Wow.SetKnownSpells(spellIDs)
    state.knownSpells = {}
    for _, spellID in ipairs(spellIDs or {}) do
        state.knownSpells[spellID] = true
    end
end

function Wow.SetTradeSkill(title, rows, opts)
    opts = opts or {}
    state.tradeSkill.title = title
    state.tradeSkill.entries = deepcopy(rows or {})
    state.tradeSkill.subclasses = deepcopy(opts.subclasses or { "All" })
    state.tradeSkill.invSlots = deepcopy(opts.invSlots or { "All" })
    state.tradeSkill.subclassFilter = opts.subclassFilter or 0
    state.tradeSkill.invSlotFilter = opts.invSlotFilter or 0
    state.tradeSkill.nameFilter = opts.nameFilter or ""
    _G.TradeSkillFilterBox.text = state.tradeSkill.nameFilter
    _G.TradeSkillFrame.shown = opts.shown ~= false
end

function Wow.SetCraftSkill(title, rows, opts)
    opts = opts or {}
    state.craftSkill.title = title
    state.craftSkill.entries = deepcopy(rows or {})
    state.craftSkill.nameFilter = opts.nameFilter or ""
    _G.CraftFrame.shown = opts.shown ~= false
end

function Wow.AdvanceTime(seconds)
    state.now = state.now + (seconds or 0)
end

function Wow.RunTimers(maxRuns)
    maxRuns = maxRuns or 100
    local ran = 0
    while ran < maxRuns do
        local index, timer = sortedTimerIndex()
        if not timer then break end
        table.remove(state.timers, index)
        if timer.dueAt > state.now then state.now = timer.dueAt end
        if not timer.cancelled then
            ran = ran + 1
            callScheduled(timer.owner, timer.callback)
            if timer.repeating and not timer.cancelled then
                timer.dueAt = state.now + (timer.delay or 0)
                state.timers[#state.timers + 1] = timer
            end
        end
    end
    return ran
end

function Wow.RunDueTimers(maxRuns)
    maxRuns = maxRuns or 100
    local ran = 0
    while ran < maxRuns do
        local index, timer = sortedTimerIndex()
        if not timer or timer.dueAt > state.now then break end
        table.remove(state.timers, index)
        if not timer.cancelled then
            ran = ran + 1
            callScheduled(timer.owner, timer.callback)
            if timer.repeating and not timer.cancelled then
                timer.dueAt = state.now + (timer.delay or 0)
                state.timers[#state.timers + 1] = timer
            end
        end
    end
    return ran
end

function Wow.GetPrints()
    return state.prints
end

function Wow.GetChatMessages()
    return state.chat
end

function Wow.GetSentComm()
    return state.sentComm
end

function Wow.DeliverComm(module, payload, opts)
    opts = opts or {}
    local target = module or (_G.RecipeRegistry and _G.RecipeRegistry.Sync)
    if not target or realType(target.OnCommReceived) ~= "function" then
        error("Wow.DeliverComm requires a module with OnCommReceived", 2)
    end
    local serializer = LibStub("AceSerializer-3.0")
    local message = serializer:Serialize(deepcopy(payload or {}))
    local prefix = opts.prefix or (_G.RecipeRegistry and _G.RecipeRegistry.ADDON_PREFIX) or "RecipeRegistry"
    local distribution = opts.distribution or "WHISPER"
    local sender = opts.sender or (payload and payload.sender) or state.playerName
    target:OnCommReceived(prefix, message, distribution, sender)
    return message
end

-- Mailbox helpers. Production code uses the WoW-compatible globals
-- installed above; these are for tests that need to script the
-- mailbox state directly (open the window, drop a fake mail in the
-- inbox, inspect what SendMail captured).

function Wow.OpenMailbox()
    state.mailbox.isOpen = true
end

function Wow.CloseMailbox()
    state.mailbox.isOpen = false
end

function Wow.IsMailboxOpen()
    return state.mailbox.isOpen == true
end

-- Appends a mail to the inbox. Spec accepts the human-facing fields
-- (sender, subject, body, items) plus optional metadata. Returns the
-- inbox index of the new mail.
function Wow.AddInboxMail(spec)
    spec = spec or {}
    local mail = {
        sender      = spec.sender or "Unknown-Realm",
        subject     = spec.subject or "",
        body        = spec.body or "",
        money       = spec.money or 0,
        codAmount   = spec.codAmount or 0,
        daysLeft    = spec.daysLeft or 30,
        wasRead     = spec.wasRead == true,
        wasReturned = spec.wasReturned == true,
        canReply    = spec.canReply ~= false,
        items       = deepcopy(spec.items or {}),
    }
    table.insert(state.mailbox.inbox, mail)
    return #state.mailbox.inbox
end

function Wow.GetSentMail()
    return state.mailbox.sent
end

function Wow.ClearSentMail()
    state.mailbox.sent = {}
end

-- Simulates dropping an item onto the cursor so the next
-- ClickSendMailItemButton call picks it up. Used by tests that
-- exercise the outgoing-mail attachment flow.
function Wow.PutItemOnCursor(item)
    state.cursorItem = item and deepcopy(item) or nil
end

function Wow.GetSendMailOutgoing()
    return state.mailbox.outgoing
end

function Wow.DeliverEvent(target, event, ...)
    local addon = target or _G.RecipeRegistry
    if not addon then
        error("Wow.DeliverEvent requires an addon target", 2)
    end

    deliverRegisteredEvent(addon, event, ...)
    for _, module in ipairs(addon.__moduleOrder or {}) do
        deliverRegisteredEvent(module, event, ...)
    end
end

Wow.Reset()

return Wow
